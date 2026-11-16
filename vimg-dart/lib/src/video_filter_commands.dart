part of 'yuv_image.dart';

const _commandEnter = 1, _commandLeave = 2, _commandExpr = 4;
const _commandVariables = {'N', 'T', 'PTS', 'TS', 'TE', 'TI', 'W', 'H'};

typedef _CommandInterval = ({
  int start,
  int end,
  int order,
  List<_ScriptCommand> commands,
});

final class _SendCmd {
  factory _SendCmd(String? args, Map<String, String> files) {
    final options = _filterOptions(
      args,
      ['commands', 'filename'],
      {'c': 'commands', 'f': 'filename'},
    );
    final inline = options['commands'], path = options['filename'];
    if ((inline == null) == (path == null)) {
      throw const FormatException(
        'sendcmd requires either commands or filename',
      );
    }
    // Inline text passes through the graph and option quoting layers.
    final source = inline == null
        ? files.putIfAbsent(path!, () => File(path).readAsStringSync())
        : _filterValue(inline);
    final reader = _CommandReader(source);
    final intervals = <_CommandInterval>[];
    while (reader.hasInterval) {
      final time = reader.word().split('-');
      if (time.length > 2 || time.any((value) => value.isEmpty)) reader.fail();
      final start = _filterDuration(time.first)!;
      final end = time.length == 1
          ? 0x7fffffffffffffff
          : _filterDuration(time.last)!;
      if (end < start) reader.fail();
      final commands = <_ScriptCommand>[];
      do {
        commands.add(_ScriptCommand.read(reader));
      } while (reader.take(','));
      if (!reader.atEnd && !reader.take(';')) reader.fail();
      intervals.add((
        start: start,
        end: end,
        order: intervals.length,
        commands: commands,
      ));
    }
    if (intervals.isEmpty) reader.fail();
    intervals.sort((a, b) {
      final result = a.start.compareTo(b.start);
      return result == 0 ? a.order.compareTo(b.order) : result;
    });
    return _SendCmd._(intervals);
  }

  const _SendCmd._(this.intervals);

  final List<_CommandInterval> intervals;

  CaptureTimeline apply(CaptureTimeline input, _FilterCommandState state) =>
      CaptureTimeline(_events(input, state), input.timeBase, input.frameRate);

  Iterable<CaptureTimelineEvent> _events(
    CaptureTimeline input,
    _FilterCommandState state,
  ) sync* {
    final previous = List.filled(intervals.length, false);
    var frameCount = 0;
    for (final event in input.events) {
      if (event is! CaptureTimedFrame) {
        yield event;
        continue;
      }
      frameCount++;
      final tick = rescaleCaptureTicks(
        event.pts,
        input.timeBase,
        captureMicroseconds,
      );
      final picture = _pictureOf(event);
      for (final (i, interval) in intervals.indexed) {
        final inside = tick >= interval.start && tick < interval.end;
        var flags = inside ? _commandExpr : 0;
        if (inside != previous[i])
          flags |= inside ? _commandEnter : _commandLeave;
        previous[i] = inside;
        if (flags == 0) continue;
        for (final command in interval.commands) {
          if ((command.flags & flags) == 0) continue;
          state.send(
            command,
            interval,
            picture,
            frameCount,
            event.pts,
            input.timeBase,
          );
        }
      }
      yield event.withPicture(picture);
    }
  }
}

final class _ScriptCommand {
  factory _ScriptCommand.read(_CommandReader reader) {
    final flags = reader.flags();
    final target = reader.word();
    final name = reader.word();
    final argument = reader.word();
    if (target.isEmpty || name.isEmpty) reader.fail();
    final option = switch (name) {
      'enable' => _FilterCommandOption.enable,
      'x' => _FilterCommandOption.x,
      'y' => _FilterCommandOption.y,
      _ => throw FormatException('Unsupported sendcmd command: $name'),
    };

    if ((flags & _commandExpr) != 0) {
      var usesSize = false;
      final expression = parseFilterExpression(
        argument,
        _commandVariables,
        onVariable: (name) => usesSize |= name == 'W' || name == 'H',
      );
      return _ScriptCommand._(
        target,
        option,
        flags,
        expression,
        usesSize: usesSize,
      );
    }
    FilterExpression? expression;
    var usesPreviousPosition = false;
    try {
      expression = option == _FilterCommandOption.enable
          ? _FilterEnable.parse(argument).expression
          : _parseOverlayCoordinate(
              argument,
              onVariable: (name) =>
                  usesPreviousPosition |= name == 'x' || name == 'y',
            );
    } on FormatException {
      // A rejected runtime expression leaves the previous one active.
    }
    return _ScriptCommand._(
      target,
      option,
      flags,
      expression,
      usesPreviousPosition: usesPreviousPosition,
    );
  }

  const _ScriptCommand._(
    this.target,
    this.option,
    this.flags,
    this.expression, {
    this.usesSize = false,
    this.usesPreviousPosition = false,
  });

  final String target;
  final _FilterCommandOption option;
  final int flags;
  final FilterExpression? expression;
  final bool usesSize;
  final bool usesPreviousPosition;
}

enum _FilterCommandOption { enable, x, y }

