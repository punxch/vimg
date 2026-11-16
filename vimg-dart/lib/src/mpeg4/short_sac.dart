part of 'decoder.dart';

// Annex E uses a fixed model for each syntactic element and a fresh
// 16-bit interval at each picture, GOB or structured slice header.
final class _H263Sac {
  _H263Sac(this.bits) {
    reset();
  }

  final Rbsp bits;
  int _low = 0, _high = 0xffff, _value = 0, _zeroRun = 0, _padding = 0;

  void reset() {
    _low = _value = _zeroRun = _padding = 0;
    _high = 0xffff;
    for (var i = 0; i < 16; i++) {
      _value = (_value << 1) | _bit();
    }
  }

  int read(List<int> frequencies) {
    final total = frequencies.first;
    final range = _high - _low + 1;
    final scaled = ((_value - _low + 1) * total - 1) ~/ range;
    var lower = 0, upper = frequencies.length - 1;
    while (upper - lower > 1) {
      final mid = (lower + upper) >> 1;
      if (frequencies[mid] > scaled) {
        lower = mid;
      } else {
        upper = mid;
      }
    }
    _high = _low + range * frequencies[lower] ~/ total - 1;
    _low += range * frequencies[upper] ~/ total;
    while (true) {
      final int middle;
      if (_high < 0x8000) {
        middle = 0;
      } else if (_low >= 0x8000) {
        middle = 0x8000;
      } else if (_low >= 0x4000 && _high < 0xc000) {
        middle = 0x4000;
      } else {
        return lower;
      }
      _low = (_low - middle) << 1;
      _high = ((_high - middle) << 1) | 1;
      _value = ((_value - middle) << 1) | _bit();
    }
  }

  int _bit() {
    if (_atEndOfSegment()) return _pad();
    var bit = bits.bit();
    // The encoder inserts a one after every fourteen data zeroes so
    // the interval reader can distinguish arithmetic data from start codes.
    if (_zeroRun == 14) {
      _zeroRun = 0;
      if (bit == 1) {
        if (_atEndOfSegment()) return _pad();
        bit = bits.bit();
      }
    }
    _zeroRun = bit == 0 ? _zeroRun + 1 : 0;
    return bit;
  }

  bool _atEndOfSegment() {
    if (bits.remaining < 17) return bits.remaining == 0;
    final start = bits.position;
    final marker = bits.read(17) == 1;
    bits.position = start;
    return marker;
  }

  int _pad() {
    // Lookahead can reach a header or the end of a packet before the
    // last arithmetic symbol ends. The header stays in the raw reader.
    if (++_padding > 16) {
      throw const FormatException('Truncated H.263 arithmetic data');
    }
    return 0;
  }

  _Vector motion(_Vector predictor, bool long) => (
    x: _addMotionDifference(predictor.x, read(_sacMotion) - 32, 32, long),
    y: _addMotionDifference(predictor.y, read(_sacMotion) - 32, 32, long),
  );

  _DctEvent event(int number, {required bool intra, required bool advanced}) {
    final model = (intra
        ? _sacIntraCoefficients
        : _sacInterCoefficients)[number];
    final index = read(model);
    if (index == interRuns.length) {
      final last = read(intra ? _sacIntraLast : _sacInterLast) != 0;
      final run = read(intra ? _sacIntraRun : _sacInterRun);
      final level = read(intra ? _sacIntraLevel : _sacInterLevel);
      return (run: run, value: level - (level < 127 ? 127 : 126), last: last);
    }
    final table = advanced ? _aicEvents : _interEvents;
    final code = advanced ? _sacAdvancedIndices[index] : index;
    final sign = read(_sacSign) == 0 ? 1 : -1;
    return (
      run: table._runs[code],
      value: table._levels[code] * sign,
      last: code >= table._firstLast,
    );
  }
}

const _sacInterCoefficients = [
  _sacInterFirst,
  _sacInterSecond,
  _sacInterThird,
  _sacInterRest,
];
const _sacIntraCoefficients = [
  _sacIntraFirst,
  _sacIntraSecond,
  _sacIntraThird,
  _sacIntraRest,
];

// Advanced intra coding assigns new runs and levels to the same Table 16
// codewords. Look up that assignment in the existing Annex I VLC table.
final _sacAdvancedIndices = [
  for (var i = 0; i < interRuns.length * 2; i += 2)
    _aicEvents._vlc._values[(1 << interCoefficients[i + 1]) |
        interCoefficients[i]]!,
];
