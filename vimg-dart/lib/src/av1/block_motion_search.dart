part of 'dct_encoder.dart';

/// Search the reconstructed luma at integer positions and refine to quarter-pels.
/// The score combines sampled SAD and the estimated cost of signaling a vector.
final class _BlockMotionSearch {
  _BlockMotionSearch(
    this.width,
    this.height,
    this.stride,
    this.source,
    this.reference,
    this.quantStep,
  );

  static const _radius = 12;
  static const _span = _radius * 2 + 1;
  final int width, height, stride, quantStep;
  final Uint16List source, reference;
  final _tested = Uint32List(_span * _span);
  var _block = 0;

  Av1Mv find(int x, int y, int side, Av1MvStack stack) {
    _block++;
    final w = math.min(side, width - x), h = math.min(side, height - y);
    final nearest = stack.entries[0].mv.$1, near = stack.entries[1].mv.$1;
    final lambda = (quantStep + 7) >> 3;
    final zeroSad = _sad(x, y, w, h, 0, 0);
    final samples = ((w + 1) >> 1) * ((h + 1) >> 1);
    if (zeroSad * 32 <= quantStep * samples) return av1ZeroMv;

    var bestCost = zeroSad;
    var bestX = 0, bestY = 0;
    _tested[_radius * _span + _radius] = _block;
    void consider(int dx, int dy) {
      if (dx.abs() > _radius || dy.abs() > _radius) return;
      final index = (dy + _radius) * _span + dx + _radius;
      if (_tested[index] == _block) return;
      _tested[index] = _block;
      final x8 = dx << 3, y8 = dy << 3;
      final bits = Av1SingleReferenceMotionEncoder.estimatedBits(stack, (
        x: x8,
        y: y8,
      ));
      final penalty = lambda * bits;
      if (penalty >= bestCost) return;
      final sad = _sad(x, y, w, h, dx, dy, bestCost - penalty);
      final cost = sad + penalty;
      if (cost < bestCost) {
        bestCost = cost;
        bestX = dx;
        bestY = dy;
      }
    }

    consider(nearest.x >> 3, nearest.y >> 3);
    consider(near.x >> 3, near.y >> 3);
    for (var dy = -3; dy <= 3; dy++) {
      for (var dx = -3; dx <= 3; dx++) {
        consider(dx, dy);
      }
    }
    for (var dy = -8; dy <= 8; dy += 4) {
      for (var dx = -8; dx <= 8; dx += 4) {
        consider(dx, dy);
      }
    }
    for (final step in [2, 1]) {
      final centerX = bestX, centerY = bestY;
      for (var dy = -step; dy <= step; dy += step) {
        for (var dx = -step; dx <= step; dx += step) {
          consider(centerX + dx, centerY + dy);
        }
      }
    }
    final center = (x: bestX << 3, y: bestY << 3);
    var result = center;
    void refine(Av1Mv mv) {
      if (((mv.x | mv.y) & 7) == 0 ||
          mv.x.abs() > (_radius << 3) ||
          mv.y.abs() > (_radius << 3))
        return;
      final penalty =
          lambda * Av1SingleReferenceMotionEncoder.estimatedBits(stack, mv);
      if (penalty >= bestCost) return;
      final sad = _fractionalSad(x, y, w, h, mv, bestCost - penalty);
      if (sad + penalty < bestCost) {
        bestCost = sad + penalty;
        result = mv;
      }
    }

    refine(nearest);
    refine(near);
    for (final step in [4, 2]) {
      final center = result;
      for (var dy = -step; dy <= step; dy += step) {
        for (var dx = -step; dx <= step; dx += step) {
          if (dx != 0 || dy != 0) {
            refine((x: center.x + dx, y: center.y + dy));
          }
        }
      }
    }
    return result;
  }

  int _sad(int x, int y, int w, int h, int dx, int dy, [int? limit]) {
    final startX = x + dx, startY = y + dy;
    final inside =
        startX >= 0 &&
        startY >= 0 &&
        startX + w <= width &&
        startY + h <= height;
    var cost = 0;
    for (var row = 0; row < h; row += 2) {
      final current = (y + row) * stride + x;
      final previousY = inside
          ? startY + row
          : (startY + row).clamp(0, height - 1);
      final previous = previousY * stride;
      for (var col = 0; col < w; col += 2) {
        final previousX = inside
            ? startX + col
            : (startX + col).clamp(0, width - 1);
        cost += (source[current + col] - reference[previous + previousX]).abs();
      }
      if (limit != null && cost >= limit) break;
    }
    return cost;
  }

  // Bilinear sampling ranks fractional candidates. The chosen vector is
  // reconstructed with the normative AV1 filter before residual comparison.
  int _fractionalSad(int x, int y, int w, int h, Av1Mv mv, int limit) {
    final startX = x + (mv.x >> 3), startY = y + (mv.y >> 3);
    final fx = mv.x & 7, fy = mv.y & 7;
    final wx = 8 - fx, wy = 8 - fy;
    var cost = 0;
    for (var row = 0; row < h; row += 2) {
      final current = (y + row) * stride + x;
      final top = (startY + row).clamp(0, height - 1) * stride;
      final bottom = (startY + row + 1).clamp(0, height - 1) * stride;
      for (var col = 0; col < w; col += 2) {
        final left = (startX + col).clamp(0, width - 1);
        final right = (startX + col + 1).clamp(0, width - 1);
        final a = wx * reference[top + left] + fx * reference[top + right];
        final b =
            wx * reference[bottom + left] + fx * reference[bottom + right];
        final prediction = (a * wy + b * fy + 32) >> 6;
        cost += (source[current + col] - prediction).abs();
      }
      if (cost >= limit) break;
    }
    return cost;
  }
}
