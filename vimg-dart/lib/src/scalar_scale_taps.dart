part of 'yuv_image.dart';

typedef _AxisTap = ({int start, Int16List weights});

/// Scalar fixed-point bilinear and bicubic taps used by the packed RGB scaler.
List<_AxisTap> _scalarAxisTaps(
  int from,
  int to,
  int unit,
  int step,
  int count,
  _ScaleKernel kernel,
) {
  final reduction = math.min(math.max(0, (from ~/ to).bitLength - 1), 8);
  final coefficientUnit = 1 << (54 - reduction);
  final cutoff = coefficientUnit ~/ 500;
  final positions = Int32List(to);
  final weights = List.generate(to, (output) {
    final center = (2 * output + 1) * step - 65536;
    final start = (center - (count - 2) * 65536) ~/ 131072;
    positions[output] = start;
    final row = Int64List(count);
    for (var j = 0; j < count; j++) {
      var distance = ((start + j) * 131072 - center).abs() << 13;
      if (step > 65536) distance = distance * to ~/ from;
      row[j] = kernel == _ScaleKernel.triangle
          ? math.max(0, (1 << 30) - distance) * (coefficientUnit >> 30)
          : _scalarCubicWeight(distance) ~/ (1 << reduction);
    }
    return row;
  }, growable: false);

  // Omit negligible end taps and keep the first sample monotonic.
  var length = 1;
  final dropped = Int32List(to);
  for (var i = to - 1; i >= 0; i--) {
    var left = 0, magnitude = 0;
    final row = weights[i];
    while (left < count) {
      magnitude += row[left].abs();
      if (magnitude > cutoff ||
          (i + 1 < to && positions[i] >= positions[i + 1])) {
        break;
      }
      positions[i]++;
      left++;
    }
    dropped[i] = left;
    magnitude = 0;
    var retained = count;
    for (var j = count - 1; j > 0; j--) {
      final offset = j + left;
      if (offset < count) magnitude += row[offset].abs();
      if (magnitude > cutoff) break;
      retained--;
    }
    length = math.max(retained, length);
  }

  return List.generate(to, (i) {
    var start = positions[i];
    final row = Int64List(length);
    final left = dropped[i];
    for (var j = 0; j < length && j + left < count; j++) {
      row[j] = weights[i][j + left];
    }
    if (start < 0) {
      for (var j = 1; j < length; j++) {
        row[math.max(j + start, 0)] += row[j];
        row[j] = 0;
      }
      start = 0;
    }
    final excess = start + length - from;
    if (excess > 0) {
      var edge = 0;
      for (var j = math.max(0, length - excess); j < length; j++) {
        edge += row[j];
      }
      for (var j = length - 1; j >= 0; j--) {
        row[j] = j < excess ? 0 : row[j - excess];
      }
      start -= excess;
      row[length - 1] += edge;
    }
    final sum = row.fold(0, (sum, value) => sum + value);
    final divisor = math.max(1, (sum + (unit >> 1)) ~/ unit);
    final half = divisor >> 1;
    final quantized = Int16List(length);
    var error = 0;
    for (var j = 0; j < length; j++) {
      final value = row[j] + error;
      final normalized = (value + (value < 0 ? -half : half)) ~/ divisor;
      quantized[j] = normalized;
      error = value - normalized * divisor;
    }
    return (start: start, weights: quantized);
  }, growable: false);
}

int _scalarCubicWeight(int distance) {
  const one = 1 << 30;
  const c = (0.6 * (1 << 24));
  final coefficient = c.toInt();
  if (distance >= 2 * one) return 0;
  final squared = distance * distance >> 30;
  final cubed = squared * distance >> 30;
  if (distance < one) {
    return ((12 << 24) - 6 * coefficient) * cubed +
        (6 * coefficient - (18 << 24)) * squared +
        (6 << 54);
  }
  return coefficient * (-6 * cubed + 30 * squared - 48 * distance + 24 * one);
}
