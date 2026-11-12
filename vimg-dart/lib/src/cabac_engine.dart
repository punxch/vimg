import 'dart:typed_data';

import 'cabac_probability.dart';
import 'rbsp.dart';

/// Binary arithmetic decoding with separate context-adaptive, bypass, and
/// termination paths. Each video codec provides its initial probability models.
base class CabacEngine {
  CabacEngine(this.bits, this._models) {
    restart();
  }

  final Rbsp bits;
  final Uint8List _models;

  Uint8List copyModels() => Uint8List.fromList(_models);

  var _range = 510;
  var _offset = 0;

  void restart() {
    _range = 510;
    _offset = bits.read(9);
    if (_offset >= _range)
      throw FormatException('Invalid ${bits.codec} CABAC initial offset');
  }

  int decision(int context) {
    final model = _models[context];
    final state = model >> 1;
    final mps = model & 1;
    final lps = lpsRanges[(state << 2) | ((_range >> 6) & 3)];
    _range -= lps;
    final int value;
    if (_offset >= _range) {
      value = mps ^ 1;
      _offset -= _range;
      _range = lps;
      _models[context] =
          (nextLpsState[state] << 1) | (state == 0 ? value : mps);
    } else {
      value = mps;
      _models[context] = state < 62 ? model + 2 : model;
    }
    _normalize();
    return value;
  }

  int bypass() {
    _offset = (_offset << 1) | bits.bit();
    if (_offset < _range) return 0;
    _offset -= _range;
    return 1;
  }

  bool terminate() {
    _range -= 2;
    if (_offset >= _range) return true;
    _normalize();
    return false;
  }

  void _normalize() {
    final shift = 9 - _range.bitLength;
    if (shift > 0) {
      _range <<= shift;
      _offset = (_offset << shift) | bits.read(shift);
    }
  }
}

int cabacModel(int slope, int offset, int qp) {
  final pre = (((slope * qp) >> 4) + offset).clamp(1, 126);
  return pre < 64 ? (63 - pre) << 1 : ((pre - 64) << 1) | 1;
}
