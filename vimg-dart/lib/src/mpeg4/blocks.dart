part of 'decoder.dart';

final class _Vlc {
  _Vlc(List<int> words)
    : _values = {
        for (var i = 0; i < words.length; i += 2)
          if (words[i + 1] != 0) (1 << words[i + 1]) | words[i]: i >> 1,
      };

  final Map<int, int> _values;

  int read(Rbsp bits, {bool leadingZero = false}) {
    var key = leadingZero ? 2 : 1;
    for (var count = leadingZero ? 1 : 0; count < 16; count++) {
      key = (key << 1) | bits.bit();
      if (_values[key] case final index?) return index;
    }
    throw const FormatException('Invalid MPEG-4 VLC');
  }
}

final _intraMacroblock = _Vlc(intraMacroblock);
final _interMacroblock = _Vlc(interMacroblock);
final _bMacroblock = _Vlc(bMacroblockType);
final _lumaPattern = _Vlc(lumaPattern);
final _lumaDc = _Vlc(lumaDc), _chromaDc = _Vlc(chromaDc);
final _motionCode = _Vlc(motionCode);

final _intraEvents = _Events(intraCoefficients, intraRuns, intraLevels, 67);
final _interEvents = _Events(interCoefficients, interRuns, interLevels, 58);
final _intraReversibleEvents = _Events(
  intraReversibleCoefficients,
  intraReversibleRuns,
  intraReversibleLevels,
  103,
  reversible: true,
);
final _interReversibleEvents = _Events(
  interReversibleCoefficients,
  interReversibleRuns,
  interReversibleLevels,
  103,
  reversible: true,
);

typedef _DctEvent = ({int run, int value, bool last});

final class _Events {
  _Events(
    List<int> words,
    this._runs,
    this._levels,
    this._firstLast, {
    bool reversible = false,
  }) : _reversible = reversible,
       _vlc = _Vlc(words) {
    if (reversible) return;
    for (var i = 0; i < _runs.length; i++) {
      final plane = i >= _firstLast ? 64 : 0;
      final run = _runs[i], level = _levels[i];
      _maxLevel[plane + run] = math.max(_maxLevel[plane + run], level);
      _maxRun[plane + level] = math.max(_maxRun[plane + level], run);
    }
  }

  final _Vlc _vlc;
  final List<int> _runs, _levels;
  final int _firstLast;
  final bool _reversible;
  final _maxLevel = Uint8List(128), _maxRun = Uint8List(128);

  _DctEvent read(Rbsp bits) {
    var code = _vlc.read(bits);
    var extendedLevel = false, extendedRun = false;
    if (code == _runs.length) {
      if (_reversible) {
        mpeg4Marker(bits);
        final last = bits.flag(), run = bits.read(6);
        mpeg4Marker(bits);
        final level = bits.read(11);
        if (level == 0 || bits.read(5) != 0x10) {
          throw const FormatException('Invalid MPEG-4 reversible VLC escape');
        }
        return (run: run, value: bits.flag() ? -level : level, last: last);
      } else if (!bits.flag()) {
        extendedLevel = true;
      } else if (!bits.flag()) {
        extendedRun = true;
      } else {
        final last = bits.flag(), run = bits.read(6);
        mpeg4Marker(bits);
        final unsigned = bits.read(12);
        final value = unsigned >= 2048 ? unsigned - 4096 : unsigned;
        mpeg4Marker(bits);
        if (value == 0 || value == -2048)
          throw const FormatException('Invalid MPEG-4 escape level');
        return (run: run, value: value, last: last);
      }
      code = _vlc.read(bits);
      if (code == _runs.length)
        throw const FormatException('Nested MPEG-4 escape');
    }
    final last = code >= _firstLast;
    final table = last ? 64 : 0;
    final run = _runs[code], level = _levels[code];
    final value = extendedLevel ? level + _maxLevel[table + run] : level;
    return (
      run: extendedRun ? run + 1 + _maxRun[table + level] : run,
      value: bits.flag() ? -value : value,
      last: last,
    );
  }

  _DctEvent readReverse(_ReverseTextureBits bits) {
    final negative = bits.read(1) != 0;
    var word = 0;
    for (var length = 1; length <= 15; length++) {
      word |= bits.read(1) << (length - 1);
      if (length == 5 && word == 0x10) {
        final level = bits.read(11);
        if (level == 0 || bits.read(1) != 1) break;
        final run = bits.read(6), last = bits.read(1) != 0;
        if (bits.read(1) != 1 || bits.read(4) != 0) break;
        return (run: run, value: negative ? -level : level, last: last);
      }
      final code = _vlc._values[(1 << length) | word];
      // The escape opens with 0000 in the forward direction only.
      if (code != null && code < _runs.length) {
        final level = _levels[code];
        return (
          run: _runs[code],
          value: negative ? -level : level,
          last: code >= _firstLast,
        );
      }
    }
    throw const FormatException('Invalid MPEG-4 reverse VLC');
  }
}

