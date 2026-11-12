part of 'decode.dart';

final class _Prediction {
  const _Prediction(
    this.direction,
    this.x,
    this.y, {
    this.sourceField,
    this.destField,
    this.half,
  });

  final int direction, x, y;
  final int? sourceField, destField, half;
}

/// In frame pictures, vertical predictors are stored in frame coordinates
/// even when a macroblock uses field-based prediction.
final class _MotionVectors {
  final _pmv = List.filled(4, (0, 0));

  void reset() => _pmv.fillRange(0, 4, (0, 0));

  List<_Prediction> implied(int directions, MpegPictureHeader header) => [
    for (var direction = 0; direction < 2; direction++)
      if (directions & (_forward >> direction) != 0)
        _Prediction(
          direction,
          _pmv[2 * direction].$1 << (header.fullPel[direction] ? 1 : 0),
          _pmv[2 * direction].$2 << (header.fullPel[direction] ? 1 : 0),
          sourceField: header.field,
          destField: header.field,
        ),
  ];

  List<_Prediction> read(
    Rbsp bits,
    MpegPictureHeader header,
    int directions,
    int mode,
  ) {
    final predictions = <_Prediction>[];
    final field = header.field;
    for (var direction = 0; direction < 2; direction++) {
      if (directions & (_forward >> direction) == 0) continue;
      final first = direction * 2;
      final (cx, cy) = header.motionCode[direction];
      if (mode == 3) {
        _dualPrime(bits, header, direction, predictions);
        continue;
      }
      if (field != null) {
        final parts = switch (mode) {
          1 => 1,
          2 => 2,
          _ => throw const FormatException('Invalid MPEG field motion type'),
        };
        for (var part = 0; part < parts; part++) {
          final source = bits.bit();
          final (x, y) = _vector(bits, cx, cy, first + part);
          predictions.add(
            _Prediction(
              direction,
              x,
              y,
              sourceField: source,
              destField: field,
              half: parts == 2 ? part : null,
            ),
          );
        }
        if (parts == 1) _pmv[first + 1] = _pmv[first];
        continue;
      }
      switch (mode) {
        case 1: // independent motion vector for each field of a frame
          for (var parity = 0; parity < 2; parity++) {
            final reference = bits.bit();
            final (x, y) = _vector(
              bits,
              cx,
              cy,
              first + parity,
              verticalShift: 1,
            );
            predictions.add(
              _Prediction(
                direction,
                x,
                y,
                sourceField: reference,
                destField: parity,
              ),
            );
          }
        case 2: // frame prediction
          final (x, y) = _vector(bits, cx, cy, first);
          _pmv[first + 1] = _pmv[first];
          final shift = header.fullPel[direction] ? 1 : 0;
          predictions.add(_Prediction(direction, x << shift, y << shift));
        default:
          throw const FormatException('Invalid MPEG motion type');
      }
    }
    return predictions;
  }

  (int, int) _vector(
    Rbsp bits,
    int cx,
    int cy,
    int slot, {
    int verticalShift = 0,
  }) {
    final (px, py) = _pmv[slot];
    final x = _motionComponent(bits, cx, px);
    final y = _motionComponent(bits, cy, py >> verticalShift);
    _pmv[slot] = (x, y << verticalShift);
    return (x, y);
  }

  void _dualPrime(
    Rbsp bits,
    MpegPictureHeader header,
    int direction,
    List<_Prediction> predictions,
  ) {
    if (header.type != 2 || direction != 0) {
      throw const FormatException('Invalid MPEG dual-prime prediction');
    }
    final (cx, cy) = header.motionCode[0];
    final (px, py) = _pmv[0];
    final field = header.field;
    final shift = field == null ? 1 : 0;
    final x = _motionComponent(bits, cx, px), dx = _differential(bits);
    final y = _motionComponent(bits, cy, py >> shift), dy = _differential(bits);
    _pmv[0] = _pmv[1] = (x, y << shift);
    for (var parity = field ?? 0; parity <= (field ?? 1); parity++) {
      final distance = field != null || (parity == 0) == header.topFirst
          ? 1
          : 3;
      final otherX = ((x * distance + (x > 0 ? 1 : 0)) >> 1) + dx;
      final otherY =
          ((y * distance + (y > 0 ? 1 : 0)) >> 1) + dy + (2 * parity - 1);
      predictions.add(
        _Prediction(0, x, y, sourceField: parity, destField: parity),
      );
      predictions.add(
        _Prediction(
          0,
          otherX,
          otherY,
          sourceField: 1 - parity,
          destField: parity,
        ),
      );
    }
  }
}

