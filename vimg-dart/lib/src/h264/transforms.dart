import 'dart:typed_data';

import 'parameters.dart';

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

int chromaQp(int luma, int offset) {
  final index = (luma + offset).clamp(0, 51);
  return index < 30 ? index : _chromaQp[index - 30];
}

final class IntraScaling {
  IntraScaling(H264Pps pps) {
    final seq = pps.sps.scaling;
    final pic = pps.scaling;
    final default4 = _raster(scan4, _default4Scan);
    final seqY = seq == null
        ? List.filled(16, 16)
        : _resolve(seq, 0, scan4, default4, default4);
    final seqCb = seq == null ? seqY : _resolve(seq, 1, scan4, seqY, default4);
    final seqCr = seq == null
        ? seqCb
        : _resolve(seq, 2, scan4, seqCb, default4);
    final seq8 = seq == null
        ? List.filled(64, 16)
        : _resolve(seq, 6, scan8, _default8, _default8);
    if (pic == null) {
      four = [seqY, seqCb, seqCr];
      eight = seq8;
    } else {
      final y = _resolve(
        pic,
        0,
        scan4,
        seq == null ? default4 : seqY,
        default4,
      );
      final cb = _resolve(pic, 1, scan4, y, default4);
      final cr = _resolve(pic, 2, scan4, cb, default4);
      four = [y, cb, cr];
      eight = _resolve(
        pic,
        6,
        scan8,
        seq == null ? _default8 : seq8,
        _default8,
      );
    }
  }

  late final List<List<int>> four;
  late final List<int> eight;

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

/// Inverse scanning, scaling and transforms (§8.5). The residual buffer is
/// reused for each block to keep the frame's working set proportional to pixels.
final class IntraTransform {
  final residual = Int32List(64);
  final _lumaDc = Int32List(16);

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

  Int32List lumaDc(Int32List levels, int qp, int weight) {
    for (var i = 0; i < 16; i++) {
      _lumaDc[scan4[i]] = levels[i];
    }
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

  static List<int> chromaDc(Int32List levels, int start, int qp, int weight) {
    final a = levels[start];
    final b = levels[start + 1];
    final c = levels[start + 2];
    final d = levels[start + 3];
    final scale = _scale4[qp % 6][0] * weight;
    final shift = 5 - qp ~/ 6;
    return [
      for (final dc in [
        a + b + c + d,
        a - b + c - d,
        a + b - c - d,
        a - b - c + d,
      ])
        shift <= 0 ? (dc * scale) << -shift : (dc * scale) >> shift,
    ];
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
