import 'dart:typed_data';

import 'parameters.dart';

/// AVCDecoderConfigurationRecord and length-prefixed samples used by AVC in
/// Matroska and ISO BMFF. Parameter sets carried in avc3 samples can replace
/// the sets stored in the container.
final class AvcConfiguration {
  AvcConfiguration.inBand(Uint8List parameterSets) : lengthBytes = 4 {
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

  void store(Uint8List nal) {
    if (nal.isEmpty) throw const FormatException('Empty H.264 NAL unit');
    switch (nal[0] & 31) {
      case 7:
        final sps = H264Sps.parse(nal);
        sequences[sps.id] = sps;
      case 8:
        final pps = H264Pps.parse(nal, sequences);
        pictures[pps.id] = pps;
    }
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

  bool containsIdr(
    int start,
    int length,
    int Function(int offset, int width) read,
  ) => _extents(start, length, read).any((nal) => nal.type == 5);

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
