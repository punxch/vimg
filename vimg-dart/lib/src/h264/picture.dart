import 'dart:typed_data';

import 'package:image/image.dart' as image;

import 'motion.dart';
import 'parameters.dart';

final class H264Picture {
  H264Picture(this.sps)
    : stride = sps.mbWidth * 16,
      y = Uint8List(sps.mbWidth * sps.mbHeight * 256),
      cb = Uint8List(
        sps.chromaFormat == 0 ? 0 : sps.mbWidth * sps.mbHeight * 64,
      ),
      cr = Uint8List(
        sps.chromaFormat == 0 ? 0 : sps.mbWidth * sps.mbHeight * 64,
      );

  final H264Sps sps;
  final int stride;
  final Uint8List y, cb, cr;
  MotionField? motionL0;

  image.Image rgb() {
    final pixels = image.Image(width: sps.width, height: sps.height);
    final (rv, gu, gv, bu) = switch (sps.color.matrix) {
      1 => (1.5748, 0.187324, 0.468124, 1.8556), // BT.709
      9 || 10 => (1.4746, 0.164553, 0.571353, 1.8814), // BT.2020
      _ => (1.402, 0.344136, 0.714136, 1.772), // BT.601 / unspecified
    };
    final fullRange = sps.color.fullRange;
    final scale = fullRange ? 1.0 : 255 / 224;
    const precision = 1 << 14;
    final red = (rv * scale * precision).round();
    final greenU = (gu * scale * precision).round();
    final greenV = (gv * scale * precision).round();
    final blue = (bu * scale * precision).round();
    final yScale = (precision * (fullRange ? 1.0 : 255 / 219)).round();
    final bias = fullRange ? 0 : 16;
    for (final pixel in pixels) {
      final x = sps.cropLeft + pixel.x;
      final row = sps.cropTop + pixel.y;
      final luma = (y[row * stride + x] - bias) * yScale + (precision >> 1);
      final offset = (row >> 1) * (stride >> 1) + (x >> 1);
      final u = cb.isEmpty ? 0 : cb[offset] - 128;
      final v = cr.isEmpty ? 0 : cr[offset] - 128;
      pixel.setRgb(
        ((luma + red * v) >> 14).clamp(0, 255),
        ((luma - greenU * u - greenV * v) >> 14).clamp(0, 255),
        ((luma + blue * u) >> 14).clamp(0, 255),
      );
    }
    return pixels;
  }
}
