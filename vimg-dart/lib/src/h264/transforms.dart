import 'dart:typed_data';

import 'parameters.dart';
import 'slice_data.dart' show blockX, blockY;

const scan4 = [0, 1, 4, 8, 5, 2, 3, 6, 9, 12, 13, 10, 7, 11, 14, 15];
const scan8 = [
  0,
  1,
  8,
  16,
  9,
  2,
  3,
  10,
  17,
  24,
  32,
  25,
  18,
  11,
  4,
  5,
  12,
  19,
  26,
  33,
  40,
  48,
  41,
  34,
  27,
  20,
  13,
  6,
  7,
  14,
  21,
  28,
  35,
  42,
  49,
  56,
  57,
  50,
  43,
  36,
  29,
  22,
  15,
  23,
  30,
  37,
  44,
  51,
  58,
  59,
  52,
  45,
  38,
  31,
  39,
  46,
  53,
  60,
  61,
  54,
  47,
  55,
  62,
  63,
];

const _scale4 = [
  [10, 13, 16],
  [11, 14, 18],
  [13, 16, 20],
  [14, 18, 23],
  [16, 20, 25],
  [18, 23, 29],
];
const _scale8 = [
  [20, 18, 32, 19, 25, 24],
  [22, 19, 35, 21, 28, 26],
  [26, 23, 42, 24, 33, 31],
  [28, 25, 45, 26, 35, 33],
  [32, 28, 51, 30, 40, 38],
  [36, 32, 58, 34, 46, 43],
];
const _adjust8 = [0, 3, 4, 3, 3, 1, 5, 1, 4, 5, 2, 5, 3, 1, 5, 1];
const _chromaQp = [
  29,
  30,
  31,
  32,
  32,
  33,
  34,
  34,
  35,
  35,
  36,
  36,
  37,
  37,
  37,
  38,
  38,
  38,
  39,
  39,
  39,
  39,
];

int chromaQp(int luma, int offset, int depthOffset) {
  final index = (luma + offset).clamp(-depthOffset, 51);
  return index < 30 ? index : _chromaQp[index - 30];
}

final class ScalingMatrices {
  ScalingMatrices(H264Pps pps) {
    final seq = pps.sps.scaling;
    final pic = pps.scaling;
    List<List<int>> fourGroup(int start, List<int> defaults) {
      var sequence = seq == null ? List.filled(16, 16) : defaults;
      var picture = defaults;
      final weights = <List<int>>[];
      for (var plane = 0; plane < 3; plane++) {
        if (seq != null)
          sequence = _resolve(seq, start + plane, scan4, sequence, defaults);
        if (pic == null) {
          picture = sequence;
        } else {
          final fallback = plane == 0 && seq != null ? sequence : picture;
          picture = _resolve(pic, start + plane, scan4, fallback, defaults);
        }
        weights.add(picture);
      }
      return weights;
    }

    List<int> eightGroup(int index, List<int> defaults) {
      final sequence = seq == null
          ? List.filled(64, 16)
          : _resolve(seq, index, scan8, defaults, defaults);
      return pic == null
          ? sequence
          : _resolve(
              pic,
              index,
              scan8,
              seq == null ? defaults : sequence,
              defaults,
            );
    }

    four = fourGroup(0, _raster(scan4, _default4Scan));
    interFour = fourGroup(3, _defaultInter4);
    eight = eightGroup(6, _default8);
    interEight = eightGroup(7, _defaultInter8);
  }

  late final List<List<int>> four, interFour;
  late final List<int> eight, interEight;

  static List<int> _resolve(
    List<H264ScalingList?> matrices,
    int index,
    List<int> scan,
    List<int> fallback,
    List<int> defaults,
  ) {
    final matrix = index < matrices.length ? matrices[index] : null;
    if (matrix == null) return fallback;
    return matrix.isEmpty ? defaults : _raster(scan, matrix);
  }

  static List<int> _raster(List<int> scan, List<int> weights) {
    final result = List<int>.filled(scan.length, 0);
    for (var i = 0; i < scan.length; i++) {
      result[scan[i]] = weights[i];
    }
    return result;
  }
}

const _default4Scan = [
  6,
  13,
  13,
  20,
  20,
  20,
  28,
  28,
  28,
  28,
  32,
  32,
  32,
  37,
  37,
  42,
];
const _default8 = [
  6,
  10,
  13,
  16,
  18,
  23,
  25,
  27,
  10,
  11,
  16,
  18,
  23,
  25,
  27,
  29,
  13,
  16,
  18,
  23,
  25,
  27,
  29,
  31,
  16,
  18,
  23,
  25,
  27,
  29,
  31,
  33,
  18,
  23,
  25,
  27,
  29,
  31,
  33,
  36,
  23,
  25,
  27,
  29,
  31,
  33,
  36,
  38,
  25,
  27,
  29,
  31,
  33,
  36,
  38,
  40,
  27,
  29,
  31,
  33,
  36,
  38,
  40,
  42,
];

