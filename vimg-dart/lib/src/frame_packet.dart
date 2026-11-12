typedef FrameTimestamp = ({
  int pts,
  int numerator,
  int denominator,
  int? duration,
});

typedef FramePacket = ({
  double seconds,
  int offset,
  int size,
  FrameTimestamp? timestamp,
});

typedef FrameVisitor = void Function(FramePacket packet, bool sync);

FrameTimestamp frameTimestamp(
  int pts,
  int numerator,
  int denominator, {
  int? duration,
}) {
  final divisor = numerator.gcd(denominator);
  return (
    pts: pts,
    numerator: numerator ~/ divisor,
    denominator: denominator ~/ divisor,
    duration: duration != null && duration > 0 ? duration : null,
  );
}
