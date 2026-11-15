import 'dart:typed_data';

import 'package:image/image.dart' as image;

import '../rbsp.dart';
import '../mpeg_idct.dart';
import '../yuv_image.dart';
import 'syntax.dart';

part 'motion.dart';
part 'tables.dart';

/// Sequential MPEG video decoder. Each sample is one coded frame, consisting
/// of a frame picture or two field pictures, in coding order.
final class MpegStreamDecoder {
  MpegStreamDecoder([Uint8List? configuration]) {
    if (configuration != null) _read(configuration, headersOnly: true);
  }

  MpegSequence? _sequence;
  MpegPicture? _older, _newer;
  final _transform = MpegIdct();

  MpegPicture decode(Uint8List bytes) =>
      _read(bytes) ??
      (throw const FormatException('Missing MPEG video picture'));

  /// Preserve header changes while omitting unselected non-reference pictures.
  void advance(Uint8List bytes) => _read(bytes, skipB: true);

  MpegPicture? _read(
    Uint8List bytes, {
    bool headersOnly = false,
    bool skipB = false,
  }) {
    MpegPictureHeader? header;
    MpegPictureHeader? firstField;
    MpegPicture? firstPixels;
    _PictureSlices? slices;
    var hasSlices = false;
    for (final unit in mpegStartCodes(bytes)) {
      final code = unit.code;
      final payload = Uint8List.sublistView(bytes, unit.data, unit.end);
      if (code == 0xb3) {
        if (hasSlices || firstField != null)
          throw const FormatException('Unexpected MPEG sequence header');
        _sequence = MpegSequence(payload);
      } else if (code == 0xb5) {
        if (payload.isEmpty)
          throw const FormatException('Missing MPEG extension type');
        if (payload[0] >> 4 == 8) {
          if (headersOnly) continue;
          if (header == null || hasSlices) {
            throw const FormatException(
              'Unexpected MPEG picture coding extension',
            );
          }
          header.extension(payload);
        } else {
          _sequence?.extension(payload);
        }
      } else if (code == 0 && !headersOnly) {
        final previous = header;
        if (previous != null) {
          if (firstField != null || previous.field == null || !hasSlices) {
            throw const FormatException(
              'Unexpected MPEG picture in coded frame',
            );
          }
          firstField = previous;
          firstPixels = slices?.finish();
          slices = null;
          hasSlices = false;
        }
        header = MpegPictureHeader(payload);
      } else if (code >= 1 && code <= 0xaf && !headersOnly) {
        final sequence = _sequence;
        if (sequence == null || header == null) {
          throw const FormatException(
            'MPEG slice lacks sequence or picture headers',
          );
        }
        if (sequence.mpeg2 != header.codingExtension) {
          throw const FormatException(
            'Missing or misplaced MPEG picture coding extension',
          );
        }
        final field = header.field;
        if (!hasSlices) {
          if (field != null &&
              (sequence.progressive || header.framePrediction)) {
            throw const FormatException('Invalid MPEG field picture flags');
          }
          if (firstField != null &&
              (field == null ||
                  field == firstField.field ||
                  header.temporalReference != firstField.temporalReference ||
                  !mpegFieldTypesPair(firstField.type, header.type))) {
            throw const FormatException('Invalid complementary MPEG field');
          }
          hasSlices = true;
        }
        if (skipB && header.type == 3) continue;
        slices ??= _PictureSlices(
          sequence,
          header,
          _transform,
          picture: firstPixels ?? MpegPicture._(sequence),
          forward: header.type == 3
              ? _older
              : firstField?.type == 1
              ? null
              : _newer,
          backward: header.type == 3 ? _newer : null,
          previousField: header.type == 2 ? firstField?.field : null,
        );
        slices.decode(code, payload);
      }
    }
    if (headersOnly) return null;
    if (header?.field != null && firstField == null) {
      throw const FormatException('Missing complementary MPEG field');
    }
    if (!hasSlices) throw const FormatException('Missing MPEG picture slices');
    final picture = slices?.finish();
    if (picture != null && header!.type != 3) {
      _older = _newer;
      _newer = picture;
    }
    return picture;
  }
}

