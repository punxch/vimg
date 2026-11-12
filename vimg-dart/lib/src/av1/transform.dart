import 'dart:math' as math;
import 'dart:typed_data';

/// Transform dimensions in AV1 bitstream table order.
enum Av1TxSize {
  tx4x4(4, 4, 0),
  tx8x8(8, 8, 1),
  tx16x16(16, 16, 2),
  tx32x32(32, 32, 2),
  tx64x64(64, 64, 2),
  tx4x8(4, 8, 0),
  tx8x4(8, 4, 0),
  tx8x16(8, 16, 1),
  tx16x8(16, 8, 1),
  tx16x32(16, 32, 1),
  tx32x16(32, 16, 1),
  tx32x64(32, 64, 1),
  tx64x32(64, 32, 1),
  tx4x16(4, 16, 1),
  tx16x4(16, 4, 1),
  tx8x32(8, 32, 2),
  tx32x8(32, 8, 2),
  tx16x64(16, 64, 2),
  tx64x16(64, 16, 2);

  const Av1TxSize(this.width, this.height, this.rowShift);

  final int width, height, rowShift;

  int get square => math.min(width, height).bitLength - 3;
  int get squareUp => math.max(width, height).bitLength - 3;
  int get coefficientContext => (square + squareUp + 1) >> 1;
  int get coefficientWidth => math.min(width, 32);
  int get coefficientHeight => math.min(height, 32);
  int get quantShift => width * height > 1024
      ? 2
      : width * height > 256
      ? 1
      : 0;

  static final _byDimensions = {
    for (final size in values) (size.width, size.height): size,
  };

  static Av1TxSize of(int width, int height) =>
      _byDimensions[(width, height)] ??
      (throw FormatException(
        'Invalid AV1 transform dimensions ${width}×$height',
      ));
}

enum _Kernel { dct, adst, flippedAdst, identity }

enum Av1TxClass { twoDimensional, horizontal, vertical }

/// AV1 transform type order. The name lists column kernel before row kernel.
enum Av1TxType {
  dctDct(_Kernel.dct, _Kernel.dct),
  adstDct(_Kernel.adst, _Kernel.dct),
  dctAdst(_Kernel.dct, _Kernel.adst),
  adstAdst(_Kernel.adst, _Kernel.adst),
  flipAdstDct(_Kernel.flippedAdst, _Kernel.dct),
  dctFlipAdst(_Kernel.dct, _Kernel.flippedAdst),
  flipAdstFlipAdst(_Kernel.flippedAdst, _Kernel.flippedAdst),
  adstFlipAdst(_Kernel.adst, _Kernel.flippedAdst),
  flipAdstAdst(_Kernel.flippedAdst, _Kernel.adst),
  identity(_Kernel.identity, _Kernel.identity),
  vDct(_Kernel.dct, _Kernel.identity),
  hDct(_Kernel.identity, _Kernel.dct),
  vAdst(_Kernel.adst, _Kernel.identity),
  hAdst(_Kernel.identity, _Kernel.adst),
  vFlipAdst(_Kernel.flippedAdst, _Kernel.identity),
  hFlipAdst(_Kernel.identity, _Kernel.flippedAdst);

  const Av1TxType(this._column, this._row);

  final _Kernel _column, _row;

  Av1TxClass get txClass => index < 10
      ? Av1TxClass.twoDimensional
      : index.isEven
      ? Av1TxClass.vertical
      : Av1TxClass.horizontal;
}

int av1Round(int value, int shift) =>
    shift == 0 ? value : (value + (1 << (shift - 1))) >> shift;

/// AV1 §7.13 inverse transforms, including the lossless 4×4 WHT.
final class Av1InverseTransform {
  final _line = Int32List(64);
  final _permutation = Int32List(64);

