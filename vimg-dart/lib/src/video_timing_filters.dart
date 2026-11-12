part of 'yuv_image.dart';

abstract interface class _TimingFilter {
  CaptureTimeline apply(CaptureTimeline input);
}

final class _Trim implements _TimingFilter {
  factory _Trim(String? args) {
    final options = _filterOptions(args, [
      'start',
      'end',
      'start_pts',
      'end_pts',
      'duration',
      'start_frame',
      'end_frame',
    ]);
    final duration = _filterDuration(options['duration']);
    if (duration != null && duration < 0) {
      throw const FormatException('trim duration must be nonnegative');
    }
    final first = _filterInteger(options, 'start_frame', minimum: -1);
    return _Trim._(
      _filterDuration(options['start']),
      _filterDuration(options['end']),
      _filterInteger(options, 'start_pts'),
      _filterInteger(options, 'end_pts'),
      duration,
      first == -1 ? null : first,
      _filterInteger(options, 'end_frame', minimum: 0),
    );
  }

  _Trim._(
    this.start,
    this.end,
    this.startPts,
    this.endPts,
    this.duration,
    this.startFrame,
    this.endFrame,
  );

  final int? start, end, startPts, endPts, duration, startFrame, endFrame;

  @override
  CaptureTimeline apply(CaptureTimeline input) =>
      CaptureTimeline(_events(input), input.timeBase, input.frameRate);

  Iterable<CaptureTimelineEvent> _events(CaptureTimeline input) sync* {
    int? ticks(int? us) => us == null
        ? null
        : rescaleCaptureTicks(us, captureMicroseconds, input.timeBase);
    final startTime = ticks(start);
    final endTime = ticks(end);
    final first = startTime == null || startPts == null
        ? startTime ?? startPts
        : math.min(startTime, startPts!);
    final last = endTime == null || endPts == null
        ? endTime ?? endPts
        : math.max(endTime, endPts!);
    final length = ticks(duration) ?? 0;
    final checkStart = first != null || startFrame != null;
    final checkEnd = last != null || endFrame != null || length > 0;
    var index = 0;
    int? firstKept;
    for (final event in input.events) {
      if (event is CaptureTimelineEnd) {
        yield event;
        return;
      }
      final position = index++;
      final pts = event.pts;
      if (checkStart &&
          !(first != null && pts >= first ||
              startFrame != null && position >= startFrame!)) {
        continue;
      }
      firstKept ??= pts;
      if (checkEnd &&
          !(last != null && pts < last ||
              endFrame != null && position < endFrame! ||
              length > 0 && pts - firstKept < length)) {
        yield CaptureTimelineEnd(pts);
        return;
      }
      yield event;
    }
  }
}

const _setPtsVariables = {
  'PTS',
  'TB',
  'T',
  'N',
  'STARTPTS',
  'STARTT',
  'T_CHANGE',
  'PREV_INPTS',
  'PREV_INT',
  'PREV_OUTPTS',
  'PREV_OUTT',
  'FRAME_RATE',
  'FR',
};

final class _SetPts implements _TimingFilter {
  factory _SetPts(String? args) {
    final options = _filterOptions(args, ['expr', 'strip_fps']);
    final strip = switch (options['strip_fps']) {
      null || '0' || 'false' || 'no' || 'off' => false,
      '1' || 'true' || 'yes' || 'on' => true,
      _ => throw const FormatException('setpts strip_fps must be a boolean'),
    };
    return _SetPts._(
      parseFilterExpression(options['expr'] ?? 'PTS', _setPtsVariables),
      strip,
    );
  }

  _SetPts._(this.expression, this.stripRate);
  final FilterExpression expression;
  final bool stripRate;

  @override
  CaptureTimeline apply(CaptureTimeline input) => CaptureTimeline(
    _events(input),
    input.timeBase,
    stripRate ? null : input.frameRate,
  );

