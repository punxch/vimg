import 'dart:typed_data';

import 'nal.dart';
import 'parameters.dart';
import 'slice_header.dart';

/// HEVCDecoderConfigurationRecord (hvcC) and its length-prefixed samples.
final class HevcConfiguration {
  HevcConfiguration.inBand(Uint8List parameterSets) : lengthBytes = 4 {
    final units = nals(parameterSets).toList();
    for (final type in [32, 33, 34]) {
      for (final nal in units) {
        if (nal.header.type == type) store(nal);
      }
    }
  }

  HevcConfiguration(Uint8List record) {
    if (record.length < 23 ||
        record[0] != 1 ||
        record[13] & 0xf0 != 0xf0 ||
        record[15] & 0xfc != 0xfc ||
        record[16] & 0xfc != 0xfc ||
        record[17] & 0xf8 != 0xf8 ||
        record[18] & 0xf8 != 0xf8) {
      throw const FormatException('Invalid HEVC configuration');
    }
    lengthBytes = (record[21] & 3) + 1;
    if (lengthBytes == 3)
      throw const FormatException('Invalid HEVC NAL length width');
    final parameterSets = <int, List<HevcNal>>{};
    var offset = 23;
    final view = ByteData.sublistView(record);
    for (var i = 0; i < record[22]; i++) {
      if (offset + 3 > record.length || record[offset] & 0x40 != 0) {
        throw const FormatException('Invalid HEVC configuration array');
      }
      final type = record[offset] & 63;
      final count = view.getUint16(offset + 1);
      offset += 3;
      for (var j = 0; j < count; j++) {
        if (offset + 2 > record.length)
          throw const FormatException('Truncated HEVC configuration');
        final size = view.getUint16(offset);
        offset += 2;
        if (size < 2 || size > record.length - offset)
          throw const FormatException('Invalid HEVC configuration NAL size');
        final nal = HevcNal(
          Uint8List.sublistView(record, offset, offset + size),
        );
        if (nal.header.type != type)
          throw const FormatException('HEVC configuration NAL type mismatch');
        if (type >= 32 && type <= 34)
          parameterSets.putIfAbsent(type, () => []).add(nal);
        offset += size;
      }
    }
    if (offset != record.length)
      throw const FormatException('Unexpected bytes in HEVC configuration');
    for (final type in [32, 33, 34]) {
      for (final nal in parameterSets[type] ?? const <HevcNal>[]) {
        store(nal);
      }
    }
  }

  late final int lengthBytes;
  final videos = <int, HevcVps>{};
  final sequences = <int, HevcSps>{};
  final pictures = <int, HevcPps>{};

  void store(HevcNal nal) {
    if (nal.header.layer != 0) return;
    switch (nal.header.type) {
      case 32:
        final vps = HevcVps.parse(nal);
        videos[vps.id] = vps;
      case 33:
        final sps = HevcSps.parse(nal);
        sequences[sps.id] = sps;
      case 34:
        final pps = HevcPps.parse(nal, sequences);
        pictures[pps.id] = pps;
    }
  }

  List<HevcSliceHeader> slices(Uint8List sample) {
    final result = <HevcSliceHeader>[];
    for (final nal in nals(sample)) {
      if (nal.header.layer != 0) continue;
      if (!nal.header.codedSlice) {
        store(nal);
        continue;
      }
      final previous = result.lastOrNull;
      final slice = HevcSliceHeader.parse(
        nal,
        sequences,
        pictures,
        preceding: previous,
      );
      if (slice.first != (previous == null) ||
          (previous != null &&
              (previous.pps != slice.pps ||
                  previous.sps != slice.sps ||
                  previous.nal.type != slice.nal.type ||
                  previous.nal.temporalId != slice.nal.temporalId ||
                  previous.parameters.pocLsb != slice.parameters.pocLsb))) {
        throw const FormatException(
          'HEVC sample contains unrelated slice segments',
        );
      }
      result.add(slice);
    }
    return result;
  }

  Iterable<HevcNal> nals(Uint8List sample) sync* {
    final data = ByteData.sublistView(sample);
    int read(int offset, int width) => switch (width) {
      1 => data.getUint8(offset),
      2 => data.getUint16(offset),
      _ => data.getUint32(offset),
    };
    for (final nal in _extents(0, sample.length, read)) {
      yield HevcNal(Uint8List.sublistView(sample, nal.start, nal.end));
    }
  }

  bool containsRandomAccess(
    int start,
    int length,
    int Function(int, int) read,
  ) => pictureHeader(start, length, read)?.randomAccess == true;

  HevcNalHeader? pictureHeader(
    int start,
    int length,
    int Function(int, int) read,
  ) {
    for (final extent in _extents(start, length, read)) {
      final header = readHevcNalHeader(read(extent.start, 2));
      if (header.layer != 0 || !header.codedSlice) continue;
      if (extent.end - extent.start < 3)
        throw const FormatException('Missing HEVC slice payload');
      if (read(extent.start + 2, 1) & 0x80 == 0)
        throw const FormatException(
          'HEVC sample starts with a partial picture',
        );
      return header;
    }
    return null;
  }

  Iterable<({int start, int end})> _extents(
    int offset,
    int length,
    int Function(int, int) read,
  ) sync* {
    final end = offset + length;
    while (offset < end) {
      if (end - offset < lengthBytes)
        throw const FormatException('Truncated HEVC NAL length');
      final size = read(offset, lengthBytes);
      offset += lengthBytes;
      if (size < 2 || size > end - offset)
        throw const FormatException('Invalid HEVC sample NAL length');
      yield (start: offset, end: offset + size);
      offset += size;
    }
  }
}
