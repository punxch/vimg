import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as image;

/// Mean per-channel SSIM over overlapping 8×8 windows at a four-pixel step.
double frameSsim(image.Image first, image.Image second) {
  final width = first.width, height = first.height;
  if (second.width != width || second.height != height)
    throw const FormatException('SSIM frame dimensions differ');
  final a = first.getBytes(order: image.ChannelOrder.rgb);
  final b = second.getBytes(order: image.ChannelOrder.rgb);
  final w = math.min(8, width), h = math.min(8, height);
  final count = w * h;
  final c1 = (6.5025 * count).roundToDouble();
  final c2 = (58.5225 * count * (count - 1)).roundToDouble();
  final sums = Int32List(12);
  var score = 0.0, windows = 0;
  for (var y = 0; y <= height - h; y += 4) {
    for (var x = 0; x <= width - w; x += 4) {
      sums.fillRange(0, sums.length, 0);
      for (var dy = 0; dy < h; dy++) {
        var offset = ((y + dy) * width + x) * 3;
        for (var dx = 0; dx < w; dx++) {
          for (var c = 0; c < 3; c++) {
            final p = a[offset], q = b[offset++];
            final base = c * 4;
            sums[base] += p;
            sums[base + 1] += q;
            sums[base + 2] += p * p + q * q;
            sums[base + 3] += p * q;
          }
        }
      }
      for (var c = 0; c < 12; c += 4) {
        final s1 = sums[c], s2 = sums[c + 1];
        final squares = s1 * s1 + s2 * s2;
        final numerator = 2 * s1 * s2 + c1;
        final variance = count * sums[c + 2] - squares;
        final covariance = count * sums[c + 3] - s1 * s2;
        final contrast = variance == 0
            ? 1.0
            : (2 * covariance + c2) / (variance + c2);
        score += numerator / (squares + c1) * contrast;
      }
      windows++;
    }
  }
  return score / (3 * windows);
}
