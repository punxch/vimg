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

typedef _CaptureRate = ({int numerator, int denominator});

extension on _CaptureRate {
  double get period => denominator / numerator;
}

/// The bounded rational used by av_parse_video_rate for a positive rate.
_CaptureRate _captureRate(double rate) {
  const intMax = 0x7fffffff;
  if (!rate.isFinite || rate <= 0 || rate > intMax + 3) {
    throw const FormatException('Capture frame rate is out of range');
  }
  final binary = ByteData(8)..setFloat64(0, rate);
  final exponent = math.max(0, ((binary.getUint64(0) >> 52) & 0x7ff) - 1023);
  final denominator = BigInt.one << (62 - exponent);
  final numerator = BigInt.from(
    (rate * denominator.toDouble() + 0.5).floorToDouble(),
  );

  (int, int) reduce(int maximum) {
    final max = BigInt.from(maximum);
    var n = numerator, d = denominator;
    var previous = (BigInt.zero, BigInt.one);
    var current = (BigInt.one, BigInt.zero);
    while (d != BigInt.zero) {
      var quotient = n ~/ d;
      final next = (
        quotient * current.$1 + previous.$1,
        quotient * current.$2 + previous.$2,
      );
      if (next.$1 > max || next.$2 > max) {
        if (current.$1 != BigInt.zero)
          quotient = (max - previous.$1) ~/ current.$1;
        if (current.$2 != BigInt.zero) {
          final byDenominator = (max - previous.$2) ~/ current.$2;
          if (byDenominator < quotient) quotient = byDenominator;
        }
        if (d * ((quotient * current.$2 << 1) + previous.$2) > n * current.$2) {
          current = (
            quotient * current.$1 + previous.$1,
            quotient * current.$2 + previous.$2,
          );
        }
        break;
      }
      (previous, current) = (current, next);
      (n, d) = (d, n % d);
    }
    return (current.$1.toInt(), current.$2.toInt());
  }

  var (n, d) = reduce(1001000);
  if (n == 0 || d == 0) (n, d) = reduce(intMax);
  if (n == 0 || d == 0) {
    throw const FormatException('Capture frame rate is out of range');
  }
  return (numerator: n, denominator: d);
}

double? _durationSeconds(FramePacket packet) {
  final time = packet.timestamp;
  final duration = time?.duration;
  return duration == null
      ? null
      : duration * time!.numerator / time.denominator;
}

typedef _SelectedSource = ({FramePacket packet, int index});

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
  final _CaptureRate rate;
  final CaptureSelection? onSelect;
  final frames = <FramePacket>[];
  _SelectedSource? _previous;
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
    final ticks = _relativeTicks(packet, time);
    final scale = 1 << _extraBits;
    final divisor =
        BigInt.from(time.denominator) * BigInt.from(rate.denominator);
    final product =
        BigInt.from(ticks.abs()) *
        BigInt.from(time.numerator) *
        BigInt.from(rate.numerator) *
        BigInt.from(scale);
    final precise =
        ((product + (divisor >> 1)) ~/ divisor).toDouble() * ticks.sign / scale;
    return precise == precise.truncateToDouble()
        ? precise
        : precise + precise.sign / 131072;
  }

  void push(FramePacket packet, int inputIndex, double duration) {
    final source = (packet: packet, index: inputIndex);
    final drift = _adjustedPts(packet) - frames.length;
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
  }

  void finish(FramePacket last, int lastIndex) {
    while (!complete) {
      _add((packet: last, index: lastIndex));
    }
  }

  void _add(_SelectedSource source) {
    onSelect?.call(frames.length, index, source.packet, source.index);
    frames.add(source.packet);
  }

  int _roundFrameCount(double value) {
    final float = _asFloat32(value);
    final floor = float.floor();
    return float - floor == 0.5 ? floor + (floor & 1) : float.round();
  }
}
