part of 'yuv_image.dart';

/// A single-input, single-output graph of video filters.
final class VideoFilterChain {
  VideoFilterChain._(this.source, this._filters, this._timing, [this._graph]);

  factory VideoFilterChain.parse(String source) {
    if (source.length > 2048) {
      throw const FormatException('Video filter chain exceeds 2048 characters');
    }
    return _compileFilterGraph(source);
  }

  final String source;
  final List<_SpatialFilter> _filters;
  final List<_TimingFilter> _timing;
  final _SynchronizedFilterGraph? _graph;

  static VideoFilterChain _presentation(
    VideoCrop? crop,
    VideoOrientation? orientation,
    VideoFilterChain? next,
  ) {
    final (:degrees, :horizontal, :vertical) =
        orientation ?? (degrees: 0, horizontal: false, vertical: false);
    return VideoFilterChain._(
      next?.source ?? '',
      [
        if (crop != null) _PresentationCrop(crop),
        if (degrees == 90 || degrees == 270)
          _Transpose._(degrees == 90 ? 1 : 2, 0)
        else if (degrees != 0)
          _Rotate(degrees),
        if (horizontal) _Flip.horizontal,
        if (vertical) _Flip.vertical,
        ...?next?._filters,
      ],
      next?._timing ?? const [],
      next?._graph,
    );
  }

  bool get hasSpatialFilters => _filters.isNotEmpty || _graph != null;
  bool get usesTimeline => _timing.isNotEmpty || _graph != null;

  CaptureTimeline filterTiming(CaptureTimeline timeline) {
    if (_graph case final graph?) return graph.schedule(timeline);
    for (final filter in _timing) {
      timeline = filter.apply(timeline);
    }
    return timeline;
  }

  _Scale? get _finalScale => switch (_filters.lastOrNull) {
    final _Scale scale => scale,
    _ => null,
  };

  _VideoPlanes _apply(
    _VideoPlanes frame,
    List<FilterFramePosition> positions, {
    required bool deferScale,
  }) {
    if (_graph != null) {
      throw const FormatException(
        'This video filter graph requires a capture timeline',
      );
    }
    final count = _filters.length - (deferScale ? 1 : 0);
    var next = 0;
    for (var i = 0; i < count; i++) {
      final filter = _filters[i];
      frame =
          filter is _FrameSpatialFilter &&
              filter.usesFramePosition &&
              next < positions.length
          ? filter.applyAt(frame, positions[next++])
          : filter.apply(frame);
    }
    return frame;
  }
}

typedef _FilterToken = ({int start, int end, String kind});

Iterable<_FilterToken> _filterSyntax(String source) sync* {
  var quoted = false, escaped = false, depth = 0;
  for (var i = 0; i < source.length; i++) {
    final char = source[i];
    if (escaped) {
      escaped = false;
    } else if (char == "'") {
      quoted = !quoted;
    } else if (!quoted) {
      switch (char) {
        case r'\':
          escaped = true;
        case '(':
          depth++;
        case ')':
          if (--depth < 0)
            throw const FormatException('Unbalanced filter expression');
        case '[' when depth == 0:
          final close = source.indexOf(']', i + 1);
          if (close < 0 || source.substring(i + 1, close).contains('[')) {
            throw const FormatException('Unterminated video filter label');
          }
          yield (start: i, end: close + 1, kind: '[');
          i = close;
        case ']':
          throw const FormatException('Unexpected video filter label end');
        case ',' || ';' || ':' when depth == 0:
          yield (start: i, end: i + 1, kind: char);
      }
    }
  }
  if (quoted || escaped || depth != 0) {
    throw const FormatException('Unterminated video filter argument');
  }
}

List<String> _splitFilterOptions(String source) {
  final parts = <String>[];
  var start = 0;
  for (final token in _filterSyntax(source)) {
    switch (token.kind) {
      case '[' || ';':
        throw const FormatException('Unexpected video filter option delimiter');
      case ':':
        parts.add(source.substring(start, token.start));
        start = token.end;
    }
  }
  return [...parts, source.substring(start)];
}

String _filterValue(String source) {
  final value = StringBuffer();
  var quoted = false;
  for (var i = 0; i < source.length; i++) {
    switch (source[i]) {
      case "'":
        quoted = !quoted;
      case r'\' when !quoted:
        value.write(source[++i]);
      default:
        value.write(source[i]);
    }
  }
  return value.toString().trim();
}

