import 'dart:math' as math;
import 'dart:typed_data';

enum Vp9TransformType { dct, verticalAdst, horizontalAdst, adst }

const vp9IntraTransforms = [
  Vp9TransformType.dct,
  Vp9TransformType.verticalAdst,
  Vp9TransformType.horizontalAdst,
  Vp9TransformType.dct,
  Vp9TransformType.adst,
  Vp9TransformType.verticalAdst,
  Vp9TransformType.horizontalAdst,
  Vp9TransformType.horizontalAdst,
  Vp9TransformType.verticalAdst,
  Vp9TransformType.adst,
];

int _round(int value, int shift) => (value + (1 << (shift - 1))) >> shift;

const _cosine = [
  16384,
  16364,
  16305,
  16207,
  16069,
  15893,
  15679,
  15426,
  15137,
  14811,
  14449,
  14053,
  13623,
  13160,
  12665,
  12140,
  11585,
  11003,
  10394,
  9760,
  9102,
  8423,
  7723,
  7005,
  6270,
  5520,
  4756,
  3981,
  3196,
  2404,
  1606,
  804,
  0,
];

int _cos(int angle) {
  final quadrant = (angle & 127) >> 5;
  final remainder = angle & 31;
  return switch (quadrant) {
    0 => _cosine[remainder],
    1 => -_cosine[32 - remainder],
    2 => -_cosine[remainder],
    _ => _cosine[32 - remainder],
  };
}

int _reverse(int value, int bits) {
  var result = 0;
  for (var i = 0; i < bits; i++) {
    result = (result << 1) | ((value >> i) & 1);
  }
  return result;
}

/// VP9 §8.7 inverse transforms. The coefficient buffer becomes the residual.
final class Vp9InverseTransform {
  final _line = Int32List(32);
  final _permutation = Int32List(32);
  final _wide = Int64List(16);

  void apply(Int32List values, int size, Vp9TransformType type, bool lossless) {
    final width = 4 << size;
    final shift = math.min(6, size + 4);
    final rowAdst =
        type == Vp9TransformType.horizontalAdst ||
        type == Vp9TransformType.adst;
    final columnAdst =
        type == Vp9TransformType.verticalAdst || type == Vp9TransformType.adst;
    for (var row = 0; row < width; row++) {
      var nonzero = false;
      for (var column = 0; column < width; column++) {
        final value = values[row * width + column];
        nonzero |= value != 0;
        _line[column] = value;
      }
      if (!nonzero) continue;
      _transform(size + 2, rowAdst, lossless, 2);
      values.setRange(row * width, (row + 1) * width, _line);
    }
    for (var column = 0; column < width; column++) {
      var nonzero = false;
      for (var row = 0; row < width; row++) {
        final value = values[row * width + column];
        nonzero |= value != 0;
        _line[row] = value;
      }
      if (!nonzero) continue;
      _transform(size + 2, columnAdst, lossless, 0);
      for (var row = 0; row < width; row++) {
        final value = _line[row];
        values[row * width + column] = lossless ? value : _round(value, shift);
      }
    }
  }

  void _transform(int log, bool adst, bool lossless, int preShift) {
    if (lossless) {
      final a = (_line[0] >> preShift) + (_line[1] >> preShift);
      final b = _line[3] >> preShift;
      final c = _line[1] >> preShift;
      final d = (_line[2] >> preShift) - b;
      final middle = (a - d) >> 1;
      _line[0] = a - middle + b;
      _line[1] = middle - b;
      _line[2] = middle - c;
      _line[3] = d + middle - c;
    } else if (adst) {
      _adst(log);
    } else {
      final count = 1 << log;
      _permutation.setRange(0, count, _line);
      for (var i = 0; i < count; i++) {
        _line[i] = _permutation[_reverse(i, log)];
      }
      _dct(log);
    }
  }

  void _rotate(int a, int b, int angle, bool swap, {bool wide = false}) {
    final cosine = _cos(angle), sine = _cos(angle - 32);
    final x = _line[a], y = _line[b];
    final first = x * cosine - y * sine;
    final second = x * sine + y * cosine;
    if (wide) {
      _wide[swap ? b : a] = first;
      _wide[swap ? a : b] = second;
    } else {
      _line[swap ? b : a] = _round(first, 14);
      _line[swap ? a : b] = _round(second, 14);
    }
  }