// dart format off
const _defaultInter4 = [
  10, 14, 20, 24, 14, 20, 24, 27,
  20, 24, 27, 30, 24, 27, 30, 34,
];
const _defaultInter8 = [
  9, 13, 15, 17, 19, 21, 22, 24,
  13, 13, 17, 19, 21, 22, 24, 25,
  15, 17, 19, 21, 22, 24, 25, 27,
  17, 19, 21, 22, 24, 25, 27, 28,
  19, 21, 22, 24, 25, 27, 28, 30,
  21, 22, 24, 25, 27, 28, 30, 32,
  22, 24, 25, 27, 28, 30, 32, 33,
  24, 25, 27, 28, 30, 32, 33, 35,
];
// dart format on

/// Inverse scanning, scaling and transforms (§8.5). The residual buffer is
/// reused for each block to keep the frame's working set proportional to pixels.
final class IntraTransform {
  final residual = Int32List(256);
  final _lumaDc = Int32List(16);
  final _chromaDc = Int32List(8);

  void bypassBlock(Int32List levels, int offset, int size, {int mode = 2}) {
    _unscan(levels, offset, size == 8 ? scan8 : scan4, 0, size, size);
    _undoResidualPrediction(size, size, mode);
  }

  void bypassMacroblock(
    Int32List levels,
    int offset,
    List<int> dc,
    int width,
    int height,
    int mode,
  ) {
    final blocksAcross = width ~/ 4;
    for (var i = 0; i < blocksAcross * (height ~/ 4); i++) {
      final x = width == 16 ? blockX(i) : i & 1;
      final y = width == 16 ? blockY(i) : i >> 1;
      final start = 4 * (y * width + x);
      _unscan(levels, offset + i * 16, scan4, start, 4, width);
      residual[start] = dc[y * blocksAcross + x];
    }
    _undoResidualPrediction(width, height, mode);
  }

  void _unscan(
    Int32List levels,
    int offset,
    List<int> scan,
    int start,
    int size,
    int stride,
  ) {
    for (var i = 0; i < scan.length; i++) {
      final position = scan[i];
      residual[start + position ~/ size * stride + position % size] =
          levels[offset + i];
    }
  }

  // Intra horizontal and vertical modes predict from the preceding sample
  // in the bypass residual, including across 4×4 boundaries in a macroblock.
  void _undoResidualPrediction(int width, int height, int mode) {
    if (mode > 1) return;
    final step = mode == 0 ? width : 1;
    for (var y = mode == 0 ? 1 : 0; y < height; y++) {
      for (var x = mode == 1 ? 1 : 0; x < width; x++) {
        final index = y * width + x;
        residual[index] += residual[index - step];
      }
    }
  }

  void block4(
    Int32List levels,
    int offset,
    int qp,
    List<int> weights, {
    int? dc,
  }) {
    final scale = _scale4[qp % 6];
    final shift = 4 - qp ~/ 6;
    for (var i = 0; i < 16; i++) {
      final pos = scan4[i];
      final group = (pos & 1) + ((pos >> 2) & 1);
      residual[pos] = _shift(
        levels[offset + i] * scale[group] * weights[pos],
        shift,
      );
    }
    if (dc != null) residual[0] = dc;
    for (var i = 0; i < 4; i++) {
      _transform4(residual, i * 4, 1);
    }
    for (var i = 0; i < 4; i++) {
      _transform4(residual, i, 4);
    }
    _round(16);
  }

  void block8(Int32List levels, int offset, int qp, List<int> weights) {
    final scale = _scale8[qp % 6];
    final shift = 6 - qp ~/ 6;
    for (var i = 0; i < 64; i++) {
      final pos = scan8[i];
      final group = _adjust8[(((pos >> 3) & 3) << 2) | (pos & 3)];
      residual[pos] = _shift(
        levels[offset + i] * scale[group] * weights[pos],
        shift,
      );
    }
    for (var i = 0; i < 8; i++) {
      _transform8(residual, i * 8, 1);
    }
    for (var i = 0; i < 8; i++) {
      _transform8(residual, i, 8);
    }
    _round(64);
  }

  Int32List lumaDc(
    Int32List levels,
    int qp,
    int weight, {
    bool bypass = false,
  }) {
    for (var i = 0; i < 16; i++) {
      _lumaDc[scan4[i]] = levels[i];
    }
    if (bypass) return _lumaDc;
    for (var i = 0; i < 4; i++) {
      _hadamard4(_lumaDc, i * 4, 1);
    }
    for (var i = 0; i < 4; i++) {
      _hadamard4(_lumaDc, i, 4);
    }
    final scale = _scale4[qp % 6][0] * weight;
    final shift = 6 - qp ~/ 6;
    for (var i = 0; i < 16; i++) {
      _lumaDc[i] = _shift(_lumaDc[i] * scale, shift);
    }
    return _lumaDc;
  }