  Iterable<CaptureTimelineEvent> _events(CaptureTimeline input) sync* {
    final tb = input.timeBase.value;
    final rate = input.frameRate ?? double.nan;
    final variables = <String, double>{
      'TB': tb,
      'FRAME_RATE': rate,
      'FR': rate,
    };
    var index = 0;
    for (final event in input.events) {
      final pts = event.pts.toDouble();
      final seconds = pts * tb;
      variables['STARTPTS'] ??= pts;
      variables['STARTT'] ??= seconds;
      variables['T_CHANGE'] ??= seconds;
      variables['PTS'] = pts;
      variables['T'] = seconds;
      variables['N'] = index.toDouble();
      final output = checkedCaptureTick(expression(variables), truncate: true);
      if (event is! CaptureTimedFrame) {
        yield CaptureTimelineEnd(output);
        return;
      }
      yield event.retime(output, duration: stripRate ? 0 : null);
      variables['PREV_INPTS'] = pts;
      variables['PREV_INT'] = seconds;
      variables['PREV_OUTPTS'] = output.toDouble();
      variables['PREV_OUTT'] = output * tb;
      index++;
    }
  }
}

const _fpsVariables = {
  'ntsc': 30000 / 1001,
  'pal': 25.0,
  'film': 24.0,
  'ntsc_film': 24000 / 1001,
};

final class _Fps implements _TimingFilter {
  factory _Fps(String? args) {
    final options = _filterOptions(args, [
      'fps',
      'start_time',
      'round',
      'eof_action',
    ]);
    final rounding = switch (options['round']) {
      null || 'near' || '5' => CaptureRounding.near,
      'zero' || '0' => CaptureRounding.zero,
      'inf' || '1' => CaptureRounding.away,
      'down' || '2' => CaptureRounding.down,
      'up' || '3' => CaptureRounding.up,
      _ => throw const FormatException('Unsupported fps rounding mode'),
    };
    final eof = switch (options['eof_action']) {
      null || 'round' || '0' => rounding,
      'pass' || '1' => CaptureRounding.up,
      _ => throw const FormatException('Unsupported fps EOF action'),
    };
    final start = options['start_time'];
    final startUs = start == null
        ? null
        : checkedCaptureTick(
            (double.tryParse(start) ?? double.nan) * 1000000,
            truncate: true,
          );
    return _Fps._(
      parseFilterExpression(options['fps'] ?? '25', {
        'source_fps',
        ..._fpsVariables.keys,
      }),
      startUs,
      rounding,
      eof,
    );
  }

  _Fps._(this.expression, this.start, this.rounding, this.eofRounding);
  final FilterExpression expression;
  final int? start;
  final CaptureRounding rounding, eofRounding;

  @override
  CaptureTimeline apply(CaptureTimeline input) {
    final rate = captureRational(
      expression({
        ..._fpsVariables,
        'source_fps': input.frameRate ?? double.nan,
      }),
      maximum: 0x7fffffff,
      description: 'fps rate',
    );
    return CaptureTimeline(
      _events(input, rate.inverse),
      rate.inverse,
      rate.value,
    );
  }

  Iterable<CaptureTimelineEvent> _events(
    CaptureTimeline input,
    CaptureRational outputBase,
  ) sync* {
    final inputOffset = rescaleCaptureTicks(
      start ?? 0,
      captureMicroseconds,
      input.timeBase,
      rounding: rounding,
    );
    final outputOffset = rescaleCaptureTicks(
      start ?? 0,
      captureMicroseconds,
      outputBase,
      rounding: rounding,
    );
    int framePts(int pts) =>
        outputOffset +
        rescaleCaptureTicks(
          pts - inputOffset,
          input.timeBase,
          outputBase,
          rounding: rounding,
        );

    int? next = start == null ? null : outputOffset;
    CaptureTimedFrame? previous;
    for (final event in input.events) {
      if (event is CaptureTimedFrame) {
        final pts = framePts(event.pts);
        var tick = next ?? pts;
        if (previous != null) {
          while (tick < pts) {
            yield previous.retime(tick++, duration: 1);
          }
        }
        next = tick;
        previous = event;
      } else {
        // EOF uses its own rounding and the absolute input clock.
        final end = rescaleCaptureTicks(
          event.pts,
          input.timeBase,
          outputBase,
          rounding: eofRounding,
        );
        var tick = next ?? end;
        if (previous != null) {
          while (tick < end) {
            yield previous.retime(tick++, duration: 1);
          }
        }
        yield CaptureTimelineEnd(tick);
        return;
      }
    }
  }
}

