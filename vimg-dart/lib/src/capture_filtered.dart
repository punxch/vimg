part of 'capture.dart';

List<List<CaptureFrame>> _selectFilteredCaptures(
  CapturePlan plan,
  Iterable<FramePacket> packets,
  CaptureTimeline Function(CaptureTimeline) filter,
  CaptureRational? timeBase,
  double? frameRate,
  CaptureSelection? onSelect,
) {
  final input = _CaptureWindowReader(
    packets,
    timeBase,
    frameRate,
    plan._rate.period,
  );
  final selected = <List<CaptureFrame>>[];
  for (final (index, start) in plan.starts.indexed) {
    final schedule = _CaptureSchedule(
      index,
      start,
      plan.frames,
      plan._rate,
      onSelect,
    );
    final timeline = filter(input.window(start, plan._seekWindow));
    var first = 0, second = 0, third = 0;
    for (final event in timeline.events) {
      if (event is! CaptureTimedFrame) break;
      (first, second, third) = (
        schedule.pushFiltered(event, timeline.timeBase),
        first,
        second,
      );
      if (schedule.complete) break;
    }
    if (!schedule.complete) {
      // The encoder drains the median number of preceding-frame copies
      // before the vimg capture fills any remaining slots from its last output.
      final median = math.max(
        math.min(first, second),
        math.min(math.max(first, second), third),
      );
      schedule.finishFiltered(median);
    }
    selected.add(schedule.frames);
  }
  return selected;
}

/// Forward-only source reader. Adjacent seek windows can reuse source
/// metadata without retaining an index of the entire video.
final class _CaptureWindowReader {
  _CaptureWindowReader(
    Iterable<FramePacket> packets,
    CaptureRational? base,
    double? nominalRate,
    double fallbackPeriod,
  ) {
    final iterator = packets.iterator;
    final initial = <FramePacket>[];
    final prefix = base == null || nominalRate == null ? 64 : 1;
    while (initial.length < prefix && iterator.moveNext()) {
      initial.add(iterator.current);
    }
    if (initial.isEmpty) throw const FormatException('No video frames');
    final stamp = initial.first.timestamp;
    timeBase =
        base ??
        (stamp == null
            ? captureMicroseconds
            : (numerator: stamp.numerator, denominator: stamp.denominator));
    frameRate = nominalRate ?? _estimateRate(initial);
    final fallback = math.max(1, (fallbackPeriod / timeBase.value).round());
    _source = _timedFrames(_join(initial, iterator), fallback).iterator;
  }

  late final CaptureRational timeBase;
  late final double? frameRate;
  late final Iterator<CaptureTimedFrame> _source;
  final _buffer = ListQueue<CaptureTimedFrame>();
  var _eof = false;

  bool _advance() {
    if (_eof) return false;
    if (!_source.moveNext()) {
      _eof = true;
      return false;
    }
    _buffer.addLast(_source.current);
    return true;
  }

  CaptureTimeline window(double start, double duration) {
    final seek = _windowTicks(start);
    final length = _windowTicks(duration);
    while ((_buffer.isNotEmpty || _advance()) && _buffer.first.pts < seek) {
      _buffer.removeFirst();
    }
    return CaptureTimeline(_windowEvents(seek, length), timeBase, frameRate);
  }

  int _windowTicks(double seconds) => rescaleCaptureTicks(
    checkedCaptureTick(seconds * 1000000),
    captureMicroseconds,
    timeBase,
  );

  Iterable<CaptureTimelineEvent> _windowEvents(int seek, int length) sync* {
    if (_buffer.isEmpty) {
      yield const CaptureTimelineEnd(0);
      return;
    }
    final first = _buffer.first.pts;
    var end = first;
    // Iterate the retained range before extending the queue for this window.
    Iterable<CaptureTimedFrame> frames() sync* {
      yield* _buffer;
      while (_advance()) {
        yield _buffer.last;
      }
    }

    for (final frame in frames()) {
      if (length > 0 && frame.pts - first >= length) {
        yield CaptureTimelineEnd(frame.pts - seek);
        return;
      }
      end = frame.pts + frame.duration;
      yield frame.retime(frame.pts - seek);
    }
    yield CaptureTimelineEnd(end - seek);
  }

  Iterable<FramePacket> _join(
    List<FramePacket> initial,
    Iterator<FramePacket> rest,
  ) sync* {
    yield* initial;
    while (rest.moveNext()) {
      yield rest.current;
    }
  }

  int _playbackTicks(FramePacket packet) =>
      checkedCaptureTick(packet.seconds / timeBase.value);

  int? _durationTicks(FramePacket packet) {
    final stamp = packet.timestamp;
    final duration = stamp?.duration;
    if (duration == null) return null;
    return rescaleCaptureTicks(duration, (
      numerator: stamp!.numerator,
      denominator: stamp.denominator,
    ), timeBase);
  }

  double? _estimateRate(List<FramePacket> packets) {
    // Common positive durations and intervals give the nominal sampling grid,
    // including the doubled intervals of a variable-rate file.
    var smallest = 0, divisor = 0;
    void interval(int ticks) {
      if (ticks <= 0) return;
      smallest = smallest == 0 ? ticks : math.min(ticks, smallest);
      divisor = divisor.gcd(ticks);
    }

    int? previous;
    for (final packet in packets) {
      final pts = _playbackTicks(packet);
      if (previous != null) interval(pts - previous);
      interval(_durationTicks(packet) ?? 0);
      previous = pts;
    }
    if (divisor == 0) return null;
    // A rounded timestamp or a nonuniform edit can introduce a tiny gcd.
    final period = divisor * 4 < smallest ? smallest : divisor;
    return 1 / (period * timeBase.value);
  }

  Iterable<CaptureTimedFrame> _timedFrames(
    Iterable<FramePacket> packets,
    int fallback,
  ) sync* {
    FramePacket? pending;
    var timestamp = 0, duration = fallback;
    var index = 0;
    for (final packet in packets) {
      final pts = _playbackTicks(packet);
      if (pending != null) {
        if (packet.seconds < pending.seconds) {
          throw const FormatException('Out-of-order presentation timestamps');
        }
        final elapsed = pts - timestamp;
        duration =
            _durationTicks(pending) ?? (elapsed > 0 ? elapsed : duration);
        yield CaptureTimedFrame(timestamp, duration, (
          frame: CaptureFrame(pending),
          index: index++,
        ));
      }
      pending = packet;
      timestamp = pts;
    }
    if (pending != null) {
      yield CaptureTimedFrame(timestamp, _durationTicks(pending) ?? duration, (
        frame: CaptureFrame(pending),
        index: index,
      ));
    }
  }
}