final class MpegPicture {
  MpegPicture._(MpegSequence sequence)
    : width = sequence.width,
      height = sequence.height,
      matrix = sequence.matrix,
      subsamplingX = sequence.chroma == 3 ? 0 : 1,
      subsamplingY = sequence.chroma == 1 ? 1 : 0,
      stride = (sequence.width + 15) & ~15,
      paddedHeight = sequence.progressive
          ? (sequence.height + 15) & ~15
          : (sequence.height + 31) & ~31 {
    if (width <= 0 || height <= 0 || stride * paddedHeight > 1 << 26) {
      throw const FormatException('Invalid MPEG picture dimensions');
    }
    final size = stride * paddedHeight;
    final chromaSize = size >> (subsamplingX + subsamplingY);
    planes = [Uint8List(size), Uint8List(chromaSize), Uint8List(chromaSize)];
  }

  final int width,
      height,
      matrix,
      subsamplingX,
      subsamplingY,
      stride,
      paddedHeight;
  late final List<Uint8List> planes;

  image.Image rgb({YuvImageScaler? scaler}) => yuvImage(
    y: planes[0],
    cb: planes[1],
    cr: planes[2],
    stride: stride,
    chromaStride: stride >> subsamplingX,
    width: width,
    height: height,
    cropLeft: 0,
    cropTop: 0,
    matrix: matrix,
    fullRange: false,
    subsamplingX: subsamplingX,
    subsamplingY: subsamplingY,
    scaler: scaler,
  );
}

final class _PictureSlices {
  _PictureSlices(
    this.sequence,
    this.header,
    this.transform, {
    required this.picture,
    required this.forward,
    required this.backward,
    required this.previousField,
  }) {
    coded = Uint8List(columns * rows);
  }

  final MpegSequence sequence;
  final MpegPictureHeader header;
  final MpegIdct transform;
  final MpegPicture? forward, backward;
  final MpegPicture picture;
  final int? previousField;
  late final Uint8List coded;
  final _coefficients = Int16List(64);
  final _dc = [0, 0, 0];
  final _motion = _MotionVectors();
  var _lastDirections = 0;
  var _quantizer = 0;

  int get columns => picture.stride >> 4;
  int get rows => picture.paddedHeight >> (header.field == null ? 4 : 5);

  void decode(int code, Uint8List payload) {
    final bits = mpegBits(payload);
    final extension = sequence.mpeg2 && picture.height > 2800
        ? bits.read(3)
        : 0;
    final row = (extension << 7) + code - 1;
    _readQuantizer(bits);
    while (bits.flag()) {
      bits.skip(8); // slice extension or extra information
    }
    _resetDc();
    _motion.reset();
    _lastDirections = 0;
    var address = row * columns - 1;
    var first = true;
    while (bits.remaining >= 1) {
      // No address code can start with 23 zero bits. This also covers a
      // sliced sample whose start-code prefix was removed by the container.
      final saved = bits.position;
      if (bits.read(bits.remaining < 23 ? bits.remaining : 23) == 0) break;
      bits.position = saved;
      final increment = _addressIncrement(bits, sequence.mpeg2);
      final next = address + increment;
      if (next < 0 ||
          next >= coded.length ||
          (first && next ~/ columns != row)) {
        throw const FormatException('Invalid MPEG macroblock address');
      }
      if (!first) {
        for (var skipped = address + 1; skipped < next; skipped++) {
          _skipped(skipped);
        }
      }
      _macroblock(bits, next);
      address = next;
      first = false;
      if (address + 1 == coded.length) break;
    }
    if (first) throw const FormatException('Empty MPEG slice');
  }

