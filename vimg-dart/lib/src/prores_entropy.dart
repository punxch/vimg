part of 'prores.dart';

// RDD 36 §7.2.2, indexed by frequency position in the coded scan.
final _progressiveScan = _inverseScan([
  0,
  1,
  4,
  5,
  16,
  17,
  21,
  22,
  2,
  3,
  6,
  7,
  18,
  20,
  23,
  28,
  8,
  9,
  12,
  13,
  19,
  24,
  27,
  29,
  10,
  11,
  14,
  15,
  25,
  26,
  30,
  31,
  32,
  33,
  37,
  38,
  45,
  46,
  53,
  54,
  34,
  36,
  39,
  44,
  47,
  52,
  55,
  60,
  35,
  40,
  43,
  48,
  51,
  56,
  59,
  61,
  41,
  42,
  49,
  50,
  57,
  58,
  62,
  63,
]);
final _fieldScan = _inverseScan([
  0,
  2,
  8,
  10,
  32,
  34,
  35,
  41,
  1,
  3,
  9,
  11,
  33,
  36,
  40,
  42,
  4,
  6,
  12,
  14,
  37,
  39,
  43,
  49,
  5,
  7,
  13,
  15,
  38,
  44,
  48,
  50,
  16,
  18,
  19,
  25,
  45,
  47,
  51,
  57,
  17,
  20,
  24,
  26,
  46,
  52,
  56,
  58,
  21,
  23,
  27,
  30,
  53,
  55,
  59,
  62,
  22,
  28,
  29,
  31,
  54,
  60,
  61,
  63,
]);

Uint8List _inverseScan(List<int> indices) {
  final scan = Uint8List(64);
  for (final (raster, index) in indices.indexed) {
    scan[index] = raster;
  }
  return scan;
}

final class _ProResCoefficients {
  // Up to eight macroblocks, with up to four blocks per component each.
  final values = Int32List(32 * 64);
  final rows = Uint8List(32);

  void decode(_ProResBits bits, int blocks, List<int> scan) {
    final length = blocks * 64;
    values.fillRange(0, length, 0);
    rows.fillRange(0, blocks, 0);
    if (bits.empty) return; // Empty chroma component uses neutral samples.

    var dc = _signedGolomb(bits.golomb(5));
    values[0] = _coefficient(dc);
    var previous = 3;
    for (var block = 1; block < blocks; block++) {
      final code = switch (previous.abs()) {
        0 => bits.golomb(0),
        1 => bits.golomb(1),
        2 => bits.golomb(3, riceLevels: 2, riceOrder: 2),
        _ => bits.golomb(3),
      };
      final difference = _signedGolomb(code);
      previous = previous < 0 ? -difference : difference;
      dc += previous;
      values[block * 64] = _coefficient(dc);
    }
    var position = blocks - 1;
    var run = 4, level = 1;
    while (bits.hasCode) {
      run = switch (run) {
        <= 1 => bits.golomb(1, riceLevels: 3),
        <= 3 => bits.golomb(1, riceLevels: 2),
        4 => bits.golomb(0),
        <= 8 => bits.golomb(2, riceLevels: 2, riceOrder: 1),
        <= 14 => bits.golomb(1),
        _ => bits.golomb(2),
      };
      position += run + 1;
      if (position >= length) {
        throw const FormatException('ProRes coefficient run exceeds slice');
      }
      level = switch (level) {
        0 => bits.golomb(2, riceLevels: 3),
        1 => bits.golomb(1, riceLevels: 2),
        2 => bits.golomb(1, riceLevels: 3),
        3 => bits.golomb(0),
        <= 7 => bits.golomb(1),
        _ => bits.golomb(2),
      };
      final sign = bits.read(1);
      final coefficient = _coefficient((level + 1) * (1 - 2 * sign));
      final raster = scan[position ~/ blocks];
      final block = position % blocks;
      values[block * 64 + raster] = coefficient;
      rows[block] |= 1 << (raster >> 3);
    }
  }

  int _coefficient(int value) {
    if (value < -32768 || value > 32767) {
      throw const FormatException('Invalid ProRes coefficient magnitude');
    }
    return value;
  }
}

int _signedGolomb(int code) => (code >> 1) ^ -(code & 1);

void _decodeProResAlpha(
  _ProResBits bits,
  Uint16List plane,
  int depth,
  int stride,
  int x,
  int y,
  int rowStep,
  int sliceWidth,
  int rows,
) {
  final mask = (1 << depth) - 1;
  final visible = sliceWidth * rows;
  final columns = math.min(sliceWidth, stride - x);
  var value = mask, position = 0;
  while (position < visible) {
    final delta = bits.read(1) == 1
        ? bits.read(depth)
        : _alphaDelta(bits.read(depth == 8 ? 4 : 7));
    value = (value + delta) & mask;
    var repeat = 1;
    if (bits.read(1) == 0) {
      final short = bits.read(4);
      repeat += short == 0 ? bits.read(11) : short;
    }
    final end = position + repeat;
    // Older encoders extend the alpha data through the padded final row.
    if (end > sliceWidth * 16) {
      throw const FormatException('ProRes alpha run exceeds slice');
    }
    final stop = math.min(end, visible);
    while (position < stop) {
      final column = position % sliceWidth;
      final row = position ~/ sliceWidth;
      final count = math.min(stop - position, sliceWidth - column);
      final write = math.min(count, columns - column);
      if (write > 0) {
        final start = (y + row * rowStep) * stride + x + column;
        plane.fillRange(start, start + write, value);
      }
      position += count;
    }
  }
}

int _alphaDelta(int code) => ((code >> 1) + 1) * (1 - 2 * (code & 1));

final class _ProResBits {
  _ProResBits(this.bytes, int start, this.end) : _index = start {
    var last = end - 1;
    while (last >= start && bytes[last] == 0) {
      last--;
    }
    if (last < start) {
      _lastOne = start * 8;
    } else {
      final byte = bytes[last];
      _lastOne = (last + 1) * 8 - ((byte & -byte).bitLength - 1);
    }
  }

  final Uint8List bytes;
  final int end;
  late final int _lastOne;
  int _index;
  var _cache = 0, _bits = 0;

  bool get empty => _index == end && _bits == 0;
  bool get hasCode => _index * 8 - _bits < _lastOne;

  void _refill() {
    if (_index == end) {
      throw const FormatException('Truncated ProRes component');
    }
    _cache = (_cache << 8) | bytes[_index++];
    _bits += 8;
  }

  int read(int count) {
    while (_bits < count) {
      _refill();
    }
    _bits -= count;
    return (_cache >> _bits) & ((1 << count) - 1);
  }

  int _unary() {
    var zeros = 0;
    while (true) {
      final value = _cache & ((1 << _bits) - 1);
      if (value != 0) {
        final prefix = _bits - value.bitLength;
        _bits -= prefix + 1;
        return zeros + prefix;
      }
      zeros += _bits;
      _bits = 0;
      if (zeros > 24) {
        throw const FormatException('Invalid ProRes Golomb prefix');
      }
      _refill();
    }
  }

  /// The first riceLevels unary prefixes use Rice coding. The remaining
  /// prefixes use an exponential-Golomb code after the Rice codewords.
  int golomb(int expOrder, {int riceLevels = 0, int riceOrder = 0}) {
    final prefix = _unary();
    if (prefix < riceLevels) {
      return (prefix << riceOrder) + read(riceOrder);
    }
    final exp = prefix - riceLevels;
    return (riceLevels << riceOrder) +
        (((1 << exp) - 1) << expOrder) +
        read(exp + expOrder);
  }
}
