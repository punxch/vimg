import 'dart:typed_data';

// A separable fixed-point 8×8 IDCT. The row pass leaves three fractional bits
// for the column pass, which rounds to the nearest reconstructed sample.
final _idctWeights = Int32List.fromList([
  for (var sample = 0; sample < 8; sample++)
    for (var frequency = 0; frequency < 8; frequency++)
      _idctWeight((2 * sample + 1) * frequency),
]);

int _idctWeight(int phase) {
  const weights = [16383, 22725, 21407, 19266, 16383, 12873, 8867, 4520, 0];
  var angle = phase & 31;
  if (angle > 16) angle = 32 - angle;
  return angle > 8 ? -weights[16 - angle] : weights[angle];
}

final class MpegIdct {
  // Large coefficients can exceed 16 bits in the intermediate row pass.
  final _rows = Int32List(64);

  void write(
    Uint8List plane,
    int offset,
    int stride,
    Int16List coefficients,
    bool intra,
  ) {
    _prepare(coefficients);
    for (var y = 0; y < 8; y++) {
      final base = offset + y * stride;
      for (var x = 0; x < 8; x++) {
        final predicted = intra ? 0 : plane[base + x];
        plane[base + x] = (predicted + _sample(x, y)).clamp(0, 255);
      }
    }
  }

  void samples(Int16List coefficients, Int16List output) {
    _prepare(coefficients);
    for (var y = 0; y < 8; y++) {
      for (var x = 0; x < 8; x++) {
        output[y * 8 + x] = _sample(x, y).clamp(-256, 255);
      }
    }
  }

  void _prepare(Int16List coefficients) {
    for (var row = 0; row < 64; row += 8) {
      var last = 7;
      while (last > 0 && coefficients[row + last] == 0) {
        last--;
      }
      if (last == 0) {
        _rows.fillRange(row, row + 8, coefficients[row] << 3);
      } else {
        for (var x = 0; x < 8; x++) {
          var sum = 1024;
          for (var i = 0; i <= last; i++) {
            sum += coefficients[row + i] * _idctWeights[x * 8 + i];
          }
          _rows[row + x] = sum >> 11;
        }
      }
    }
  }

  int _sample(int x, int y) {
    var sum = 32 * _idctWeights[0];
    for (var i = 0; i < 8; i++) {
      sum += _rows[i * 8 + x] * _idctWeights[y * 8 + i];
    }
    return sum >> 20;
  }
}