Map<String, String> _filterOptions(
  String? source,
  List<String> positional, [
  Map<String, String> aliases = const {},
]) {
  final options = <String, String>{};
  if (source == null) return options;
  var index = 0;
  // A colon escaped in both the graph and option layers remains literal.
  for (final arg in _splitFilterOptions(source.replaceAll(r'\\:', r'\:'))) {
    final equal = arg.indexOf('=');
    if (equal < 0 && index >= positional.length) {
      throw FormatException('Unexpected video filter argument: $arg');
    }
    final raw = equal < 0
        ? positional[index++]
        : arg.substring(0, equal).trim();
    final name = aliases[raw] ?? raw;
    if (!positional.contains(name)) {
      throw FormatException('Unsupported video filter option: $raw');
    }
    if (options.containsKey(name)) {
      throw FormatException('Duplicate video filter option: $name');
    }
    options[name] = _filterValue(arg.substring(equal + 1));
  }
  return options;
}

const _dimensionVariables = {
  'iw',
  'in_w',
  'ih',
  'in_h',
  'ow',
  'out_w',
  'oh',
  'out_h',
  'a',
  'sar',
  'dar',
  'hsub',
  'vsub',
};

void _checkFilterSize(int width, int height) {
  if (width < 1 ||
      height < 1 ||
      width > 32768 ||
      height > 32768 ||
      width * height > 100000000) {
    throw FormatException('Invalid video filter dimensions: ${width}x$height');
  }
}

int _dimension(double value, {bool nearest = false}) {
  if (!value.isFinite || value.abs() > 2147483647) {
    throw const FormatException('Invalid video filter dimension expression');
  }
  if (!nearest) return value.truncate();
  final floor = value.floor();
  // Crop uses nearest integer, with ties to even.
  return value - floor == 0.5 ? floor + (floor & 1) : value.round();
}

abstract interface class _SpatialFilter {
  _VideoPlanes apply(_VideoPlanes frame);
}

abstract class _FrameSpatialFilter implements _SpatialFilter {
  bool get usesFramePosition;
  _VideoPlanes applyAt(_VideoPlanes frame, FilterFramePosition position);

  @override
  _VideoPlanes apply(_VideoPlanes frame) =>
      applyAt(frame, (index: 0, seconds: 0));
}

const _frameVariables = {'n', 't'};

final class _PresentationCrop implements _SpatialFilter {
  const _PresentationCrop(this.crop);
  final VideoCrop crop;

  @override
  _VideoPlanes apply(_VideoPlanes frame) {
    final (:left, :right, :top, :bottom) = crop;
    final width = frame.width - left - right;
    final height = frame.height - top - bottom;
    if (width <= 0 || height <= 0) {
      throw const FormatException('Matroska crop exceeds decoded dimensions');
    }
    return frame.map(
      (plane, sx, sy) => plane.window(
        left >> sx,
        top >> sy,
        _subSize(width, sx),
        _subSize(height, sy),
      ),
    );
  }
}

enum _Flip implements _SpatialFilter {
  horizontal,
  vertical;

  @override
  _VideoPlanes apply(_VideoPlanes frame) => frame.map(
    (plane, _, _) => plane.orient(
      horizontal: this == horizontal,
      vertical: this == vertical,
    ),
  );
}

final class _Crop extends _FrameSpatialFilter {
  factory _Crop(String? source) {
    final options = _filterOptions(
      source,
      ['w', 'h', 'x', 'y', 'keep_aspect', 'exact'],
      {'out_w': 'w', 'out_h': 'h'},
    );
    final exact = switch (options['exact']) {
      null || '0' || 'false' => false,
      '1' || 'true' => true,
      _ => throw const FormatException('crop exact must be 0 or 1'),
    };
    final keepAspect = _filterFlag(options['keep_aspect'], 'crop keep_aspect');
    const positionVariables = {
      ..._dimensionVariables,
      ..._frameVariables,
      'x',
      'y',
    };
    var dynamicPosition = false;
    void reference(String name) {
      if (_frameVariables.contains(name)) dynamicPosition = true;
    }

    final x = parseFilterExpression(
      options['x'] ?? '(iw-ow)/2',
      positionVariables,
      onVariable: reference,
    );
    final y = parseFilterExpression(
      options['y'] ?? '(ih-oh)/2',
      positionVariables,
      onVariable: reference,
    );
    return _Crop._(
      parseFilterExpression(options['w'] ?? 'iw', _dimensionVariables),
      parseFilterExpression(options['h'] ?? 'ih', _dimensionVariables),
      x,
      y,
      exact,
      keepAspect,
      dynamicPosition,
    );
  }

  _Crop._(
    this.width,
    this.height,
    this.x,
    this.y,
    this.exact,
    this.keepAspect,
    this.usesFramePosition,
  );

  final FilterExpression width, height, x, y;
  final bool exact, keepAspect;
  @override
  final bool usesFramePosition;

