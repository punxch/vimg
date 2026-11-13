import 'dart:math' as math;

import 'package:image/image.dart' as image;

import 'grid_label.dart';

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

/// A grid's geometry and label coverage are shared by its animation frames.
final class GridComposer {
  GridComposer(
    this.tileWidth,
    this.tileHeight,
    this.count,
    int columns,
    List<String> labels,
  ) {
    if (count < 1)
      throw const FormatException('At least one image is required');
    if (columns < 0)
      throw const FormatException('Columns must be non-negative');
    _columns = columns == 0 ? count : math.min(columns, count);
    width = tileWidth * _columns;
    height = tileHeight * ((count + _columns - 1) ~/ _columns);
    if (width * height > 100000000) {
      throw const FormatException('Grid exceeds 100 million pixels');
    }
    _labels = [
      for (final label in labels.take(count))
        GridLabel(tileWidth, tileHeight, label),
    ];
  }

  final int tileWidth, tileHeight, count;
  late final int width, height, _columns;
  late final List<GridLabel> _labels;

  image.Image compose(
    List<image.Image> frames, {
    bool sourceAlpha = false,
    bool fitTiles = false,
  }) {
    if (frames.length != count) {
      throw const FormatException('Grid capture count changed');
    }
    final grid = image.Image(width: width, height: height);
    for (var i = 0; i < frames.length; i++) {
      final source = frames[i];
      if (!fitTiles &&
          (source.width != tileWidth || source.height != tileHeight)) {
        throw const FormatException(
          'Grid images must have the same dimensions',
        );
      }
      final frame = fitTiles
          ? resizeToFit(source, width: tileWidth, height: tileHeight)
          : source;
      final x = i % _columns * tileWidth;
      final y = i ~/ _columns * tileHeight;
      final left = x + (tileWidth - frame.width) ~/ 2;
      final top = y + (tileHeight - frame.height) ~/ 2;
      for (final pixel in frame) {
        grid.setPixelRgb(
          left + pixel.x,
          top + pixel.y,
          pixel.r,
          pixel.g,
          pixel.b,
        );
      }
      if (i < _labels.length) {
        _labels[i].paint(grid, x, y, source: sourceAlpha ? frame : null);
      }
    }
    return grid;
  }
}
