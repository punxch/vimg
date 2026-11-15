part of 'decoder.dart';

/// Separable VP9 subpixel interpolation for the active picture references.
final class _InterPrediction {
  // The largest scaled step is 32/16, plus seven rows for the filter.
  final _intermediate = Uint16List(64 * (64 * 2 + 8));

  void predict({
    required Vp9Plane plane,
    required Vp9Picture target,
    required List<Vp9Picture> references,
    required _Motion motion,
    required int index,
    required int x,
    required int y,
    required int blockWidth,
    required int blockHeight,
    required bool subblock,
  }) {
    final header = target.header;
    final sx = index == 0 ? 0 : header.color.subX;
    final sy = index == 0 ? 0 : header.color.subY;
    final width = blockWidth >> sx, height = blockHeight >> sy;
    final stepX = subblock ? 4 : width, stepY = subblock ? 4 : height;
    for (var row = 0; row < height; row += stepY) {
      for (var col = 0; col < width; col += stepX) {
        final sub = (row >> 2) * (width >> 2) + (col >> 2);
        for (var list = 0; list <= _flag(motion.compound); list++) {
          final reference = references[motion.reference(list) - 1];
          final vector = subblock
              ? _averageSplitMotion(motion, list, sub, sx, sy)
              : motion.vector(list, 3);
          final px = (x >> sx) + col, py = (y >> sy) + row;
          final borderX = (4 + width) * 16, borderY = (4 + height) * 16;
          final mvX = (vector.column << (1 - sx)).clamp(
            -(x * 16 >> sx) - borderX,
            ((header.miColumns * 8 - x - blockWidth) * 16 >> sx) + borderX - 16,
          );
          final mvY = (vector.row << (1 - sy)).clamp(
            -(y * 16 >> sy) - borderY,
            ((header.miRows * 8 - y - blockHeight) * 16 >> sy) + borderY - 16,
          );
          final ref = reference.header;
          if (ref.width > header.width * 2 ||
              ref.height > header.height * 2 ||
              ref.width * 16 < header.width ||
              ref.height * 16 < header.height) {
            throw const FormatException('Unsupported VP9 reference size ratio');
          }
          final scaleX = (ref.width << 14) ~/ header.width;
          final scaleY = (ref.height << 14) ~/ header.height;
          // Fractional origins use luma block coordinates plus the plane
          // offset, including for the sub-blocks of a subsampled plane.
          final fracX = (((x + col) * 16 * scaleX) >> 14) & 15;
          final fracY = (((y + row) * 16 * scaleY) >> 14) & 15;
          final startX =
              (((px * scaleX) >> 14) << 4) + ((mvX * scaleX) >> 14) + fracX;
          final startY =
              (((py * scaleY) >> 14) << 4) + ((mvY * scaleY) >> 14) + fracY;
          _convolve(
            plane,
            px,
            py,
            stepX,
            stepY,
            source: switch (index) {
              0 => reference.y,
              1 => reference.u,
              _ => reference.v,
            },
            lastX: ((ref.width + sx) >> sx) - 1,
            lastY: ((ref.height + sy) >> sy) - 1,
            startX: startX,
            startY: startY,
            dx: scaleX >> 10,
            dy: scaleY >> 10,
            filter: motion.filter,
            max: (1 << header.color.depth) - 1,
            average: list != 0,
          );
        }
      }
    }
  }

  _Vector _averageSplitMotion(
    _Motion motion,
    int list,
    int sub,
    int sx,
    int sy,
  ) {
    final first = motion.vector(list, sub);
    if (sx == 0 && sy == 0) return first;
    final second = motion.vector(list, sub + (sx == 1 ? 1 : 2));
    var row = first.row + second.row, column = first.column + second.column;
    var count = 2;
    if (sx == 1 && sy == 1) {
      final third = motion.vector(list, 2), fourth = motion.vector(list, 3);
      row += third.row + fourth.row;
      column += third.column + fourth.column;
      count = 4;
    }
    final half = count >> 1;
    return (
      row: (row + (row < 0 ? -half : half)) ~/ count,
      column: (column + (column < 0 ? -half : half)) ~/ count,
    );
  }

  void _convolve(
    Vp9Plane plane,
    int x,
    int y,
    int width,
    int height, {
    required Vp9Plane source,
    required int lastX,
    required int lastY,
    required int startX,
    required int startY,
    required int dx,
    required int dy,
    required int filter,
    required int max,
    required bool average,
  }) {
    final src = source.samples, dst = plane.samples;
    final filterBase = filter * 128;
    final offsetY = startY >> 4, fractionY = startY & 15;
    final vertical = dy != 16 || fractionY != 0;
    final horizontal = dx != 16 || startX & 15 != 0;
    final sourceX = startX >> 4;
    if (!vertical && !horizontal) {
      for (var row = 0; row < height; row++) {
        final sourceOffset = (offsetY + row).clamp(0, lastY) * source.stride;
        final targetOffset = (y + row) * plane.stride + x;
        for (var col = 0; col < width; col++) {
          final value = src[sourceOffset + (sourceX + col).clamp(0, lastX)];
          final at = targetOffset + col;
          dst[at] = average ? (dst[at] + value + 1) >> 1 : value;
        }
      }
      return;
    }
    final heightWithTaps = vertical
        ? ((fractionY + dy * (height - 1)) >> 4) + 8
        : height;
    for (var row = 0; row < heightWithTaps; row++) {
      final sourceOffset =
          (offsetY + row - (vertical ? 3 : 0)).clamp(0, lastY) * source.stride;
      for (var col = 0; col < width; col++) {
        final pos = startX + col * dx;
        var value = 0;
        final origin = pos >> 4, fraction = pos & 15;
        if (fraction == 0) {
          value = src[sourceOffset + origin.clamp(0, lastX)];
        } else {
          final taps = filterBase + fraction * 8;
          for (var tap = 0; tap < 8; tap++) {
            value +=
                vp9SubpixelFilters[taps + tap] *
                src[sourceOffset + (origin + tap - 3).clamp(0, lastX)];
          }
          value = ((value + 64) >> 7).clamp(0, max);
        }
        _intermediate[row * width + col] = value;
      }
    }
    for (var row = 0; row < height; row++) {
      final position = fractionY + row * dy;
      final origin = position >> 4, fraction = position & 15;
      final taps = filterBase + fraction * 8;
      final targetOffset = (y + row) * plane.stride + x;
      for (var col = 0; col < width; col++) {
        var value = 0;
        if (fraction == 0) {
          value = _intermediate[(origin + (vertical ? 3 : 0)) * width + col];
        } else {
          for (var tap = 0; tap < 8; tap++) {
            value +=
                vp9SubpixelFilters[taps + tap] *
                _intermediate[(origin + tap) * width + col];
          }
          value = ((value + 64) >> 7).clamp(0, max);
        }
        final at = targetOffset + col;
        dst[at] = average ? (dst[at] + value + 1) >> 1 : value;
      }
    }
  }
}