  @override
  _VideoPlanes applyAt(_VideoPlanes frame, FilterFramePosition position) {
    final vars = frame.variables
      ..['n'] = position.index.toDouble()
      ..['t'] = position.seconds;
    vars['out_w'] = vars['ow'] = width(vars);
    vars['out_h'] = vars['oh'] = height(vars);
    vars['out_w'] = vars['ow'] = width(vars);
    final h = _dimension(vars['oh']!, nearest: true);
    final w = _dimension(vars['ow']!, nearest: true);
    final xs = exact ? 0 : frame.subX, ys = exact ? 0 : frame.subY;
    final cropW = w >> xs << xs, cropH = h >> ys << ys;
    _checkFilterSize(cropW, cropH);
    if (cropW > frame.width || cropH > frame.height) {
      throw const FormatException('Crop dimensions exceed the source frame');
    }
    vars['x'] = x(vars);
    vars['y'] = y(vars);
    final top = _dimension(vars['y']!, nearest: true);
    final left = _dimension(x(vars), nearest: true);
    final ox = left.clamp(0, frame.width - cropW) >> xs << xs;
    final oy = top.clamp(0, frame.height - cropH) >> ys << ys;
    return frame.map(
      (plane, sx, sy) => plane.window(
        ox >> sx,
        oy >> sy,
        _subSize(cropW, sx),
        _subSize(cropH, sy),
      ),
      sampleAspect: keepAspect
          ? frame.sampleAspect * frame.width * cropH / (frame.height * cropW)
          : null,
    );
  }
}

final class _Transpose implements _SpatialFilter {
  factory _Transpose(String? source) {
    final options = _filterOptions(source, ['dir', 'passthrough']);
    final direction = switch (options['dir']) {
      null || '0' || '4' || 'cclock_flip' => 0,
      '1' || '5' || 'clock' => 1,
      '2' || '6' || 'cclock' => 2,
      '3' || '7' || 'clock_flip' => 3,
      _ => throw const FormatException('Invalid transpose direction'),
    };
    final passthrough = switch (options['dir']) {
      '4' || '5' || '6' || '7' => 2,
      _ => switch (options['passthrough']) {
        null || '0' || 'none' => 0,
        '1' || 'portrait' => 1,
        '2' || 'landscape' => 2,
        _ => throw const FormatException('Invalid transpose passthrough'),
      },
    };
    return _Transpose._(direction, passthrough);
  }

  _Transpose._(this.direction, this.passthrough);
  final int direction, passthrough;

  @override
  _VideoPlanes apply(_VideoPlanes frame) {
    if (passthrough == 1 && frame.width <= frame.height ||
        passthrough == 2 && frame.width >= frame.height) {
      return frame;
    }
    return _VideoPlanes(
      [
        for (final plane in frame.planes)
          plane.orient(
            transpose: true,
            horizontal: direction.isOdd,
            vertical: direction >= 2,
          ),
      ],
      frame.subY,
      frame.subX,
      matrix: frame.matrix,
      fullRange: frame.fullRange,
      packedRgb: frame.packedRgb,
      bgr24: frame.bgr24,
      sampleAspect: 1 / frame.sampleAspect,
      alpha: frame.alpha?.orient(
        transpose: true,
        horizontal: direction.isOdd,
        vertical: direction >= 2,
      ),
      premultiplied: frame.premultiplied,
    );
  }
}

/// Fixed-canvas bilinear rotation for display matrices at other angles.
final class _Rotate implements _SpatialFilter {
  _Rotate(int degrees)
    : _cos = math.cos(degrees * math.pi / 180),
      _sin = math.sin(degrees * math.pi / 180);

  final double _cos, _sin;

  @override
  _VideoPlanes apply(_VideoPlanes frame) {
    return frame.mapComponents((plane, _, _, component) {
      final width = plane.width, height = plane.height;
      final middleX = (width - 1) / 2, middleY = (height - 1) / 2;
      final depth = plane.floating ? 16 : plane.depth;
      final fill = switch (component) {
        3 => (1 << depth) - 1,
        _ when frame.rgb => 0,
        1 || 2 => 1 << (depth - 1),
        _ => frame.fullRange ? 0 : 16 << (depth - 8),
      };
      final samples = plane.emptySamples(width * height);
      final blank = plane.floating ? fill / 65535 : fill;
      final source = plane.values;
      for (var y = 0; y < height; y++) {
        final dy = y - middleY;
        var sx = middleX - middleX * _cos + dy * _sin;
        var sy = middleY + middleX * _sin + dy * _cos;
        for (var x = 0; x < width; x++, sx += _cos, sy -= _sin) {
          final destination = y * width + x;
          if (sx < -0.5 || sx > width - 0.5 || sy < -0.5 || sy > height - 0.5) {
            samples[destination] = blank;
            continue;
          }
          final u = sx.clamp(0.0, width - 1.0);
          final v = sy.clamp(0.0, height - 1.0);
          final left = u.floor(), top = v.floor();
          final fx = u - left, fy = v - top;
          final at =
              plane.offset + top * plane.rowStep + left * plane.columnStep;
          final dx = left + 1 < width ? plane.columnStep : 0;
          final dy = top + 1 < height ? plane.rowStep : 0;
          final a = source[at] * (1 - fx) + source[at + dx] * fx;
          final b = source[at + dy] * (1 - fx) + source[at + dy + dx] * fx;
          final value = a * (1 - fy) + b * fy;
          samples[destination] = plane.floating ? value : value.round();
        }
      }
      return plane.withSamples(samples, width, height);
    });
  }
}