  /// [coefficients] uses the compact coefficient grid, capped at 32 per axis.
  /// The first width × height entries of [residual] receive raster samples.
  void apply(
    Int32List coefficients,
    Int32List residual,
    Av1TxSize size,
    Av1TxType type,
    int depth, {
    required bool lossless,
  }) {
    final width = size.width, height = size.height;
    final cw = size.coefficientWidth, ch = size.coefficientHeight;
    final logW = width.bitLength - 1, logH = height.bitLength - 1;
    final rowLimit = 1 << (depth + 7);
    final columnLimit = 1 << math.max(depth + 5, 15);
    final rowShift = lossless ? 0 : size.rowShift;
    final rect = (logW - logH).abs() == 1;
    for (var y = 0; y < height; y++) {
      final row = y * width;
      if (y >= ch) {
        residual.fillRange(row, row + width, 0);
        continue;
      }
      var nonzero = false;
      for (var x = 0; x < cw; x++) {
        final v = coefficients[y * cw + x];
        nonzero |= v != 0;
        _line[x] = rect ? av1Round(v * 2896, 12) : v;
      }
      if (!nonzero) {
        residual.fillRange(row, row + width, 0);
        continue;
      }
      _line.fillRange(cw, width, 0);
      if (lossless) {
        _wht(2);
      } else {
        _kernel(type._row, logW, rowLimit);
      }
      final flip = type._row == _Kernel.flippedAdst;
      for (var x = 0; x < width; x++) {
        final value = av1Round(_line[flip ? width - 1 - x : x], rowShift);
        residual[row + x] = value.clamp(-columnLimit, columnLimit - 1);
      }
    }
    for (var x = 0; x < width; x++) {
      var nonzero = false;
      for (var y = 0; y < height; y++) {
        final value = residual[y * width + x];
        nonzero |= value != 0;
        _line[y] = value;
      }
      if (!nonzero) continue;
      if (lossless) {
        _wht(0);
      } else {
        _kernel(type._column, logH, columnLimit);
      }
      final flip = type._column == _Kernel.flippedAdst;
      for (var y = 0; y < height; y++) {
        residual[y * width + x] = av1Round(
          _line[flip ? height - 1 - y : y],
          lossless ? 0 : 4,
        );
      }
    }
  }

  void _kernel(_Kernel kernel, int log, int limit) {
    switch (kernel) {
      case _Kernel.dct:
        _dct(log, limit);
      case _Kernel.adst || _Kernel.flippedAdst:
        _adst(log, limit);
      case _Kernel.identity:
        final (scale, shift) = switch (log) {
          2 => (5793, 12),
          3 => (2, 0),
          4 => (11586, 12),
          5 => (4, 0),
          _ => throw const FormatException(
            'Invalid AV1 identity transform size',
          ),
        };
        for (var i = 0; i < 1 << log; i++) {
          _line[i] = av1Round(_line[i] * scale, shift);
        }
    }
  }

  void _wht(int shift) {
    final a = (_line[0] >> shift) + (_line[1] >> shift);
    final c = _line[1] >> shift;
    final b = _line[3] >> shift;
    final d = (_line[2] >> shift) - b;
    final e = (a - d) >> 1;
    _line[0] = a - (e - b);
    _line[1] = e - b;
    _line[2] = e - c;
    _line[3] = d + (e - c);
  }

  void _rotate(int a, int b, int angle, int flip) {
    final cosine = _cosine(angle), sine = _cosine(angle - 64);
    final x = _line[a], y = _line[b];
    _line[flip == 0 ? a : b] = av1Round(x * cosine - y * sine, 12);
    _line[flip == 0 ? b : a] = av1Round(x * sine + y * cosine, 12);
  }

  void _sum(int a, int b, int flip, int limit) {
    final i = flip == 0 ? a : b, j = flip == 0 ? b : a;
    final x = _line[i], y = _line[j];
    _line[i] = (x + y).clamp(-limit, limit - 1);
    _line[j] = (x - y).clamp(-limit, limit - 1);
  }

