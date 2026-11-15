part of 'ffv1.dart';

final class _RiceReader {
  _RiceReader(this.bytes, int start, int end)
    : _position = start * 8,
      _end = end * 8;

  final Uint8List bytes;
  final int _end;
  int _position;
  int runIndex = 0;
  int _zeros = 0;
  bool _inRun = false;
  bool _runEnds = false;

  void startLine() {
    _zeros = 0;
    _inRun = false;
    _runEnds = false;
  }

  int difference(
    List<_RiceContext?> states,
    int context,
    int bits,
    int remaining,
  ) {
    if (context == 0) _inRun = true;
    if (_inRun) {
      if (_zeros == 0 && !_runEnds) {
        final shift = _runWidths[runIndex];
        if (_read(1) != 0) {
          _zeros = 1 << shift;
          if (_zeros <= remaining) runIndex++;
        } else {
          _zeros = _read(shift);
          if (runIndex > 0) runIndex--;
          _runEnds = true;
        }
      }
      if (_zeros > 0) {
        _zeros--;
        return 0;
      }
      _inRun = false;
      _runEnds = false;
      final value = _scalar(states[context] ??= _RiceContext(), bits);
      return value < 0 ? value : value + 1;
    }
    return _scalar(states[context] ??= _RiceContext(), bits);
  }

  int _scalar(_RiceContext state, int bits) {
    var k = 0;
    while ((state.count << k) < state.errorSum && k < bits) {
      k++;
    }
    var prefix = 0;
    while (prefix < 12 && _read(1) == 0) {
      prefix++;
    }
    final code = prefix == 12 ? _read(bits) + 11 : (prefix << k) + _read(k);
    var value = code.isOdd ? ~(code >> 1) : code >> 1;
    if (state.drift * 2 < -state.count) value = ~value;
    final difference = (value + state.bias).toSigned(bits);
    state.update(value);
    return difference;
  }

  int _read(int count) {
    if (_position + count > _end) {
      throw const FormatException('Truncated FFV1 Golomb–Rice payload');
    }
    var value = 0;
    for (var bit = 0; bit < count; bit++, _position++) {
      value =
          (value << 1) | ((bytes[_position >> 3] >> (7 - (_position & 7))) & 1);
    }
    return value;
  }
}

final class _RiceContext {
  int count = 1;
  int errorSum = 4;
  int drift = 0;
  int bias = 0;

  void update(int value) {
    errorSum += value.abs();
    drift += value;
    if (count == 128) {
      count >>= 1;
      errorSum >>= 1;
      drift >>= 1;
    }
    count++;
    if (drift <= -count) {
      bias = math.max(bias - 1, -128);
      drift = math.max(drift + count, 1 - count);
    } else if (drift > 0) {
      bias = math.min(bias + 1, 127);
      drift = math.min(drift - count, 0);
    }
  }
}

// RFC 9043, section 3.8.2.2.1.
// dart format off
const _runWidths = [
   0,  0,  0,  0,  1,  1,  1,  1,
   2,  2,  2,  2,  3,  3,  3,  3,
   4,  4,  5,  5,  6,  6,  7,  7,
   8,  9, 10, 11, 12, 13, 14, 15,
  16, 17, 18, 19, 20, 21, 22, 23,
  24,
];
// dart format on
