part of 'yuv_image.dart';

/// A linear chain of spatial operations and frame-timing filters.
final class VideoFilterChain {
  VideoFilterChain._(this.source, this._filters, this._timing);

  factory VideoFilterChain.parse(String source) {
    if (source.length > 2048) {
      throw const FormatException('Video filter chain exceeds 2048 characters');
    }
    final filters = <_SpatialFilter>[];
    final timing = <_TimingFilter>[];
    void addSpatial(_SpatialFilter filter) {
      filters.add(filter);
      if (filter is _FrameSpatialFilter && filter.usesFramePosition) {
        timing.add(const _RecordFramePosition());
      }
    }

    for (final entry in _splitFilters(source, ',')) {
      final equal = entry.indexOf('=');
      final name = (equal < 0 ? entry : entry.substring(0, equal)).trim();
      final args = equal < 0 ? null : entry.substring(equal + 1);
      switch (name) {
        case 'null' || 'hflip' || 'vflip':
          if (args != null) throw FormatException('$name takes no options');
          if (name == 'hflip') filters.add(_Flip.horizontal);
          if (name == 'vflip') filters.add(_Flip.vertical);
        case 'crop':
          addSpatial(_Crop(args));
        case 'transpose':
          filters.add(_Transpose(args));
        case 'scale':
          addSpatial(_Scale(args));
        case 'pad':
          filters.add(_Pad(args));
        case 'drawbox':
          filters.add(_DrawBox(args));
        case 'negate':
          filters.add(_Negate(args));
        case 'setsar' || 'setdar':
          filters.add(_SetAspect(args, display: name == 'setdar'));
        case 'trim':
          timing.add(_Trim(args));
        case 'setpts':
          timing.add(_SetPts(args));
        case 'settb':
          timing.add(_SetTimeBase(args));
        case 'fps':
          timing.add(_Fps(args));
        default:
          throw FormatException('Unsupported video filter: $name');
      }
    }
    return VideoFilterChain._(source, filters, timing);
  }

  final String source;
  final List<_SpatialFilter> _filters;
  final List<_TimingFilter> _timing;

  static VideoFilterChain _presentation(
    VideoCrop? crop,
    VideoOrientation? orientation,
    VideoFilterChain? next,
  ) {
    final (:degrees, :horizontal, :vertical) =
        orientation ?? (degrees: 0, horizontal: false, vertical: false);
    return VideoFilterChain._(next?.source ?? '', [
      if (crop != null) _PresentationCrop(crop),
      if (degrees == 90 || degrees == 270)
        _Transpose._(degrees == 90 ? 1 : 2, 0)
      else if (degrees != 0)
        _Rotate(degrees),
      if (horizontal) _Flip.horizontal,
      if (vertical) _Flip.vertical,
      ...?next?._filters,
    ], next?._timing ?? const []);
  }

  bool get hasSpatialFilters => _filters.isNotEmpty;
  bool get usesTimeline => _timing.isNotEmpty;

  CaptureTimeline filterTiming(CaptureTimeline timeline) {
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

List<String> _splitFilters(String source, String delimiter) {
  final parts = <String>[];
  var quoted = false, escaped = false, depth = 0, start = 0;
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
        case ';' || '[' || ']':
          throw const FormatException(
            'Only linear video filter chains are supported',
          );
        case _ when char == delimiter && depth == 0:
          parts.add(source.substring(start, i));
          start = i + 1;
      }
    }
  }
  if (quoted || escaped || depth != 0) {
    throw const FormatException('Unterminated video filter argument');
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
  for (final arg in _splitFilters(source.replaceAll(r'\\:', r'\:'), ':')) {
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
      sampleAspect: 1 / frame.sampleAspect,
      alpha: frame.alpha?.orient(
        transpose: true,
        horizontal: direction.isOdd,
        vertical: direction >= 2,
      ),
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
      final fill = switch (component) {
        3 => (1 << plane.depth) - 1,
        _ when frame.rgb => 0,
        1 || 2 => 1 << (plane.depth - 1),
        _ => frame.fullRange ? 0 : 16 << (plane.depth - 8),
      };
      final samples = _paintSamples(plane.depth, width * height);
      for (var y = 0; y < height; y++) {
        final dy = y - middleY;
        var sx = middleX - middleX * _cos + dy * _sin;
        var sy = middleY + middleX * _sin + dy * _cos;
        for (var x = 0; x < width; x++, sx += _cos, sy -= _sin) {
          final destination = y * width + x;
          if (sx < -0.5 || sx > width - 0.5 || sy < -0.5 || sy > height - 0.5) {
            samples[destination] = fill;
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
          final a = plane.samples[at] * (1 - fx) + plane.samples[at + dx] * fx;
          final b =
              plane.samples[at + dy] * (1 - fx) +
              plane.samples[at + dy + dx] * fx;
          samples[destination] = (a * (1 - fy) + b * fy).round();
        }
      }
      return _FilterPlane(samples, width, height, plane.depth, rowStep: width);
    });
  }
}

