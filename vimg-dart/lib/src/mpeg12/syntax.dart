import 'dart:typed_data';

import '../rbsp.dart';

typedef MpegStartCode = ({int code, int start, int data, int end});

bool isMpegVideo(String codec) =>
    codec == 'mpeg1video' || codec == 'mpeg2video';

/// H.262 §6.2.1. Start codes are aligned to bytes in the elementary stream.
Iterable<MpegStartCode> mpegStartCodes(Uint8List bytes) sync* {
  var code = -1, start = 0, data = 0;
  for (var i = 2; i + 1 < bytes.length; i++) {
    if (bytes[i] != 1 || bytes[i - 1] != 0 || bytes[i - 2] != 0) continue;
    if (code >= 0) yield (code: code, start: start, data: data, end: i - 2);
    code = bytes[++i];
    start = i - 3;
    data = i + 1;
  }
  if (code >= 0)
    yield (code: code, start: start, data: data, end: bytes.length);
}

Rbsp mpegBits(Uint8List bytes) => Rbsp(bytes, codec: 'MPEG video');

void mpegMarker(Rbsp bits) {
  if (!bits.flag())
    throw const FormatException('Missing MPEG video marker bit');
}

final class MpegSequence {
  MpegSequence(Uint8List header) {
    final bits = mpegBits(header);
    width = bits.read(12);
    height = bits.read(12);
    bits.skip(4); // aspect ratio
    final rate = bits.read(4);
    if (rate < 1 || rate > _rates.length) {
      throw const FormatException('Invalid MPEG video frame rate');
    }
    timing = _rates[rate - 1];
    bits.skip(18); // bit rate
    mpegMarker(bits);
    bits.skip(11); // VBV buffer size and constrained parameters
    final intra = bits.flag() ? _matrix(bits) : _defaultIntra;
    final inter = bits.flag() ? _matrix(bits) : _defaultInter;
    matrices = [intra, inter, intra, inter];
  }

  late int width, height;
  late (int, int) timing; // frame ticks, ticks per second
  late final List<List<int>> matrices;
  bool mpeg2 = false, progressive = true;
  int chroma = 1, matrix = 2;

  void extension(Uint8List payload) {
    final bits = mpegBits(payload);
    switch (bits.read(4)) {
      case 1:
        mpeg2 = true;
        bits.skip(8); // profile and level
        progressive = bits.flag();
        chroma = bits.read(2);
        if (chroma == 0)
          throw const FormatException('Invalid MPEG chroma format');
        width = (bits.read(2) << 12) | width;
        height = (bits.read(2) << 12) | height;
        bits.skip(12); // bit rate extension
        mpegMarker(bits);
        bits.skip(9); // VBV buffer size extension and low delay
        final multiplier = bits.read(2) + 1, divisor = bits.read(5) + 1;
        timing = (timing.$1 * divisor, timing.$2 * multiplier);
      case 2:
        bits.skip(3); // video format
        if (bits.flag()) {
          bits.skip(16); // colour primaries and transfer characteristics
          matrix = bits.read(8);
        }
      case 3:
        // Luma downloads also replace the corresponding chroma matrices.
        // Separate chroma downloads in the same extension take precedence.
        for (var i = 0; i < 4; i++) {
          if (!bits.flag()) continue;
          final matrix = _matrix(bits);
          matrices[i] = matrix;
          if (i < 2) matrices[i + 2] = matrix;
        }
      case 5:
        throw UnsupportedError('Scalable MPEG-2 video is unavailable');
    }
  }
}

final class MpegPictureHeader {
  MpegPictureHeader(Uint8List header) {
    final bits = mpegBits(header);
    bits.skip(10); // temporal reference
    type = bits.read(3);
    if (type < 1 || type > 3) {
      throw UnsupportedError('MPEG picture coding type $type is unavailable');
    }
    bits.skip(16); // VBV delay
    if (type != 1) {
      fullPel[0] = bits.flag();
      final code = bits.read(3);
      motionCode[0] = (code, code);
    }
    if (type == 3) {
      fullPel[1] = bits.flag();
      final code = bits.read(3);
      motionCode[1] = (code, code);
    }
  }

  late final int type;
  final motionCode = [(0, 0), (0, 0)];
  final fullPel = [false, false];
  int precision = 0, structure = 3;
  bool codingExtension = false, framePrediction = true, topFirst = false;
  bool concealment = false, nonlinear = false, alternateVlc = false;
  bool alternateScan = false;

