part of 'yuv_image.dart';

typedef _FilterEntry = ({
  String specification,
  List<String> inputs,
  List<String> outputs,
  bool linked,
});

Iterable<_FilterEntry> _filterEntries(String source) sync* {
  var start = 0;
  var linked = false;
  String? specification;
  var inputs = <String>[], outputs = <String>[];
  final tokens = [
    ..._filterSyntax(source),
    (start: source.length, end: source.length, kind: ';'),
  ];
  for (final token in tokens) {
    if (token.kind == ':') continue;
    final text = source.substring(start, token.start).trim();
    if (text.isNotEmpty) {
      if (specification != null) {
        throw const FormatException(
          'Unexpected text after filter output label',
        );
      }
      specification = text;
    }
    if (token.kind == '[') {
      final label = source.substring(token.start + 1, token.end - 1).trim();
      if (label.isEmpty)
        throw const FormatException('Empty video filter label');
      (specification == null ? inputs : outputs).add(label);
    } else {
      if (specification == null)
        throw const FormatException('Missing video filter');
      yield (
        specification: specification,
        inputs: inputs,
        outputs: outputs,
        linked: linked,
      );
      linked = token.kind == ',';
      specification = null;
      inputs = [];
      outputs = [];
    }
    start = token.end;
  }
}

Object? _graphFilter(String specification) {
  final equal = specification.indexOf('=');
  final name = (equal < 0 ? specification : specification.substring(0, equal))
      .trim()
      .split('@')
      .first;
  final args = equal < 0 ? null : specification.substring(equal + 1);
  if ((name == 'null' || name == 'hflip' || name == 'vflip') && args != null) {
    throw FormatException('$name takes no options');
  }
  return switch (name) {
    'null' => null,
    'hflip' => _Flip.horizontal,
    'vflip' => _Flip.vertical,
    'crop' => _Crop(args),
    'transpose' => _Transpose(args),
    'scale' => _Scale(args),
    'pad' => _Pad(args),
    'drawbox' => _DrawBox(args),
    'negate' => _Negate(args),
    'setsar' || 'setdar' => _SetAspect(args, display: name == 'setdar'),
    'trim' => _Trim(args),
    'setpts' => _SetPts(args),
    'settb' => _SetTimeBase(args),
    'fps' => _Fps(args),
    'split' => _Split(args),
    'hstack' || 'vstack' || 'xstack' => _Stack(args, name),
    'overlay' => _Overlay(args),
    _ => throw FormatException('Unsupported video filter: $name'),
  };
}

typedef _FilterStep = ({Object? filter, List<int> inputs, List<int> outputs});

List<_FilterStep> _orderedFilterSteps(String source) {
  final labels = <String, int>{};
  final entries =
      <({Object? filter, List<Object> inputs, List<int> outputs})>[];
  var nextLink = 1;
  var pending = const <int>[];
  for (final entry in _filterEntries(source)) {
    final filter = _graphFilter(entry.specification);
    final inputCount = switch (filter) {
      final _Stack stack => stack.inputs,
      _Overlay() => 2,
      _ => 1,
    };
    final outputCount = filter is _Split ? filter.outputs : 1;
    if (entry.inputs.length > inputCount ||
        entry.outputs.length > outputCount) {
      throw const FormatException('Too many labels for video filter pads');
    }
    if (!entry.linked) pending = const [];
    final outputs = List.generate(outputCount, (_) => nextLink++);
    final inputs = <Object>[
      ...entry.inputs,
      for (var i = 0; i < inputCount - entry.inputs.length; i++)
        i < pending.length ? pending[i] : 0,
    ];
    for (final (index, label) in entry.outputs.indexed) {
      if (labels.containsKey(label)) {
        throw FormatException('Duplicate video filter output label: $label');
      }
      labels[label] = outputs[index];
    }
    pending = outputs.sublist(entry.outputs.length);
    entries.add((filter: filter, inputs: inputs, outputs: outputs));
  }

  final producers = <int, _FilterStep>{};
  final consumed = <int>{};
  for (final entry in entries) {
    final inputs = <int>[];
    for (final reference in entry.inputs) {
      // Exactly one unlinked input, labeled or unlabelled, takes the video.
      final link = reference is int ? reference : labels[reference] ?? 0;
      if (!consumed.add(link)) {
        throw const FormatException(
          'Video filter pads can be connected only once',
        );
      }
      inputs.add(link);
    }
    final step = (filter: entry.filter, inputs: inputs, outputs: entry.outputs);
    for (final link in entry.outputs) {
      producers[link] = step;
    }
  }
  final outputs = producers.keys
      .where((link) => !consumed.contains(link))
      .toList();
  if (!consumed.contains(0) || outputs.length != 1) {
    throw const FormatException(
      'Video filter graph requires one input and one output',
    );
  }

  final sorted = <_FilterStep>[];
  final active = <_FilterStep>{}, finished = <_FilterStep>{};
  void visit(int link) {
    if (link == 0) return;
    final step = producers[link]!;
    if (finished.contains(step)) return;
    if (!active.add(step))
      throw const FormatException('Cyclic video filter graph');
    for (final input in step.inputs) {
      visit(input);
    }
    active.remove(step);
    finished.add(step);
    sorted.add(step);
  }

  visit(outputs.single);
  if (sorted.length != entries.length) {
    throw const FormatException('Disconnected video filter graph');
  }
  return sorted;
}