  void _round(int count) {
    for (var i = 0; i < count; i++) {
      residual[i] = (residual[i] + 32) >> 6;
    }
  }

  List<int> chromaDc(
    Int32List levels,
    int start,
    int count,
    int qp,
    int weight, {
    required bool bypass,
  }) {
    const scan422 = [0, 2, 1, 4, 6, 3, 5, 7];
    for (var i = 0; i < count; i++) {
      _chromaDc[count == 8 ? scan422[i] : i] = levels[start + i];
    }
    if (bypass) return _chromaDc;

    for (var i = 0; i < count; i += 2) {
      final a = _chromaDc[i], b = _chromaDc[i + 1];
      _chromaDc[i] = a + b;
      _chromaDc[i + 1] = a - b;
    }
    if (count == 8) {
      _hadamard4(_chromaDc, 0, 2);
      _hadamard4(_chromaDc, 1, 2);
      final dcQp = qp + 3;
      final scale = _scale4[dcQp % 6][0] * weight;
      final shift = 6 - dcQp ~/ 6;
      for (var i = 0; i < 8; i++) {
        _chromaDc[i] = _shift(_chromaDc[i] * scale, shift);
      }
    } else {
      final shift = 5 - qp ~/ 6;
      final scale = (_scale4[qp % 6][0] * weight) << (shift < 0 ? -shift : 0);
      final fractionBits = shift > 0 ? shift : 0;
      for (var i = 0; i < 2; i++) {
        final a = _chromaDc[i], b = _chromaDc[i + 2];
        _chromaDc[i] = ((a + b) * scale) >> fractionBits;
        _chromaDc[i + 2] = ((a - b) * scale) >> fractionBits;
      }
    }
    return _chromaDc;
  }
}

int _shift(int value, int shift) =>
    shift <= 0 ? value << -shift : (value + (1 << (shift - 1))) >> shift;

void _transform4(Int32List a, int p, int step) {
  final x0 = a[p];
  final x1 = a[p + step];
  final x2 = a[p + 2 * step];
  final x3 = a[p + 3 * step];
  final s0 = x0 + x2, s1 = x0 - x2;
  final s2 = (x1 >> 1) - x3, s3 = x1 + (x3 >> 1);
  a[p] = s0 + s3;
  a[p + step] = s1 + s2;
  a[p + 2 * step] = s1 - s2;
  a[p + 3 * step] = s0 - s3;
}

void _hadamard4(Int32List a, int p, int step) {
  final x0 = a[p];
  final x1 = a[p + step];
  final x2 = a[p + 2 * step];
  final x3 = a[p + 3 * step];
  final s0 = x0 + x3, s1 = x1 + x2, s2 = x0 - x3, s3 = x1 - x2;
  a[p] = s0 + s1;
  a[p + step] = s2 + s3;
  a[p + 2 * step] = s0 - s1;
  a[p + 3 * step] = s2 - s3;
}

void _transform8(Int32List a, int p, int step) {
  final a0 = a[p], a1 = a[p + step], a2 = a[p + 2 * step], a3 = a[p + 3 * step];
  final a4 = a[p + 4 * step],
      a5 = a[p + 5 * step],
      a6 = a[p + 6 * step],
      a7 = a[p + 7 * step];
  final e0 = a0 + a4, e2 = a0 - a4, e4 = (a2 >> 1) - a6, e6 = a2 + (a6 >> 1);
  final e1 = -a3 + a5 - a7 - (a7 >> 1);
  final e3 = a1 + a7 - a3 - (a3 >> 1);
  final e5 = -a1 + a7 + a5 + (a5 >> 1);
  final e7 = a3 + a5 + a1 + (a1 >> 1);

  final f0 = e0 + e6, f2 = e2 + e4, f4 = e2 - e4, f6 = e0 - e6;
  final f1 = e1 + (e7 >> 2),
      f3 = e3 + (e5 >> 2),
      f5 = (e3 >> 2) - e5,
      f7 = e7 - (e1 >> 2);
  a[p] = f0 + f7;
  a[p + step] = f2 + f5;
  a[p + 2 * step] = f4 + f3;
  a[p + 3 * step] = f6 + f1;
  a[p + 4 * step] = f6 - f1;
  a[p + 5 * step] = f4 - f3;
  a[p + 6 * step] = f2 - f5;
  a[p + 7 * step] = f0 - f7;
}
