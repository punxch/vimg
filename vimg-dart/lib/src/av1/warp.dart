import 'dart:math' as math;
import 'dart:typed_data';

import 'inter_prediction.dart';
import 'inter_prediction_tables.dart';
import 'motion_vectors.dart';
import 'transform.dart';

typedef Av1WarpSample = ({int x, int y, Av1Mv mv});

List<Av1WarpSample> av1WarpSamples(
  int x,
  int y,
  int w4,
  int h4,
  int ref,
  Av1Mv mv,
  Av1InterNeighbor? Function(int x, int y) neighbor,
) {
  final samples = <Av1WarpSample>[];
  void add(int x, int y, Av1InterNeighbor? block) {
    final m = block?.motion;
    if (m == null || m.ref0 != ref || m.ref1 != -1 || samples.length >= 8)
      return;
    final bx = x & -block!.width4, by = y & -block.height4;
    samples.add((
      x: (bx * 4 + block.width4 * 2 - 1) * 8,
      y: (by * 4 + block.height4 * 2 - 1) * 8,
      mv: m.mv0,
    ));
  }

  var topLeft = true, topRight = true;
  final above = neighbor(x, y - 1), left = neighbor(x - 1, y);
  if (above != null) {
    if (above.width4 >= w4) {
      final off = x & (above.width4 - 1);
      topLeft = off == 0;
      topRight = above.width4 - off <= w4;
      add(x, y - 1, above);
    } else {
      for (var i = 0; i < w4 && samples.length < 8;) {
        final b = neighbor(x + i, y - 1);
        if (b == null) break;
        add(x + i, y - 1, b);
        i += math.min(w4, b.width4);
      }
    }
  }
  if (left != null) {
    if (left.height4 >= h4) {
      topLeft &= (y & (left.height4 - 1)) == 0;
      add(x - 1, y, left);
    } else {
      for (var i = 0; i < h4 && samples.length < 8;) {
        final b = neighbor(x - 1, y + i);
        if (b == null) break;
        add(x - 1, y + i, b);
        i += math.min(h4, b.height4);
      }
    }
  }
  if (topLeft) add(x - 1, y - 1, neighbor(x - 1, y - 1));
  if (topRight && math.max(w4, h4) <= 16) {
    add(x + w4, y - 1, neighbor(x + w4, y - 1));
  }
  if (samples.isEmpty) return samples;
  final threshold = (4 * math.max(w4, h4)).clamp(16, 112);
  final filtered = samples
      .where((p) => (p.mv.x - mv.x).abs() + (p.mv.y - mv.y).abs() <= threshold)
      .toList();
  return filtered.isEmpty ? [samples.first] : filtered;
}

List<int>? av1EstimateWarp(
  List<Av1WarpSample> points,
  int x4,
  int y4,
  int w4,
  int h4,
  Av1Mv mv,
) {
  final midX = x4 * 4 + w4 * 2 - 1, midY = y4 * 4 + h4 * 2 - 1;
  final sx = midX * 8, sy = midY * 8;
  var xx = 0, xy = 0, yy = 0, ux = 0, uy = 0, vx = 0, vy = 0;
  int ls(int a, int b) => ((a * b) >> 2) + a + b;
  for (final sample in points) {
    final x = sample.x - sx, y = sample.y - sy;
    final dx = sample.mv.x - mv.x, dy = sample.mv.y - mv.y;
    if (dx.abs() >= 256 || dy.abs() >= 256) continue;
    final u = x + dx, v = y + dy;
    xx += ls(x, x) + 8;
    xy += ls(x, y) + 4;
    yy += ls(y, y) + 8;
    ux += ls(x, u) + 8;
    uy += ls(y, u) + 4;
    vx += ls(x, v) + 4;
    vy += ls(y, v) + 8;
  }

  final determinant = xx * yy - xy * xy;
  if (determinant == 0) return null;
  final (factor, shift) = _resolveDivisor(determinant);
  int normalize(int value, int base) {
    final product = value * factor;
    final adjusted = shift < 16
        ? product << (16 - shift)
        : _roundSigned(product, shift - 16);
    return adjusted.clamp(base - 8191, base + 8191);
  }

  final a = normalize(yy * ux - xy * uy, 65536);
  final b = normalize(xx * uy - xy * ux, 0);
  final c = normalize(yy * vx - xy * vy, 0);
  final d = normalize(xx * vy - xy * vx, 65536);
  final tx = (mv.x * 8192 - midX * (a - 65536) - midY * b).clamp(
    -8388608,
    8388607,
  );
  final ty = (mv.y * 8192 - midX * c - midY * (d - 65536)).clamp(
    -8388608,
    8388607,
  );
  return [tx, ty, a, b, c, d];
}

