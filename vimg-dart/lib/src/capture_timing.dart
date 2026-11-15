part of 'capture.dart';

final _float32 = Float32List(1);

double _asFloat32(double value) {
  _float32[0] = value;
  return _float32[0];
}

double _offsetFloat32(VideoOffset offset, double duration) {
  final value = _asFloat32(offset.value);
  return offset.percent
      ? _asFloat32(_asFloat32(duration * value) * _asFloat32(0.01))
      : value;
}

// Rust passes the shortest decimal representation of the f32 seek to FFmpeg.
double _seekDecimal(double value) {
  for (var digits = 1; digits < 9; digits++) {
    final decimal = double.parse(value.toStringAsPrecision(digits));
    if (_asFloat32(decimal) == value) return decimal;
  }
  return double.parse(value.toStringAsPrecision(9));
}

extension on CaptureRational {
  double get period => denominator / numerator;
}

double? _durationSeconds(FramePacket packet) {
  final time = packet.timestamp;
  final duration = time?.duration;
  return duration == null
      ? null
      : duration * time!.numerator / time.denominator;
}

/// The same constant-frame-rate drift and duplication rules as the Rust
/// FrameSchedule. Timestamps refer to the source even when a frame repeats.
final class _CaptureSchedule {
  _CaptureSchedule(
    this.index,
    this.start,
    this.count,
    this.rate,
    this.onSelect,
  );

  final int index, count;
  final double start;
  final CaptureRational rate;
  final CaptureSelection? onSelect;
  final frames = <CaptureFrame>[];
  CaptureSource? _previous, _lastEmitted;
  late final _extraBits = (30 - rate.numerator.bitLength).clamp(0, 16);

  bool get complete => frames.length == count;

  bool containsStart(FramePacket packet) {
    final time = packet.timestamp;
    return time == null
        ? packet.seconds >= start
        : _relativeTicks(packet, time) >= 0;
  }

  int _relativeTicks(FramePacket packet, FrameTimestamp time) {
    // seconds includes presentation edits, while pts is the source timestamp.
    final ticks =
        time.pts + (start - packet.seconds) * time.denominator / time.numerator;
    return time.pts - ticks.round();
  }

  double _adjustedPts(FramePacket packet) {
    final time = packet.timestamp;
    if (time == null) return (packet.seconds - start) / rate.period;
    return _scaledPts(_relativeTicks(packet, time), (
      numerator: time.numerator,
      denominator: time.denominator,
    ));
  }

  double _scaledPts(int ticks, CaptureRational timeBase) {
    final scale = 1 << _extraBits;
    final divisor =
        BigInt.from(timeBase.denominator) * BigInt.from(rate.denominator);
    final product =
        BigInt.from(ticks.abs()) *
        BigInt.from(timeBase.numerator) *
        BigInt.from(rate.numerator) *
        BigInt.from(scale);
    final precise =
        ((product + (divisor >> 1)) ~/ divisor).toDouble() * ticks.sign / scale;
    return precise == precise.truncateToDouble()
        ? precise
        : precise + precise.sign / 131072;
  }

  void push(FramePacket packet, int inputIndex, double duration) {
    _push(
      (frame: CaptureFrame(packet), index: inputIndex),
      _adjustedPts(packet),
      duration,
    );
  }

  int _push(CaptureSource source, double pts, double duration) {
    final drift = pts - frames.length;
    final end = drift + duration / rate.period;
    final copies = end < -1.1
        ? 0
        : end > 1.1
        ? _roundFrameCount(end)
        : 1;
    final previousCopies = end > 1.1 && drift > 1.1
        ? _roundFrameCount(drift - 0.6)
        : 0;
    final remaining = math.min(copies, count - frames.length);
    for (var i = 0; i < remaining; i++) {
      _add(i < previousCopies ? _previous ?? source : source);
    }
    _previous = source;
    return previousCopies;
  }

  int pushFiltered(CaptureTimedFrame frame, CaptureRational timeBase) => _push(
    frame.source,
    _scaledPts(frame.pts, timeBase),
    frame.duration * timeBase.value,
  );

  void finishFiltered(int previousCopies) {
    final previous = _previous;
    if (previous != null) {
      for (var i = 0; i < previousCopies && !complete; i++) {
        _add(previous);
      }
    }
    final last = _lastEmitted;
    if (last == null) {
      throw FormatException(
        'Video filters produced no frames for capture ${index + 1}',
      );
    }
    _fill(last);
  }

  void finish(FramePacket last, int lastIndex) =>
      _fill((frame: CaptureFrame(last), index: lastIndex));

  void _fill(CaptureSource last) {
    while (!complete) {
      _add(last);
    }
  }

  void _add(CaptureSource source) {
    onSelect?.call(frames.length, index, source.frame.packet, source.index);
    frames.add(source.frame);
    _lastEmitted = source;
  }

  int _roundFrameCount(double value) {
    final float = _asFloat32(value);
    final floor = float.floor();
    return float - floor == 0.5 ? floor + (floor & 1) : float.round();
  }
}
