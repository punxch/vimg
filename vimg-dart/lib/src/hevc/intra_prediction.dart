import 'dart:math' as math;
import 'dart:typed_data';

import 'picture.dart';

/// HEVC §8.4.4.2. Reference samples are traversed from bottom-left to
/// top-right so unavailable samples inherit the nearest preceding sample.
final class HevcIntraPrediction {
  final _reference = Int32List(129);
  final _filtered = Int32List(129);

  void reconstruct(
    HevcPlane plane,
    int x,
    int y,
    int log2,
    int mode, {
    required bool luma,
    required bool filterReferences,
    bool filterAngularBoundary = true,
    required bool strongSmoothing,
    required bool Function(int, int) available,
    Int32List? residual,
  }) {
    final n = 1 << log2, corner = 2 * n, end = 4 * n;
    final samples = plane.samples;
    int get(int sx, int sy) => plane.reconstructed(sx, sy) && available(sx, sy)
        ? samples[sy * plane.width + sx]
        : -1;

    var first = -1;
    for (var i = 0; i <= end; i++) {
      final value = i < corner
          ? get(x - 1, y + corner - 1 - i)
          : get(x + i - corner - 1, y - 1);
      if (first < 0 && value >= 0) first = i;
      _reference[i] = value;
    }
    var previous = first < 0 ? 1 << (plane.depth - 1) : _reference[first];
    for (var i = 0; i <= end; i++) {
      if (_reference[i] >= 0) previous = _reference[i];
      _reference[i] = previous;
    }

    var reference = _reference;
    if (filterReferences &&
        mode != 1 &&
        n > 4 &&
        math.min((mode - 10).abs(), (mode - 26).abs()) >
            (n == 8
                ? 7
                : n == 16
                ? 1
                : 0)) {
      final middle = _reference[corner];
      final limit = 1 << (plane.depth - 5);
      final strong =
          n == 32 &&
          luma &&
          strongSmoothing &&
          (_reference[0] + middle - 2 * _reference[n]).abs() < limit &&
          (_reference[end] + middle - 2 * _reference[3 * n]).abs() < limit;
      _filtered[0] = _reference[0];
      _filtered[end] = _reference[end];
      for (var i = 1; i < end; i++) {
        if (strong) {
          final near = i <= corner ? _reference[0] : middle;
          final far = i <= corner ? middle : _reference[end];
          final distance = i <= corner ? i : i - corner;
          _filtered[i] =
              ((corner - distance) * near + distance * far + n) >> (log2 + 1);
        } else {
          _filtered[i] =
              (_reference[i - 1] + 2 * _reference[i] + _reference[i + 1] + 2) >>
              2;
        }
      }
      reference = _filtered;
    }

    int left(int i) => reference[corner - 1 - i];
    int top(int i) => reference[corner + 1 + i];
    final boundary = luma && n < 32;
    var dc = 0;
    if (mode == 1) {
      for (var i = 0; i < n; i++) dc += left(i) + top(i);
      dc = (dc + n) >> (log2 + 1);
    }
    final angle = _angles[mode], vertical = mode >= 18;
    int angularRef(int i) {
      if (i >= 0) return vertical ? top(i - 1) : left(i - 1);
      final index = ((i * _inverseAngles[mode - 11] + 128) >> 8) - 1;
      return vertical ? left(index) : top(index);
    }

    for (var row = 0; row < n; row++) {
      final start = (y + row) * plane.width + x;
      for (var col = 0; col < n; col++) {
        final int predicted;
        if (mode == 0) {
          predicted =
              ((n - 1 - col) * left(row) +
                  (col + 1) * top(n) +
                  (n - 1 - row) * top(col) +
                  (row + 1) * left(n) +
                  n) >>
              (log2 + 1);
        } else if (mode == 1) {
          predicted = !boundary || (row != 0 && col != 0)
              ? dc
              : row == 0 && col == 0
              ? (left(0) + top(0) + 2 * dc + 2) >> 2
              : ((row == 0 ? top(col) : left(row)) + 3 * dc + 2) >> 2;
        } else if (boundary &&
            filterAngularBoundary &&
            mode == 26 &&
            col == 0) {
          predicted = (top(0) + ((left(row) - reference[corner]) >> 1)).clamp(
            0,
            plane.maximum,
          );
        } else if (boundary &&
            filterAngularBoundary &&
            mode == 10 &&
            row == 0) {
          predicted = (left(0) + ((top(col) - reference[corner]) >> 1)).clamp(
            0,
            plane.maximum,
          );
        } else {
          final delta = (1 + (vertical ? row : col)) * angle;
          final index = (vertical ? col : row) + (delta >> 5) + 1;
          final weight = delta & 31;
          final a = angularRef(index);
          predicted = weight == 0
              ? a
              : ((32 - weight) * a + weight * angularRef(index + 1) + 16) >> 5;
        }
        final value = predicted + (residual?[row * n + col] ?? 0);
        samples[start + col] = value.clamp(0, plane.maximum);
      }
    }
    plane.mark(x, y, n);
  }
}

// H.265 Tables 8-5 and 8-6.
// dart format off
const _angles = [0, 0, 32, 26, 21, 17, 13, 9, 5, 2, 0, -2, -5, -9, -13, -17,
  -21, -26, -32, -26, -21, -17, -13, -9, -5, -2, 0, 2, 5, 9, 13, 17, 21, 26, 32];
const _inverseAngles = [-4096, -1638, -910, -630, -482, -390, -315, -256,
  -315, -390, -482, -630, -910, -1638, -4096];