int _nextCoefficient(int position, _DctEvent event) {
  position += event.run + 1;
  if (position >= 64) {
    throw const FormatException('MPEG-4 run exceeds the block');
  }
  return position;
}

typedef _IntraBlock = ({int dc, int quant, Int16List edges});

int _readDcDifference(Rbsp bits, bool luma) {
  final size = (luma ? _lumaDc : _chromaDc).read(bits);
  if (size == 0) return 0;
  final value = bits.read(size);
  if (size > 8) mpeg4Marker(bits);
  return value < (1 << (size - 1)) ? value + 1 - (1 << size) : value;
}

extension _DctBlocks on _VopDecoder {
  void _readBlock(
    int x,
    int y,
    int block, {
    required bool coded,
    required bool intra,
    bool separateDc = false,
    bool acPrediction = false,
    bool fieldDct = false,
    int? dcDifference,
    List<_DctEvent>? texture,
  }) {
    final luma = block < 4;
    final plane = luma ? 0 : block - 3;
    final subX = luma ? 1 : 0;
    final bx = (x << subX) + (luma ? block & 1 : 0);
    final by = (y << subX) + (luma ? block >> 1 : 0);
    final columns = _columns << subX;
    final values = _coefficients..fillRange(0, 64, 0);
    final _IntraBlock? neighbor;
    var predictTop = false;
    var dc = 0;
    if (intra) {
      _IntraBlock? at(int column, int row) {
        if (column < 0 ||
            row < 0 ||
            (row >> subX) * _columns + (column >> subX) < _sliceStart)
          return null;
        return _intra[plane][row * columns + column];
      }

      final left = at(bx - 1, by), top = at(bx, by - 1);
      final diagonal = at(bx - 1, by - 1)?.dc ?? 1024;
      predictTop =
          ((left?.dc ?? 1024) - diagonal).abs() <
          (diagonal - (top?.dc ?? 1024)).abs();
      neighbor = predictTop ? top : left;
      dc = neighbor?.dc ?? 1024;
      if (separateDc) {
        values[0] = dcDifference ?? _readDcDifference(_bits, luma);
      }
    } else {
      neighbor = null;
    }

    final scan = header.alternateScan || acPrediction && !predictTop
        ? verticalScan
        : acPrediction
        ? horizontalScan
        : mpegZigzag;
    if (coded) {
      final reversible =
          header.volume.reversibleVlc &&
          header.type != Mpeg4PictureType.bidirectional;
      final events = reversible
          ? (intra ? _intraReversibleEvents : _interReversibleEvents)
          : (intra ? _intraEvents : _interEvents);
      var position = separateDc ? 0 : -1;
      var index = 0;
      while (true) {
        final event = texture == null ? events.read(_bits) : texture[index++];
        position = _nextCoefficient(position, event);
        values[scan[position]] = event.value;
        if (event.last) break;
      }
    }
    if (intra) {
      final scale = _quant < 32
          ? (luma ? lumaDcScale : chromaDcScale)[_quant]
          : luma
          ? _quant * 2 - 16
          : _quant - 6;
      final absolute = (values[0] + ((dc + (scale >> 1)) ~/ scale)) * scale;
      if (acPrediction && neighbor != null) {
        for (var i = 1; i < 8; i++) {
          final position = predictTop ? i : i * 8;
          final previous = neighbor.edges[predictTop ? i : 8 + i];
          final scaled = previous.abs() * neighbor.quant + (_quant >> 1);
          values[position] += previous.sign * (scaled ~/ _quant);
        }
      }
      final edges = Int16List(16);
      for (var i = 1; i < 8; i++) {
        edges[i] = values[i];
        edges[8 + i] = values[8 * i];
      }
      _intra[plane][by * columns + bx] = (
        dc: absolute.clamp(0, 2047),
        quant: _quant,
        edges: edges,
      );
      values[0] = absolute.clamp(-2048, 2047);
    }

    final matrix = intra
        ? header.volume.intraMatrix
        : header.volume.interMatrix;
    var parity = intra ? values[0] : 0;
    for (var i = intra ? 1 : 0; i < 64; i++) {
      final q = values[i];
      if (q == 0) continue;
      final level = q.abs();
      final magnitude = matrix == null
          ? 2 * level * _quant + ((_quant - 1) | 1)
          : intra
          ? (level * _quant * matrix[i]) >> 3
          : ((2 * level + 1) * _quant * matrix[i]) >> 4;
      values[i] = (q.sign * magnitude).clamp(-2048, 2047);
      parity ^= values[i];
    }
    if (matrix != null && !intra) values[63] ^= ((parity & 1) ^ 1);
    final stride = luma ? picture.stride : picture.stride >> 1;
    final interleaved = luma && fieldDct;
    final row = interleaved ? y * 16 + (block >> 1) : by * 8;
    _transform.write(
      picture.planes[plane],
      row * stride + bx * 8,
      interleaved ? stride * 2 : stride,
      values,
      intra,
    );
  }
}
