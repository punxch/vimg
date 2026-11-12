part of 'prores.dart';

final _proResCosines = Float64List.fromList([
  for (var frequency = 0; frequency < 8; frequency++)
    for (var sample = 0; sample < 8; sample++)
      math.cos((2 * sample + 1) * frequency * math.pi / 16) *
          (frequency == 0 ? math.sqrt1_2 : 1) *
          0.5,
]);

final class _ProResTransform {
  final _intermediate = Float64List(64);

  void write(
    Uint16List plane,
    int stride,
    int height,
    int x,
    int y,
    int rowStep,
    Int32List coefficients,
    int offset,
    List<int> weights,
    int quantizer,
    int depth,
    int acRows,
  ) {
    final cols = math.min(8, stride - x);
    final rows = math.min(8, (height - y + rowStep - 1) ~/ rowStep);
    if (cols <= 0 || rows <= 0) return;
    final midpoint = 1 << (depth - 1);
    final maximum = (1 << depth) - 5;
    // Weight times quantizer divided by eight, with the normalization from
    // the signed nine-bit IDCT domain to the requested sample depth.
    final scale = quantizer * (1 << depth) / 4096;
    if (acRows == 0) {
      final value = (midpoint + coefficients[offset] * weights[0] * scale / 8)
          .round()
          .clamp(4, maximum);
      for (var r = 0; r < rows; r++) {
        final start = (y + r * rowStep) * stride + x;
        plane.fillRange(start, start + cols, value);
      }
      return;
    }
    final activeRows = acRows | 1;
    _intermediate.fillRange(0, 64, 0);
    for (var r = 0; r < activeRows.bitLength; r++) {
      if ((activeRows & (1 << r)) == 0) continue;
      final row = r * 8;
      for (var f = 0; f < 8; f++) {
        final coefficient = coefficients[offset + row + f] * weights[row + f];
        if (coefficient == 0) continue;
        final basis = f * 8;
        for (var c = 0; c < 8; c++) {
          _intermediate[row + c] += coefficient * _proResCosines[basis + c];
        }
      }
    }
    for (var r = 0; r < rows; r++) {
      final output = (y + r * rowStep) * stride + x;
      for (var c = 0; c < cols; c++) {
        var value = 0.0;
        for (var f = 0; f < activeRows.bitLength; f++) {
          value += _intermediate[f * 8 + c] * _proResCosines[f * 8 + r];
        }
        plane[output + c] = (midpoint + value * scale).round().clamp(
          4,
          maximum,
        );
      }
    }
  }
}