enum _ScaleAspect { disable, decrease, increase }

int? _scaleColorMatrix(String? name) => switch (name) {
  null || 'auto' || '-1' => null,
  'bt601' || 'bt470' || 'smpte170m' => 5,
  'bt2020' => 9,
  '1' || '2' || '4' || '5' || '6' || '7' || '9' => int.parse(name),
  _ => _namedColorMatrix(name),
};

bool? _scaleColorRange(String? name) => switch (name) {
  null || 'auto' || 'unknown' || '0' => null,
  'tv' || 'limited' || 'mpeg' || '1' => false,
  'pc' || 'full' || 'jpeg' || '2' => true,
  _ => throw FormatException('Unsupported scale color range: $name'),
};

final class _Scale extends _FrameSpatialFilter {
  factory _Scale(String? source) {
    final options = _filterOptions(
      source,
      [
        'w',
        'h',
        'flags',
        'eval',
        'force_original_aspect_ratio',
        'force_divisible_by',
        'reset_sar',
        'in_color_matrix',
        'out_color_matrix',
        'in_range',
        'out_range',
      ],
      {'width': 'w', 'height': 'h'},
    );
    final (algorithm, fullChromaInput) = switch (options['flags']) {
      null || 'bicubic' => (_ScaleAlgorithm.bicubic, false),
      'bilinear' => (_ScaleAlgorithm.bilinear, false),
      'bilinear+full_chroma_inp' ||
      'full_chroma_inp+bilinear' => (_ScaleAlgorithm.bilinear, true),
      'bicublin' => (_ScaleAlgorithm.bicublin, false),
      'bicublin+full_chroma_inp' ||
      'full_chroma_inp+bicublin' => (_ScaleAlgorithm.bicublin, true),
      'neighbor' => (_ScaleAlgorithm.neighbor, false),
      'neighbor+full_chroma_inp' ||
      'full_chroma_inp+neighbor' => (_ScaleAlgorithm.neighbor, true),
      _ => throw const FormatException(
        'Supported scale flags are bicubic, bilinear, bicublin and neighbor',
      ),
    };
    final perFrame = switch (options['eval']) {
      null || 'init' || '0' => false,
      'frame' || '1' => true,
      _ => throw const FormatException('scale eval must be init or frame'),
    };
    final aspect = switch (options['force_original_aspect_ratio']) {
      null || '0' || 'disable' => _ScaleAspect.disable,
      '1' || 'decrease' => _ScaleAspect.decrease,
      '2' || 'increase' => _ScaleAspect.increase,
      _ => throw const FormatException('Invalid scale aspect ratio mode'),
    };
    final divisibleBy =
        _filterInteger(options, 'force_divisible_by', minimum: 1) ?? 1;
    if (divisibleBy > 256) {
      throw const FormatException('scale force_divisible_by exceeds 256');
    }
    final resetSar = _filterFlag(options['reset_sar'], 'scale reset_sar');
    final variables = perFrame
        ? const {..._dimensionVariables, ..._frameVariables}
        : _dimensionVariables;
    var dynamicSize = false;
    void reference(String name) {
      if (_frameVariables.contains(name)) dynamicSize = true;
    }

    final width = parseFilterExpression(
      options['w'] ?? 'iw',
      variables,
      onVariable: reference,
    );
    final height = parseFilterExpression(
      options['h'] ?? 'ih',
      variables,
      onVariable: reference,
    );
    final outputMatrix = _scaleColorMatrix(options['out_color_matrix']);
    return _Scale._(
      width,
      height,
      algorithm,
      fullChromaInput,
      dynamicSize,
      aspect,
      divisibleBy,
      resetSar,
      inputMatrix: _scaleColorMatrix(options['in_color_matrix']),
      outputMatrix: outputMatrix == 2 ? null : outputMatrix,
      inputRange: _scaleColorRange(options['in_range']),
      outputRange: _scaleColorRange(options['out_range']),
    );
  }

