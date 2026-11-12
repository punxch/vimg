import 'dart:math' as math;
import 'dart:typed_data';

import 'frame_parameters.dart';

const _directions = [
  [(-1, 1), (-2, 2)],
  [(0, 1), (-1, 2)],
  [(0, 1), (0, 2)],
  [(0, 1), (1, 2)],
  [(1, 1), (2, 2)],
  [(1, 0), (2, 1)],
  [(1, 0), (2, 0)],
  [(1, 0), (2, -1)],
];

/// AV1 §7.15. CDEF reads the deblocked frame and writes each region once.
final class Av1CdefFilter {
  Av1CdefFilter(this.params, this.depth, this.sx, this.sy);

  final Av1Cdef params;
  final int depth, sx, sy;
  final _partial = Int32List(8 * 15);
  final _cost = Int32List(8);

  void apply(
    List<Uint16List> planes,
    List<int> strides,
    int width,
    int height, {
    required int Function(int x4, int y4) index,
    required bool Function(int x4, int y4) skip,
  }) {
    final w = (width + 7) & -8, h = (height + 7) & -8;
    final shift = depth - 8;
    final source = [for (final plane in planes) Uint16List.fromList(plane)];
    for (var y = 0; y < h; y += 8) {
      for (var x = 0; x < w; x += 8) {
        final y4 = y >> 2, x4 = x >> 2;
        final idx = index(x4, y4);
        if (idx < 0 ||
            (skip(x4, y4) &&
                skip(x4 + 1, y4) &&
                skip(x4, y4 + 1) &&
                skip(x4 + 1, y4 + 1))) {
          continue;
        }
        final luma = params.y[idx];
        final uv = params.uv.isEmpty
            ? (primary: 0, secondary: 0)
            : params.uv[idx];
        if (luma.primary == 0 &&
            luma.secondary == 0 &&
            uv.primary == 0 &&
            uv.secondary == 0) {
          continue;
        }
        final (direction, variance) = _direction(
          source[0],
          strides[0],
          x,
          y,
          shift,
        );
        final adjust = ((variance >> 6).bitLength - 1).clamp(0, 12);
        final yPrimary = variance == 0
            ? 0
            : (((luma.primary << shift) * (4 + adjust) + 8) >> 4);
        _filter(
          source[0],
          planes[0],
          strides[0],
          w,
          h,
          x,
          y,
          8,
          8,
          yPrimary,
          luma.secondary << shift,
          params.damping + shift,
          luma.primary == 0 ? 0 : direction,
          shift,
        );
        final chromaDirection = uv.primary == 0
            ? 0
            : switch ((sx, sy)) {
                (1, 0) => const [7, 0, 2, 4, 5, 6, 6, 6][direction],
                (0, 1) => const [1, 2, 2, 2, 3, 4, 6, 0][direction],
                _ => direction,
              };
        for (var p = 1; p < planes.length; p++) {
          _filter(
            source[p],
            planes[p],
            strides[p],
            w >> sx,
            h >> sy,
            x >> sx,
            y >> sy,
            8 >> sx,
            8 >> sy,
            uv.primary << shift,
            uv.secondary << shift,
            params.damping + shift - 1,
            chromaDirection,
            shift,
          );
        }
      }
    }
  }

  (int, int) _direction(
    Uint16List pixels,
    int stride,
    int x,
    int y,
    int shift,
  ) {
    _partial.fillRange(0, _partial.length, 0);
    for (var r = 0; r < 8; r++) {
      for (var c = 0; c < 8; c++) {
        final v = (pixels[(y + r) * stride + x + c] >> shift) - 128;
        _partial[r + c] += v;
        _partial[15 + r + (c >> 1)] += v;
        _partial[30 + r] += v;
        _partial[45 + 3 + r - (c >> 1)] += v;
        _partial[60 + 7 + r - c] += v;
        _partial[75 + 3 - (r >> 1) + c] += v;
        _partial[90 + c] += v;
        _partial[105 + (r >> 1) + c] += v;
      }
    }
    var best = 0;
    for (var d = 0; d < 8; d++) {
      final start = d * 15;
      var cost = 0;
      final lengths = _lineLengths[d];
      for (var i = 0; i < lengths.length; i++) {
        final v = _partial[start + i];
        cost += v * v * (840 ~/ lengths[i]);
      }
      _cost[d] = cost;
      if (cost > _cost[best]) best = d;
    }
    return (best, (_cost[best] - _cost[(best + 4) & 7]) >> 10);
  }

  void _filter(
    Uint16List src,
    Uint16List dst,
    int stride,
    int width,
    int height,
    int x,
    int y,
    int w,
    int h,
    int primary,
    int secondary,
    int damping,
    int direction,
    int shift,
  ) {
    if (primary == 0 && secondary == 0) return;
    final priTap = ((primary >> shift) & 1) == 0 ? const [4, 2] : const [3, 3];
    final pShift = math.max(0, damping - primary.bitLength + 1);
    final sShift = math.max(0, damping - secondary.bitLength + 1);
    for (var r = y; r < y + h; r++) {
      for (var c = x; c < x + w; c++) {
        final at = r * stride + c;
        final center = src[at];
        var sum = 0, lo = center, hi = center;
        for (var k = 0; k < 2; k++) {
          for (var d = -2; d <= 2; d += 2) {
            final (dy, dx) = _directions[(direction + d) & 7][k];
            final threshold = d == 0 ? primary : secondary;
            final damp = d == 0 ? pShift : sShift;
            final weight = d == 0 ? priTap[k] : 2 - k;
            for (var sign = -1; sign <= 1; sign += 2) {
              final yy = r + sign * dy, xx = c + sign * dx;
              if (yy < 0 || yy >= height || xx < 0 || xx >= width) continue;
              final value = src[yy * stride + xx];
              lo = math.min(lo, value);
              hi = math.max(hi, value);
              final diff = value - center, magnitude = diff.abs();
              final constrained = math.min<int>(
                magnitude,
                math.max<int>(0, threshold - (magnitude >> damp)),
              );
              sum += weight * diff.sign * constrained;
            }
          }
        }
        dst[at] = (center + ((8 + sum - (sum < 0 ? 1 : 0)) >> 4)).clamp(lo, hi);
      }
    }
  }
}

const _diagonal = [1, 2, 3, 4, 5, 6, 7, 8, 7, 6, 5, 4, 3, 2, 1];
const _oblique = [2, 4, 6, 8, 8, 8, 8, 8, 6, 4, 2];
const _straight = [8, 8, 8, 8, 8, 8, 8, 8];
const _lineLengths = [
  _diagonal,
  _oblique,
  _straight,
  _oblique,
  _diagonal,
  _oblique,
  _straight,
  _oblique,
];
