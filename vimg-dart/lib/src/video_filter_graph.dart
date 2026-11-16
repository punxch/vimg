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
    'hstack' || 'vstack' => _Stack(args, vertical: name == 'vstack'),
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
    final inputCount = filter is _Stack ? filter.inputs : 1;
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
  for (final step in _orderedFilterSteps(source)) {
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
        throw const FormatException(
          'Timing filters require a shared video filter stream',
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
    final filter = step.filter;
    return filter is _FrameSpatialFilter && filter.usesFramePosition;
  });

  @override
  _VideoPlanes applyAt(_VideoPlanes frame, FilterFramePosition position) {
    final active = {steps.first.inputs.single: frame};
    for (final step in steps) {
      final inputs = [for (final link in step.inputs) active.remove(link)!];
      final result = switch (step.filter) {
        final _Stack stack => stack.apply(inputs),
        final _FrameSpatialFilter filter => filter.applyAt(
          inputs.single,
          position,
        ),
        final _SpatialFilter filter => filter.apply(inputs.single),
        _ => inputs.single,
      };
      for (final link in step.outputs) {
        active[link] = result;
      }
    }
    return active.values.single;
  }
}

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

final class _Stack {
  factory _Stack(String? args, {required bool vertical}) {
    final options = _filterOptions(args, ['inputs', 'shortest']);
    // Both branches have the same timeline, including the same end event.
    _filterFlag(options['shortest'], 'shortest');
    return _Stack._(_filterPadCount(options, 'inputs', 2), vertical);
  }

  const _Stack._(this.inputs, this.vertical);
  final int inputs;
  final bool vertical;

  _VideoPlanes apply(List<_VideoPlanes> frames) {
    final first = frames.first;
    final offsets = <int>[];
    var length = 0;
    for (final frame in frames) {
      if ((vertical && frame.width != first.width) ||
          (!vertical && frame.height != first.height)) {
        throw FormatException(
          vertical
              ? 'vstack inputs must have equal widths'
              : 'hstack inputs must have equal heights',
        );
      }
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
      offsets.add(length);
      length += vertical ? frame.height : frame.width;
    }
    final width = vertical ? first.width : length;
    final height = vertical ? length : first.height;
    _checkFilterSize(width, height);
    return first.mapComponents((plane, sx, sy, index) {
      final w = _subSize(width, sx), h = _subSize(height, sy);
      final result = plane.depth <= 8 ? Uint8List(w * h) : Uint16List(w * h);
      for (final (i, frame) in frames.indexed) {
        final input = index == 3 ? frame.alpha! : frame.planes[index];
        if (input.depth != plane.depth) {
          throw const FormatException(
            'Stacked inputs must have the same pixel depth',
          );
        }
        final left = vertical ? 0 : _subSize(offsets[i], sx);
        final top = vertical ? _subSize(offsets[i], sy) : 0;
        final copyWidth = math.min(input.width, w - left);
        final copyHeight = math.min(input.height, h - top);
        for (var row = 0; row < copyHeight; row++) {
          final destination = (top + row) * w + left;
          if (input.columnStep == 1) {
            result.setRange(
              destination,
              destination + copyWidth,
              input.samples,
              input.offset + row * input.rowStep,
            );
          } else {
            for (var x = 0; x < copyWidth; x++) {
              result[destination + x] = input.at(x, row);
            }
          }
        }
      }
      return _FilterPlane(result, w, h, plane.depth, rowStep: w);
    });
  }
}