VideoFilterChain _compileFilterGraph(String source) {
  final spatial = <_SpatialFilter>[];
  final timing = <_TimingFilter>[];
  void addSpatial(_SpatialFilter filter) {
    spatial.add(filter);
    if (filter is _FrameSpatialFilter && filter.usesFramePosition) {
      timing.add(const _RecordFramePosition());
    }
  }

  // A split and its eventual joins share one frame position. Where only
  // one link remains, ordinary timing filters can still retime that stream.
  var live = 1;
  var region = <_FilterStep>[];
  final steps = _orderedFilterSteps(source);
  for (final step in steps) {
    final filter = step.filter;
    final next = live + step.outputs.length - step.inputs.length;
    if (live == 1 && next == 1) {
      switch (filter) {
        case final _TimingFilter filter:
          timing.add(filter);
        case final _SpatialFilter filter:
          addSpatial(filter);
      }
    } else {
      if (filter is _TimingFilter) {
        return VideoFilterChain._(
          source,
          const [],
          const [],
          _SynchronizedFilterGraph(steps),
        );
      }
      region.add(step);
      if (next == 1) {
        addSpatial(_FilterBranches(region));
        region = [];
      }
    }
    live = next;
  }
  return VideoFilterChain._(source, spatial, timing);
}

final class _FilterBranches extends _FrameSpatialFilter {
  _FilterBranches(this.steps);
  final List<_FilterStep> steps;

  @override
  late final bool usesFramePosition = steps.any((step) {
    return switch (step.filter) {
      final _Overlay filter => filter.usesFramePosition,
      final _FrameSpatialFilter filter => filter.usesFramePosition,
      _ => false,
    };
  });

  @override
  _VideoPlanes applyAt(_VideoPlanes frame, FilterFramePosition position) {
    final active = {steps.first.inputs.single: frame};
    for (final step in steps) {
      final inputs = [for (final link in step.inputs) active.remove(link)!];
      final result = _applyFilterStep(step.filter, inputs, position);
      for (final link in step.outputs) {
        active[link] = result;
      }
    }
    return active.values.single;
  }
}

_VideoPlanes _applyFilterStep(
  Object? filter,
  List<_VideoPlanes> inputs,
  FilterFramePosition position,
) => switch (filter) {
  final _Stack stack => stack.apply(inputs),
  final _Overlay filter => filter.apply(inputs[0], inputs[1], position),
  final _FrameSpatialFilter filter => filter.applyAt(inputs.single, position),
  final _SpatialFilter filter => filter.apply(inputs.single),
  _ => inputs.single,
};

int _filterPadCount(Map<String, String> options, String key, int minimum) {
  final count = _filterInteger(options, key, minimum: minimum) ?? 2;
  if (count > 2048) throw FormatException('Too many video filter $key');
  return count;
}

final class _Split {
  _Split(String? args)
    : outputs = _filterPadCount(
        _filterOptions(args, ['outputs']),
        'outputs',
        1,
      );

  final int outputs;
}

typedef _StackPosition = ({int left, int top});
typedef _StackCoordinate = int Function(List<_VideoPlanes>);

final class _Stack {
  factory _Stack(String? args, String name) {
    final options = _filterOptions(args, [
      'inputs',
      if (name == 'xstack') ...['layout', 'grid'],
      'shortest',
      if (name == 'xstack') 'fill',
    ]);
    final shortest = _filterFlag(options['shortest'], 'shortest');
    var inputs = _filterPadCount(options, 'inputs', 2);
    final fill = options['fill'];
    final color = fill == null || fill == 'none'
        ? null
        : _PaintColor.parse(fill);
    final grid = options['grid'], layout = options['layout'];
    if (layout != null) {
      if (grid != null)
        throw const FormatException('xstack accepts either grid or layout');
      final positions = layout.split('|');
      if (positions.length != inputs) {
        throw const FormatException('xstack layout must place every input');
      }
      final coordinates = [
        for (final (i, position) in positions.indexed)
          _stackCoordinates(position, i, inputs),
      ];
      return _Stack._(
        inputs,
        shortest,
        color,
        (frames) => [
          for (final (left, top) in coordinates)
            (left: left(frames), top: top(frames)),
        ],
      );
    }
    var columns = name == 'vstack' ? 1 : inputs;
    if (grid != null) {
      final match = RegExp(r'^([1-9][0-9]*)x([1-9][0-9]*)$').firstMatch(grid);
      final cols = int.tryParse(match?.group(1) ?? '');
      final rows = int.tryParse(match?.group(2) ?? '');
      if (cols == null ||
          rows == null ||
          cols > 2048 ||
          rows > 2048 ||
          cols * rows > 2048) {
        throw const FormatException('Invalid xstack grid dimensions');
      }
      columns = cols;
      inputs = cols * rows;
    } else if (name == 'xstack' && inputs != 2) {
      throw const FormatException(
        'xstack requires a layout or grid for more than two inputs',
      );
    }
    return _Stack._(
      inputs,
      shortest,
      color,
      (frames) => _stackGrid(frames, columns),
    );
  }