int _motionComponent(Rbsp bits, int code, int predicted) {
  if (code < 1 || code > 9)
    throw const FormatException('Invalid MPEG motion f_code');
  final magnitude = _vlc(bits, _motionCodes, 10);
  if (magnitude == 0) return predicted;
  final negative = bits.flag();
  final shift = code - 1;
  final difference = ((magnitude - 1) << shift) + bits.read(shift) + 1;
  final bound = 16 << shift;
  final value = predicted + (negative ? -difference : difference);
  return ((value + bound) & ((bound << 1) - 1)) - bound;
}

int _differential(Rbsp bits) => !bits.flag()
    ? 0
    : bits.flag()
    ? -1
    : 1;

void _motionCompensate(
  MpegPicture picture,
  int mbX,
  int mbY,
  MpegPicture? forward,
  MpegPicture? backward,
  List<_Prediction> predictions, {
  required bool fieldPicture,
  required int? previousField,
}) {
  final used = [false, false];
  for (final prediction in predictions) {
    final reference = prediction.direction != 0
        ? backward
        : previousField != null && prediction.sourceField == previousField
        ? picture
        : forward;
    if (reference == null ||
        reference.stride != picture.stride ||
        reference.paddedHeight != picture.paddedHeight ||
        reference.subsamplingX != picture.subsamplingX ||
        reference.subsamplingY != picture.subsamplingY) {
      throw const FormatException(
        'Missing or incompatible MPEG reference picture',
      );
    }
    final step = prediction.destField == null ? 1 : 2;
    final destField = prediction.destField ?? 0;
    final sourceField = prediction.sourceField ?? 0;
    final partition = prediction.half ?? destField;
    final average = used[partition];
    for (var component = 0; component < 3; component++) {
      final sx = component == 0 ? 0 : picture.subsamplingX;
      final sy = component == 0 ? 0 : picture.subsamplingY;
      final width = 16 >> sx;
      final rows = (16 >> sy) ~/ (fieldPicture ? 1 : step);
      final height = prediction.half == null ? rows : rows ~/ 2;
      final x = mbX * width, y = mbY * rows + (prediction.half ?? 0) * height;
      final dx = prediction.x ~/ (1 << sx), dy = prediction.y ~/ (1 << sy);
      _predictPlane(
        picture.planes[component],
        reference.planes[component],
        stride: picture.stride >> sx,
        x: x,
        y: y,
        width: width,
        height: height,
        step: step,
        destField: destField,
        sourceField: sourceField,
        dx: dx,
        dy: dy,
        average: average,
      );
    }
    used[partition] = true;
  }
}

void _predictPlane(
  Uint8List destination,
  Uint8List source, {
  required int stride,
  required int x,
  required int y,
  required int width,
  required int height,
  required int step,
  required int destField,
  required int sourceField,
  required int dx,
  required int dy,
  required bool average,
}) {
  final line = stride * step;
  final maxY = source.length ~/ line - 1;
  final left = x + (dx >> 1), top = y + (dy >> 1);
  final halfX = dx & 1, halfY = dy & 1;
  final shift = halfX + halfY, rounding = shift == 0 ? 0 : 1 << (shift - 1);
  final maxX = stride - 1;
  for (var r = 0; r < height; r++) {
    final rowA = (top + r).clamp(0, maxY) * line + sourceField * stride;
    final rowB = (top + r + halfY).clamp(0, maxY) * line + sourceField * stride;
    final dest = (y + r) * line + destField * stride + x;
    if (shift == 0 && !average && left >= 0 && left + width <= stride) {
      destination.setRange(dest, dest + width, source, rowA + left);
      continue;
    }
    for (var c = 0; c < width; c++) {
      final a = (left + c).clamp(0, maxX);
      final b = (left + c + halfX).clamp(0, maxX);
      var value = source[rowA + a] + rounding;
      if (halfX != 0) value += source[rowA + b];
      if (halfY != 0) {
        value += source[rowB + a];
        if (halfX != 0) value += source[rowB + b];
      }
      value >>= shift;
      destination[dest + c] = average
          ? (destination[dest + c] + value + 1) >> 1
          : value;
    }
  }
}
