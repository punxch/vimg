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

final class _ScheduledTimeline {
  const _ScheduledTimeline(this.timeline, {this.pushed, this.stop});

  final CaptureTimeline timeline;
  final _PushedFilterLink? pushed;
  final void Function()? stop;
}

final class _SynchronizedFilterGraph {
  _SynchronizedFilterGraph(this.steps);
  final List<_FilterStep> steps;

  CaptureTimeline schedule(CaptureTimeline source) {
    final active = {0: _ScheduledTimeline(source)};
    final commands = steps.any((step) => step.filter is _SendCmd)
        ? _FilterCommandState(steps)
        : null;
    for (final (index, step) in steps.indexed) {
      final links = [for (final link in step.inputs) active.remove(link)!];
      final inputs = [for (final link in links) link.timeline];
      final filter = step.filter;
      final order = step.outputs.first;
      if (step.outputs.length > 1) {
        final timeline = inputs.single;
        if (commands != null) {
          final input = links.single.pushed;
          final fork =
              input?.fork ?? _PushedFilterFork(timeline.events.iterator);
          final outputs = <_PushedFilterLink>[];
          for (final link in step.outputs) {
            final output = _PushedFilterLink(
              fork,
              timeline.timeBase,
              timeline.frameRate,
              onStop: () {
                if (outputs.every((output) => output.closed))
                  links.single.stop?.call();
              },
            );
            outputs.add(output);
            active[link] = output.scheduled;
          }
          if (input == null) {
            fork.outputs.addAll(outputs);
          } else {
            input.connect(order, (event) {
              for (final output in outputs) {
                output.publish(event);
              }
            });
          }
          continue;
        }
        final start = _ForkEvent();
        final fork = _TimelineFork(timeline.events.iterator, start);
        for (final link in step.outputs) {
          active[link] = _ScheduledTimeline(
            CaptureTimeline(
              fork.events(_ForkCursor(start)),
              timeline.timeBase,
              timeline.frameRate,
            ),
          );
        }
        continue;
      }
      if (links.singleOrNull?.pushed case final input?) {
        final timeline = inputs.single;
        final transition = switch (filter) {
          final _ImmediateTimingFilter filter => filter.transition(timeline),
          final _SendCmd filter => filter.transition(timeline, commands!),
          _VideoAlphaFilter(inplace: false) => null,
          _SpatialFilter() => _spatialTransition(index, timeline, commands),
          null || _Split() => (
            timeBase: timeline.timeBase,
            frameRate: timeline.frameRate,
            createTransform: () =>
                (CaptureTimelineEvent event) => event,
          ),
          _ => null,
        };
        if (transition != null) {
          active[order] = input.transition(order, transition).scheduled;
          continue;
        }
      }
      final timeline = switch (filter) {
        final _TimingFilter filter => filter.apply(inputs.single),
        final _SendCmd filter => filter.apply(inputs.single, commands!),
        _Stack() ||
        _Overlay() ||
        _MergeAlpha() ||
        _VideoAlphaFilter(
          inplace: false,
        ) => _synchronize(index, inputs, commands),
        _SpatialFilter() => _spatial(index, inputs.single, commands),
        _ => inputs.single,
      };
      final stops = [
        for (final link in links)
          if (link.stop case final stop?) stop,
      ];
      if (stops.isEmpty) {
        active[order] = _ScheduledTimeline(timeline);
      } else {
        void stop() {
          for (final close in stops) {
            close();
          }
        }

        active[order] = _ScheduledTimeline(
          CaptureTimeline(
            _stopOnEnd(timeline.events, stop),
            timeline.timeBase,
            timeline.frameRate,
          ),
          stop: stop,
        );
      }
    }
    return active.values.single.timeline;
  }

  CaptureTimeline _spatial(
    int step,
    CaptureTimeline source,
    _FilterCommandState? commands,
  ) => _applyTransition(source, _spatialTransition(step, source, commands));

  _TimelineTransition _spatialTransition(
    int step,
    CaptureTimeline source,
    _FilterCommandState? commands,
  ) {
    _TimelineTransform createTransform() {
      var index = 0;
      return (event) => event is CaptureTimedFrame
          ? event.withPicture(
              FilterOperationPicture(
                step,
                [_pictureOf(event)],
                (index: index++, seconds: event.pts * source.timeBase.value),
                enableCommand: commands?.enableAt(step),
              ),
            )
          : event;
    }

    return (
      timeBase: source.timeBase,
      frameRate: source.frameRate,
      createTransform: createTransform,
    );
  }

