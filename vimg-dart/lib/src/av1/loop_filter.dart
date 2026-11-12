import 'dart:math' as math;
import 'dart:typed_data';

import 'transform.dart';

/// AV1 §7.14. The transform grid is stored at stride/4,
/// with zero for uncoded cells and one plus the transform-size ordinal.
void av1DeblockPlane(
  Uint16List pixels,
  Uint8List transforms,
  int stride,
  int width,
  int height,
  int depth,
  int sharpness, {
  required bool chroma,
  required int Function(int x4, int y4, int pass) levelAt,
  bool Function(int x4, int y4, int pass)? filterEdge,
}) {
  final width4 = (width + 3) >> 2, height4 = (height + 3) >> 2;
  final paddedW = (width + 7) & -8, paddedH = (height + 7) & -8;
  final gridStride = stride >> 2;
  final shift = depth - 8;
  final half = 128 << shift;
  final taps = Int32List(14);
  for (var pass = 0; pass < 2; pass++) {
    final vertical = pass == 0;
    final dx = vertical ? 1 : 0, dy = vertical ? 0 : 1;
    for (var y = 0; y < height4; y++) {
      for (var x = 0; x < width4; x++) {
        if (vertical ? x == 0 : y == 0) continue;
        if (filterEdge != null && !filterEdge(x, y, pass)) continue;
        final current = transforms[y * gridStride + x];
        if (current == 0) continue;
        final tx = Av1TxSize.values[current - 1];
        final length = vertical ? tx.width : tx.height;
        if (((vertical ? x : y) * 4) % length != 0) continue;
        final previous = transforms[(y - dy) * gridStride + x - dx];
        if (previous == 0) continue;
        final prior = Av1TxSize.values[previous - 1];
        final span = math.min(length, vertical ? prior.width : prior.height);
        final filter = span == 4
            ? 4
            : chroma
            ? 6
            : math.min(span, 16);

        var level = levelAt(x, y, pass);
        if (level == 0) level = levelAt(x - dx, y - dy, pass);
        if (level == 0) continue;
        final shifted =
            level >>
            (sharpness == 0
                ? 0
                : sharpness <= 4
                ? 1
                : 2);
        final limit = shifted.clamp(1, sharpness == 0 ? 63 : 9 - sharpness);
        final outer = (2 * (level + 2) + limit) << shift;
        final threshold = (level >> 4) << shift;
        final inner = limit << shift;
        final reach = filter == 16 ? 7 : filter >> 1;
        for (var i = 0; i < 4; i++) {
          final px = x * 4 + dy * i, py = y * 4 + dx * i;
          for (var j = -reach; j < reach; j++) {
            final xx = (px + j * dx).clamp(0, paddedW - 1);
            final yy = (py + j * dy).clamp(0, paddedH - 1);
            taps[7 + j] = pixels[yy * stride + xx];
          }
          _deblockLine(
            pixels,
            py * stride + px,
            dx + dy * stride,
            taps,
            filter,
            outer,
            inner,
            threshold,
            half,
            1 << shift,
          );
        }
      }
    }
  }
}

void _deblockLine(
  Uint16List pixels,
  int at,
  int step,
  Int32List taps,
  int filter,
  int outer,
  int inner,
  int threshold,
  int half,
  int flatThreshold,
) {
  final p0 = taps[6], p1 = taps[5], q0 = taps[7], q1 = taps[8];
  if (2 * (p0 - q0).abs() + ((p1 - q1).abs() >> 1) > outer) return;
  final steps = math.min(filter >> 1, 4);
  var flat = filter > 4;
  var hev = false;
  for (var i = 1; i < steps; i++) {
    final p = taps[6 - i], q = taps[7 + i];
    final diff = math.max((p - taps[7 - i]).abs(), (q - taps[6 + i]).abs());
    if (diff > inner) return;
    if (i == 1) hev = diff > threshold;
    if ((p - p0).abs() > flatThreshold || (q - q0).abs() > flatThreshold) {
      flat = false;
    }
  }
  if (flat) {
    var wide = filter == 16;
    if (wide) {
      for (var i = 4; i <= 6; i++) {
        if ((taps[6 - i] - p0).abs() > flatThreshold ||
            (taps[7 + i] - q0).abs() > flatThreshold) {
          wide = false;
          break;
        }
      }
    }
    final n = wide
        ? 6
        : filter == 6
        ? 2
        : 3;
    final center = n == 3 ? 0 : 1;
    for (var i = -n; i < n; i++) {
      var sum = 0;
      for (var j = -n; j <= n; j++) {
        sum += (j.abs() <= center ? 2 : 1) * taps[(i + j).clamp(-n - 1, n) + 7];
      }
      pixels[at + i * step] = av1Round(sum, wide ? 4 : 3);
    }
    return;
  }

  var value = hev ? (p1 - q1).clamp(-half, half - 1) : 0;
  value = (value + 3 * (q0 - p0)).clamp(-half, half - 1);
  final f1 = (value + 4).clamp(-half, half - 1) >> 3;
  final f2 = (value + 3).clamp(-half, half - 1) >> 3;
  final maximum = 2 * half - 1;
  pixels[at] = (q0 - f1).clamp(0, maximum);
  pixels[at - step] = (p0 + f2).clamp(0, maximum);
  if (!hev) {
    final outer = av1Round(f1, 1);
    pixels[at + step] = (q1 - outer).clamp(0, maximum);
    pixels[at - 2 * step] = (p1 + outer).clamp(0, maximum);
  }
}
