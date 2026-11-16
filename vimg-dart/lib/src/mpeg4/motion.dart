part of 'decoder.dart';

typedef _Vector = ({int x, int y});
typedef _FieldSelection = ({int top, int bottom});
typedef _FieldMotion = ({
  _FieldSelection selection,
  _Vector top,
  _Vector bottom,
});
typedef _FieldPair = ({int destination, int reference});
const _zeroVector = (x: 0, y: 0);

({_Vector forward, _Vector backward}) _directVectors(
  _Vector reference,
  _Vector delta,
  int offset,
  int period,
) {
  if (period <= 0 || offset <= 0 || offset >= period) {
    throw const FormatException('Invalid MPEG-4 direct motion timing');
  }
  final forward = (
    x: reference.x * offset ~/ period + delta.x,
    y: reference.y * offset ~/ period + delta.y,
  );
  final backward = (
    x: delta.x != 0
        ? forward.x - reference.x
        : reference.x * (offset - period) ~/ period,
    y: delta.y != 0
        ? forward.y - reference.y
        : reference.y * (offset - period) ~/ period,
  );
  return (forward: forward, backward: backward);
}

final class _PictureMotion {
  _PictureMotion(int columns, int rows, bool interlaced)
    : _columns = columns * 2,
      _rows = rows * 2,
      _vectors = Int16List(columns * rows * 8),
      skipped = Uint8List(columns * rows),
      split = Uint8List(columns * rows),
      fields = interlaced
          ? List<_FieldMotion?>.filled(columns * rows, null)
          : null;

  final int _columns, _rows;
  final Int16List _vectors;
  final Uint8List skipped, split;
  final List<_FieldMotion?>? fields;

  _Vector at(int x, int y) {
    if (x < 0 || x >= _columns || y < 0 || y >= _rows) return _zeroVector;
    final position = (y * _columns + x) * 2;
    return (x: _vectors[position], y: _vectors[position + 1]);
  }

  void store(int x, int y, int block, _Vector vector) {
    final position =
        ((y * 2 + (block >> 1)) * _columns + x * 2 + (block & 1)) * 2;
    _vectors[position] = vector.x;
    _vectors[position + 1] = vector.y;
  }
}

_Vector _medianVector(_Vector a, _Vector b, _Vector c) {
  int middle(int a, int b, int c) =>
      a +
      b +
      c -
      math.min<int>(a, math.min<int>(b, c)) -
      math.max<int>(a, math.max<int>(b, c));
  return (x: middle(a.x, b.x, c.x), y: middle(a.y, b.y, c.y));
}

_Vector _motionPrediction(
  _PictureMotion motion,
  int columns,
  int start,
  int x,
  int y,
  int block, {
  bool h263 = false,
}) {
  final bx = x * 2 + (block & 1), by = y * 2 + (block >> 1);
  final startX = start % columns;
  final firstLine = y * columns + x < start + columns;
  final a = motion.at(bx - 1, by);
  final c = motion.at(bx + const [2, 1, 1, -1][block], by - 1);
  if (firstLine && block < 2) {
    if (block == 0 && x == startX) return _zeroVector;
    if (!h263 && x + 1 == startX) {
      return x == 0 && block == 0 ? c : _medianVector(a, _zeroVector, c);
    }
    return a;
  }
  final b = motion.at(bx, by - 1);
  return _medianVector(
    firstLine && block == 2 && x == startX ? _zeroVector : a,
    b,
    c,
  );
}

_Vector _motionVector(
  Rbsp bits,
  _Vector prediction,
  int code, {
  bool long = false,
}) {
  final extra = code - 1;
  final limit = 32 << extra;
  int component(int base) {
    final magnitude = _motionCode.read(bits);
    if (magnitude == 0) return base;
    final negative = bits.flag();
    final delta = ((magnitude - 1) << extra) + bits.read(extra) + 1;
    final value = base + (negative ? -delta : delta);
    if (long) {
      if (base < -31 && value < -63) return value + 64;
      if (base > 32 && value > 63) return value - 64;
      return value;
    }
    return ((value + limit) & (2 * limit - 1)) - limit;
  }

  return (x: component(prediction.x), y: component(prediction.y));
}

final class _Mpeg4MotionCompensation {
  final _sourceRow = Uint8List(17);
  final _horizontal = Uint8List(17 * 16);

