part of 'ffv1.dart';

final class _SampleMap {
  _SampleMap(this.samples)
    : bits = (samples.length - 1).bitLength,
      _mask = (1 << (samples.length - 1).bitLength) - 1;

  final Uint32List samples;
  final int bits;
  final int _mask;

  int restore(int value) {
    final index = value & _mask;
    if (index >= samples.length) {
      throw const FormatException('FFV1 sample outside remapping table');
    }
    return samples[index];
  }

  static _SampleMap read(
    _RangeDecoder range,
    int depth,
    int pixels, {
    required bool flipSignOrder,
  }) {
    final segments = range.symbol(_initialStates(32));
    if (segments > 4096) {
      throw const FormatException('Too many FFV1 remapping segments');
    }
    final strides = Uint32List(segments + 1)..[segments] = 1;
    final state = _initialStates(5 * 32);
    final domain = 1 << depth;
    final sign = domain >> 1;
    final samples = Uint32List(math.min(pixels, domain));
    var count = 0;
    var position = 0;
    var stride = 1;
    var occupied = false;
    while (position < domain) {
      final runContext = occupied ? 64 : 0;
      final run = range.symbol(state, offset: runContext);
      if (!occupied) position += run * stride;
      final entries = occupied ? run : 1;
      for (var entry = 0; entry < entries; entry++) {
        if (stride > 1) {
          final delta = range.symbol(
            state,
            offset: runContext + 32,
            signed: true,
          );
          if (delta <= -stride || delta > stride ~/ 2) {
            throw const FormatException('Invalid FFV1 remapping adjustment');
          }
          position += stride - 1 + delta;
        }
        if (position >= domain) break;
        if (count == samples.length) {
          throw const FormatException('Too many FFV1 remapped samples');
        }
        samples[count++] = flipSignOrder && position < sign
            ? position ^ (sign - 1)
            : position;
        position++;
        final segment = (position * segments) >> 32;
        stride = strides[segment];
        if (stride == 0) {
          stride = range.symbol(state, offset: 128);
          if (stride == 0 || stride >= 1 << 30) {
            throw const FormatException('Invalid FFV1 remapping stride');
          }
          strides[segment] = stride;
        }
      }
      if (occupied) position += stride;
      if (run == 0) occupied = !occupied;
    }
    if (count == 0) throw const FormatException('Empty FFV1 sample map');
    return _SampleMap(Uint32List.sublistView(samples, 0, count));
  }
}

Uint16List _floatToVideoSamples(List<int> samples, int depth) {
  final converted = Uint16List(samples.length);
  if (depth == 32) {
    final values = Float32List.sublistView(samples as Uint32List);
    for (var i = 0; i < samples.length; i++) {
      converted[i] = _normalizedSample(values[i]);
    }
  } else {
    for (var i = 0; i < samples.length; i++) {
      final bits = samples[i];
      if (bits & 0x8000 != 0) continue;
      final fraction = bits & 0x03ff;
      final exponent = bits >> 10;
      converted[i] = switch (exponent) {
        31 => fraction == 0 ? 65535 : 0,
        0 => _normalizedSample(fraction / (1 << 24)),
        _ => _normalizedSample((1024 + fraction) * _halfFloatScales[exponent]),
      };
    }
  }
  return converted;
}

final _halfFloatScales = List<double>.generate(
  31,
  (exponent) => math.pow(2.0, exponent - 25).toDouble(),
  growable: false,
);

int _normalizedSample(double value) {
  if (value.isNaN || value <= 0) return 0;
  if (value >= 1) return 65535;
  return (value * 65535).round();
}
