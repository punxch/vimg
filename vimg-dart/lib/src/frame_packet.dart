typedef FrameTimestamp = ({
  int pts,
  int numerator,
  int denominator,
  int? duration,
});

/// A coded unit within a container sample's restored payload.
/// The display index counts visible pictures and is absent for reference-only units.
typedef FrameSubframe = ({
  int offset,
  int length,
  int? displayIndex,
  FrameTimestamp? sampleTimestamp,
});

typedef FramePacket = ({
  double seconds,
  int offset,
  int size,
  FrameTimestamp? timestamp,
  FrameSubframe? subframe,
});

extension FramePacketSource on FramePacket {
  FrameTimestamp? get sourceTimestamp => subframe?.sampleTimestamp ?? timestamp;
}

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
