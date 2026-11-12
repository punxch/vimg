part of 'coefficients.dart';

/// Writes AV1 §5.11.39 coefficient tokens in the inverse of decoder order.
final class Av1CoefficientEncoder {
  Av1CoefficientEncoder(this._writer, this._cdfs);

  final RangeEncoder _writer;
  final Av1CoefficientCdfs _cdfs;
  final _levels = Uint8List(36 * 36);

  void write(
    Int32List quantized, {
    required Av1CoefficientNeighbors neighbors,
    required int x4,
    required int y4,
    required int blockWidth,
    required int blockHeight,
    required Av1TxSize size,
    required Av1TxType type,
    required bool chroma,
    required void Function() writeType,
  }) {
    final width = size.coefficientWidth, height = size.coefficientHeight;
    final count = width * height;
    final sizeContext = size.coefficientContext;
    final plane = chroma ? 1 : 0;
    final txClass = type.txClass;
    final scan = _scans[(width, height, txClass)]!;
    var eob = count;
    while (eob > 0 && quantized[scan[eob - 1]] == 0) {
      eob--;
    }
    final context = neighbors._contexts(
      x4,
      y4,
      size,
      blockWidth,
      blockHeight,
      chroma,
    );
    _symbol(_Family.skip, sizeContext, 0, context.skip, eob == 0 ? 1 : 0);
    if (eob == 0) {
      neighbors.stamp(x4, y4, size.width >> 2, size.height >> 2, 0, 0);
      return;
    }
    writeType();
    _writeEob(count, sizeContext, plane, txClass, eob);
    final stride = width + 4;
    _levels.fillRange(0, (height + 4) * stride, 0);
    final offsets = _levelOffsets(stride, txClass);
    final brSize = math.min(sizeContext, 3);
    for (var i = eob - 1; i >= 0; i--) {
      final pos = scan[i];
      final row = pos ~/ width, col = pos % width;
      final p = row * stride + col;
      final level = quantized[pos].abs();
      final base = math.min(level, 3);
      if (i == eob - 1) {
        _symbol(
          _Family.baseEob,
          sizeContext,
          plane,
          _baseEobContext(i, count),
          base - 1,
        );
      } else {
        final ctx = _baseContext(
          _levels,
          p,
          stride,
          offsets,
          size,
          txClass,
          row,
          col,
        );
        _symbol(_Family.base, sizeContext, plane, ctx, base);
      }
      if (base == 3) {
        final ctx = _rangeContext(
          _levels,
          p,
          stride,
          offsets.$1,
          txClass,
          row,
          col,
        );
        final table = _cdfs._table(_Family.baseRange, brSize, plane, ctx);
        for (var left = math.min(12, level - base), k = 0; k < 4; k++) {
          final increment = math.min(left, 3);
          _writer.adaptive(table, increment);
          if (increment < 3) break;
          left -= increment;
        }
      }
      _levels[p] = math.min(level, 15);
    }

    var cumulative = 0;
    for (var i = 0; i < eob; i++) {
      final level = quantized[scan[i]];
      if (level == 0) continue;
      final negative = level < 0 ? 1 : 0;
      if (i == 0) {
        _symbol(_Family.dcSign, 0, plane, context.dcSign, negative);
      } else {
        _writer.literal(negative, 1);
      }
      final magnitude = level.abs();
      if (magnitude >= 15) {
        final value = magnitude - 14;
        final zeros = value.bitLength - 1;
        _writer.literal(0, zeros);
        _writer.literal(value, zeros + 1);
      }
      cumulative += magnitude;
    }
    neighbors.stamp(
      x4,
      y4,
      size.width >> 2,
      size.height >> 2,
      math.min(cumulative, 63),
      quantized[0].sign,
    );
  }

  void _symbol(_Family family, int size, int plane, int context, int value) =>
      _writer.adaptive(_cdfs._table(family, size, plane, context), value);

  void _writeEob(int count, int size, int plane, Av1TxClass txClass, int eob) {
    final multi = count.bitLength - 5;
    final context = multi < 5 && txClass != Av1TxClass.twoDimensional ? 1 : 0;
    final point = eob == 1 ? 1 : (eob - 1).bitLength + 1;
    _symbol(_Family.eobPoint, multi, plane, context, point - 1);
    if (point < 3) return;
    final extra = eob - (1 << (point - 2)) - 1;
    final shift = point - 3;
    _symbol(_Family.eobExtra, size, plane, shift, extra >> shift);
    _writer.literal(extra & ((1 << shift) - 1), shift);
  }
}