  _Scale._(
    this.width,
    this.height,
    this.algorithm,
    this.fullChromaInput,
    this.usesFramePosition,
    this.aspect,
    this.divisibleBy,
    this.resetSar, {
    this.inputMatrix,
    this.outputMatrix,
    this.inputRange,
    this.outputRange,
  });
  final FilterExpression width, height;
  final _ScaleAlgorithm algorithm;
  final bool fullChromaInput, resetSar;
  final _ScaleAspect aspect;
  final int divisibleBy;
  final int? inputMatrix, outputMatrix;
  final bool? inputRange, outputRange;
  @override
  final bool usesFramePosition;
  final _scalers = <(int, int, int, int, _ScaleKernel, int), _PlaneScaler>{};
  late final _converter = _PixelFormatConverter();

  bool get nearest => algorithm == _ScaleAlgorithm.neighbor;

  _FormatFilter? get outputColors => outputMatrix == null && outputRange == null
      ? null
      : _FormatFilter._(
          const [],
          [if (outputMatrix case final matrix?) matrix],
          [if (outputRange case final range?) range],
        );

  @override
  _VideoPlanes applyAt(
    _VideoPlanes frame,
    FilterFramePosition position, {
    _FormatFilter? outputFormat,
  }) {
    final (w, h) = dimensions(frame, position);
    final selection = outputFormat?.select(
      frame,
      outputMatrix: outputMatrix,
      outputRange: outputRange,
    );
    final target = selection?.format ?? _frameFormat(frame);
    final alpha = selection?.alpha;
    final mode = outputFormat?.alphaMode(frame);
    if (mode != null && alpha != false) {
      frame = _converter.changeAlphaMode(frame, mode);
    }
    final preserveAlpha = alpha == null || alpha == (frame.alpha != null);
    final sameLayout = target == _frameFormat(frame) && preserveAlpha;
    if (frame.rgb && target.color == _PixelColor.rgb) {
      final resized = resize(frame, w, h);
      return sameLayout
          ? resized
          : _converter.convert(
              resized,
              target,
              alpha: alpha,
              premultiplied: mode,
            );
    }
    final input = interpretInputColor(frame);
    // For planar output, default to the color properties of the source link.
    final matrix =
        selection?.matrix ?? outputMatrix ?? (frame.rgb ? 6 : frame.matrix);
    final fullRange =
        selection?.fullRange ??
        outputRange ??
        (target.color == _PixelColor.yuv
            ? !frame.rgb && frame.planes.length == 3 && frame.fullRange
            : !sameLayout || frame.fullRange);
    if (sameLayout &&
        (input.planes.length == 1 ||
            _rgbCoefficients(input.matrix) == _rgbCoefficients(matrix))) {
      return resize(
        input,
        w,
        h,
        fullRange: fullRange,
      ).withColor(matrix: matrix, fullRange: fullRange);
    }
    return _converter.convert(
      input,
      target,
      alpha: alpha,
      matrix: matrix,
      fullRange: target.color == _PixelColor.rgb ? true : fullRange,
      premultiplied: mode,
      scale: (
        width: w,
        height: h,
        sampleAspect: _outputAspect(frame, w, h),
        algorithm: algorithm,
        fullChromaInput: fullChromaInput,
      ),
    );
  }

  _VideoPlanes interpretInputColor(_VideoPlanes frame) => frame.rgb
      ? frame
      : frame.withColor(
          matrix: inputMatrix ?? frame.matrix,
          fullRange: inputRange ?? frame.fullRange,
        );

  bool _subsamplesRgb(_VideoPlanes frame, int width) =>
      !fullChromaInput &&
      frame.packedRgb &&
      frame.width.isEven &&
      width <= frame.width ~/ 2;

  double _outputAspect(_VideoPlanes frame, int width, int height) => resetSar
      ? 1.0
      : frame.sampleAspect * frame.width * height / (frame.height * width);

  _VideoPlanes resize(
    _VideoPlanes frame,
    int width,
    int height, {
    bool? fullRange,
  }) {
    final sampleAspect = _outputAspect(frame, width, height);
    if (_subsamplesRgb(frame, width)) {
      return nearest
          ? _pointScalePackedRgb(frame, width, height, sampleAspect)
          : _scaleSubsampledRgb(frame, width, height, sampleAspect, this);
    }
    return frame.mapComponents((plane, sx, sy, component) {
      final chroma = !frame.rgb && (component == 1 || component == 2);
      final range =
          !plane.floating &&
              component != 3 &&
              fullRange != null &&
              fullRange != frame.fullRange
          ? _VideoSampleRange(plane.depth, frame.fullRange, fullRange, chroma)
          : null;
      return _resize(
        plane,
        _subSize(width, sx),
        _subSize(height, sy),
        packedAlpha: frame.packedRgb && component == 3,
        kernel: algorithm.kernel(chroma: chroma),
        range: range,
      );
    }, sampleAspect: sampleAspect);
  }