final class _SetTimeBase implements _TimingFilter {
  factory _SetTimeBase(String? args) {
    final options = _filterOptions(args, ['expr'], {'tb': 'expr'});
    return _SetTimeBase._(
      parseFilterExpression(options['expr'] ?? 'intb', {'AVTB', 'intb', 'sr'}),
    );
  }

  _SetTimeBase._(this.expression);
  final FilterExpression expression;

  @override
  CaptureTimeline apply(CaptureTimeline input) {
    final timeBase = captureRational(
      expression({
        'AVTB': captureMicroseconds.value,
        'intb': input.timeBase.value,
        'sr': 0,
      }),
      maximum: 0x7fffffff,
      description: 'settb time base',
    );
    if (timeBase == input.timeBase) return input;
    return CaptureTimeline(
      input.events.map((event) {
        final pts = rescaleCaptureTicks(event.pts, input.timeBase, timeBase);
        return switch (event) {
          final CaptureTimedFrame frame => frame.retime(
            pts,
            duration: rescaleCaptureTicks(
              frame.duration,
              input.timeBase,
              timeBase,
            ),
          ),
          CaptureTimelineEnd() => CaptureTimelineEnd(pts),
        };
      }),
      timeBase,
      input.frameRate,
    );
  }
}

int? _filterInteger(Map<String, String> options, String name, {int? minimum}) {
  final value = options[name];
  if (value == null) return null;
  final number = int.tryParse(value);
  if (number == null ||
      number <= -(1 << 62) ||
      number >= 1 << 62 ||
      (minimum != null && number < minimum)) {
    throw FormatException('Invalid video filter integer for $name: $value');
  }
  return number;
}

final _durationNumber = RegExp(r'^(\d*)(?:\.(\d+))?(s|ms|us)?$');

int? _filterDuration(String? value) {
  if (value == null) return null;
  final negative = value.startsWith('-');
  final unsigned = value.startsWith('+') || negative
      ? value.substring(1)
      : value;
  final clock = unsigned.replaceAll(r'\:', ':').split(':');
  final match = _durationNumber.firstMatch(clock.last);
  if (match == null ||
      clock.length > 3 ||
      (match[1]!.isEmpty && match[2] == null) ||
      (clock.length > 1 && match[3] != null)) {
    throw FormatException('Invalid video filter duration: $value');
  }
  final unit = switch (match[3]) {
    'ms' => 1000,
    'us' => 1,
    _ => 1000000,
  };
  var whole = BigInt.zero;
  for (final (index, part) in clock.take(clock.length - 1).indexed) {
    final integer = int.tryParse(part);
    if (integer == null || integer < 0 || (index == 1 && integer >= 60)) {
      throw FormatException('Invalid video filter duration: $value');
    }
    whole = whole * BigInt.from(60) + BigInt.from(integer);
  }
  final seconds = BigInt.tryParse(match[1]!) ?? BigInt.zero;
  if (clock.length > 1 && seconds >= BigInt.from(60)) {
    throw FormatException('Invalid video filter duration: $value');
  }
  whole = whole * BigInt.from(60) + seconds;
  // Truncate the fractional part to the number of microsecond digits in
  // the given unit, just as the filter time parser does.
  final digits = unit.toString().length - 1;
  final fraction = (match[2] ?? '').padRight(digits, '0').substring(0, digits);
  final result =
      whole * BigInt.from(unit) + (BigInt.tryParse(fraction) ?? BigInt.zero);
  if (result.bitLength > 62) {
    throw FormatException('Video filter duration is out of range: $value');
  }
  return result.toInt() * (negative ? -1 : 1);
}