  CaptureTimeline _synchronize(
    int step,
    List<CaptureTimeline> timelines,
    _FilterCommandState? commands,
  ) {
    final filter = steps[step].filter;
    final sync = switch (filter) {
      final _Overlay filter => filter.sync,
      final _MergeAlpha filter => filter.sync,
      _ => null,
    };
    final baseTimestamps = filter is _VideoAlphaFilter;
    final primary = timelines.first;
    // Compare timestamps at the common precision before rescaling output
    // back to the main link's clock.
    final clock = sync?.dropSecondary == true
        ? primary.timeBase
        : timelines.map((input) => input.timeBase).reduce(_sharedFilterClock);
    final outputClock = baseTimestamps || sync != null
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
        commands: commands,
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
    required _FilterCommandState? commands,
  }) sync* {
    final inputs = [
      for (final source in sources) _FilterSyncInput(source, clock),
    ];
    final main = inputs.first;
    final commandTarget = commands != null && steps[step].commandTarget != null;
    final trackEnable =
        commandTarget || steps[step].enable?.usesFramePosition == true;
    final overlay = commands?.tracksOverlayFrames(step) == true
        ? steps[step].filter as _Overlay
        : null;
    final stackDuration = outputRate == null
        ? 1
        : math.max(1, checkedCaptureTick(1 / (outputRate * clock.value)));
    int? lastOutput;
    int? reportedEnd;
    FilterCommandArgument? enableCommand;
    FilterOperationPicture? lastOverlay;
    while (true) {
      int? nextTime;
      var active = 0;
      for (final (i, input) in inputs.indexed) {
        final wasEnded = input.ended;
        final waitingForMain = commandTarget && i == 0 && input.next == null;
        input.prepare(stop || sync?.dropSecondary == true && i == 1);
        if (waitingForMain && input.next != null)
          enableCommand = commands.enableAt(step);
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
      final overlayCommands = commands?.overlayAt(step);
      final hasSecondary = overlay != null && inputs[1].frame != null;
      final needsPrevious =
          hasSecondary &&
          (overlay.usesPreviousPosition ||
              overlayCommands?.x?.usesPreviousPosition == true ||
              overlayCommands?.y?.usesPreviousPosition == true ||
              enableCommand != null ||
              steps[step].enable != null);
      final picture = FilterOperationPicture(
        step,
        [
          for (final input in inputs)
            if (input.frame case final frame?) _pictureOf(frame),
        ],
        (index: main.index, seconds: pts * outputClock.value),
        enablePosition: trackEnable ? main.consumedPosition : null,
        enableCommand: enableCommand,
        overlayCommands: overlayCommands,
        previousOverlay: needsPrevious ? lastOverlay : null,
      );
      if (hasSecondary) lastOverlay = picture;
      lastOutput = pts;
      yield primary.withPicture(picture);
    }
  }
}

FilterPicture _pictureOf(CaptureTimedFrame frame) =>
    frame.source.frame.picture ?? FilterInputPicture(frame.source.frame.packet);

Iterable<CaptureTimelineEvent> _stopOnEnd(
  Iterable<CaptureTimelineEvent> events,
  void Function() stop,
) sync* {
  for (final event in events) {
    if (event is CaptureTimelineEnd) {
      stop();
      yield event;
      return;
    }
    yield event;
  }
  stop();
}

/// A split in a command graph delivers each source event to the immediate
/// filters on all its live branches. Filters requiring lookahead pull from
/// the resulting queues when their output is requested.
final class _PushedFilterFork {
  _PushedFilterFork(this.source);

  final Iterator<CaptureTimelineEvent> source;
  final outputs = <_PushedFilterLink>[];
  final _ready = SplayTreeMap<int, void Function()>();
  var _ended = false;

  bool advance() {
    if (_ended || !source.moveNext()) {
      _ended = true;
      return false;
    }
    final event = source.current;
    for (final output in outputs) {
      output.publish(event);
    }
    while (_ready.isNotEmpty) {
      _ready.remove(_ready.firstKey()!)!();
    }
    _ended = event is CaptureTimelineEnd;
    return true;
  }
}

final class _PushedFilterLink {
  _PushedFilterLink(this.fork, this.timeBase, this.frameRate, {this.onStop});

  final _PushedFilterFork fork;
  final CaptureRational timeBase;
  final double? frameRate;
  final void Function()? onStop;
  final _buffer = ListQueue<CaptureTimelineEvent>();
  var closed = false;
  ({int order, void Function(CaptureTimelineEvent) receive})? _consumer;

  _ScheduledTimeline get scheduled => _ScheduledTimeline(
    CaptureTimeline(_events(), timeBase, frameRate),
    pushed: this,
    stop: stop,
  );

  void connect(int order, void Function(CaptureTimelineEvent) receive) {
    _consumer = (order: order, receive: receive);
  }

  _PushedFilterLink transition(int order, _TimelineTransition transition) {
    final output = _PushedFilterLink(
      fork,
      transition.timeBase,
      transition.frameRate,
      onStop: stop,
    );
    final transform = transition.createTransform();
    connect(order, (event) {
      final result = transform(event);
      if (result == null) return;
      output.publish(result);
      if (result is CaptureTimelineEnd) stop();
    });
    return output;
  }

  void publish(CaptureTimelineEvent event) {
    if (closed) return;
    if (_consumer case (:final order, :final receive)) {
      fork._ready[order] = () {
        if (!closed) receive(event);
      };
    } else {
      _buffer.addLast(event);
    }
  }

  void stop() {
    if (closed) return;
    closed = true;
    _buffer.clear();
    onStop?.call();
  }

  Iterable<CaptureTimelineEvent> _events() sync* {
    while (!closed && (_buffer.isNotEmpty || fork.advance())) {
      if (_buffer.isEmpty) continue;
      final event = _buffer.removeFirst();
      yield event;
      if (event is CaptureTimelineEnd) {
        stop();
        return;
      }
    }
    stop();
  }
}

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
  int? _lastInputPts;
  var ended = false;
  var index = -1;

  // Framesync evaluates enable when taking a frame from the main link's FIFO.
  // This can be a lookahead frame while a secondary event still uses the last main picture.
  FilterFramePosition? get consumedPosition => switch (_lastInputPts) {
    final pts? => (
      index: next == null ? index : index + 1,
      seconds: pts * source.timeBase.value,
    ),
    null => null,
  };

  void prepare(bool stopExtending) {
    if (nextTime != null || ended) return;
    if (events.moveNext()) {
      final event = events.current;
      if (event is CaptureTimedFrame) {
        _lastInputPts = event.pts;
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