(int, int, int, int)? _shear(List<int> m) {
  if (m[2] == 0) return null;
  final (factor, shift) = _resolveDivisor(m[2]);
  int reduce(int v) => _roundSigned(v.clamp(-32768, 32767), 6) << 6;
  final a = reduce(m[2] - 65536), b = reduce(m[3]);
  final c = reduce(_roundSigned((m[4] << 16) * factor, shift));
  final d = reduce(m[5] - _roundSigned(m[3] * m[4] * factor, shift) - 65536);
  if (4 * a.abs() + 7 * b.abs() >= 65536 || 4 * c.abs() + 4 * d.abs() >= 65536)
    return null;
  return (a, b, c, d);
}

(int, int) _resolveDivisor(int divisor) {
  final v = divisor.abs(), bits = divisor.abs().bitLength - 1;
  final residual = v - (1 << bits);
  final index = bits > 8
      ? av1Round(residual, bits - 8)
      : residual << (8 - bits);
  final n = 256 + index;
  return (divisor.sign * (((1 << 22) + (n >> 1)) ~/ n), bits + 14);
}

int _roundSigned(int v, int bits) => v.sign * av1Round(v.abs(), bits);

/// §7.11.3.5 warped compensation in 8×8 regions.
final class Av1WarpPredictor {
  final _intermediate = Int32List(15 * 8);

  bool apply(
    Int32List output,
    Uint16List source,
    List<int> matrix, {
    required int x,
    required int y,
    required int width,
    required int height,
    required int stride,
    required int lastX,
    required int lastY,
    required int sx,
    required int sy,
    required int depth,
    required bool compound,
  }) {
    final shear = _shear(matrix);
    if (shear == null) return false;
    final (alpha, beta, gamma, delta) = shear;
    final round0 = depth == 12 ? 5 : 3;
    final round1 = compound ? 7 : 14 - round0;
    for (var by = 0; by < height; by += 8) {
      for (var bx = 0; bx < width; bx += 8) {
        final px = (x + bx + 4) << sx, py = (y + by + 4) << sy;
        final tx = (matrix[2] * px + matrix[3] * py + matrix[0]) >> sx;
        final ty = (matrix[4] * px + matrix[5] * py + matrix[1]) >> sy;
        final ix = tx >> 16, iy = ty >> 16;
        final fx = tx & 65535, fy = ty & 65535;
        for (var r = -7; r < 8; r++) {
          final src = (iy + r).clamp(0, lastY) * stride;
          for (var c = -4; c < 4; c++) {
            final phase = (64 + av1Round(fx + alpha * c + beta * r, 10)).clamp(
              0,
              192,
            );
            final filter = av1WarpedFilters[phase];
            var sum = 0;
            for (var i = 0; i < 8; i++) {
              sum += filter[i] * source[src + (ix + c - 3 + i).clamp(0, lastX)];
            }
            _intermediate[(r + 7) * 8 + c + 4] = av1Round(sum, round0);
          }
        }
        final w = math.min(8, width - bx), h = math.min(8, height - by);
        for (var r = 0; r < h; r++) {
          for (var c = 0; c < w; c++) {
            final phase =
                (64 + av1Round(fy + gamma * (c - 4) + delta * (r - 4), 10))
                    .clamp(0, 192);
            final filter = av1WarpedFilters[phase];
            var sum = 0;
            for (var i = 0; i < 8; i++) {
              sum += filter[i] * _intermediate[(r + i) * 8 + c];
            }
            output[(by + r) * width + bx + c] = av1Round(sum, round1);
          }
        }
      }
    }
    return true;
  }
}
