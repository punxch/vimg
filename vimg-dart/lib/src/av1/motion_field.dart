part of 'picture_decoder.dart';

/// The projected 8×8 motion field for the current frame (§7.9).
final class _MotionField {
  _MotionField(this.frame, this.references, _FrameState state)
    : columns = state.columns >> 1,
      rows = state.rows >> 1 {
    final last = references.first;
    if (last.referenceHints.isEmpty ||
        last.referenceHints[6] != references[3].header.orderHint) {
      _project(1, -1);
    }
    var available = 1;
    for (final ref in [5, 6, 7]) {
      if (available >= 0 && _distance(ref) > 0 && _project(ref, 1)) available--;
    }
    if (available >= 0) _project(2, -1);
  }

  final Av1CodedFrame frame;
  final List<_DecodedPicture> references;
  final int columns, rows;
  late final _samples = List<({Av1Mv mv, int offset})?>.filled(
    columns * rows,
    null,
  );

  int _distance(int reference) => frame.sequence.relativeDistance(
    references[reference - 1].header.orderHint,
    frame.header.orderHint,
  );

  bool _project(int ref, int sign) {
    final source = references[ref - 1];
    final prior = source.state;
    if (source.header.type.intra ||
        prior.columns != columns * 2 ||
        prior.rows != rows * 2)
      return false;
    final toCurrent = _distance(ref);
    if (toCurrent.abs() > 31) return true;
    final offsets = [
      for (final hint in source.referenceHints)
        frame.sequence.relativeDistance(source.header.orderHint, hint),
    ];
    for (var y = 0; y < rows; y++) {
      for (var x = 0; x < columns; x++) {
        final motion = prior.block(2 * x + 1, 2 * y + 1)?.motion;
        if (motion == null) continue;
        for (final (reference, mv) in [
          (motion.ref1, motion.mv1),
          (motion.ref0, motion.mv0),
        ]) {
          if (reference <= 0 ||
              offsets[reference - 1] <= 0 ||
              mv.x.abs() > 4095 ||
              mv.y.abs() > 4095)
            continue;
          final offset = offsets[reference - 1];
          if (offset <= 31) {
            final vector = _mvProject(mv, toCurrent * sign, offset);
            final tx = x + sign * (vector.x ~/ 64),
                ty = y + sign * (vector.y ~/ 64);
            final bx = x & -8, by = y & -8;
            if (tx >= 0 &&
                tx < columns &&
                ty >= 0 &&
                ty < rows &&
                tx >= bx - 8 &&
                tx < bx + 16 &&
                ty >= by &&
                ty < by + 8) {
              _samples[ty * columns + tx] = (mv: mv, offset: offset);
            }
          }
          break;
        }
      }
    }
    return true;
  }

  Av1MvPair? at(int x4, int y4, int a, int b) {
    final sample = _samples[(y4 >> 1) * columns + (x4 >> 1)];
    if (sample == null) return null;
    return (
      _mvProject(sample.mv, -_distance(a), sample.offset),
      b > 0 ? _mvProject(sample.mv, -_distance(b), sample.offset) : av1ZeroMv,
    );
  }
}

Av1Mv _mvProject(Av1Mv mv, int numerator, int denominator) {
  final scale = numerator.clamp(-31, 31) * (16384 ~/ denominator);
  int project(int n) {
    final value = n * scale;
    return (value.sign * av1Round(value.abs(), 14)).clamp(-16383, 16383);
  }

  return (x: project(mv.x), y: project(mv.y));
}
