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

  CaptureTimeline apply(CaptureTimeline input, _EnableCommandState state) =>
      CaptureTimeline(_events(input, state), input.timeBase, input.frameRate);

  Iterable<CaptureTimelineEvent> _events(
    CaptureTimeline input,
    _EnableCommandState state,
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
    if (name != 'enable')
      throw FormatException('Unsupported sendcmd command: $name');

    if ((flags & _commandExpr) != 0) {
      var usesSize = false;
      final expression = parseFilterExpression(
        argument,
        _commandVariables,
        onVariable: (name) => usesSize |= name == 'W' || name == 'H',
      );
      return _ScriptCommand._(target, flags, expression, usesSize: usesSize);
    }
    FilterExpression? expression;
    try {
      expression = _FilterEnable.parse(argument).expression;
    } on FormatException {
      // A rejected runtime enable expression leaves the previous one active.
    }
    return _ScriptCommand._(target, flags, expression);
  }

  const _ScriptCommand._(
    this.target,
    this.flags,
    this.expression, {
    this.usesSize = false,
  });

  final String target;
  final int flags;
  final FilterExpression? expression;
  final bool usesSize;
}

final class _EnableCommandState {
  _EnableCommandState(List<_FilterStep> steps) {
    // FFmpeg dispatches to the first matching filter in declaration order.
    final order = List.generate(
      steps.length,
      (i) => i,
    )..sort((a, b) => steps[a].outputs.first.compareTo(steps[b].outputs.first));
    if (steps[order.first].commandTarget != null) _targets['all'] = order.first;
    for (final i in order) {
      final target = steps[i].commandTarget;
      if (target == null) continue;
      _targets.putIfAbsent(target.name, () => i);
      _targets.putIfAbsent(target.instance, () => i);
    }
  }

  final _targets = <String, int>{};
  final _active = <int, FilterEnableCommand>{};

  FilterEnableCommand? at(int step) => _active[step];

  void send(
    _ScriptCommand command,
    _CommandInterval interval,
    FilterPicture picture,
    int frameCount,
    int pts,
    CaptureRational timeBase,
  ) {
    final step = _targets[command.target], expression = command.expression;
    if (step == null || expression == null) return;
    if ((command.flags & _commandExpr) == 0) {
      _active[step] = FilterEnableCommand(expression);
      return;
    }
    final t = pts * timeBase.value;
    final start = interval.start / 1000000, end = interval.end / 1000000;
    _active[step] = FilterEnableCommand(
      expression,
      variables: {
        'N': frameCount.toDouble(),
        'T': t,
        'PTS': pts.toDouble(),
        'TS': start,
        'TE': end,
        'TI': (t - start) / (end - start),
      },
      sender: command.usesSize ? picture : null,
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
