part of 'yuv_image.dart';

typedef _OverlayFormat = ({bool rgb, int subX, int subY, int depth});

final class _Overlay {
  factory _Overlay(String? source) {
    final options = _filterOptions(source, [
      'x',
      'y',
      'eof_action',
      'eval',
      'shortest',
      'format',
      'repeatlast',
      'alpha',
      'ts_sync_mode',
    ]);
    // The two inputs arrive together, and have the same end event.
    _filterFlag(options['shortest'], 'overlay shortest');
    _filterFlag(options['repeatlast'], 'overlay repeatlast');
    if (!const {
          null,
          'repeat',
          'endall',
          'pass',
          '0',
          '1',
          '2',
        }.contains(options['eof_action']) ||
        !const {
          null,
          'default',
          'nearest',
          '0',
          '1',
        }.contains(options['ts_sync_mode'])) {
      throw const FormatException('Invalid overlay synchronization option');
    }
    final evaluateFrame = switch (options['eval']) {
      null || 'frame' || '1' => true,
      'init' || '0' => false,
      _ => throw const FormatException('Invalid overlay evaluation mode'),
    };
    final premultiplied = switch (options['alpha']) {
      null || 'auto' || 'unknown' || 'straight' || '0' || '2' => false,
      'premultiplied' || '1' => true,
      _ => throw const FormatException('Invalid overlay alpha mode'),
    };
    final format = switch (options['format']) {
      null || 'yuv420' || '0' => (rgb: false, subX: 1, subY: 1, depth: 8),
      'yuv420p10' || '1' => (rgb: false, subX: 1, subY: 1, depth: 10),
      'yuv422' || '2' => (rgb: false, subX: 1, subY: 0, depth: 8),
      'yuv422p10' || '3' => (rgb: false, subX: 1, subY: 0, depth: 10),
      'yuv444' || '4' => (rgb: false, subX: 0, subY: 0, depth: 8),
      'yuv444p10' || '5' => (rgb: false, subX: 0, subY: 0, depth: 10),
      'rgb' || 'gbrp' || '6' || '7' => (rgb: true, subX: 0, subY: 0, depth: 8),
      'auto' || '8' => null,
      _ => throw const FormatException('Invalid overlay pixel format'),
    };
    const variables = {
      'main_w',
      'main_h',
      'W',
      'H',
      'overlay_w',
      'overlay_h',
      'w',
      'h',
      'hsub',
      'vsub',
      'x',
      'y',
      'n',
      't',
    };
    var dynamicPosition = false;
    void reference(String name) {
      if (_frameVariables.contains(name)) dynamicPosition = true;
    }

    final x = parseFilterExpression(
      options['x'] ?? '0',
      variables,
      onVariable: reference,
    );
    final y = parseFilterExpression(
      options['y'] ?? '0',
      variables,
      onVariable: reference,
    );
    return _Overlay._(
      x,
      y,
      format,
      premultiplied,
      evaluateFrame && dynamicPosition,
      options['format'] == 'rgb' || options['format'] == '6'
          ? true
          : options['format'] == 'gbrp' || options['format'] == '7'
          ? false
          : null,
    );
  }

  const _Overlay._(
    this.x,
    this.y,
    this.format,
    this.premultiplied,
    this.usesFramePosition,
    this.packedRgb,
  );

  final FilterExpression x, y;
  final _OverlayFormat? format;
  final bool premultiplied, usesFramePosition;
  final bool? packedRgb;

