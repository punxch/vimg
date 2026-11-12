import 'package:image/image.dart' as image;

/// Convert cropped 4:2:0 or monochrome samples to an 8-bit RGB image.
image.Image yuv420Image({
  required List<int> y,
  required List<int> cb,
  required List<int> cr,
  required int stride,
  required int chromaStride,
  required int width,
  required int height,
  required int cropLeft,
  required int cropTop,
  required int matrix,
  required bool fullRange,
  int lumaDepth = 8,
  int chromaDepth = 8,
}) {
  final pixels = image.Image(width: width, height: height);
  final (rv, gu, gv, bu) = switch (matrix) {
    1 => (1.5748, 0.187324, 0.468124, 1.8556), // BT.709
    9 || 10 => (1.4746, 0.164553, 0.571353, 1.8814), // BT.2020
    _ => (1.402, 0.344136, 0.714136, 1.772), // BT.601 / unspecified
  };
  final scale =
      255 / (fullRange ? (1 << chromaDepth) - 1 : 224 << (chromaDepth - 8));
  const precision = 1 << 14;
  final red = (rv * scale * precision).round();
  final greenU = (gu * scale * precision).round();
  final greenV = (gv * scale * precision).round();
  final blue = (bu * scale * precision).round();
  final yScale =
      (precision *
              255 /
              (fullRange ? (1 << lumaDepth) - 1 : 219 << (lumaDepth - 8)))
          .round();
  final bias = fullRange ? 0 : 16 << (lumaDepth - 8);
  final midpoint = 1 << (chromaDepth - 1);
  for (final pixel in pixels) {
    final x = cropLeft + pixel.x;
    final row = cropTop + pixel.y;
    final luma = (y[row * stride + x] - bias) * yScale + (precision >> 1);
    final offset = (row >> 1) * chromaStride + (x >> 1);
    final u = cb.isEmpty ? 0 : cb[offset] - midpoint;
    final v = cr.isEmpty ? 0 : cr[offset] - midpoint;
    pixel.setRgb(
      ((luma + red * v) >> 14).clamp(0, 255),
      ((luma - greenU * u - greenV * v) >> 14).clamp(0, 255),
      ((luma + blue * u) >> 14).clamp(0, 255),
    );
  }
  return pixels;
}