  void _adst(int log, int limit) {
    if (log == 2) {
      final x = _line[0], y = _line[1], z = _line[2], w = _line[3];
      final a = 1321 * x + 3803 * z + 2482 * w;
      final b = 2482 * x - 1321 * z - 3803 * w;
      final c = 3344 * y;
      _line[0] = av1Round(a + c, 12);
      _line[1] = av1Round(b + c, 12);
      _line[2] = av1Round(3344 * (x - z + w), 12);
      _line[3] = av1Round(a + b - c, 12);
      return;
    }
    if (log != 3 && log != 4)
      throw const FormatException('Invalid AV1 ADST size');
    final size = 1 << log;
    _permutation.setRange(0, size, _line);
    for (var i = 0; i < size; i++) {
      _line[i] = _permutation[i.isOdd ? i - 1 : size - i - 1];
    }
    final half = size >> 1;
    final step = 128 ~/ size;
    for (var i = 0; i < half; i++) {
      _rotate(2 * i, 2 * i + 1, 64 - step ~/ 4 - step * i, 1);
    }
    for (var i = 0; i < half; i++) {
      _sum(i, half + i, 0, limit);
    }
    if (log == 4) {
      for (var i = 0; i < 2; i++) {
        _rotate(8 + 2 * i, 9 + 2 * i, 56 - 32 * i, 1);
        _rotate(13 + 2 * i, 12 + 2 * i, 8 + 32 * i, 1);
      }
      for (var j = 0; j < size; j += 8) {
        for (var i = 0; i < 4; i++) {
          _sum(j + i, j + i + 4, 0, limit);
        }
      }
    }
    for (var j = 0; j < size; j += 8) {
      for (var i = 0; i < 2; i++) {
        _rotate(4 + j + 3 * i, 5 + j + i, 48 - 32 * i, 1);
      }
    }
    for (var j = 0; j < size; j += 4) {
      _sum(j, j + 2, 0, limit);
      _sum(j + 1, j + 3, 0, limit);
      _rotate(j + 2, j + 3, 32, 1);
    }
    _permutation.setRange(0, size, _line);
    for (var i = 0; i < size; i++) {
      final value = _permutation[_reverse(log, i ^ (i >> 1))];
      _line[i] = i.isOdd ? -value : value;
    }
  }