  void predictGlobal(
    Mpeg4Picture output,
    Mpeg4Picture reference,
    int x,
    int y,
    Mpeg4Gmc warp, {
    required bool noRound,
  }) {
    final precision = warp.accuracy + 1;
    final scale = warp.scale;
    final fraction = scale - 1;
    final bias = (scale * scale >> 1) - (noRound ? 1 : 0);
    for (var plane = 0; plane < 3; plane++) {
      final sub = plane == 0 ? 0 : 1;
      final size = 16 >> sub;
      final stride = output.stride >> sub;
      final height = output.rows * size;
      final pixels = reference.planes[plane];
      final destination = output.planes[plane];
      final offset = plane == 0 ? warp.luma : warp.chroma;
      final dx = warp.stepX, dy = warp.stepY;
      final left = x * size, top = y * size;
      var rowX = offset.x + dx.x * left + dy.x * top;
      var rowY = offset.y + dx.y * left + dy.y * top;
      if (warp.translation) {
        rowX = math.min(rowX, (reference.volume.width >> sub) << precision);
        rowY = math.min(rowY, (reference.volume.height >> sub) << precision);
      }
      for (var row = 0; row < size; row++, rowX += dy.x, rowY += dy.y) {
        final target = (top + row) * stride + left;
        var valueX = rowX, valueY = rowY;
        for (var column = 0; column < size; column++) {
          final scaledX = valueX >> warp.shift, scaledY = valueY >> warp.shift;
          valueX += dx.x;
          valueY += dx.y;
          final srcX = scaledX >> precision, srcY = scaledY >> precision;
          final wx = scaledX & fraction, wy = scaledY & fraction;
          final a = srcX.clamp(0, stride - 1);
          final b = (srcX + 1).clamp(0, stride - 1);
          final upper = srcY.clamp(0, height - 1) * stride;
          final lower = (srcY + 1).clamp(0, height - 1) * stride;
          final upperValue =
              pixels[upper + a] * (scale - wx) + pixels[upper + b] * wx;
          final lowerValue =
              pixels[lower + a] * (scale - wx) + pixels[lower + b] * wx;
          destination[target + column] =
              (upperValue * (scale - wy) + lowerValue * wy + bias) >>
              (2 * precision);
        }
      }
    }
  }

  void predict(
    _DctPicture output,
    _DctPicture reference,
    int x,
    int y,
    List<_Vector> vectors, {
    bool noRound = false,
    bool average = false,
  }) {
    final stride = output.stride, lines = output.rows * 16;
    final split = vectors.length == 4;
    final quarter = output.quarter;
    final luma = quarter ? _quarter : _half;
    var sumX = 0, sumY = 0;
    for (final (i, vector) in vectors.indexed) {
      sumX += quarter ? vector.x ~/ 2 : vector.x;
      sumY += quarter ? vector.y ~/ 2 : vector.y;
      luma(
        output.planes[0],
        reference.planes[0],
        stride,
        lines,
        x * 16 + 8 * (i & 1),
        y * 16 + 8 * (i >> 1),
        split ? 8 : 16,
        vector.x,
        vector.y,
        noRound,
        average,
      );
    }
    _predictChroma(
      output,
      reference,
      x,
      y,
      (x: sumX, y: sumY),
      split: split,
      noRound: noRound,
      average: average,
    );
  }

  void _predictChroma(
    _DctPicture output,
    _DctPicture reference,
    int x,
    int y,
    _Vector sum, {
    required bool split,
    required bool noRound,
    bool average = false,
  }) {
    const chromaRound = [0, 0, 0, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0, 1, 1];
    int reduce(int value) => split
        ? (value >> 3) + chromaRound[value & 15]
        : (value >> 1) | (value & 1);
    final chromaX = reduce(sum.x), chromaY = reduce(sum.y);
    for (var plane = 1; plane < 3; plane++) {
      _half(
        output.planes[plane],
        reference.planes[plane],
        output.stride >> 1,
        output.rows * 8,
        x * 8,
        y * 8,
        8,
        chromaX,
        chromaY,
        noRound,
        average,
      );
    }
  }

  void predictFields(
    Mpeg4Picture output,
    Mpeg4Picture reference,
    int x,
    int y,
    _FieldMotion motion, {
    bool noRound = false,
    bool average = false,
  }) {
    final stride = output.stride, lines = output.rows * 16;
    final quarter = output.volume.quarter;
    for (final (parity, vector) in [motion.top, motion.bottom].indexed) {
      final field = (
        destination: parity,
        reference: parity == 0 ? motion.selection.top : motion.selection.bottom,
      );
      if (quarter) {
        for (var block = 0; block < 2; block++) {
          _quarter(
            output.planes[0],
            reference.planes[0],
            stride,
            lines,
            x * 16 + block * 8,
            y * 8,
            8,
            vector.x,
            vector.y,
            noRound,
            average,
            field: field,
          );
        }
      } else {
        _half(
          output.planes[0],
          reference.planes[0],
          stride,
          lines,
          x * 16,
          y * 8,
          16,
          vector.x,
          vector.y,
          noRound,
          average,
          field: field,
          rows: 8,
        );
      }
      final mx = quarter ? vector.x ~/ 2 : vector.x;
      final my = quarter ? vector.y >> 1 : vector.y;
      final chromaX = (mx >> 1) | (mx & 1);
      final chromaY = (my >> 1) | (my & 1);
      for (var plane = 1; plane < 3; plane++) {
        _half(
          output.planes[plane],
          reference.planes[plane],
          stride >> 1,
          lines >> 1,
          x * 8,
          y * 4,
          8,
          chromaX,
          chromaY,
          noRound,
          average,
          field: field,
          rows: 4,
        );
      }
    }
  }

