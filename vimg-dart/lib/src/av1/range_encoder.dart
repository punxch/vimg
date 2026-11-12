import 'dart:typed_data';

/// AV1 Q15 entropy writer for tiles with CDF updates disabled. The carry
/// handling is based on go-av1's BSD-licensed od_ec encoder (see NOTICE).
final class RangeEncoder {
  static const _full = 32768;
  static const _equiprobable = [16384];

  final _pending = <int>[];
  int _range = _full;
  int _low = 0;
  int _count = -9;

  /// [cdf] contains the ascending cumulative probabilities, omitting 32768.
  void symbol(List<int> cdf, int value) {
    final symbols = cdf.length + 1;
    final upper = value == 0
        ? _range
        : _boundary(_full - cdf[value - 1], symbols - value);
    final lower = value == cdf.length
        ? 0
        : _boundary(_full - cdf[value], symbols - value - 1);
    var low = _low + _range - upper;
    final range = upper - lower;
    final shift = 16 - range.bitLength;
    var next = _count + shift;
    if (next >= 0) {
      var count = _count + 16;
      if (next >= 8) {
        _pending.add(low >> count);
        low &= (1 << count) - 1;
        count -= 8;
      }
      _pending.add(low >> count);
      low &= (1 << count) - 1;
      next = count + shift - 24;
    }
    _low = low << shift;
    _range = range << shift;
    _count = next;
  }

  int _boundary(int inverseCdf, int remaining) =>
      (((_range >> 8) * (inverseCdf >> 6)) >> 1) + 4 * remaining;

  void literal(int value, int bits) {
    assert(value >= 0 && value.bitLength <= bits);
    for (var bit = bits - 1; bit >= 0; bit--) {
      symbol(_equiprobable, (value >> bit) & 1);
    }
  }

  void uniform(int value, int count) {
    final bits = count.bitLength;
    final short = (1 << bits) - count;
    if (value < short) {
      literal(value, bits - 1);
    } else {
      literal(value + short, bits);
    }
  }

  Uint8List finish() {
    // Choose a terminating value inside the interval and resolve deferred carry
    // bits back toward the start of the tile.
    var endpoint = ((_low + 0x3fff) & ~0x3fff) | 0x4000;
    for (var shift = _count + 16; shift > 6; shift -= 8) {
      _pending.add(endpoint >> shift);
      endpoint &= (1 << shift) - 1;
    }
    final bytes = Uint8List(_pending.length);
    var carry = 0;
    for (var i = bytes.length - 1; i >= 0; i--) {
      carry += _pending[i];
      bytes[i] = carry & 255;
      carry >>= 8;
    }
    return bytes;
  }
}