  void extension(Uint8List payload) {
    final bits = mpegBits(payload)..skip(4);
    codingExtension = true;
    for (var i = 0; i < 2; i++) {
      motionCode[i] = (bits.read(4), bits.read(4));
      fullPel[i] = false;
    }
    precision = bits.read(2);
    structure = bits.read(2);
    topFirst = bits.flag();
    framePrediction = bits.flag();
    concealment = bits.flag();
    nonlinear = bits.flag();
    alternateVlc = bits.flag();
    alternateScan = bits.flag();
  }
}

typedef MpegPictureInfo = ({int type, bool closedGop, bool brokenLink});

MpegPictureInfo mpegPictureInfo(Uint8List header, int gopFlags) {
  if (header.length < 2) {
    throw const FormatException('Truncated MPEG picture header');
  }
  return (
    type: (header[1] >> 3) & 7,
    closedGop: gopFlags & 64 != 0,
    brokenLink: gopFlags & 32 != 0,
  );
}

/// Retains the sequence state a decoder needs when seeking to an I-picture.
final class MpegHeaders {
  final _units = <int, Uint8List>{};
  MpegSequence? sequence;
  Uint8List? _configuration;

  void add(int code, Uint8List payload) {
    if (code == 0xb3) {
      sequence = MpegSequence(payload);
      _units
        ..clear()
        ..[0] = Uint8List.fromList([0, 0, 1, code, ...payload]);
      _configuration = null;
    } else if (code == 0xb5 && payload.isNotEmpty && sequence != null) {
      final id = payload[0] >> 4;
      if (id > 5 || id == 4) return;
      sequence!.extension(payload);
      if (id >= 1 && id <= 3) {
        _units[id] = id == 3
            ? _quantizerExtension(sequence!.matrices)
            : Uint8List.fromList([0, 0, 1, code, ...payload]);
        _configuration = null;
      }
    }
  }

  Uint8List configuration() => _configuration ??= Uint8List.fromList([
    for (final id in const [0, 1, 2, 3]) ...?_units[id],
  ]);
}

Uint8List _quantizerExtension(List<List<int>> matrices) {
  // Four complete downloads, ordered so explicit chroma overrides luma.
  // Writing the merged state keeps each snapshot bounded even when a stream
  // updates only one matrix at a time.
  final output = Uint8List(4 + 257);
  output.setRange(0, 4, const [0, 0, 1, 0xb5]);
  var position = 32;
  void write(int value, int count) {
    for (var i = count - 1; i >= 0; i--) {
      output[position >> 3] |= ((value >> i) & 1) << (7 - (position & 7));
      position++;
    }
  }

  write(3, 4);
  for (final matrix in matrices) {
    write(1, 1);
    for (final index in mpegZigzag) {
      write(matrix[index], 8);
    }
  }
  return output;
}

List<int> _matrix(Rbsp bits) {
  final values = Uint8List(64);
  for (final index in mpegZigzag) {
    final value = bits.read(8);
    if (value == 0)
      throw const FormatException('Invalid MPEG quantizer matrix');
    values[index] = value;
  }
  return values;
}

// dart format off
const mpegZigzag = [
  0, 1, 8, 16, 9, 2, 3, 10,
  17, 24, 32, 25, 18, 11, 4, 5,
  12, 19, 26, 33, 40, 48, 41, 34,
  27, 20, 13, 6, 7, 14, 21, 28,
  35, 42, 49, 56, 57, 50, 43, 36,
  29, 22, 15, 23, 30, 37, 44, 51,
  58, 59, 52, 45, 38, 31, 39, 46,
  53, 60, 61, 54, 47, 55, 62, 63,
];

const _defaultIntra = [
   8, 16, 19, 22, 26, 27, 29, 34,
  16, 16, 22, 24, 27, 29, 34, 37,
  19, 22, 26, 27, 29, 34, 34, 38,
  22, 22, 26, 27, 29, 34, 37, 40,
  22, 26, 27, 29, 32, 35, 40, 48,
  26, 27, 29, 32, 35, 40, 48, 58,
  26, 27, 29, 34, 38, 46, 56, 69,
  27, 29, 35, 38, 46, 56, 69, 83,
];
// dart format on

final _defaultInter = List<int>.unmodifiable(List.filled(64, 16));
const _rates = [
  (1001, 24000),
  (1, 24),
  (1, 25),
  (1001, 30000),
  (1, 30),
  (1, 50),
  (1001, 60000),
  (1, 60),
];
