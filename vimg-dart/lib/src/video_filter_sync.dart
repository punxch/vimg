part of 'yuv_image.dart';

final class _FrameSyncOptions {
  factory _FrameSyncOptions.parse(Map<String, String> options) {
    final shortest = _filterFlag(options['shortest'], 'shortest');
    final repeat = _filterFlag(options['repeatlast'] ?? '1', 'repeatlast');
    final eofAction = options['eof_action'];
    final endAll = switch (eofAction) {
      null || 'repeat' || 'pass' || '0' || '2' => false,
      'endall' || '1' => true,
      _ => throw const FormatException('Invalid eof_action'),
    };
    final nearest = switch (options['ts_sync_mode']) {
      null || 'default' || '0' => false,
      'nearest' || '1' => true,
      _ => throw const FormatException('Invalid ts_sync_mode'),
    };
    final pass = !repeat || eofAction == 'pass' || eofAction == '2';
    return _FrameSyncOptions._(shortest || !pass && endAll, pass, nearest);
  }

  const _FrameSyncOptions._(this.stopAtEof, this.dropSecondary, this.nearest);

  final bool stopAtEof, dropSecondary, nearest;
}

final class _SynchronizedFilterGraph {
  _SynchronizedFilterGraph(this.steps);
  final List<_FilterStep> steps;

  CaptureTimeline schedule(CaptureTimeline source) {
    final active = {0: source};
    for (final (index, step) in steps.indexed) {
      final inputs = [for (final link in step.inputs) active.remove(link)!];
      final filter = step.filter;
      if (step.outputs.length > 1) {
        final timeline = inputs.single;
        final start = _ForkEvent();
        final fork = _TimelineFork(timeline.events.iterator, start);
        for (final link in step.outputs) {
          active[link] = CaptureTimeline(
            fork.events(_ForkCursor(start)),
            timeline.timeBase,
            timeline.frameRate,
          );
        }
        continue;
      }
      active[step.outputs.single] = switch (filter) {
        final _TimingFilter filter => filter.apply(inputs.single),
        _Stack() ||
        _Overlay() ||
        _MergeAlpha() ||
        _VideoAlphaFilter(inplace: false) => _synchronize(index, inputs),
        _SpatialFilter() => _spatial(index, inputs.single),
        _ => inputs.single,
      };
    }
    return active.values.single;
  }

  CaptureTimeline _spatial(int step, CaptureTimeline source) => CaptureTimeline(
    _spatialEvents(step, source),
    source.timeBase,
    source.frameRate,
  );

  Iterable<CaptureTimelineEvent> _spatialEvents(
    int step,
    CaptureTimeline source,
  ) sync* {
    var index = 0;
    for (final event in source.events) {
      yield event is CaptureTimedFrame
          ? event.withPicture(
              FilterOperationPicture(
                step,
                [_pictureOf(event)],
                (index: index++, seconds: event.pts * source.timeBase.value),
              ),
            )
          : event;
    }
  }

  CaptureTimeline _synchronize(int step, List<CaptureTimeline> timelines) {
    final filter = steps[step].filter;
    final sync = switch (filter) {
      final _Overlay filter => filter.sync,
      final _MergeAlpha filter => filter.sync,
      _ => null,
    };
    final baseTimestamps = filter is _VideoAlphaFilter;
    final primary = timelines.first;
    final clock = filter is _Overlay || sync?.dropSecondary == true
        ? primary.timeBase
        : timelines.map((input) => input.timeBase).reduce(_sharedFilterClock);
    final outputClock = baseTimestamps || filter is _MergeAlpha
        ? primary.timeBase
        : clock;
    final rate = primary.frameRate;
    final sameRate = timelines.every((input) => input.frameRate == rate);
    final outputRate = sync != null || baseTimestamps || sameRate ? rate : null;
    final stop = sync?.stopAtEof ?? (filter is _Stack && filter.shortest);
    return CaptureTimeline(
      _joinEvents(
        step,
        timelines,
        clock,
        outputClock,
        outputRate,
        sync,
        stop,
        baseTimestamps: baseTimestamps,
      ),
      outputClock,
      outputRate,
    );
  }

