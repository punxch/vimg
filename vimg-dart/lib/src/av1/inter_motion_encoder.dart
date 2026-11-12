part of 'inter_syntax.dart';

/// Writes motion for a block with one predetermined reference, a fixed
/// interpolation filter and no high-precision vector syntax.
final class Av1SingleReferenceMotionEncoder {
  Av1SingleReferenceMotionEncoder(this._writer, this._context);

  final RangeEncoder _writer;
  final Av1EntropyContext _context;

  Av1InterMotion write(Av1MvStack stack, Av1Mv motion) {
    final mode = modeFor(stack, motion);
    final n = stack.newContext, z = stack.zeroContext, r = stack.refContext;
    _symbol(_Cdf.newMv, interNewMvCdf[n], mode == Av1MvMode.newMv ? 0 : 1, n);
    if (mode == Av1MvMode.newMv) {
      if (stack.count > 1) _writeDrl(stack, 0);
      final predictor = stack.entries.first.mv.$1;
      final dx = motion.x - predictor.x, dy = motion.y - predictor.y;
      _symbol(
        _Cdf.joint,
        interMvJointCdf,
        (dy == 0 ? 0 : 2) | (dx == 0 ? 0 : 1),
      );
      if (dy != 0) _component(0, dy);
      if (dx != 0) _component(1, dx);
    } else {
      _symbol(
        _Cdf.zeroMv,
        interZeroMvCdf[z],
        mode == Av1MvMode.global ? 0 : 1,
        z,
      );
      if (mode != Av1MvMode.global) {
        _symbol(
          _Cdf.refMv,
          interRefMvCdf[r],
          mode == Av1MvMode.nearest ? 0 : 1,
          r,
        );
        if (mode == Av1MvMode.near && stack.count > 2) _writeDrl(stack, 1);
      }
    }
    return (
      ref0: 1,
      ref1: -1,
      mv0: motion,
      mv1: av1ZeroMv,
      mode0: mode,
      mode1: Av1MvMode.nearest,
      filterX: 0,
      filterY: 0,
      compound: null,
      invertMask: false,
      wedgeIndex: -1,
      interIntraMode: null,
      obmc: false,
      warp: null,
    );
  }

  static Av1MvMode modeFor(Av1MvStack stack, Av1Mv motion) {
    if (motion == stack.global.$1) return Av1MvMode.global;
    if (motion == stack.entries[0].mv.$1) return Av1MvMode.nearest;
    if (motion == stack.entries[1].mv.$1) return Av1MvMode.near;
    return Av1MvMode.newMv;
  }

  static int estimatedBits(Av1MvStack stack, Av1Mv motion) {
    final predictor = stack.entries[0].mv.$1;
    return switch (modeFor(stack, motion)) {
      Av1MvMode.global => 0,
      Av1MvMode.nearest => 2,
      Av1MvMode.near => 4,
      Av1MvMode.newMv =>
        6 +
            2 *
                (((motion.x - predictor.x).abs() >> 2).bitLength +
                    ((motion.y - predictor.y).abs() >> 2).bitLength),
    };
  }

  void _writeDrl(Av1MvStack stack, int index) {
    final ctx = stack.drlContext(index);
    _symbol(_Cdf.drl, interDrlModeCdf[ctx], 0, ctx);
  }

  void _component(int plane, int delta) {
    assert(delta.isEven);
    final magnitude = delta.abs() - 1;
    final integer = magnitude >> 3;
    final kind = math.max(0, integer.bitLength - 1);
    _symbol(_Cdf.sign, interMvSignCdf, delta < 0 ? 1 : 0, plane);
    _symbol(_Cdf.mvClass, interMvClassCdf[plane], kind, plane);
    final fraction = (magnitude >> 1) & 3;
    if (kind == 0) {
      _symbol(_Cdf.class0, interMvClass0BitCdf, integer, plane);
      _symbol(
        _Cdf.class0Fraction,
        interMvClass0FrCdf[plane][integer],
        fraction,
        plane,
        integer,
      );
    } else {
      for (var bit = 0; bit < kind; bit++) {
        _symbol(
          _Cdf.mvBit,
          interMvBitCdf[bit],
          (integer >> bit) & 1,
          plane,
          bit,
        );
      }
      _symbol(_Cdf.fraction, interMvFrCdf[plane], fraction, plane);
    }
  }

  void _symbol(
    _Cdf family,
    List<int> defaults,
    int value, [
    int a = 0,
    int b = 0,
  ]) => _writer.adaptive(_context.cdf((family, a, b), defaults), value);
}