final class _Scale extends _FrameSpatialFilter {
  factory _Scale(String? source) {
    final options = _filterOptions(
      source,
      ['w', 'h', 'flags', 'eval'],
      {'width': 'w', 'height': 'h'},
    );
    final nearest = switch (options['flags']) {
      null || 'bicubic' => false,
      'neighbor' => true,
      _ => throw const FormatException(
        'Supported scale flags are bicubic and neighbor',
      ),
    };
    final perFrame = switch (options['eval']) {
      null || 'init' || '0' => false,
      'frame' || '1' => true,
      _ => throw const FormatException('scale eval must be init or frame'),
    };
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
    return _Scale._(width, height, nearest, dynamicSize);
  }

  _Scale._(this.width, this.height, this.nearest, this.usesFramePosition);
  final FilterExpression width, height;
  final bool nearest;
  @override
  final bool usesFramePosition;
  final _scalers = <(int, int, int, int), _PlaneScaler>{};

  @override
  _VideoPlanes applyAt(_VideoPlanes frame, FilterFramePosition position) {
    final (w, h) = dimensions(frame, position);
    return frame.map(
      (plane, sx, sy) => _resize(plane, _subSize(w, sx), _subSize(h, sy)),
      sampleAspect: frame.sampleAspect * frame.width * h / (frame.height * w),
    );
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
    if (w < 0 && h < 0) {
      w = frame.width;
      h = frame.height;
    } else if (w < 0) {
      w = (h * frame.width / (frame.height * -w)).round() * -w;
    } else if (h < 0) {
      h = (w * frame.height / (frame.width * -h)).round() * -h;
    }
    _checkFilterSize(w, h);
    return (w, h);
  }

  _FilterPlane _resize(_FilterPlane source, int width, int height) {
    if (source.width == width && source.height == height) return source;
    if (nearest) {
      final samples = Int32List(width * height);
      final dx = _scaleStep(source.width, width);
      final dy = _scaleStep(source.height, height);
      var i = 0;
      for (var y = 0; y < height; y++) {
        final row = _nearestIndex(y, dy, source.height);
        for (var x = 0; x < width; x++) {
          final column = _nearestIndex(x, dx, source.width);
          samples[i++] =
              source.samples[source.offset +
                  row * source.rowStep +
                  column * source.columnStep];
        }
      }
      return _FilterPlane(samples, width, height, source.depth, rowStep: width);
    }
    if (width * source.height > 100000000) {
      throw const FormatException(
        'Video filter scaling exceeds 100 million intermediate samples',
      );
    }
    final plane = source.forward;
    final geometry = (plane.width, plane.height, width, height);
    if (_scalers.length >= 4 && !_scalers.containsKey(geometry)) {
      _scalers.clear();
    }
    final scaler = _scalers.putIfAbsent(
      geometry,
      () => _PlaneScaler(plane.width, plane.height, width, height),
    );
    final samples = scaler.resize(
      plane.samples,
      plane.rowStep,
      plane.offset,
      plane.depth,
      plane.depth - 8,
    );
    final limit = (1 << plane.depth) - 1;
    for (var i = 0; i < samples.length; i++) {
      samples[i] = samples[i].clamp(0, limit);
    }
    return _FilterPlane(samples, width, height, plane.depth, rowStep: width);
  }
}

int _subSize(int size, int shift) => (size + (1 << shift) - 1) >> shift;

final class _VideoPlanes {
  _VideoPlanes(
    this.planes,
    this.subX,
    this.subY, {
    required this.matrix,
    required this.fullRange,
    this.sampleAspect = 1,
    this.alpha,
  });
  final List<_FilterPlane> planes;
  final int subX, subY;
  final _FilterPlane? alpha;
  final int matrix;
  final bool fullRange;
  final double sampleAspect;

  int get width => planes.first.width;
  int get height => planes.first.height;
  bool get rgb => matrix == 0 && planes.length == 3;

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
    sampleAspect: sampleAspect ?? this.sampleAspect,
    alpha: alpha == null ? null : transform(alpha!, 0, 0, 3),
  );
}

/// A rectangular sample view. Crop, flips and transpose compose by changing
/// the origin and signed strides. Samples are copied only when needed by RGB
/// conversion or the separable resampler.
final class _FilterPlane {
  _FilterPlane(
    this.samples,
    this.width,
    this.height,
    this.depth, {
    required this.rowStep,
    this.columnStep = 1,
    this.offset = 0,
  });

  final List<int> samples;
  final int width, height, depth, rowStep, columnStep, offset;

  _FilterPlane window(int x, int y, int width, int height) => _FilterPlane(
    samples,
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
    return _FilterPlane(
      samples,
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
}