  void _quarter(
    Uint8List output,
    Uint8List reference,
    int stride,
    int height,
    int x,
    int y,
    int size,
    int mx,
    int my,
    bool noRound,
    bool average, {
    _FieldPair? field,
  }) {
    final dx = mx & 3, dy = my & 3;
    if (dx == 0 && dy == 0) {
      _half(
        output,
        reference,
        stride,
        height,
        x,
        y,
        size,
        mx >> 1,
        my >> 1,
        noRound,
        average,
        field: field,
      );
      return;
    }
    final sx = x + (mx >> 2), sy = y + (my >> 2);
    final round = noRound ? 0 : 1;
    final step = field == null ? 1 : 2;
    final sourceField = field?.reference ?? 0;
    final destinationField = field?.destination ?? 0;
    final rows = dy == 0 ? size : size + 1;
    for (var row = 0; row < rows; row++) {
      final referenceRow =
          ((sy + row) * step + sourceField).clamp(0, height - 1) * stride;
      final horizontalRow = row * size;
      if (dx == 0) {
        for (var column = 0; column < size; column++) {
          _horizontal[horizontalRow + column] =
              reference[referenceRow + (sx + column).clamp(0, stride - 1)];
        }
      } else {
        for (var column = 0; column <= size; column++) {
          _sourceRow[column] =
              reference[referenceRow + (sx + column).clamp(0, stride - 1)];
        }
        for (var column = 0; column < size; column++) {
          _horizontal[horizontalRow + column] = _quarterPhase(
            _sourceRow,
            0,
            1,
            size,
            column,
            dx,
            round,
          );
        }
      }
    }
    for (var row = 0; row < size; row++) {
      final target = ((y + row) * step + destinationField) * stride + x;
      for (var column = 0; column < size; column++) {
        final value = dy == 0
            ? _horizontal[row * size + column]
            : _quarterPhase(_horizontal, column, size, size, row, dy, round);
        output[target + column] = average
            ? (output[target + column] + value + 1) >> 1
            : value;
      }
    }
  }

  int _quarterPhase(
    Uint8List source,
    int start,
    int step,
    int size,
    int position,
    int phase,
    int round,
  ) {
    // The 8-tap filter reflects around the two ends of the input block.
    int sample(int index) {
      final reflected = index < 0
          ? -index - 1
          : index > size
          ? 2 * size + 1 - index
          : index;
      return source[start + reflected * step];
    }

    final half =
        ((20 * (sample(position) + sample(position + 1)) -
                    6 * (sample(position - 1) + sample(position + 2)) +
                    3 * (sample(position - 2) + sample(position + 3)) -
                    (sample(position - 3) + sample(position + 4)) +
                    15 +
                    round) >>
                5)
            .clamp(0, 255);
    return phase == 2
        ? half
        : (half + sample(position + (phase >> 1)) + round) >> 1;
  }

  void _half(
    Uint8List output,
    Uint8List reference,
    int stride,
    int height,
    int x,
    int y,
    int size,
    int mx,
    int my,
    bool noRound,
    bool average, {
    _FieldPair? field,
    int? rows,
    bool packed = false,
  }) {
    final dx = mx & 1, dy = my & 1;
    final sx = x + (mx >> 1), sy = y + (my >> 1);
    final adjustment = noRound ? 0 : 1;
    final step = field == null ? 1 : 2;
    final sourceField = field?.reference ?? 0;
    final destinationField = field?.destination ?? 0;
    for (var j = 0; j < (rows ?? size); j++) {
      final source = (sy + j) * step + sourceField;
      final top = source.clamp(0, height - 1) * stride;
      final bottom = (source + dy * step).clamp(0, height - 1) * stride;
      final target = packed
          ? j * size
          : ((y + j) * step + destinationField) * stride + x;
      for (var i = 0; i < size; i++) {
        final left = (sx + i).clamp(0, stride - 1);
        final right = (sx + i + dx).clamp(0, stride - 1);
        final a = reference[top + left];
        final value = switch ((dx, dy)) {
          (0, 0) => a,
          (1, 0) => (a + reference[top + right] + adjustment) >> 1,
          (0, 1) => (a + reference[bottom + left] + adjustment) >> 1,
          _ =>
            (a +
                    reference[top + right] +
                    reference[bottom + left] +
                    reference[bottom + right] +
                    adjustment +
                    1) >>
                2,
        };
        output[target + i] = average
            ? (output[target + i] + value + 1) >> 1
            : value;
      }
    }
  }
}