  (int, int) dimensions(_VideoPlanes frame, FilterFramePosition? position) {
    final vars = frame.variables
      // FFmpeg 8's scale evaluates after its input frame has been consumed.
      ..['n'] = ((position?.index ?? 0) + 1).toDouble()
      ..['t'] = position?.seconds ?? 0;
    final firstWidth = width(vars);
    vars['out_w'] = vars['ow'] = firstWidth == 0
        ? frame.width.toDouble()
        : firstWidth.isFinite
        ? firstWidth.truncateToDouble()
        : double.nan;
    var h = _dimension(height(vars));
    if (h == 0) h = frame.height;
    vars['out_h'] = vars['oh'] = h.toDouble();
    var w = _dimension(width(vars));
    if (w == 0) w = frame.width;
    final displayWidth = frame.width * (resetSar ? frame.sampleAspect : 1.0);
    // FFmpeg rounds to the nearest requested multiple, with ties upward.
    // Its integer rescaling truncates the SAR-adjusted operand first.
    int widthFor(int height, int multiple) => _scaleMultiple(
      height,
      displayWidth.truncate(),
      frame.height * multiple,
      multiple,
    );
    int heightFor(int width, int multiple) => _scaleMultiple(
      width,
      frame.height,
      (displayWidth * multiple).truncate(),
      multiple,
    );

    if (w < 0 && h < 0) {
      w = displayWidth.truncate();
      h = frame.height;
    } else if (w < 0) {
      w = widthFor(h, -w);
    } else if (h < 0) {
      h = heightFor(w, -h);
    }
    if (aspect != _ScaleAspect.disable) {
      final proportionalWidth = widthFor(h, divisibleBy);
      final proportionalHeight = heightFor(w, divisibleBy);
      if (aspect == _ScaleAspect.decrease) {
        w = math.min(w, proportionalWidth) ~/ divisibleBy * divisibleBy;
        h = math.min(h, proportionalHeight) ~/ divisibleBy * divisibleBy;
      } else {
        w =
            (math.max(w, proportionalWidth) + divisibleBy - 1) ~/
            divisibleBy *
            divisibleBy;
        h =
            (math.max(h, proportionalHeight) + divisibleBy - 1) ~/
            divisibleBy *
            divisibleBy;
      }
    }
    _checkFilterSize(w, h);
    return (w, h);
  }

  _PlaneScaler _planeScaler(
    int sourceWidth,
    int sourceHeight,
    int width,
    int height,
    _ScaleKernel kernel, {
    int precision = 15,
  }) {
    if (width * sourceHeight > 100000000) {
      throw const FormatException(
        'Video filter scaling exceeds 100 million intermediate samples',
      );
    }
    final geometry = (
      sourceWidth,
      sourceHeight,
      width,
      height,
      kernel,
      precision,
    );
    if (_scalers.length >= 4 && !_scalers.containsKey(geometry)) {
      _scalers.clear();
    }
    return _scalers.putIfAbsent(
      geometry,
      () => _PlaneScaler(
        sourceWidth,
        sourceHeight,
        width,
        height,
        kernel: kernel,
        precision: precision,
      ),
    );
  }

  _FilterPlane _resize(
    _FilterPlane source,
    int width,
    int height, {
    required bool packedAlpha,
    required _ScaleKernel kernel,
    required _VideoSampleRange? range,
  }) {
    final sameSize = source.width == width && source.height == height;
    if (sameSize && range == null) return source;
    if (source.floating)
      return _resizeFloatPlane(source, width, height, kernel);
    final limit = (1 << source.depth) - 1;
    if (nearest || sameSize) {
      final samples = Int32List(width * height);
      final dx = _scaleStep(source.width, width);
      final dy = _scaleStep(source.height, height);
      var i = 0;
      for (var y = 0; y < height; y++) {
        final row = _nearestIndex(y, dy, source.height);
        for (var x = 0; x < width; x++) {
          final column = _nearestIndex(x, dx, source.width);
          final sample = source.at(column, row);
          samples[i++] = range != null
              ? range.sample(sample, source.depth).clamp(0, limit)
              : packedAlpha
              ? _packedPointAlpha(sample)
              : sample;
        }
      }
      return _FilterPlane(samples, width, height, source.depth, rowStep: width);
    }
    final scaler = _planeScaler(
      source.width,
      source.height,
      width,
      height,
      kernel,
      precision: range?.precision ?? 15,
    );
    final plane = source.forward;
    final samples = scaler.resize(
      plane.samples,
      plane.rowStep,
      plane.offset,
      plane.depth,
      plane.depth - 8,
      range: range,
    );
    for (var i = 0; i < samples.length; i++) {
      samples[i] = samples[i].clamp(0, limit);
    }
    return _FilterPlane(samples, width, height, plane.depth, rowStep: width);
  }
}