  MpegPicture finish() {
    if (coded.contains(0))
      throw const FormatException('Incomplete MPEG picture');
    return picture;
  }

  void _mark(int address) {
    if (coded[address] != 0)
      throw const FormatException('Overlapping MPEG slices');
    coded[address] = 1;
  }

  void _resetDc() => _dc.fillRange(0, 3, 128 << header.precision);

  void _readQuantizer(Rbsp bits) {
    final scale = bits.read(5);
    if (scale == 0) throw const FormatException('Invalid MPEG quantizer scale');
    _quantizer = header.nonlinear ? _nonLinearQuantizer[scale] : scale * 2;
  }

  void _skipped(int address) {
    _mark(address);
    _resetDc();
    if (header.type == 2) {
      _motion.reset();
      _predictZero(address);
    } else if (header.type == 3 && _lastDirections != 0) {
      _predict(address, _motion.implied(_lastDirections, header));
    } else {
      throw const FormatException('Invalid skipped MPEG macroblock');
    }
  }

  void _macroblock(Rbsp bits, int address) {
    _mark(address);
    final types = switch (header.type) {
      1 => _intraTypes,
      2 => _predictedTypes,
      _ => _bidirectionalTypes,
    };
    final type = _vlc(bits, types, 6);
    final intra = type & _intra != 0;
    final codedPattern = type & _coded != 0;
    final directions = type & (_forward | _backward);
    final field = header.field;
    final motionType = directions != 0 && !header.framePrediction
        ? bits.read(2)
        : field == null
        ? 2
        : 1;
    final fieldDct =
        field == null &&
        !header.framePrediction &&
        (intra || codedPattern) &&
        bits.flag();
    if (type & _quant != 0) _readQuantizer(bits);
    if (intra) {
      if (header.concealment) {
        _motion.read(bits, header, _forward, field == null ? 2 : 1);
        mpegMarker(bits);
      } else {
        _motion.reset();
      }
      _lastDirections = 0;
    } else {
      _resetDc();
      if (directions == 0) {
        _motion.reset();
        _predictZero(address);
      } else {
        final predictions = _motion.read(bits, header, directions, motionType);
        _predict(address, predictions);
      }
      _lastDirections = directions;
    }
    final blocks = switch (sequence.chroma) {
      1 => 6,
      2 => 8,
      _ => 12,
    };
    var pattern = 0;
    if (intra) {
      pattern = (1 << blocks) - 1;
    } else if (codedPattern) {
      final extra = blocks - 6;
      pattern = (_vlc(bits, _patternCodes, 9) << extra) | bits.read(extra);
      if (pattern == 0)
        throw const FormatException('Empty MPEG coded block pattern');
    }
    final mbX = address % columns, mbY = address ~/ columns;
    for (var i = 0; i < blocks; i++) {
      if (pattern & (1 << (blocks - i - 1)) == 0) continue;
      final component = i < 4 ? 0 : 1 + (i & 1);
      final index = i < 4 ? i : (i - 4) >> 1;
      final sx = component == 0 ? 0 : picture.subsamplingX;
      final sy = component == 0 ? 0 : picture.subsamplingY;
      final column = i < 4 ? index & 1 : index >> 1;
      final row = i < 4 ? index >> 1 : index & 1;
      final fieldBlock = fieldDct && sy == 0;
      final step = field != null || fieldBlock ? 2 : 1;
      final stride = picture.stride >> sx;
      final x = (mbX * 16 >> sx) + column * 8;
      var y = (mbY * 16 >> sy) + row * (fieldBlock ? 1 : 8);
      if (field != null) y = 2 * y + field;
      _block(bits, component, intra);
      transform.write(
        picture.planes[component],
        y * stride + x,
        stride * step,
        _coefficients,
        intra,
      );
    }
  }

