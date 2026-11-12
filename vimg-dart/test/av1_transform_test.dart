import 'dart:math' as math;
import 'dart:typed_data';

import '../lib/src/av1/transform.dart';

void main() {
  // Sample checksums from OxideAV's AV1 inverse-transform implementation,
  // with the flipped ADST permutations applied to the output raster.
  const expected = {8: 1652035253, 10: 2059739720, 12: 1832941523};
  const vertical = [0, 1, 0, 1, 1, 0, 1, 1, 1, 2, 0, 2, 1, 2, 1, 2, 0];
  const horizontal = [0, 0, 1, 1, 0, 1, 1, 1, 1, 2, 2, 0, 2, 1, 2, 1, 0];
  final inverse = Av1InverseTransform();
  final residual = Int32List(64 * 64);
  for (final depth in [8, 10, 12]) {
    var hash = 0;
    final limit = 1 << (depth + 7);
    for (final size in Av1TxSize.values) {
      final (w, h) = (size.width, size.height);
      final coefficients = Int32List(math.min(w, 32) * math.min(h, 32));
      for (
        var typeIndex = 0;
        typeIndex <= Av1TxType.values.length;
        typeIndex++
      ) {
        final lossless = typeIndex == Av1TxType.values.length;
        if ((lossless && size != Av1TxSize.tx4x4) ||
            (vertical[typeIndex] == 1 && h > 16) ||
            (vertical[typeIndex] == 2 && h > 32) ||
            (horizontal[typeIndex] == 1 && w > 16) ||
            (horizontal[typeIndex] == 2 && w > 32)) {
          continue;
        }
        final type = lossless ? Av1TxType.dctDct : Av1TxType.values[typeIndex];
        for (var vector = 0; vector < 4; vector++) {
          for (var i = 0; i < coefficients.length; i++) {
            final k = i * 197 + size.index * 73 + typeIndex * 29;
            coefficients[i] = switch (vector) {
              0 => i % 5 == 0 ? k % 2003 - 1001 : 0,
              1 => (k * 997) % (2 * limit) - limit,
              2 => i == 0 ? -limit + 1 : 0,
              _ => 0,
            };
          }
          inverse.apply(
            coefficients,
            residual,
            size,
            type,
            depth,
            lossless: lossless,
          );
          for (var i = 0; i < w * h; i++) {
            final value = residual[i] + 0x80000;
            hash = (hash * 257 + value) & 0x7fffffff;
          }
        }
      }
    }
    if (hash != expected[depth]) {
      throw StateError('AV1 inverse transform mismatch at $depth bits: $hash');
    }
  }
}