final class _ScaleFormat extends _FrameSpatialFilter {
  _ScaleFormat(this.scale, this.format);

  final _Scale scale;
  final _FormatFilter format;

  @override
  bool get usesFramePosition => scale.usesFramePosition;

  @override
  _VideoPlanes applyAt(_VideoPlanes frame, FilterFramePosition position) =>
      scale.applyAt(frame, position, outputFormat: format);
}

/// Maps video range while samples still have horizontal filter precision.
final class _VideoSampleRange {
  factory _VideoSampleRange(int depth, bool inputFull, bool full, bool chroma) {
    final precision = depth <= 14 ? 15 : 19;
    final shift = precision - depth;
    final multiplicationShift = precision - 1;
    final (inputMin, inputSpan) = _componentLevels(
      depth,
      inputFull,
      chroma,
      fromMinimum: true,
    );
    final (outputMin, outputSpan) = _componentLevels(
      depth,
      full,
      chroma,
      fromMinimum: true,
    );
    final inputMax = inputMin + inputSpan, outputMax = outputMin + outputSpan;
    final divisor = 1 << shift;
    final slope = (outputSpan << (multiplicationShift + shift)) ~/ inputSpan;
    final factor = (slope + divisor - 1) >> shift;
    // Anchor the upper endpoint after quantizing the fixed-point factor.
    final offset =
        (outputMax << (multiplicationShift + shift)) -
        (inputMax << shift) * factor +
        (1 << (multiplicationShift - 1));
    return _VideoSampleRange._(precision, factor, offset);
  }

  const _VideoSampleRange._(this.precision, this.factor, this.offset);

  final int precision, factor, offset;

  int convert(int value) => math.min(
    (1 << precision) - 1,
    (value * factor + offset) >> (precision - 1),
  );

  int sample(int value, int depth) {
    final shift = precision - depth;
    return (convert(value << shift) + (1 << (shift - 1))) >> shift;
  }
}

int _scaleMultiple(int size, int numerator, int denominator, int multiple) {
  if (denominator <= 0) {
    throw const FormatException('Invalid scale input aspect ratio');
  }
  final divisor = BigInt.from(denominator);
  final product = BigInt.from(size) * BigInt.from(numerator);
  final scaled =
      ((product + (divisor >> 1)) ~/ divisor) * BigInt.from(multiple);
  if (!scaled.isValidInt) {
    throw const FormatException('Invalid scaled video dimension');
  }
  return scaled.toInt();
}

int _subSize(int size, int shift) => (size + (1 << shift) - 1) >> shift;

final class _VideoPlanes {
  _VideoPlanes(
    this.planes,
    this.subX,
    this.subY, {
    required this.matrix,
    required this.fullRange,
    this.packedRgb = false,
    this.bgr24 = false,
    this.sampleAspect = 1,
    this.alpha,
    this.premultiplied = false,
  });
  final List<_FilterPlane> planes;
  final int subX, subY;
  final _FilterPlane? alpha;
  final bool premultiplied;
  final int matrix;
  final bool fullRange;
  final bool packedRgb;
  final bool bgr24;
  final double sampleAspect;

  int get width => planes.first.width;
  int get height => planes.first.height;
  bool get rgb => matrix == 0 && planes.length == 3;
  bool get floating => planes.first.floating;

  bool get usesDeepRgbPacking =>
      rgb &&
      !packedRgb &&
      fullRange &&
      subX == 0 &&
      subY == 0 &&
      planes.first.depth > 8 &&
      planes.every((plane) => plane.depth == planes.first.depth);

  bool get usesUnscaledRgbTable =>
      width.isEven &&
      height.isEven &&
      subX == 1 &&
      subY <= 1 &&
      !rgb &&
      planes.length == 3 &&
      planes.every((plane) => plane.depth == 8);

  _VideoPlanes withColor({required int matrix, required bool fullRange}) {
    if (matrix == this.matrix && fullRange == this.fullRange) return this;
    return _VideoPlanes(
      planes,
      subX,
      subY,
      matrix: matrix,
      fullRange: fullRange,
      packedRgb: packedRgb,
      bgr24: bgr24,
      sampleAspect: sampleAspect,
      alpha: alpha,
      premultiplied: premultiplied,
    );
  }

  Map<String, double> get variables => {
    'iw': width.toDouble(),
    'in_w': width.toDouble(),
    'ih': height.toDouble(),
    'in_h': height.toDouble(),
    'a': width / height,
    'sar': sampleAspect,
    'dar': width / height * sampleAspect,
    'hsub': (1 << subX).toDouble(),
    'vsub': (1 << subY).toDouble(),
  };

