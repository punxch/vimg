import 'dart:math' as math;

import 'package:image/image.dart' as image;

image.Image resizeToFit(
  image.Image frame, {
  int? width,
  int? height,
  bool enlarge = true,
}) {
  final (scaledWidth, scaledHeight) = fitDimensions(
    frame.width,
    frame.height,
    width: width,
    height: height,
    enlarge: enlarge,
  );
  if (scaledWidth == frame.width && scaledHeight == frame.height) return frame;
  return image.copyResize(
    frame,
    width: scaledWidth,
    height: scaledHeight,
    interpolation: image.Interpolation.cubic,
  );
}

(int, int) fitDimensions(
  int sourceWidth,
  int sourceHeight, {
  int? width,
  int? height,
  bool enlarge = true,
}) {
  if (width == null && height == null) return (sourceWidth, sourceHeight);
  final scale = math.min(
    width == null ? double.infinity : width / sourceWidth,
    height == null ? double.infinity : height / sourceHeight,
  );
  if (scale == 1 || (!enlarge && scale >= 1))
    return (sourceWidth, sourceHeight);
  return (
    math.max(1, (sourceWidth * scale).round()),
    math.max(1, (sourceHeight * scale).round()),
  );
}

image.Image composeGrid(
  List<image.Image> frames,
  int columns,
  List<String> labels,
) {
  if (frames.isEmpty)
    throw const FormatException('At least one image is required');
  if (columns < 0) throw const FormatException('Columns must be non-negative');
  final width = frames.first.width;
  final height = frames.first.height;
  final count = columns == 0 ? frames.length : math.min(columns, frames.length);
  final rows = (frames.length + count - 1) ~/ count;
  if (width * height * count * rows > 100000000) {
    throw const FormatException('Grid exceeds 100 million pixels');
  }
  final grid = image.Image(width: width * count, height: height * rows);
  for (var i = 0; i < frames.length; i++) {
    final frame = frames[i];
    if (frame.width != width || frame.height != height) {
      throw const FormatException('Grid images must have the same dimensions');
    }
    final x = i % count * width;
    final y = i ~/ count * height;
    // Copy RGB directly so transparent input retains its RGB values.
    for (final pixel in frame) {
      grid.setPixelRgb(x + pixel.x, y + pixel.y, pixel.r, pixel.g, pixel.b);
    }
    if (i < labels.length && labels[i].isNotEmpty) {
      _drawLabel(grid, x, y, width, height, labels[i]);
    }
  }
  return grid;
}

void _drawLabel(
  image.Image grid,
  int x,
  int y,
  int width,
  int height,
  String label,
) {
  final minDimension = math.min(width, height);
  final font = switch (minDimension) {
    < 225 => image.arial14,
    < 390 => image.arial24,
    _ => image.arial48,
  };
  final margin = math.max(1, (minDimension * 0.01).round());
  final labelWidth = label.runes.fold(
    0,
    (sum, rune) => sum + (font.characters[rune]?.xAdvance ?? 0),
  );
  final labelHeight = font.lineHeight;
  final right = width - margin * 2;
  final bottom = height - margin;
  if (labelWidth == 0 || right <= 0 || bottom < labelHeight) return;
  final left = math.max(0, right - labelWidth);
  final top = bottom - labelHeight;
  final overlay = image.Image(
    width: right - left,
    height: labelHeight,
    numChannels: 4,
  );
  image.fill(overlay, color: image.ColorRgba8(0, 0, 0, 179));
  image.drawString(
    overlay,
    label,
    font: font,
    x: right - left - labelWidth,
    y: 0,
    color: image.ColorRgb8(255, 255, 255),
  );
  image.compositeImage(grid, overlay, dstX: x + left, dstY: y + top);
}