final class _FilterCommandState {
  _FilterCommandState(this.steps) {
    // FFmpeg dispatches to the first matching filter in declaration order.
    final order = List.generate(
      steps.length,
      (i) => i,
    )..sort((a, b) => steps[a].outputs.first.compareTo(steps[b].outputs.first));
    if (steps[order.first].commandTarget != null)
      _enableTargets['all'] = order.first;
    final firstPositionTarget = order
        .where(
          (i) => switch (steps[i].filter) {
            _Overlay() || _Crop() || _DrawBox() => true,
            _ => false,
          },
        )
        .firstOrNull;
    if (firstPositionTarget != null &&
        steps[firstPositionTarget].filter is _Overlay) {
      _overlayTargets['all'] = firstPositionTarget;
    }
    for (final i in order) {
      final target = steps[i].commandTarget;
      if (target == null) continue;
      _enableTargets.putIfAbsent(target.name, () => i);
      _enableTargets.putIfAbsent(target.instance, () => i);
      if (steps[i].filter is _Overlay) {
        _overlayTargets.putIfAbsent(target.name, () => i);
        _overlayTargets.putIfAbsent(target.instance, () => i);
      }
    }
    for (final (index, step) in steps.indexed) {
      switch (step.filter) {
        case _Overlay(usesPreviousPosition: true):
          _positionReferences.add(index);
        case final _SendCmd sender:
          for (final interval in sender.intervals) {
            for (final command in interval.commands) {
              if (!command.usesPreviousPosition) continue;
              final target = _overlayTargets[command.target];
              if (target != null) _positionReferences.add(target);
            }
          }
      }
    }
  }

  final List<_FilterStep> steps;
  final _enableTargets = <String, int>{};
  final _overlayTargets = <String, int>{};
  final _enable = <int, FilterCommandArgument>{};
  final _coordinates = <int, OverlayPositionCommands>{};
  final _positionReferences = <int>{};

  FilterCommandArgument? enableAt(int step) => _enable[step];
  OverlayPositionCommands? overlayAt(int step) => _coordinates[step];
  bool tracksOverlayFrames(int step) =>
      _positionReferences.contains(step) &&
      (steps[step].filter as _Overlay).evaluateFrame;

  void send(
    _ScriptCommand command,
    _CommandInterval interval,
    FilterPicture picture,
    int frameCount,
    int pts,
    CaptureRational timeBase,
  ) {
    final enable = command.option == _FilterCommandOption.enable;
    final step = (enable ? _enableTargets : _overlayTargets)[command.target];
    final expression = command.expression;
    if (step == null || expression == null) return;
    final senderExpression = (command.flags & _commandExpr) != 0;
    final t = pts * timeBase.value;
    final start = interval.start / 1000000, end = interval.end / 1000000;
    final argument = FilterCommandArgument(
      expression,
      variables: senderExpression
          ? {
              'N': frameCount.toDouble(),
              'T': t,
              'PTS': pts.toDouble(),
              'TS': start,
              'TE': end,
              'TI': (t - start) / (end - start),
            }
          : null,
      sender: command.usesSize ? picture : null,
      usesPreviousPosition: command.usesPreviousPosition,
    );
    if (enable) {
      _enable[step] = argument;
      return;
    }
    final horizontal = command.option == _FilterCommandOption.x;
    final previous = _coordinates[step];
    final overlay = steps[step].filter as _Overlay;
    _coordinates[step] =
        overlay.evaluateFrame || !_positionReferences.contains(step)
        ? OverlayPositionCommands(
            x: horizontal ? argument : previous?.x,
            y: horizontal ? previous?.y : argument,
          )
        : OverlayPositionCommands(
            history: OverlayPositionChange(
              horizontal,
              argument,
              previous?.history,
            ),
          );
  }
}

final class _CommandReader {
  _CommandReader(this.source);

  final String source;
  var _offset = 0;
  static final _space = RegExp(r'\s+');

  void _skipSpace() {
    _offset = _space.matchAsPrefix(source, _offset)?.end ?? _offset;
  }

  bool get atEnd {
    _skipSpace();
    return _offset == source.length;
  }

  bool get hasInterval {
    while (!atEnd && source[_offset] == '#') {
      final next = source.indexOf('\n', _offset);
      _offset = next < 0 ? source.length : next + 1;
    }
    return !atEnd;
  }

  bool take(String token) {
    _skipSpace();
    if (!source.startsWith(token, _offset)) return false;
    _offset += token.length;
    return true;
  }

  int flags() {
    if (!take('[')) return _commandEnter;
    final close = source.indexOf(']', _offset);
    if (close < 0) fail();
    var result = 0;
    for (final flag
        in source.substring(_offset, close).split(RegExp(r'[+|]'))) {
      result |= switch (flag) {
        'enter' => _commandEnter,
        'leave' => _commandLeave,
        'expr' => _commandExpr,
        _ => fail(),
      };
    }
    _offset = close + 1;
    return result;
  }

  String word() {
    _skipSpace();
    final value = StringBuffer();
    while (_offset < source.length) {
      final char = source[_offset];
      if (char == ',' ||
          char == ';' ||
          _space.matchAsPrefix(source, _offset) != null)
        break;
      _offset++;
      if (char == "'") {
        final close = source.indexOf("'", _offset);
        if (close < 0) fail();
        value.write(source.substring(_offset, close));
        _offset = close + 1;
      } else if (char == r'\') {
        if (_offset == source.length) fail();
        value.write(source[_offset++]);
      } else {
        value.write(char);
      }
    }
    return value.toString();
  }

  Never fail() =>
      throw FormatException('Invalid sendcmd script', source, _offset);
}