  void _dct(int n, int limit) {
    final size = 1 << n;
    _permutation.setRange(0, size, _line);
    for (var i = 0; i < size; i++) {
      _line[i] = _permutation[_reverse(n, i)];
    }
    if (n == 6) {
      for (var i = 0; i < 16; i++) {
        final a = 32 + i;
        final b = 63 - i;
        final angle = 63 - 4 * (_reverse(4, i));
        _rotate(a, b, angle, 0);
      }
    }
    if (n >= 5) {
      for (var i = 0; i < 8; i++) {
        final a = 16 + i;
        final b = 31 - i;
        final angle = 6 + ((_reverse(3, (7 - i))) << 3);
        _rotate(a, b, angle, 0);
      }
    }
    if (n == 6) {
      for (var i = 0; i < 16; i++) {
        _sum(32 + i * 2, 33 + i * 2, i & 1, limit);
      }
    }
    if (n >= 4) {
      for (var i = 0; i < 4; i++) {
        final a = 8 + i;
        final b = 15 - i;
        final angle = 12 + ((_reverse(2, (3 - i))) << 4);
        _rotate(a, b, angle, 0);
      }
    }
    if (n >= 5) {
      for (var i = 0; i < 8; i++) {
        _sum(16 + 2 * i, 17 + 2 * i, i & 1, limit);
      }
    }
    if (n == 6) {
      for (var i = 0; i < 4; i++) {
        for (var j = 0; j < 2; j++) {
          final a = 62 - i * 4 - j;
          final b = 33 + i * 4 + j;
          final angle = 60 - 16 * (_reverse(2, i)) + 64 * (j);
          _rotate(a, b, angle, 1);
        }
      }
    }
    if (n >= 3) {
      for (var i = 0; i < 2; i++) {
        _rotate(4 + i, 7 - i, 56 - 32 * (i), 0);
      }
    }
    if (n >= 4) {
      for (var i = 0; i < 4; i++) {
        _sum(8 + 2 * i, 9 + 2 * i, i & 1, limit);
      }
    }
    if (n >= 5) {
      for (var i = 0; i < 2; i++) {
        for (var j = 0; j < 2; j++) {
          final a = 30 - 4 * i - j;
          final b = 17 + 4 * i + j;
          final angle = 24 + ((j) << 6) + (((1 - i)) << 5);
          _rotate(a, b, angle, 1);
        }
      }
    }
    if (n == 6) {
      for (var i = 0; i < 8; i++) {
        for (var j = 0; j < 2; j++) {
          final a = 32 + i * 4 + j;
          final b = 35 + i * 4 - j;
          _sum(a, b, i & 1, limit);
        }
      }
    }
    for (var i = 0; i < 2; i++) {
      _rotate(2 * i, 2 * i + 1, 32 + 16 * (i), (1 - i));
    }
    if (n >= 3) {
      for (var i = 0; i < 2; i++) {
        _sum(4 + 2 * i, 5 + 2 * i, i, limit);
      }
    }
    if (n >= 4) {
      for (var i = 0; i < 2; i++) {
        _rotate(14 - i, 9 + i, 48 + 64 * (i), 1);
      }
    }
    if (n >= 5) {
      for (var i = 0; i < 4; i++) {
        for (var j = 0; j < 2; j++) {
          final a = 16 + 4 * i + j;
          final b = 19 + 4 * i - j;
          _sum(a, b, i & 1, limit);
        }
      }
    }
    if (n == 6) {
      for (var i = 0; i < 2; i++) {
        for (var j = 0; j < 4; j++) {
          final a = 61 - i * 8 - j;
          final b = 34 + i * 8 + j;
          final angle = 56 - (i) * 32 + ((j >> 1)) * 64;
          _rotate(a, b, angle, 1);
        }
      }
    }
    for (var i = 0; i < 2; i++) {
      _sum(i, 3 - i, 0, limit);
    }
    if (n >= 3) {
      _rotate(6, 5, 32, 1);
    }
    if (n >= 4) {
      for (var i = 0; i < 2; i++) {
        for (var j = 0; j < 2; j++) {
          _sum(8 + 4 * i + j, 11 + 4 * i - j, i, limit);
        }
      }
    }
    if (n >= 5) {
      for (var i = 0; i < 4; i++) {
        _rotate(29 - i, 18 + i, 48 + ((i >> 1)) * 64, 1);
      }
    }
    if (n == 6) {
      for (var i = 0; i < 4; i++) {
        for (var j = 0; j < 4; j++) {
          final a = 32 + 8 * i + j;
          final b = 39 + 8 * i - j;
          _sum(a, b, i & 1, limit);
        }
      }
    }
    if (n >= 3) {
      for (var i = 0; i < 4; i++) {
        _sum(i, 7 - i, 0, limit);
      }
    }
    if (n >= 4) {
      for (var i = 0; i < 2; i++) {
        _rotate(13 - i, 10 + i, 32, 1);
      }
    }
    if (n >= 5) {
      for (var i = 0; i < 2; i++) {
        for (var j = 0; j < 4; j++) {
          final a = 16 + i * 8 + j;
          final b = 23 + i * 8 - j;
          _sum(a, b, i, limit);
        }
      }
    }
    if (n == 6) {
      for (var i = 0; i < 8; i++) {
        final angle = i < 4 ? 48 : 112;
        _rotate(59 - i, 36 + i, angle, 1);
      }
    }
    if (n >= 4) {
      for (var i = 0; i < 8; i++) {
        _sum(i, 15 - i, 0, limit);
      }
    }
    if (n >= 5) {
      for (var i = 0; i < 4; i++) {
        _rotate(27 - i, 20 + i, 32, 1);
      }
    }
    if (n == 6) {
      for (var i = 0; i < 8; i++) {
        _sum(32 + i, 47 - i, 0, limit);
        _sum(48 + i, 63 - i, 1, limit);
      }
    }
    if (n >= 5) {
      for (var i = 0; i < 16; i++) {
        _sum(i, 31 - i, 0, limit);
      }
    }
    if (n == 6) {
      for (var i = 0; i < 8; i++) {
        _rotate(55 - i, 40 + i, 32, 1);
      }
    }
    if (n == 6) {
      for (var i = 0; i < 32; i++) {
        _sum(i, 63 - i, 0, limit);
      }
    }
  }
}

int _reverse(int bits, int value) {
  var result = 0;
  for (var i = 0; i < bits; i++) {
    result = (result << 1) | ((value >> i) & 1);
  }
  return result;
}

int _cosine(int angle) {
  final phase = angle & 255;
  if (phase <= 64) return _cos128[phase];
  if (phase <= 128) return -_cos128[128 - phase];
  if (phase <= 192) return -_cos128[phase - 128];
  return _cos128[256 - phase];
}

const _cos128 = [
  4096,
  4095,
  4091,
  4085,
  4076,
  4065,
  4052,
  4036,
  4017,
  3996,
  3973,
  3948,
  3920,
  3889,
  3857,
  3822,
  3784,
  3745,
  3703,
  3659,
  3612,
  3564,
  3513,
  3461,
  3406,
  3349,
  3290,
  3229,
  3166,
  3102,
  3035,
  2967,
  2896,
  2824,
  2751,
  2675,
  2598,
  2520,
  2440,
  2359,
  2276,
  2191,
  2106,
  2019,
  1931,
  1842,
  1751,
  1660,
  1567,
  1474,
  1380,
  1285,
  1189,
  1092,
  995,
  897,
  799,
  700,
  601,
  501,
  401,
  301,
  201,
  101,
  0,
];