  void _sum(int a, int b, bool swap, {bool wide = false}) {
    if (wide) {
      _line[a] = _round(_wide[a] + _wide[b], 14);
      _line[b] = _round(_wide[a] - _wide[b], 14);
    } else {
      final x = _line[a], y = _line[b];
      _line[swap ? b : a] = x + y;
      _line[swap ? a : b] = swap ? y - x : x - y;
    }
  }

  void _dct(int n) {
    final count = 1 << n;
    final half = count >> 1, quarter = count >> 2, eighth = count >> 3;
    if (n == 2) {
      _rotate(0, 1, 16, true);
    } else {
      _dct(n - 1);
    }
    for (var i = 0; i < quarter; i++) {
      _rotate(half + i, count - 1 - i, 32 - _reverse(half + i, 5), false);
    }
    for (var i = 0; i < eighth; i++) {
      _sum(half + 4 * i, half + 4 * i + 1, false);
      _sum(half + 4 * i + 2, half + 4 * i + 3, true);
    }
    if (n == 5) {
      for (var pair = 0; pair < 2; pair++) {
        for (var i = 0; i < 2; i++) {
          _rotate(
            30 - pair - 4 * i,
            17 + pair + 4 * i,
            28 - 16 * i + 32 * pair,
            true,
          );
        }
      }
      for (var group = 0; group < 4; group++) {
        final start = half + eighth * group;
        for (var i = 0; i < 2; i++) {
          _sum(start + i, start + 3 - i, group.isOdd);
        }
      }
    }
    if (n >= 4) {
      final first = half + (eighth >> 1);
      for (var i = 0; i < eighth; i++) {
        _rotate(
          count - 1 - (first - half) - i,
          first + i,
          i < (eighth >> 1) ? 24 : 56,
          true,
        );
      }
      for (var pair = 0; pair < 2; pair++) {
        final start = half + quarter * pair;
        for (var i = 0; i < eighth; i++) {
          _sum(start + i, start + quarter - 1 - i, pair.isOdd);
        }
      }
    }
    for (var i = 0; i < eighth; i++) {
      _rotate(count - eighth - 1 - i, half + eighth + i, 16, true);
    }
    for (var i = 0; i < half; i++) {
      _sum(i, count - 1 - i, false);
    }
  }

  void _adst(int log) {
    if (log == 2) {
      final x = _line[0], y = _line[1], z = _line[2], w = _line[3];
      final a = 5283 * x + 15212 * z + 9929 * w;
      final b = 9929 * x - 5283 * z - 15212 * w;
      final c = 13377 * y;
      _line[0] = _round(a + c, 14);
      _line[1] = _round(b + c, 14);
      _line[2] = _round(13377 * (x - z + w), 14);
      _line[3] = _round(a + b - c, 14);
      return;
    }
    final count = 1 << log, half = count >> 1;
    _permutation.setRange(0, count, _line);
    final step = 64 ~/ count;
    for (var i = 0; i < half; i++) {
      _line[2 * i] = _permutation[count - 1 - 2 * i];
      _line[2 * i + 1] = _permutation[2 * i];
      _rotate(2 * i, 2 * i + 1, 32 - step ~/ 4 - step * i, true, wide: true);
    }
    for (var i = 0; i < half; i++) {
      _sum(i, half + i, false, wide: true);
    }
    if (log == 4) {
      for (var i = 0; i < 2; i++) {
        _rotate(8 + 2 * i, 9 + 2 * i, 28 - 16 * i, true, wide: true);
        _rotate(13 + 2 * i, 12 + 2 * i, 4 + 16 * i, true, wide: true);
      }
      for (var i = 0; i < 4; i++) {
        _sum(i, i + 4, false);
        _sum(i + 8, i + 12, false, wide: true);
      }
    }
    for (var base = 0; base < count; base += 8) {
      for (var i = 0; i < 2; i++) {
        _rotate(base + 4 + 3 * i, base + 5 + i, 24 - 16 * i, true, wide: true);
      }
      for (var i = 0; i < 2; i++) {
        _sum(base + i, base + i + 2, false);
        _sum(base + i + 4, base + i + 6, false, wide: true);
      }
      if (log == 3) {
        _rotate(2, 3, 16, true);
        _rotate(6, 7, 16, true);
      } else {
        _rotate(base + 2, base + 3, base == 0 ? 48 : 112, false);
        _rotate(base + 6, base + 7, base == 0 ? 112 : 48, false);
      }
    }
    _permutation.setRange(0, count, _line);
    for (var i = 0; i < count; i++) {
      final value = _permutation[_reverse(i ^ (i >> 1), log)];
      _line[i] = i.isOdd && (log == 3 || i < 4 || i >= 12) ? -value : value;
    }
  }
}
