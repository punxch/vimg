import 'dart:typed_data';

import 'cabac_tables.dart';
import 'rbsp.dart';

/// H.264 binary arithmetic decoding for progressive slices (§9.3).
final class Cabac {
  Cabac(this.bits, int qp, {int? interInit}) {
    final table = interInit == null
        ? intraContextInit
        : interContextInit[interInit];
    for (var context = 0; context < _models.length; context++) {
      final m = table[context * 2];
      final n = table[context * 2 + 1];
      final pre = (((m * qp) >> 4) + n).clamp(1, 126);
      // Store pStateIdx in the high bits and valMPS in the low bit.
      _models[context] = pre < 64 ? (63 - pre) << 1 : ((pre - 64) << 1) | 1;
    }
    restart();
  }

  final Rbsp bits;
  final _models = Uint8List(intraContextInit.length ~/ 2);
  var _range = 510;
  var _offset = 0;

  void restart() {
    _range = 510;
    _offset = bits.read(9);
    if (_offset >= _range)
      throw const FormatException('Invalid H.264 CABAC initial offset');
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

  int coefficientSuffix() {
    var prefix = 0;
    while (bypass() != 0) {
      if (++prefix > 16)
        throw const FormatException('Oversized H.264 coefficient');
    }
    var suffix = 0;
    for (var bit = 0; bit < prefix; bit++) {
      suffix = (suffix << 1) | bypass();
    }
    return (1 << prefix) - 1 + suffix;
  }
}