  void _block(Rbsp bits, int component, bool intra) {
    final coefficients = _coefficients..fillRange(0, 64, 0);
    final isMpeg2 = sequence.mpeg2;
    final matrix =
        sequence.matrices[(component == 0 ? 0 : 2) + (intra ? 0 : 1)];
    final scan = header.alternateScan ? _alternateScan : mpegZigzag;
    var index = -1, mismatch = 0;
    if (intra) {
      final size = _vlc(
        bits,
        component == 0 ? _lumaDcCodes : _chromaDcCodes,
        10,
      );
      if (size != 0) {
        final value = bits.read(size);
        _dc[component] += value < 1 << (size - 1)
            ? value + 1 - (1 << size)
            : value;
      }
      mismatch = coefficients[0] = (_dc[component] << (3 - header.precision))
          .clamp(-2048, 2047);
      index = 0;
    }
    final table = intra && header.alternateVlc ? _acAlternateCodes : _acCodes;
    while (true) {
      int code;
      if (index == -1) {
        final saved = bits.position;
        if (bits.flag()) {
          code = 1; // Table B.14 uses one bit for the first (0, 1).
        } else {
          bits.position = saved;
          code = _vlc(bits, table, 16);
        }
      } else {
        code = _vlc(bits, table, 16);
      }
      if (code == -2) {
        if (index == -1)
          throw const FormatException('Missing MPEG block coefficients');
        break;
      }
      final int run, level;
      if (code == -1) {
        run = bits.read(6);
        level = _escape(bits, isMpeg2);
      } else {
        run = code >> 6;
        final magnitude = code & 63;
        level = bits.flag() ? -magnitude : magnitude;
      }
      index += run + 1;
      if (index >= 64)
        throw const FormatException('MPEG coefficient run exceeds the block');
      final position = scan[index];
      var magnitude =
          ((2 * level.abs() + (intra ? 0 : 1)) *
              _quantizer *
              matrix[position]) >>
          5;
      if (!isMpeg2 && magnitude > 0) magnitude = (magnitude - 1) | 1;
      final value = (level < 0 ? -magnitude : magnitude).clamp(-2048, 2047);
      coefficients[position] = value;
      mismatch ^= value;
    }
    if (isMpeg2 && mismatch.isEven) coefficients[63] ^= 1;
  }

  void _predictZero(int address) {
    final field = header.field;
    _predict(address, [
      _Prediction(0, 0, 0, sourceField: field, destField: field),
    ]);
  }

  void _predict(int address, List<_Prediction> predictions) {
    _motionCompensate(
      picture,
      address % columns,
      address ~/ columns,
      forward,
      backward,
      predictions,
      fieldPicture: header.field != null,
      previousField: previousField,
    );
  }
}

int _vlc(Rbsp bits, Map<int, int> table, int maximum) {
  var prefix = 1;
  for (var i = 0; i < maximum; i++) {
    prefix = (prefix << 1) | bits.bit();
    final value = table[prefix];
    if (value != null) return value;
  }
  throw const FormatException('Invalid MPEG variable-length code');
}

int _addressIncrement(Rbsp bits, bool mpeg2) {
  var increment = 0;
  while (true) {
    final value = _vlc(bits, _addressCodes, 11);
    if (value <= 33) return increment + value;
    if (value == 34) {
      increment += 33;
    } else if (mpeg2) {
      throw const FormatException('Unexpected MPEG-2 macroblock stuffing');
    }
  }
}

int _escape(Rbsp bits, bool mpeg2) {
  if (mpeg2) {
    final value = bits.read(12).toSigned(12);
    if (value == 0 || value == -2048) {
      throw const FormatException('Invalid MPEG-2 coefficient level');
    }
    return value;
  }
  final prefix = bits.read(8).toSigned(8);
  final value = switch (prefix) {
    0 => bits.read(8),
    -128 => bits.read(8) - 256,
    _ => prefix,
  };
  if (value == 0 || value == -256) {
    throw const FormatException('Invalid MPEG-1 coefficient level');
  }
  return value;
}
