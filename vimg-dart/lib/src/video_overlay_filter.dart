part of 'yuv_image.dart';

typedef _OverlayPosition = ({double x, double y});

typedef _OverlayCommandExpressions = ({
  OverlayPositionCommands positions,
  FilterExpression Function(FilterCommandArgument) resolve,
});

FilterExpression _parseOverlayCoordinate(
  String source, {
  void Function(String)? onVariable,
}) => parseFilterExpression(source, const {
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
}, onVariable: onVariable);

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
    final sync = _FrameSyncOptions.parse(options);
    final evaluateFrame = switch (options['eval']) {
      null || 'frame' || '1' => true,
      'init' || '0' => false,
      _ => throw const FormatException('Invalid overlay evaluation mode'),
    };
    final alphaMode = switch (options['alpha']) {
      null || 'auto' || 'unknown' || '0' => null,
      'straight' || '2' => false,
      'premultiplied' || '1' => true,
      _ => throw const FormatException('Invalid overlay alpha mode'),
    };
    final format = switch (options['format']) {
      null ||
      'yuv420' ||
      '0' => _pixelFormat(_PixelColor.yuv, 8, subX: 1, subY: 1),
      'yuv420p10' || '1' => _pixelFormat(_PixelColor.yuv, 10, subX: 1, subY: 1),
      'yuv422' || '2' => _pixelFormat(_PixelColor.yuv, 8, subX: 1),
      'yuv422p10' || '3' => _pixelFormat(_PixelColor.yuv, 10, subX: 1),
      'yuv444' || '4' => _pixelFormat(_PixelColor.yuv, 8),
      'yuv444p10' || '5' => _pixelFormat(_PixelColor.yuv, 10),
      'rgb' || '6' => _pixelFormat(_PixelColor.rgb, 8, packedRgb: true),
      'gbrp' || '7' => _pixelFormat(_PixelColor.rgb, 8),
      'auto' || '8' => null,
      _ => throw const FormatException('Invalid overlay pixel format'),
    };
    var dynamicPosition = false, usesPreviousPosition = false;
    void reference(String name) {
      if (_frameVariables.contains(name)) dynamicPosition = true;
      usesPreviousPosition |= name == 'x' || name == 'y';
    }

    final x = _parseOverlayCoordinate(
      options['x'] ?? '0',
      onVariable: reference,
    );
    final y = _parseOverlayCoordinate(
      options['y'] ?? '0',
      onVariable: reference,
    );
    return _Overlay._(
      x,
      y,
      format,
      alphaMode,
      evaluateFrame,
      evaluateFrame && dynamicPosition,
      usesPreviousPosition,
      sync,
    );
  }

  _Overlay._(
    this.x,
    this.y,
    this.format,
    this.alphaMode,
    this.evaluateFrame,
    this.usesFramePosition,
    this.usesPreviousPosition,
    this.sync, [
    this.outputFormat,
    this.bitmapFallback,
  ]);

  final FilterExpression x, y;
  final _VideoPixelFormat? format;
  final bool? alphaMode;
  final bool evaluateFrame;
  final bool usesFramePosition;
  final bool usesPreviousPosition;
  final _FrameSyncOptions sync;
  final _FormatFilter? outputFormat;
  final _NamedPixelFormat? bitmapFallback;
  final _converter = _PixelFormatConverter();
  late final mainFormat = _inputFormat(secondary: false);
  late final secondaryFormat = _inputFormat(secondary: true);

  _Overlay withFormat(_FormatFilter format, {required bool bitmapTerminal}) =>
      _Overlay._(
        x,
        y,
        this.format,
        alphaMode,
        evaluateFrame,
        usesFramePosition,
        usesPreviousPosition,
        sync,
        format,
        bitmapTerminal && this.format == null ? format.packedAlphaFormat : null,
      );

  static final _autoFormats = _FormatFilter._(
    [
      for (final depth in [8, 10])
        for (final (sx, sy) in [(1, 1), (1, 0), (0, 0)])
          (
            format: _pixelFormat(_PixelColor.yuv, depth, subX: sx, subY: sy),
            alpha: true,
            fullRange: null,
          ),
      _namedPixelFormat('rgba'),
      _namedPixelFormat('gbrap'),
    ],
    const [],
    const [],
  );

  _FormatFilter _inputFormat({required bool secondary}) {
    final requested = format;
    final modes = [if (secondary && alphaMode != null) alphaMode!];
    if (requested == null) {
      return modes.isEmpty
          ? _autoFormats
          : _FormatFilter._(_autoFormats.formats, const [], const [], modes);
    }
    final rgb = requested.color == _PixelColor.rgb;
    final opaque = (
      format: requested,
      alpha: false,
      fullRange: rgb ? true : null,
    );
    return _FormatFilter._(
      [
        if (!secondary) opaque,
        if (!secondary && requested.packedRgb) _namedPixelFormat('bgr24'),
        if (!secondary && !rgb && requested.depth == 8)
          (format: requested, alpha: false, fullRange: true),
        (format: requested, alpha: true, fullRange: opaque.fullRange),
      ],
      const [],
      const [],
      modes,
    );
  }

  ({_FormatSelection selection, bool convert}) _select(
    _VideoPlanes input,
    _VideoPlanes? secondary,
  ) {
    final negotiated = outputFormat ?? mainFormat;
    final original = mainFormat.matchingFormat(input);
    final secondaryLayout = format == null && secondary != null
        ? negotiated.matchingFormat(secondary)
        : null;
    // A compatible decoded main link fixes the working layout. Otherwise an
    // alpha-capable side or the negotiated output can supply the target.
    final selection = negotiated.select(
      input,
      preferred: original ?? secondaryLayout ?? bitmapFallback,
    );
    return (selection: selection, convert: original == null);
  }

  _OverlayPosition coordinates(
    _VideoPlanes main,
    _VideoPlanes over,
    _VideoPixelFormat layout,
    FilterFramePosition position, {
    _OverlayCommandExpressions? commands,
    _OverlayPosition? previous,
  }) {
    final variables = {
      'main_w': main.width.toDouble(),
      'W': main.width.toDouble(),
      'main_h': main.height.toDouble(),
      'H': main.height.toDouble(),
      'overlay_w': over.width.toDouble(),
      'w': over.width.toDouble(),
      'overlay_h': over.height.toDouble(),
      'h': over.height.toDouble(),
      'hsub': (1 << layout.subX).toDouble(),
      'vsub': (1 << layout.subY).toDouble(),
      'x': previous?.x ?? double.nan,
      'y': previous?.y ?? double.nan,
      // Overlay reads the main link's frame count after the current frame arrives.
      'n': evaluateFrame ? position.index + 1.0 : 0.0,
      't': evaluateFrame ? position.seconds : double.nan,
    };
    var xExpression = x, yExpression = y;
    void evaluateCoordinates() {
      variables['x'] = xExpression(variables);
      variables['y'] = yExpression(variables);
      variables['x'] = xExpression(variables);
    }

    if (commands == null) {
      evaluateCoordinates();
    } else if (commands.positions.history == null) {
      if (commands.positions.x case final arg?)
        xExpression = commands.resolve(arg);
      if (commands.positions.y case final arg?)
        yExpression = commands.resolve(arg);
      evaluateCoordinates();
    } else {
      // Init mode evaluates once at startup and again after each accepted update.
      evaluateCoordinates();
      final history = <OverlayPositionChange>[];
      for (
        var change = commands.positions.history;
        change != null;
        change = change.previous
      ) {
        history.add(change);
      }
      for (final change in history.reversed) {
        final expression = commands.resolve(change.argument);
        if (change.horizontal) {
          xExpression = expression;
        } else {
          yExpression = expression;
        }
        evaluateCoordinates();
      }
    }
    return (x: variables['x']!, y: variables['y']!);
  }

  _VideoPlanes apply(
    _VideoPlanes input,
    _VideoPlanes? secondary,
    FilterFramePosition position, {
    required bool enabled,
    _OverlayCommandExpressions? commands,
    _OverlayPosition? previousPosition,
  }) {
    final (:selection, :convert) = _select(input, secondary);
    final target = selection.format;
    final main = convert
        ? _converter.convert(
            input,
            target,
            alpha: selection.alpha,
            fullRange: selection.fullRange,
            matrix: selection.matrix,
          )
        : input;
    if (!enabled || secondary == null) return main;
    final over = _converter.convert(
      identical(input, secondary) ? main : secondary,
      target,
      alpha: format == null ? true : null,
      fullRange: main.fullRange,
      matrix: main.matrix,
      premultiplied: alphaMode ?? main.premultiplied,
    );
    final offset = coordinates(
      main,
      over,
      target,
      position,
      commands: commands,
      previous: previousPosition,
    );
    final top = _overlayOffset(offset.y, main.subY);
    final left = _overlayOffset(offset.x, main.subX);
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
              final sample = source!.at(col, row);
              if (alpha == max && (main.packedRgb || !over.premultiplied)) {
                output[dest] = sample;
                continue;
              }
              final weight =
                  main.alpha == null ||
                      main.premultiplied ||
                      alpha == 0 ||
                      alpha == max
                  ? alpha
                  : _straightOverlayWeight(
                      alpha,
                      _overlayAlpha(
                        main.alpha,
                        px + col,
                        py + row,
                        sx,
                        sy,
                        math.min(width, px + sourceWidth),
                        math.min(height, py + sourceHeight),
                        max,
                      ),
                    );
              if (!over.premultiplied) {
                output[dest] = _overlayDivide(
                  color * (max - weight) + sample * weight,
                  max,
                );
              } else if (main.packedRgb) {
                if (weight == 0) continue;
                if (weight == max) {
                  output[dest] = sample;
                  continue;
                }
                output[dest] = math.min(
                  max,
                  _overlayDivide(color * (max - weight), max) + sample,
                );
              } else {
                output[dest] = _blendAssociatedPlane(
                  color,
                  sample,
                  weight,
                  depth,
                  chroma: !main.rgb && index != 0,
                );
              }
            }
          }
        }
        return _FilterPlane(output, width, height, depth, rowStep: width);
      });
    }
    return result;
  }
}

int _blendAssociatedPlane(
  int color,
  int sample,
  int alpha,
  int depth, {
  required bool chroma,
}) {
  final mid = 1 << (depth - 1), maximum = (1 << depth) - 1;
  final offset = chroma ? mid : 16 << (depth - 8);
  final blended = depth > 8
      ? (color * (maximum - alpha) + sample * alpha) ~/ maximum
      : _overlayDivide(
          (color - (chroma ? mid : 0)) * (maximum - alpha),
          maximum,
        );
  final value = blended + sample - offset;
  return chroma ? value.clamp(-mid, mid) + mid : value.clamp(0, maximum);
}

int? _overlayOffset(double value, int shift) =>
    !value.isFinite || value.abs() > 2147483647
    ? null
    : value.truncate() >> shift << shift;

int _overlayDivide(int value, int max) =>
    max == 255 ? ((value + 128) * 257) >> 16 : value ~/ max;

int _straightOverlayWeight(int alpha, int under) {
  // The scalar overlay kernel stores the averaged destination alpha in a byte,
  // including in its 10-bit specialization.
  under &= 255;
  return (alpha * 255 * 255) ~/ ((alpha + under) * 255 - alpha * under);
}

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
