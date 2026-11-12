import 'dart:math' as math;
import 'dart:typed_data';

import 'cavlc_tables.dart';
import 'rbsp.dart';

/// H.264 §9.2 coefficient levels in scan order. The stride interleaves the
/// four CAVLC residual blocks of an 8×8 transform into its zigzag sequence.
final class Cavlc {
  Cavlc(this.bits);

  final Rbsp bits;
  final _levels = Int32List(16);

  int residual(
    Int32List output,
    int offset,
    int length,
    int context, {
    int stride = 1,
  }) {
    final token = _token(context);
    final total = token >> 2;
    final trailing = token & 3;
    if (total > length || trailing > total) {
      throw const FormatException('Invalid H.264 CAVLC coefficient token');
    }
    if (total == 0) return 0;
    for (var i = 0; i < trailing; i++) {
      _levels[i] = 1 - 2 * bits.bit();
    }
    var suffixLength = total > 10 && trailing < 3 ? 1 : 0;
    for (var i = trailing; i < total; i++) {
      var code = _levelCode(suffixLength);
      if (i == trailing && trailing < 3) code += 2;
      final magnitude = (code >> 1) + 1;
      _levels[i] = code.isEven ? magnitude : -magnitude;
      if (suffixLength == 0) suffixLength = 1;
      if (suffixLength < 6 && magnitude > (3 << (suffixLength - 1))) {
        suffixLength++;
      }
    }

    final zeroTable = length == 4 ? _chromaZeros : _totalZeros;
    var zeros = total == length ? 0 : zeroTable[total - 1].read(bits);
    if (total + zeros > length) {
      throw const FormatException('Invalid H.264 CAVLC zero count');
    }
    var position = total + zeros - 1;
    for (var i = 0; i < total; i++) {
      output[offset + stride * position] = _levels[i];
      final run = zeros > 0 && i + 1 < total
          ? _runBefore[math.min(zeros, 7) - 1].read(bits)
          : 0;
      if (run > zeros) throw const FormatException('Invalid H.264 CAVLC run');
      position -= run + 1;
      zeros -= run;
    }
    return total;
  }

  int _token(int context) {
    if (context >= 8) {
      final word = bits.read(6);
      return word == 3 ? 0 : word + 4;
    }
    final table = switch (context) {
      -1 => 3, // 4:2:0 chroma DC
      < 2 => 0,
      < 4 => 1,
      _ => 2,
    };
    return _coeffTokens[table].read(bits);
  }

  int _levelCode(int suffixLength) {
    var prefix = 0;
    while (!bits.flag()) {
      if (++prefix > 28)
        throw const FormatException('Oversized H.264 CAVLC level');
    }
    final suffixSize = switch (prefix) {
      14 when suffixLength == 0 => 4,
      >= 15 => prefix - 3,
      _ => suffixLength,
    };
    var code = (math.min(prefix, 15) << suffixLength) + bits.read(suffixSize);
    if (prefix >= 15 && suffixLength == 0) code += 15;
    if (prefix >= 16) code += (1 << (prefix - 3)) - 4096;
    return code;
  }
}

final _coeffTokens = coeffTokenWords.map(_Vlc.new).toList();
final _totalZeros = totalZeroWords.map(_Vlc.new).toList();
final _chromaZeros = chromaZeroWords.map(_Vlc.new).toList();
final _runBefore = runBeforeWords.map(_Vlc.new).toList();

final class _Vlc {
  _Vlc(List<int> words)
    : _symbols = {
        for (var i = 0; i < words.length; i++)
          if (words[i] != 0) words[i]: i,
      },
      _limit = words.reduce(math.max).bitLength - 1;

  final Map<int, int> _symbols;
  final int _limit;

  int read(Rbsp bits) {
    var word = 1;
    for (var i = 0; i < _limit; i++) {
      word = (word << 1) | bits.bit();
      final symbol = _symbols[word];
      if (symbol != null) return symbol;
    }
    throw const FormatException('Invalid H.264 CAVLC codeword');
  }
}
