import 'dart:math' as math;
import 'dart:typed_data';

import 'frame_packet.dart';

typedef CaptureRational = ({int numerator, int denominator});

extension CaptureRationalValue on CaptureRational {
  double get value => numerator / denominator;
  CaptureRational get inverse =>
      (numerator: denominator, denominator: numerator);
}

const captureMicroseconds = (numerator: 1, denominator: 1000000);

typedef FilterFramePosition = ({int index, double seconds});

/// A single decoded picture can appear more than once after a timing filter.
/// The values seen by spatial filters distinguish those renderings.
final class CaptureFrame {
  const CaptureFrame(this.packet, [this.positions = const []]);

  final FramePacket packet;
  final List<FilterFramePosition> positions;

  @override
  bool operator ==(Object other) {
    if (other is! CaptureFrame ||
        other.packet != packet ||
        other.positions.length != positions.length)
      return false;
    for (var i = 0; i < positions.length; i++) {
      if (positions[i] != other.positions[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(packet, Object.hashAll(positions));
}

typedef CaptureSource = ({CaptureFrame frame, int index});

sealed class CaptureTimelineEvent {
  const CaptureTimelineEvent(this.pts);
  final int pts;
}

/// Filter timestamps are separate from the original packet and source index.
final class CaptureTimedFrame extends CaptureTimelineEvent {
  const CaptureTimedFrame(super.pts, this.duration, this.source);
  final int duration;
  final CaptureSource source;

  CaptureTimedFrame retime(int pts, {int? duration}) =>
      CaptureTimedFrame(pts, duration ?? this.duration, source);

  CaptureTimedFrame atFilter(FilterFramePosition position) =>
      CaptureTimedFrame(pts, duration, (
        frame: CaptureFrame(
          source.frame.packet,
          List.unmodifiable([...source.frame.positions, position]),
        ),
        index: source.index,
      ));
}

final class CaptureTimelineEnd extends CaptureTimelineEvent {
  const CaptureTimelineEnd(super.pts);
}

final class CaptureTimeline {
  const CaptureTimeline(this.events, this.timeBase, this.frameRate);

  final Iterable<CaptureTimelineEvent> events;
  final CaptureRational timeBase;
  final double? frameRate;
}

enum CaptureRounding { zero, away, down, up, near }

int checkedCaptureTick(double value, {bool truncate = false}) {
  // Keep enough space for subtraction of two timestamps on the same clock.
  if (!value.isFinite || value.abs() >= (1 << 62)) {
    throw const FormatException('Video filter timestamp is out of range');
  }
  return truncate ? value.truncate() : value.round();
}

/// Rescale a timestamp using integer arithmetic and ties away from zero.
int rescaleCaptureTicks(
  int ticks,
  CaptureRational from,
  CaptureRational to, {
  CaptureRounding rounding = CaptureRounding.near,
}) {
  if (ticks == 0 || from == to) return ticks;
  final value =
      BigInt.from(ticks.abs()) *
      BigInt.from(from.numerator) *
      BigInt.from(to.denominator);
  final divisor = BigInt.from(from.denominator) * BigInt.from(to.numerator);
  final remainder = value.remainder(divisor);
  final increment = switch (rounding) {
    CaptureRounding.zero => false,
    CaptureRounding.away => remainder != BigInt.zero,
    CaptureRounding.down => ticks < 0 && remainder != BigInt.zero,
    CaptureRounding.up => ticks > 0 && remainder != BigInt.zero,
    CaptureRounding.near => (remainder << 1) >= divisor,
  };
  final result = value ~/ divisor + (increment ? BigInt.one : BigInt.zero);
  if (result.bitLength > 62) {
    throw const FormatException('Video filter timestamp is out of range');
  }
  return result.toInt() * ticks.sign;
}

/// The bounded rational used by FFmpeg for positive rates and time bases.
CaptureRational captureRational(
  double rate, {
  int maximum = 1001000,
  String description = 'Capture frame rate',
}) {
  const intMax = 0x7fffffff;
  if (!rate.isFinite || rate <= 0 || rate > intMax + 3) {
    throw FormatException('$description is out of range');
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

  var (n, d) = reduce(maximum);
  if (n == 0 || d == 0) (n, d) = reduce(intMax);
  if (n == 0 || d == 0) {
    throw FormatException('$description is out of range');
  }
  return (numerator: n, denominator: d);
}
