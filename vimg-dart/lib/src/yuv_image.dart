import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as image;

import 'filter_expression.dart';
import 'grid.dart';

part 'video_filters.dart';
part 'yuv_scaler.dart';

/// Convert cropped YUV, GBR or monochrome samples to an 8-bit RGB image.
image.Image yuvImage({
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
  int subsamplingX = 1,
  int subsamplingY = 1,
  List<int>? alpha,
  int alphaDepth = 8,
  YuvImageScaler? scaler,
}) {
  if (scaler != null && scaler.filters != null) {
    final sx = cb.isEmpty ? 0 : subsamplingX;
    final sy = cb.isEmpty ? 0 : subsamplingY;
    final chromaWidth = _subSize(width, sx);
    final chromaHeight = _subSize(height, sy);
    final chromaOffset = (cropTop >> sy) * chromaStride + (cropLeft >> sx);
    final planes = _VideoPlanes(
      [
        _FilterPlane(
          y,
          width,
          height,
          lumaDepth,
          rowStep: stride,
          offset: cropTop * stride + cropLeft,
        ),
        if (cb.isNotEmpty)
          for (final samples in [cb, cr])
            _FilterPlane(
              samples,
              chromaWidth,
              chromaHeight,
              chromaDepth,
              rowStep: chromaStride,
              offset: chromaOffset,
            ),
      ],
      sx,
      sy,
      alpha: alpha == null
          ? null
          : _FilterPlane(
              alpha,
              width,
              height,
              alphaDepth,
              rowStep: stride,
              offset: cropTop * stride + cropLeft,
            ),
    );
    return scaler._renderFiltered(planes, matrix: matrix, fullRange: fullRange);
  }
  if (scaler != null) {
    final (scaledWidth, scaledHeight) = scaler._dimensions(width, height);
    if (scaledWidth != width || scaledHeight != height) {
      return scaler._resize(
        y: y,
        cb: cb,
        cr: cr,
        stride: stride,
        chromaStride: chromaStride,
        sourceWidth: width,
        sourceHeight: height,
        width: scaledWidth,
        height: scaledHeight,
        cropLeft: cropLeft,
        cropTop: cropTop,
        matrix: matrix,
        fullRange: fullRange,
        lumaDepth: lumaDepth,
        chromaDepth: chromaDepth,
        subsamplingX: subsamplingX,
        subsamplingY: subsamplingY,
        alpha: alpha,
        alphaDepth: alphaDepth,
      );
    }
  }
  final pixels = image.Image(
    width: width,
    height: height,
    numChannels: alpha == null ? 3 : 4,
  );
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
    final offset = (row >> subsamplingY) * chromaStride + (x >> subsamplingX);
    if (matrix == 0 && cb.isNotEmpty) {
      final rounding = precision >> 1;
      pixel.setRgb(
        (((cr[offset] - bias) * yScale + rounding) >> 14).clamp(0, 255),
        (luma >> 14).clamp(0, 255),
        (((cb[offset] - bias) * yScale + rounding) >> 14).clamp(0, 255),
      );
      continue;
    }
    final u = cb.isEmpty ? 0 : cb[offset] - midpoint;
    final v = cr.isEmpty ? 0 : cr[offset] - midpoint;
    pixel.setRgb(
      ((luma + red * v) >> 14).clamp(0, 255),
      ((luma - greenU * u - greenV * v) >> 14).clamp(0, 255),
      ((luma + blue * u) >> 14).clamp(0, 255),
    );
  }
  if (alpha != null) {
    final maximum = (1 << alphaDepth) - 1;
    for (final pixel in pixels) {
      final sample = alpha[(cropTop + pixel.y) * stride + cropLeft + pixel.x];
      pixel.a = (sample * 255 + (maximum >> 1)) ~/ maximum;
    }
  }
  return pixels;
}