  _VideoPlanes map(
    _FilterPlane Function(_FilterPlane, int, int) transform, {
    double? sampleAspect,
  }) => mapComponents(
    (plane, sx, sy, _) => transform(plane, sx, sy),
    sampleAspect: sampleAspect,
  );

  _VideoPlanes mapComponents(
    _FilterPlane Function(_FilterPlane, int, int, int) transform, {
    double? sampleAspect,
    bool? premultiplied,
  }) => _VideoPlanes(
    [
      transform(planes.first, 0, 0, 0),
      for (var i = 1; i < planes.length; i++)
        transform(planes[i], subX, subY, i),
    ],
    subX,
    subY,
    matrix: matrix,
    fullRange: fullRange,
    packedRgb: packedRgb,
    bgr24: bgr24,
    sampleAspect: sampleAspect ?? this.sampleAspect,
    alpha: alpha == null ? null : transform(alpha!, 0, 0, 3),
    premultiplied: premultiplied ?? this.premultiplied,
  );
}

const _floatSampleDepth = 32;

/// A rectangular sample view. Crop, flips and transpose compose by changing
/// the origin and signed strides. Samples are copied only when needed by RGB
/// conversion or the separable resampler.
final class _FilterPlane {
  _FilterPlane(
    List<int> samples,
    int width,
    int height,
    int depth, {
    required int rowStep,
    int columnStep = 1,
    int offset = 0,
  }) : this._(
         samples,
         width,
         height,
         depth,
         rowStep: rowStep,
         columnStep: columnStep,
         offset: offset,
       );

  _FilterPlane.f32(Float32List samples, int width, int height)
    : this._(samples, width, height, _floatSampleDepth, rowStep: width);

  _FilterPlane._(
    this.values,
    this.width,
    this.height,
    this.depth, {
    required this.rowStep,
    this.columnStep = 1,
    this.offset = 0,
  });

  final List<num> values;
  final int width, height, depth, rowStep, columnStep, offset;

  bool get floating => depth == _floatSampleDepth;
  List<int> get samples => values as List<int>;
  List<num> emptySamples(int length) =>
      floating ? Float32List(length) : _paintSamples(depth, length);

  _FilterPlane withSamples(List<num> samples, int w, int h) =>
      _FilterPlane._(samples, w, h, depth, rowStep: w);

  int at(int x, int y) => samples[offset + y * rowStep + x * columnStep];
  double floatAt(int x, int y) =>
      (values as Float32List)[offset + y * rowStep + x * columnStep];

  _FilterPlane window(int x, int y, int width, int height) => _FilterPlane._(
    values,
    width,
    height,
    depth,
    rowStep: rowStep,
    columnStep: columnStep,
    offset: offset + x * columnStep + y * rowStep,
  );

  _FilterPlane orient({
    bool transpose = false,
    bool horizontal = false,
    bool vertical = false,
  }) {
    final w = transpose ? height : width;
    final h = transpose ? width : height;
    final dx = transpose ? rowStep : columnStep;
    final dy = transpose ? columnStep : rowStep;
    return _FilterPlane._(
      values,
      w,
      h,
      depth,
      rowStep: vertical ? -dy : dy,
      columnStep: horizontal ? -dx : dx,
      offset:
          offset +
          (horizontal ? (w - 1) * dx : 0) +
          (vertical ? (h - 1) * dy : 0),
    );
  }

  _FilterPlane get forward {
    if (columnStep == 1 && rowStep > 0) return this;
    return _copy();
  }

  _FilterPlane get atOrigin {
    if (offset == 0 && columnStep == 1 && rowStep > 0) return this;
    return _copy();
  }

  _FilterPlane get packed {
    if (rowStep == width && columnStep == 1 && offset == 0) return this;
    return _copy();
  }

  _FilterPlane _copy([int Function(int)? transform]) {
    if (floating) {
      assert(transform == null);
      return mapFloat((value, _, _) => value);
    }
    final copy = depth <= 8
        ? Uint8List(width * height)
        : Uint16List(width * height);
    var i = 0;
    for (var y = 0; y < height; y++) {
      var source = offset + y * rowStep;
      for (var x = 0; x < width; x++) {
        final value = samples[source];
        copy[i++] = transform == null ? value : transform(value);
        source += columnStep;
      }
    }
    return _FilterPlane(copy, width, height, depth, rowStep: width);
  }

  _FilterPlane mapFloat(double Function(double, int, int) transform) {
    final copy = Float32List(width * height);
    var i = 0;
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        copy[i++] = transform(floatAt(x, y), x, y);
      }
    }
    return _FilterPlane.f32(copy, width, height);
  }
}
