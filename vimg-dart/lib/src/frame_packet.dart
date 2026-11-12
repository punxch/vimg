typedef FrameTimestamp = ({int pts, int numerator, int denominator});

typedef FramePacket = ({
  double seconds,
  int offset,
  int size,
  FrameTimestamp? timestamp,
});

typedef FrameVisitor = void Function(FramePacket packet, bool sync);

FrameTimestamp frameTimestamp(int pts, int numerator, int denominator) {
  final divisor = numerator.gcd(denominator);
  return (
    pts: pts,
    numerator: numerator ~/ divisor,
    denominator: denominator ~/ divisor,
  );
}
