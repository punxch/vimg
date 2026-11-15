import 'dart:typed_data';

import '../rbsp.dart';
import 'parameters.dart';

typedef H264FieldKey = ({
  int sequence,
  int frameNum,
  bool bottom,
  bool reference,
});

bool complementaryH264Fields(H264FieldKey a, H264FieldKey b) =>
    a.sequence == b.sequence &&
    a.frameNum == b.frameNum &&
    a.reference == b.reference &&
    a.bottom != b.bottom;

/// Read just the picture boundary fields from a slice NAL prefix.
({int? colorPlane, H264FieldKey? field})? probeAvcSlice(
  Uint8List nal,
  H264Sps? Function(int) sequence,
) {
  final bits = Rbsp.fromNal(nal);
  bits.ue(); // first_mb_in_slice
  bits.ue(9); // slice_type
  final sps = sequence(bits.ue(255));
  if (sps == null) return null;
  final plane = sps.separateColorPlane ? bits.read(2) : null;
  if (plane == 3) {
    throw const FormatException('Invalid H.264 slice color plane');
  }
  H264FieldKey? field;
  if (!sps.frameOnly) {
    final frameNum = bits.read(sps.frameNumBits);
    if (bits.flag()) {
      field = (
        sequence: sps.id,
        frameNum: frameNum,
        bottom: bits.flag(),
        reference: nal[0] & 0x60 != 0,
      );
    }
  }
  return (colorPlane: plane, field: field);
}

/// AVCDecoderConfigurationRecord and length-prefixed samples used by AVC in
/// Matroska and ISO BMFF. Parameter sets carried in avc3 samples can replace
/// the sets stored in the container.
final class AvcConfiguration {
  AvcConfiguration.inBand(Uint8List parameterSets) : lengthBytes = 4 {
    applyParameterSets(parameterSets);
  }

  void applyParameterSets(Uint8List parameterSets) {
    final units = nals(parameterSets).toList();
    for (final type in [7, 8]) {
      for (final nal in units) {
        if (nal[0] & 31 == type) store(nal);
      }
    }
  }

  AvcConfiguration(Uint8List avcC) {
    if (avcC.length < 7 ||
        avcC[0] != 1 ||
        avcC[4] & 0xfc != 0xfc ||
        avcC[5] & 0xe0 != 0xe0) {
      throw const FormatException('Invalid H.264 AVC configuration');
    }
    lengthBytes = (avcC[4] & 3) + 1;
    if (lengthBytes == 3)
      throw const FormatException('Invalid H.264 NAL length width');
    var offset = 6;
    Uint8List readNal() {
      if (offset + 2 > avcC.length)
        throw const FormatException('Truncated H.264 AVC configuration');
      final size = (avcC[offset] << 8) | avcC[offset + 1];
      offset += 2;
      if (size == 0 || size > avcC.length - offset) {
        throw const FormatException('Truncated H.264 parameter set');
      }
      final nal = Uint8List.sublistView(avcC, offset, offset + size);
      offset += size;
      return nal;
    }

    for (var i = 0; i < (avcC[5] & 31); i++) {
      store(readNal());
    }
    if (offset == avcC.length)
      throw const FormatException('Missing H.264 PPS count');
    final count = avcC[offset++];
    for (var i = 0; i < count; i++) {
      store(readNal());
    }
  }

  late final int lengthBytes;
  final sequences = <int, H264Sps>{};
  final pictures = <int, H264Pps>{};
  final _sequenceNals = <int, Uint8List>{};

  (int, int)? store(Uint8List nal) {
    if (nal.isEmpty) throw const FormatException('Empty H.264 NAL unit');
    final type = nal[0] & 31;
    switch (type) {
      case 7:
        final sps = H264Sps.parse(nal);
        final previous = _sequenceNals[sps.id];
        if (previous == null ||
            previous.length != nal.length ||
            nal.indexed.any((entry) => entry.$2 != previous[entry.$1])) {
          _sequenceNals[sps.id] = Uint8List.fromList(nal);
          sequences[sps.id] = sps;
        }
        return (type, sps.id);
      case 8:
        final pps = H264Pps.parse(nal, sequences);
        pictures[pps.id] = pps;
        return (type, pps.id);
    }
    return null;
  }

  Iterable<Uint8List> nals(Uint8List sample) sync* {
    int read(int offset, int width) {
      var value = 0;
      for (var i = 0; i < width; i++) {
        value = (value << 8) | sample[offset + i];
      }
      return value;
    }

    for (final nal in _extents(0, sample.length, read)) {
      yield Uint8List.sublistView(sample, nal.start, nal.end);
    }
  }

  ({int type, H264FieldKey? field})? sampleHeader(
    int start,
    int length,
    int Function(int offset, int width) read, {
    required Uint8List Function(int, int) readBytes,
    void Function(int start, int length)? onParameterSet,
  }) {
    int? type;
    H264FieldKey? field;
    for (final nal in _extents(start, length, read)) {
      switch (nal.type) {
        case 7 || 8:
          onParameterSet?.call(nal.start, nal.end - nal.start);
        case 1 || 2 || 5:
          if (type == null && sequences.values.every((sps) => sps.frameOnly)) {
            return (type: nal.type, field: null);
          }
          final length = nal.end - nal.start;
          final header = probeAvcSlice(
            readBytes(nal.start, length < 16 ? length : 16),
            (id) => pictures[id]?.sps,
          );
          if (type == null) {
            type = nal.type;
            field = header?.field;
            if (field == null) return (type: type, field: null);
          } else if (header?.field case final other?) {
            if (complementaryH264Fields(field!, other)) {
              return (type: type, field: null);
            }
          }
      }
    }
    return type == null ? null : (type: type, field: field);
  }

  Iterable<({int start, int end, int type})> _extents(
    int offset,
    int length,
    int Function(int offset, int width) read,
  ) sync* {
    final end = offset + length;
    while (offset < end) {
      if (end - offset < lengthBytes) {
        throw const FormatException('Truncated H.264 NAL length');
      }
      final size = read(offset, lengthBytes);
      offset += lengthBytes;
      if (size < 1 || size > end - offset) {
        throw const FormatException('Invalid H.264 sample NAL length');
      }
      final header = read(offset, 1);
      if (header & 0x80 != 0)
        throw const FormatException('Invalid H.264 NAL header');
      yield (start: offset, end: offset + size, type: header & 31);
      offset += size;
    }
  }
}