  _VideoPlanes apply(
    _VideoPlanes main,
    _VideoPlanes over,
    FilterFramePosition position,
  ) {
    final inputFormat = _overlayFormat(main);
    if ((format != null && inputFormat != format) ||
        inputFormat != _overlayFormat(over) ||
        main.planes.length != over.planes.length ||
        !main.planes.every((plane) => plane.depth == inputFormat.depth) ||
        !over.planes.every((plane) => plane.depth == inputFormat.depth)) {
      throw const FormatException(
        'Overlay requires matching inputs in the requested pixel format',
      );
    }
    if (premultiplied &&
        over.alpha != null &&
        (!main.rgb ||
            inputFormat.depth != 8 ||
            !(packedRgb ?? main.packedRgb))) {
      throw const FormatException(
        'Premultiplied overlay requires packed 8-bit RGB',
      );
    }
    final variables = {
      'main_w': main.width.toDouble(),
      'W': main.width.toDouble(),
      'main_h': main.height.toDouble(),
      'H': main.height.toDouble(),
      'overlay_w': over.width.toDouble(),
      'w': over.width.toDouble(),
      'overlay_h': over.height.toDouble(),
      'h': over.height.toDouble(),
      'hsub': (1 << main.subX).toDouble(),
      'vsub': (1 << main.subY).toDouble(),
      'x': double.nan,
      'y': double.nan,
      // Overlay reads the main link's frame count after the current frame arrives.
      'n': usesFramePosition ? position.index + 1.0 : 0.0,
      't': usesFramePosition ? position.seconds : double.nan,
    };
    variables['x'] = x(variables);
    final top = _overlayOffset(variables['y'] = y(variables), main.subY);
    final left = _overlayOffset(x(variables), main.subX);
    var result = main;
    if (left != null &&
        top != null &&
        left < main.width &&
        top < main.height &&
        left + over.width > 0 &&
        top + over.height > 0) {
      result = main.mapComponents((plane, sx, sy, index) {
        final source = index == 3 ? over.alpha : over.planes[index];
        final depth = plane.depth, max = (1 << depth) - 1;
        final width = plane.width, height = plane.height;
        final px = left >> sx, py = top >> sy;
        final output = _paintSamples(depth, width * height);
        _pastePlane(plane, output, width, height, 0, 0);
        if (index != 3 && over.alpha == null) {
          _pastePlane(source!, output, width, height, px, py);
        } else {
          final sourceWidth = _subSize(over.width, sx);
          final sourceHeight = _subSize(over.height, sy);
          final right = math.min(sourceWidth, width - px);
          final bottom = math.min(sourceHeight, height - py);
          for (var row = math.max(0, -py); row < bottom; row++) {
            final start = (py + row) * width + px;
            for (var col = math.max(0, -px); col < right; col++) {
              final dest = start + col;
              final color = output[dest];
              final alpha = _overlayAlpha(
                over.alpha,
                col,
                row,
                sx,
                sy,
                sourceWidth,
                sourceHeight,
                max,
              );
              if (index == 3) {
                output[dest] =
                    color + _overlayDivide((max - color) * alpha, max);
                continue;
              }
              if (alpha == 0) continue;
              final straight = source!.at(col, row);
              // FFmpeg premultiplies its straight RGB input in Q8 before blending.
              final sample = premultiplied
                  ? (straight * alpha + 128) >> 8
                  : straight;
              if (alpha == max) {
                output[dest] = sample;
                continue;
              }
              final under = _overlayAlpha(
                main.alpha,
                px + col,
                py + row,
                sx,
                sy,
                math.min(width, px + sourceWidth),
                math.min(height, py + sourceHeight),
                max,
              );
              // For straight output divide source coverage by the composite coverage.
              final weight =
                  alpha * max * max ~/ ((alpha + under) * max - alpha * under);
              if (!premultiplied) {
                output[dest] = _overlayDivide(
                  color * (max - weight) + sample * weight,
                  max,
                );
              } else {
                output[dest] = math.min(
                  max,
                  _overlayDivide(color * (max - weight), max) + sample,
                );
              }
            }
          }
        }
        return _FilterPlane(output, width, height, depth, rowStep: width);
      });
    }
    return packedRgb == null || packedRgb == result.packedRgb
        ? result
        : _VideoPlanes(
            result.planes,
            result.subX,
            result.subY,
            matrix: result.matrix,
            fullRange: result.fullRange,
            packedRgb: packedRgb!,
            sampleAspect: result.sampleAspect,
            alpha: result.alpha,
          );
  }
}

_OverlayFormat _overlayFormat(_VideoPlanes frame) => (
  rgb: frame.rgb,
  subX: frame.subX,
  subY: frame.subY,
  depth: frame.planes.first.depth,
);

int? _overlayOffset(double value, int shift) =>
    !value.isFinite || value.abs() > 2147483647
    ? null
    : value.truncate() >> shift << shift;

int _overlayDivide(int value, int max) =>
    max == 255 ? ((value + 128) * 257) >> 16 : value ~/ max;

int _overlayAlpha(
  _FilterPlane? plane,
  int x,
  int y,
  int sx,
  int sy,
  int width,
  int height,
  int max,
) {
  if (plane == null) return max;
  final left = x << sx, top = y << sy;
  final current = plane.at(left, top);
  final right = sx != 0 && x + 1 < width && left + 1 < plane.width;
  final below = sy != 0 && y + 1 < height && top + 1 < plane.height;
  final alpha = right && below
      ? (current +
                plane.at(left + 1, top) +
                plane.at(left, top + 1) +
                plane.at(left + 1, top + 1)) >>
            2
      : right
      ? (3 * current + plane.at(left + 1, top)) >> 2
      : below
      ? (3 * current + plane.at(left, top + 1)) >> 2
      : current;
  final sourceMax = (1 << plane.depth) - 1;
  return sourceMax == max
      ? alpha
      : (alpha * max + (sourceMax >> 1)) ~/ sourceMax;
}