  const _Stack._(this.inputs, this.shortest, this.fill, this.positions);
  final bool shortest;
  final int inputs;
  final _PaintColor? fill;
  final List<_StackPosition> Function(List<_VideoPlanes>) positions;

  _VideoPlanes apply(List<_VideoPlanes> frames) {
    final first = frames.first;
    for (final frame in frames.skip(1)) {
      if (frame.subX != first.subX ||
          frame.subY != first.subY ||
          frame.planes.length != first.planes.length ||
          (frame.alpha == null) != (first.alpha == null) ||
          frame.packedRgb != first.packedRgb ||
          frame.rgb != first.rgb) {
        throw const FormatException(
          'Stacked inputs must have the same pixel format',
        );
      }
    }
    final offsets = positions(frames);
    var width = 0, height = 0;
    for (final (i, frame) in frames.indexed) {
      width = math.max(width, offsets[i].left + frame.width);
      height = math.max(height, offsets[i].top + frame.height);
    }
    _checkFilterSize(width, height);
    return first.mapComponents((plane, sx, sy, index) {
      final w = _subSize(width, sx), h = _subSize(height, sy);
      final result = _paintSamples(plane.depth, w * h);
      if (fill case final color?) {
        result.fillRange(
          0,
          result.length,
          color.sample(first, index, plane.depth),
        );
      }
      for (final (i, frame) in frames.indexed) {
        final input = index == 3 ? frame.alpha! : frame.planes[index];
        if (input.depth != plane.depth) {
          throw const FormatException(
            'Stacked inputs must have the same pixel depth',
          );
        }
        final left = _subSize(offsets[i].left, sx);
        final top = _subSize(offsets[i].top, sy);
        _pastePlane(input, result, w, h, left, top);
      }
      return _FilterPlane(result, w, h, plane.depth, rowStep: w);
    });
  }
}

void _pastePlane(
  _FilterPlane source,
  List<int> target,
  int width,
  int height,
  int left,
  int top,
) {
  final firstX = math.max(0, -left);
  final endX = math.min(source.width, width - left);
  if (firstX >= endX) return;
  final endY = math.min(source.height, height - top);
  for (var y = math.max(0, -top); y < endY; y++) {
    final start = (top + y) * width + left;
    if (source.columnStep == 1) {
      target.setRange(
        start + firstX,
        start + endX,
        source.samples,
        source.offset + y * source.rowStep + firstX,
      );
    } else {
      for (var x = firstX; x < endX; x++) {
        target[start + x] = source.at(x, y);
      }
    }
  }
}

List<_StackPosition> _stackGrid(List<_VideoPlanes> frames, int columns) {
  final positions = <_StackPosition>[];
  int? rowWidth;
  var top = 0;
  for (var start = 0; start < frames.length; start += columns) {
    final height = frames[start].height;
    var left = 0;
    for (var i = start; i < start + columns; i++) {
      final frame = frames[i];
      if (frame.height != height) {
        throw const FormatException(
          'Stacked inputs in a row must have equal heights',
        );
      }
      positions.add((left: left, top: top));
      left += frame.width;
    }
    rowWidth ??= left;
    if (left != rowWidth) {
      throw const FormatException('Stacked rows must have equal widths');
    }
    top += height;
  }
  return positions;
}

(_StackCoordinate, _StackCoordinate) _stackCoordinates(
  String position,
  int input,
  int count,
) {
  final axes = position.split('_');
  if (axes.length != 2)
    throw FormatException('Invalid xstack position: $position');
  _StackCoordinate coordinate(String expression) {
    var offset = 0;
    final dimensions = <({int input, bool vertical})>[];
    for (final term in expression.split('+')) {
      final match = RegExp(r'^([wh]?)([0-9]+)$').firstMatch(term);
      final value = int.tryParse(match?.group(2) ?? '');
      if (value == null) throw FormatException('Invalid xstack offset: $term');
      final dimension = match!.group(1)!;
      if (dimension.isEmpty) {
        if (value > 32768)
          throw FormatException('xstack offset out of range: $term');
        offset += value;
      } else {
        if (value >= count || value == input) {
          throw FormatException('Invalid xstack input reference: $term');
        }
        dimensions.add((input: value, vertical: dimension == 'h'));
      }
    }
    return (frames) {
      var sum = offset;
      for (final dimension in dimensions) {
        final frame = frames[dimension.input];
        sum += dimension.vertical ? frame.height : frame.width;
      }
      return sum;
    };
  }

  return (coordinate(axes[0]), coordinate(axes[1]));
}
