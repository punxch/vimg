import 'dart:typed_data';

import 'parameters.dart';
import 'rbsp.dart';

/// AVCDecoderConfigurationRecord and length-prefixed samples used by AVC in
/// Matroska and ISO BMFF. Parameter sets carried in avc3 samples can replace
/// the sets stored in the container.
final class AvcConfiguration {
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

final class IdrSlice {
  IdrSlice(Uint8List nal, Map<int, H264Pps> pictures)
    : bits = Rbsp.fromNal(nal) {
    if (nal[0] & 31 != 5 || nal[0] & 0x60 == 0) {
      throw const FormatException('Expected an H.264 IDR slice');
    }
    firstMb = bits.ue();
    if (bits.ue(9) % 5 != 2)
      throw const FormatException('H.264 IDR slice is not intra');
    final picture = pictures[bits.ue(255)];
    if (picture == null)
      throw const FormatException('H.264 slice references a missing PPS');
    pps = picture;
    final sps = pps.sps;
    if (!sps.frameOnly || pps.sliceGroups != 1 || sps.separateColorPlane) {
      throw UnsupportedError(
        'Interlaced and slice-group H.264 pictures are unavailable',
      );
    }
    frameNum = bits.read(sps.frameNumBits);
    idrId = bits.ue(65535);
    if (sps.pocType == 0) {
      pocLsb = bits.read(sps.pocLsbBits);
      if (pps.bottomFieldPocPresent) bits.se();
    } else if (sps.pocType == 1 && !sps.deltaPocAlwaysZero) {
      bits.se();
      if (pps.bottomFieldPocPresent) bits.se();
    }
    if (pps.redundantPicCount && bits.ue(127) != 0) {
      throw UnsupportedError('Redundant H.264 slices are unavailable');
    }
    bits.read(2); // no_output_of_prior_pics_flag and long_term_reference_flag
    qp = pps.initialQp + bits.se();
    if (qp < -6 * (sps.lumaDepth - 8) ||
        qp > 51 ||
        firstMb >= sps.mbWidth * sps.mbHeight) {
      throw const FormatException(
        'Invalid H.264 slice QP or macroblock address',
      );
    }
    if (pps.deblockingControl) {
      deblocking = bits.ue(2);
      if (deblocking != 1) {
        alphaOffset = 2 * bits.se();
        betaOffset = 2 * bits.se();
        if (alphaOffset.abs() > 12 || betaOffset.abs() > 12) {
          throw const FormatException('Invalid H.264 deblocking offset');
        }
      }
    }
    if (pps.cabac) bits.align(1);
  }

  final Rbsp bits;
  late final int firstMb, frameNum, idrId, qp;
  int? pocLsb;
  late final H264Pps pps;
  var deblocking = 0, alphaOffset = 0, betaOffset = 0;
}