  Iterable<CaptureTimelineEvent> _joinEvents(
    int step,
    List<CaptureTimeline> sources,
    CaptureRational clock,
    CaptureRational outputClock,
    double? outputRate,
    _FrameSyncOptions? sync,
    bool stop, {
    required bool baseTimestamps,
  }) sync* {
    final inputs = [
      for (final source in sources) _FilterSyncInput(source, clock),
    ];
    final main = inputs.first;
    final stackDuration = outputRate == null
        ? 1
        : math.max(1, checkedCaptureTick(1 / (outputRate * clock.value)));
    int? lastOutput;
    int? reportedEnd;
    while (true) {
      int? nextTime;
      var active = 0;
      for (final (i, input) in inputs.indexed) {
        final wasEnded = input.ended;
        input.prepare(stop || sync?.dropSecondary == true && i == 1);
        if (!wasEnded && input.ended) reportedEnd = input.end;
        if (!input.ended) active++;
        final next = input.nextTime;
        if (next != null && (nextTime == null || next < nextTime))
          nextTime = next;
      }
      if (sync?.dropSecondary == true && main.ended) {
        // A secondary that cannot extend past EOF also cannot drive output.
        nextTime = null;
        reportedEnd = main.end;
      }
      if (nextTime == null || active == 0) {
        yield CaptureTimelineEnd(
          reportedEnd == null
              ? (lastOutput ?? -1) + 1
              : rescaleCaptureTicks(reportedEnd, clock, outputClock),
          known: reportedEnd != null,
        );
        return;
      }

      var ready = false;
      for (final (i, input) in inputs.indexed) {
        final next = input.nextTime;
        final last = input.frame;
        final nearest =
            i == 1 &&
            sync?.nearest == true &&
            !main.ended &&
            input.next != null &&
            last != null &&
            next! - nextTime < nextTime - last.pts;
        if (next != nextTime && !nearest) continue;
        if (input.next == null) {
          if (stop) {
            yield CaptureTimelineEnd(
              rescaleCaptureTicks(nextTime, clock, outputClock),
              known: false,
            );
            return;
          }
          input.clear();
          continue;
        }
        input.advance();
        if (sync == null || (main.ended ? i == 1 : i == 0)) ready = true;
      }
      if (!ready ||
          main.frame == null ||
          sync == null && inputs.any((input) => input.frame == null))
        continue;
      final first = main.frame!;
      final pts = rescaleCaptureTicks(
        baseTimestamps ? first.pts : nextTime,
        clock,
        outputClock,
      );
      final primary = first.retime(
        pts,
        duration: sync == null && !baseTimestamps
            ? stackDuration
            : first.duration,
      );
      final picture = FilterOperationPicture(
        step,
        [
          for (final input in inputs)
            if (input.frame case final frame?) _pictureOf(frame),
        ],
        (index: main.index, seconds: pts * outputClock.value),
      );
      lastOutput = pts;
      yield primary.withPicture(picture);
    }
  }
}

FilterPicture _pictureOf(CaptureTimedFrame frame) =>
    frame.source.frame.picture ?? FilterInputPicture(frame.source.frame.packet);

// A branch may read ahead while applying trim or fps. Its siblings consume
// the same metadata in order without starting another demux iterator.
final class _TimelineFork {
  _TimelineFork(this.source, this._tail);
  final Iterator<CaptureTimelineEvent> source;
  _ForkEvent _tail;
  var _ended = false;

  Iterable<CaptureTimelineEvent> events(_ForkCursor cursor) sync* {
    while (true) {
      final position = cursor.position;
      if (identical(position, _tail)) {
        if (_ended || !source.moveNext()) {
          _ended = true;
          return;
        }
        position.event = source.current;
        _tail = position.next = _ForkEvent();
      }
      cursor.position = position.next!;
      yield position.event!;
    }
  }
}

final class _ForkCursor {
  _ForkCursor(this.position);
  _ForkEvent position;
}

final class _ForkEvent {
  CaptureTimelineEvent? event;
  _ForkEvent? next;
}

CaptureRational _sharedFilterClock(CaptureRational a, CaptureRational b) {
  if (a == b) return a;
  final numerator = a.numerator.gcd(b.numerator);
  final denominator =
      a.denominator ~/ a.denominator.gcd(b.denominator) * b.denominator;
  final divisor = numerator.gcd(denominator);
  return denominator ~/ divisor <= 500000
      ? (numerator: numerator ~/ divisor, denominator: denominator ~/ divisor)
      : captureMicroseconds;
}

final class _FilterSyncInput {
  _FilterSyncInput(this.source, this.clock) : events = source.events.iterator;
  final CaptureTimeline source;
  final CaptureRational clock;
  final Iterator<CaptureTimelineEvent> events;
  CaptureTimedFrame? frame, next;
  int? nextTime, end;
  var ended = false;
  var index = -1;

  void prepare(bool stopExtending) {
    if (nextTime != null || ended) return;
    if (events.moveNext()) {
      final event = events.current;
      if (event is CaptureTimedFrame) {
        final time = rescaleCaptureTicks(event.pts, source.timeBase, clock);
        next = event.retime(time);
        nextTime = time;
        return;
      }
      if ((event as CaptureTimelineEnd).known) {
        end = rescaleCaptureTicks(event.pts, source.timeBase, clock);
      }
    }
    ended = true;
    if (stopExtending && frame != null) nextTime = frame!.pts + 1;
  }

  void advance() {
    frame = next;
    index++;
    next = null;
    nextTime = null;
  }

  void clear() {
    frame = null;
    nextTime = null;
  }
}
