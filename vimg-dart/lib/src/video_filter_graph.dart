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
  if (const {'null', 'hflip', 'vflip', 'alphaextract'}.contains(name) &&
      args != null) {
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
    'format' => _FormatFilter(args),
    'setsar' || 'setdar' => _SetAspect(args, display: name == 'setdar'),
    'trim' => _Trim(args),
    'setpts' => _SetPts(args),
    'settb' => _SetTimeBase(args),
    'fps' => _Fps(args),
    'split' => _Split(args),
    'hstack' || 'vstack' || 'xstack' => _Stack(args, name),
    'overlay' => _Overlay(args),
    'alphaextract' => const _ExtractAlpha(),
    'alphamerge' => _MergeAlpha(args),
    'premultiply' ||
    'unpremultiply' ||
    'premultiply_dynamic' => _VideoAlphaFilter(name, args),
    _ => throw FormatException('Unsupported video filter: $name'),
  };
}

typedef _FilterStep = ({Object? filter, List<int> inputs, List<int> outputs});

List<_FilterStep> _orderedFilterSteps(
  String source, {
  required bool bitmapOutput,
}) {
  final labels = <String, int>{};
  final entries =
      <({Object? filter, List<Object> inputs, List<int> outputs})>[];
  var nextLink = 1;
  var pending = const <int>[];
  for (final entry in _filterEntries(source)) {
    final filter = _graphFilter(entry.specification);
    final inputCount = switch (filter) {
      final _Stack stack => stack.inputs,
      _Overlay() || _MergeAlpha() => 2,
      final _VideoAlphaFilter alpha => alpha.inputs,
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
  return _negotiateFilterFormats(sorted, bitmapOutput: bitmapOutput);
}

List<_FilterStep> _negotiateFilterFormats(
  List<_FilterStep> steps, {
  required bool bitmapOutput,
}) {
  final regions = <int, _FormatRegion>{0: _FormatRegion(fixed: true)};
  final scaleInputs = <_FormatRegion, _FormatRegion>{};
  final transposedInputs = <_FormatRegion, _FormatRegion>{};
  for (final step in steps) {
    final filter = step.filter;
    final region = switch (filter) {
      final _FormatFilter format when !format.unrestricted => _FormatRegion(
        constraints: format,
        explicitFormat: true,
        acceptsAlphaMode: true,
      ),
      final _Scale scale => _FormatRegion(constraints: scale.outputColors),
      final _VideoAlphaFilter alpha => _FormatRegion(
        constraints: alpha.format,
        explicitFormat: true,
        acceptsAlphaMode: alpha.mode == null,
      ),
      _MergeAlpha() => _FormatRegion(
        constraints: _MergeAlpha.mainFormat,
        explicitFormat: true,
        alphaLayoutOutput: true,
      ),
      final _Overlay overlay => _FormatRegion(
        constraints: overlay.mainFormat,
        explicitFormat: true,
        alphaLayoutOutput: true,
      ),
      _Stack() || _ExtractAlpha() => _FormatRegion(),
      null ||
      _TimingFilter() ||
      _SetAspect() ||
      _Flip() ||
      _Crop() ||
      _Split() ||
      _FormatFilter() => regions[step.inputs.single]!,
      _ => _FormatRegion(fixed: true),
    };
    if (filter is _Scale) scaleInputs[region] = regions[step.inputs.single]!;
    if (filter is _Transpose) {
      transposedInputs[region] = regions[step.inputs.single]!;
    }
    for (final output in step.outputs) {
      regions[output] = region;
    }
  }

  // Competing constraints are encountered in graph declaration order.
  // Frame evaluation still follows the dependency order in steps.
  final order = [...steps]
    ..sort((a, b) => a.outputs.first.compareTo(b.outputs.first));
  final absorbed = <int>{};
  for (final step in order) {
    final output = regions[step.outputs.first]!;
    switch (step.filter) {
      case final _FormatFilter format:
        final input = regions[step.inputs.single]!;
        if (format.unrestricted) {
          absorbed.add(step.outputs.first);
        } else if (input.merge(output)) {
          // A decoded alpha input can still determine the layout at runtime.
          if (!input.alphaLayoutOutput && format.alphaModes.isEmpty) {
            absorbed.add(step.outputs.first);
          }
        } else {
          output.root.inheritColor(input.root.constraints);
        }
      case _Stack():
        for (final input in step.inputs) {
          output.merge(regions[input]!);
        }
      case _VideoAlphaFilter():
        for (final input in step.inputs) {
          if (regions[input]!.root.constraints case final constraint?) {
            output.restrict(constraint.withoutAlphaModes());
          }
        }
      case _MergeAlpha():
        output.restrict(
          regions[step.inputs.first]!.root.constraints?.withoutAlphaModes() ??
              _MergeAlpha.mainFormat,
        );
        regions[step.inputs[1]]!.restrict(_MergeAlpha.maskFormat);
      case final _Overlay overlay:
        final main = regions[step.inputs.first]!;
        final secondary = regions[step.inputs[1]]!;
        final sharedInput = identical(main.root, secondary.root);
        output.merge(main);
        if (overlay.format == null) {
          final decoded = regions[0]!.root;
          if (identical(main.root, decoded) ||
              identical(secondary.root, decoded)) {
            output.root.hasDecodedOverlayInput = true;
          }
          final secondaryConstraints = secondary.root.constraints;
          final separateAlpha =
              !sharedInput &&
              (overlay.alphaMode != null ||
                  (secondaryConstraints?.alphaModes.isNotEmpty ?? false));
          if (separateAlpha) {
            if (secondaryConstraints != null) {
              output.restrict(secondaryConstraints.withoutAlphaModes());
            }
          } else {
            output.merge(secondary);
          }
        }
        secondary.restrict(overlay.secondaryFormat);
    }
  }

  final mergeAlphaInputs = <_FormatRegion, _FormatRegion>{};
  for (final step in steps.reversed) {
    final filter = step.filter;
    if (filter is _VideoAlphaFilter || filter is _MergeAlpha) {
      final output = regions[step.outputs.single]!.root;
      final layout = output.constraints!.withoutAlphaModes();
      if (filter is _MergeAlpha) {
        final main = regions[step.inputs.first]!.root;
        if (main.restrict(layout)) mergeAlphaInputs[output] = main;
      } else {
        for (final input in step.inputs) {
          regions[input]!.restrict(layout);
        }
      }
    }
  }

  for (final step in order) {
    final filter = step.filter;
    if (filter is! _VideoAlphaFilter || !filter.inplace) continue;
    final mode = filter.mode;
    if (mode == null) continue;
    final inputMode = !mode;
    var source = regions[step.inputs.single]!.root;
    while (true) {
      final input = scaleInputs[source];
      if (input == null) break;
      final format = source.constraints;
      if (format != null &&
          (format.formats.isNotEmpty && !format.formats.any((f) => f.alpha) ||
              format.alphaModes.length == 1 &&
                  format.alphaModes.single != inputMode)) {
        break;
      }
      final upstream = input.root;
      if (identical(source, upstream)) break;
      source = upstream;
    }
    if (source.acceptsAlphaMode) {
      // An implicit association can run on the source side of the existing
      // pixel converter. A producer with an incompatible mode keeps its mode.
      source.restrict(
        _FormatFilter._(const [], const [], const [], [inputMode]),
      );
    }
  }

  // A bitmap encoder accepts packed alpha. Transpose and alpha merge
  // preserve their main input layout. A scale owns its output layout.
  var bitmapRegion = bitmapOutput
      ? regions[steps.last.outputs.single]!.root
      : null;
  final bitmapRegions = <_FormatRegion>{};
  final bitmapAlphaInputs = <_FormatRegion>{};
  while (true) {
    if (bitmapRegion == null || !bitmapRegions.add(bitmapRegion)) break;
    final main = mergeAlphaInputs[bitmapRegion]?.root;
    if (main != null) bitmapAlphaInputs.add(main);
    bitmapRegion = main ?? transposedInputs[bitmapRegion]?.root;
  }
  return [
    for (final step in steps)
      (
        filter: _negotiatedFilter(
          step.filter,
          regions[step.outputs.first]!.root,
          absorbed: absorbed.contains(step.outputs.first),
          bitmapTerminal: bitmapRegions.contains(
            regions[step.outputs.first]!.root,
          ),
          bitmapAlphaInput: bitmapAlphaInputs.contains(
            regions[step.outputs.first]!.root,
          ),
        ),
        inputs: step.inputs,
        outputs: step.outputs,
      ),
  ];
}

Object? _negotiatedFilter(
  Object? filter,
  _FormatRegion region, {
  required bool absorbed,
  required bool bitmapTerminal,
  required bool bitmapAlphaInput,
}) {
  if (absorbed) return null;
  final format = region.constraints;
  return switch (filter) {
    final _Scale scale when region.explicitFormat && format != null =>
      _ScaleFormat(
        scale,
        format,
        preferred:
            bitmapTerminal &&
                (region.alphaLayoutOutput || bitmapAlphaInput) &&
                format.formats.every((candidate) => candidate.alpha)
            ? format.packedAlphaFormat
            : null,
        keepCompatibleInput: region.hasDecodedOverlayInput,
      ),
    final _Stack stack when format != null => stack.withFormat(format),
    final _Overlay overlay when format != null => overlay.withFormat(
      format,
      bitmapTerminal: bitmapTerminal,
    ),
    final _MergeAlpha merge when format != null => merge.withFormat(
      format,
      bitmapTerminal: bitmapTerminal,
    ),
    _ExtractAlpha() when format != null => _ExtractAlpha(format),
    final _VideoAlphaFilter alpha when format != null => alpha.withFormat(
      format,
    ),
    final _FormatFilter original
        when original.onlyAlphaMode && format?.formats.isNotEmpty != true =>
      original.atAlphaStage(false),
    final _FormatFilter original => format?.atAlphaStage(
      original.alphaModes.isEmpty,
      layoutBeforeAlpha:
          original.alphaModes.isNotEmpty && format.formats.isNotEmpty,
    ),
    _ => filter,
  };
}

/// Links that can use the same pixel layout and YUV color properties.
final class _FormatRegion {
  _FormatRegion({
    this.constraints,
    this.fixed = false,
    this.explicitFormat = false,
    this.alphaLayoutOutput = false,
    this.acceptsAlphaMode = false,
  });

  _FormatRegion? _parent;
  _FormatFilter? constraints;
  bool fixed, explicitFormat;
  bool hasDecodedOverlayInput = false;
  final bool alphaLayoutOutput, acceptsAlphaMode;

  _FormatRegion get root {
    final parent = _parent;
    if (parent == null) return this;
    return _parent = parent.root;
  }

  bool merge(_FormatRegion other) {
    final first = root, second = other.root;
    if (identical(first, second)) return true;
    final a = first.constraints, b = second.constraints;
    final common = a == null
        ? b
        : b == null
        ? a
        : a.intersect(b);
    if ((first.fixed || second.fixed) && common != null ||
        a != null && b != null && common == null) {
      return false;
    }
    second._parent = first;
    first.constraints = common;
    first.fixed |= second.fixed;
    first.explicitFormat |= second.explicitFormat;
    first.hasDecodedOverlayInput |= second.hasDecodedOverlayInput;
    return true;
  }

  bool restrict(_FormatFilter format) =>
      format.unrestricted ||
      merge(_FormatRegion(constraints: format, explicitFormat: true));

  void inheritColor(_FormatFilter? source) {
    final format = constraints;
    if (source == null || format == null) return;
    constraints = _FormatFilter._(
      format.formats,
      format.matrices.isEmpty ? source.matrices : format.matrices,
      format.ranges.isEmpty ? source.ranges : format.ranges,
      format.alphaModes,
    );
  }
}

VideoFilterChain _compileFilterGraph(
  String source, {
  required bool bitmapOutput,
}) {
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
  final steps = _orderedFilterSteps(source, bitmapOutput: bitmapOutput);
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
          bitmapOutput: bitmapOutput,
          graph: _SynchronizedFilterGraph(steps),
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
  return VideoFilterChain._(
    source,
    spatial,
    timing,
    bitmapOutput: bitmapOutput,
  );
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
  final _Overlay filter => filter.apply(
    inputs[0],
    inputs.elementAtOrNull(1),
    position,
  ),
  final _MergeAlpha filter => filter.apply(
    inputs[0],
    inputs.elementAtOrNull(1),
  ),
  final _VideoAlphaFilter filter when !filter.inplace => filter.applyMask(
    inputs[0],
    inputs[1],
  ),
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

  _Stack._(
    this.inputs,
    this.shortest,
    this.fill,
    this.positions, [
    this.format,
  ]);
  final bool shortest;
  final int inputs;
  final _PaintColor? fill;
  final List<_StackPosition> Function(List<_VideoPlanes>) positions;
  final _FormatFilter? format;
  late final _converter = _PixelFormatConverter();

  _Stack withFormat(_FormatFilter format) =>
      _Stack._(inputs, shortest, fill, positions, format);

  _VideoPlanes apply(List<_VideoPlanes> inputs) {
    final first = format?.apply(inputs.first) ?? inputs.first;
    final layout = _frameFormat(first);
    final frames = [
      first,
      for (final frame in inputs.skip(1))
        _converter.convert(
          frame,
          layout,
          matrix: first.matrix,
          fullRange: first.fullRange,
          alpha: first.alpha != null,
          alphaDepth: first.alpha?.depth,
          premultiplied: first.premultiplied,
        ),
    ];
    final offsets = positions(frames);
    var width = 0, height = 0;
    for (final (i, frame) in frames.indexed) {
      width = math.max(width, offsets[i].left + frame.width);
      height = math.max(height, offsets[i].top + frame.height);
    }
    _checkFilterSize(width, height);
    return first.mapComponents((plane, sx, sy, index) {
      final w = _subSize(width, sx), h = _subSize(height, sy);
      final result = plane.emptySamples(w * h);
      if (fill case final color?) {
        result.fillRange(
          0,
          result.length,
          color.sampleFor(first, index, plane),
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
      return plane.withSamples(result, w, h);
    });
  }
}

void _pastePlane(
  _FilterPlane source,
  List<num> target,
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
        source.values,
        source.offset + y * source.rowStep + firstX,
      );
    } else {
      for (var x = firstX; x < endX; x++) {
        target[start + x] = source
            .values[source.offset + y * source.rowStep + x * source.columnStep];
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
