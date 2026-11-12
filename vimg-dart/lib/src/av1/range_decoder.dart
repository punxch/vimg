import 'dart:math' as math;
import 'dart:typed_data';

import 'bitstream.dart';

/// AV1 symbol decoding (specification §8.2). Tables use ascending Q15 CDFs
/// with the final 32768 implicit, as in the range encoder.
final class RangeDecoder {
  RangeDecoder(this._bits, {this.updateCdf = true})
    : _remaining = _bits.remaining - 15 {
    final count = math.min(15, _bits.remaining);
    _value = 32767 ^ (_bits.read(count) << (15 - count));
  }

  final Av1Bits _bits;
  final bool updateCdf;
  int _range = 32768;
  late int _value;
  int _remaining;

  int symbol(List<int> cdf) {
    final last = cdf.length;
    final scale = _range >> 8;
    var upper = _range;
    var lower = 0;
    var symbol = 0;
    while (symbol < last) {
      lower = (scale * ((32768 - cdf[symbol]) >> 6) >> 1) + 4 * (last - symbol);
      if (_value >= lower) break;
      upper = lower;
      symbol++;
    }
    if (symbol == last) lower = 0;
    final range = upper - lower;
    final shift = 16 - range.bitLength;
    final count = math.min(shift, math.max(0, _remaining));
    final input = _bits.read(count) << (shift - count);
    _value = (((_value - lower + 1) << shift) - 1) ^ input;
    _range = range << shift;
    _remaining -= shift;
    if (_remaining < -14) throw const FormatException('Truncated AV1 tile');
    return symbol;
  }

  int adaptive(Av1Cdf cdf) {
    final value = symbol(cdf._values);
    if (updateCdf) cdf._observe(value);
    return value;
  }

  int literal(int count) {
    var value = 0;
    for (var i = 0; i < count; i++) {
      value = (value << 1) | symbol(const [16384]);
    }
    return value;
  }

  int uniform(int count) {
    final bits = count.bitLength;
    final short = (1 << bits) - count;
    final value = literal(bits - 1);
    return value < short ? value : (value << 1) - short + literal(1);
  }

  void finish() {
    _bits.position -= math.min(15, _remaining + 15);
    _bits.trailing();
  }
}

/// A tile's mutable cumulative distribution and its §8.3 adaptation counter.
/// Reference frames can retain a copy as the starting context of a later tile.
final class Av1Cdf {
  Av1Cdf(List<int> initial) : _values = Uint16List(initial.length) {
    if (initial.isEmpty || initial.length > 15)
      throw ArgumentError.value(
        initial.length,
        'length',
        'Expected 1 to 15 CDF entries',
      );
    var previous = 0;
    for (final (index, value) in initial.indexed) {
      if (value < previous || value > 32768)
        throw ArgumentError.value(
          initial,
          'initial',
          'Invalid ascending Q15 CDF',
        );
      _values[index] = previous = value;
    }
  }

  Av1Cdf._(this._values, this._observations);

  final Uint16List _values;
  var _observations = 0;
  late final List<int> cumulative = _values.asUnmodifiableView();

  int get observations => _observations;

  Av1Cdf copy() => Av1Cdf._(Uint16List.fromList(_values), _observations);

  void _observe(int symbol) {
    final symbols = _values.length + 1;
    final rate = 3 + (symbols >= 4 ? 2 : 1) + (_observations >> 4);
    for (var i = 0; i < _values.length; i++) {
      final value = _values[i];
      _values[i] = i < symbol
          ? value - (value >> rate)
          : value + ((32768 - value) >> rate);
    }
    if (_observations < 32) _observations++;
  }
}
