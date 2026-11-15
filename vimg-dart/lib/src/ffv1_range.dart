part of 'ffv1.dart';

Uint8List _initialStates(int count) =>
    Uint8List(count)..fillRange(0, count, 128);

final class _RangeDecoder {
  _RangeDecoder(this.bytes, int start, this.end)
    : _low = bytes[start] << 8 | bytes[start + 1],
      _position = start + 2 {
    if (_low >= _range)
      throw const FormatException('Invalid FFV1 range prefix');
  }

  final Uint8List bytes;
  final int end;
  int _position;
  int _low;
  int _range = 0xff00;
  List<int> transitions = _standardTransitions;

  int bit(Uint8List state, int index) {
    final probability = state[index];
    if (probability == 0) {
      throw const FormatException('Invalid FFV1 range probability');
    }
    final split = (_range * probability) >> 8;
    _range -= split;
    final int result;
    if (_low < _range) {
      state[index] = 256 - transitions[256 - probability];
      result = 0;
    } else {
      _low -= _range;
      _range = split;
      state[index] = transitions[probability];
      result = 1;
    }
    if (_range < 256) {
      if (_position > end + 1) {
        throw const FormatException('Truncated FFV1 range payload');
      }
      _range <<= 8;
      _low = (_low << 8) | (_position < end ? bytes[_position] : 0);
      _position++;
    }
    return result;
  }

  int riceStart(bool sentinel) {
    if (sentinel) bit(Uint8List.fromList([129]), 0);
    // The range decoder has already looked ahead by one byte.
    return _position - 1;
  }

  int symbol(Uint8List state, {int offset = 0, bool signed = false}) {
    if (bit(state, offset) != 0) return 0;
    var exponent = 0;
    while (bit(state, offset + 1 + math.min(exponent, 9)) != 0) {
      if (++exponent > 31) throw const FormatException('Oversized FFV1 symbol');
    }
    var magnitude = 1;
    for (var i = exponent - 1; i >= 0; i--) {
      magnitude = (magnitude << 1) | bit(state, offset + 22 + math.min(i, 9));
    }
    return signed && bit(state, offset + 11 + math.min(exponent, 10)) != 0
        ? -magnitude
        : magnitude;
  }
}

int _crc(Uint8List bytes, int start, int end) {
  var value = 0;
  for (var i = start; i < end; i++) {
    value = ((value << 8) & 0xffffffff) ^ _crcTable[(value >> 24) ^ bytes[i]];
  }
  return value;
}

final _crcTable = Uint32List.fromList(
  List.generate(256, (byte) {
    var value = byte << 24;
    for (var bit = 0; bit < 8; bit++) {
      value =
          ((value << 1) & 0xffffffff) ^
          ((value & 0x80000000) == 0 ? 0 : 0x04c11db7);
    }
    return value;
  }),
);

// RFC 9043, section 3.8.1.5.
// dart format off
const _standardTransitions = [
    0,   0,   0,   0,   0,   0,   0,   0,  20,  21,  22,  23,  24,  25,  26,  27,
   28,  29,  30,  31,  32,  33,  34,  35,  36,  37,  37,  38,  39,  40,  41,  42,
   43,  44,  45,  46,  47,  48,  49,  50,  51,  52,  53,  54,  55,  56,  56,  57,
   58,  59,  60,  61,  62,  63,  64,  65,  66,  67,  68,  69,  70,  71,  72,  73,
   74,  75,  75,  76,  77,  78,  79,  80,  81,  82,  83,  84,  85,  86,  87,  88,
   89,  90,  91,  92,  93,  94,  94,  95,  96,  97,  98,  99, 100, 101, 102, 103,
  104, 105, 106, 107, 108, 109, 110, 111, 112, 113, 114, 114, 115, 116, 117, 118,
  119, 120, 121, 122, 123, 124, 125, 126, 127, 128, 129, 130, 131, 132, 133, 133,
  134, 135, 136, 137, 138, 139, 140, 141, 142, 143, 144, 145, 146, 147, 148, 149,
  150, 151, 152, 152, 153, 154, 155, 156, 157, 158, 159, 160, 161, 162, 163, 164,
  165, 166, 167, 168, 169, 170, 171, 171, 172, 173, 174, 175, 176, 177, 178, 179,
  180, 181, 182, 183, 184, 185, 186, 187, 188, 189, 190, 190, 191, 192, 194, 194,
  195, 196, 197, 198, 199, 200, 201, 202, 202, 204, 205, 206, 207, 208, 209, 209,
  210, 211, 212, 213, 215, 215, 216, 217, 218, 219, 220, 220, 222, 223, 224, 225,
  226, 227, 227, 229, 229, 230, 231, 232, 234, 234, 235, 236, 237, 238, 239, 240,
  241, 242, 243, 244, 245, 246, 247, 248, 248,   0,   0,   0,   0,   0,   0,   0,
];
// dart format on
