part of 'decoder.dart';

final class _Entropy {
  _Entropy()
    : coefficients = _copyCoefficients(kCoeffsProba0),
      mv = [for (final values in _defaultMv) List<int>.of(values)],
      luma = [112, 86, 140, 37],
      chroma = [162, 101, 204];

  _Entropy._(this.coefficients, this.mv, this.luma, this.chroma);

  final List<List<List<List<int>>>> coefficients;
  final List<List<int>> mv;
  final List<int> luma, chroma;

  _Entropy copy() => _Entropy._(
    _copyCoefficients(coefficients),
    [for (final values in mv) List<int>.of(values)],
    List<int>.of(luma),
    List<int>.of(chroma),
  );

  void updateCoefficients(_BoolReader bits) {
    for (var type = 0; type < 4; type++) {
      for (var band = 0; band < 8; band++) {
        for (var context = 0; context < 3; context++) {
          final target = coefficients[type][band][context];
          final update = kCoeffsUpdateProba[type][band][context];
          for (var node = 0; node < 11; node++) {
            if (bits.bit(update[node]) != 0) target[node] = bits.read(8);
          }
        }
      }
    }
  }

  void updateInter(_BoolReader bits) {
    for (final probabilities in [luma, chroma]) {
      if (bits.bit() == 0) continue;
      for (var i = 0; i < probabilities.length; i++) {
        probabilities[i] = bits.read(8);
      }
    }
    for (var component = 0; component < 2; component++) {
      for (var node = 0; node < 19; node++) {
        if (bits.bit(_updateMv[component][node]) != 0) {
          final value = bits.read(7);
          mv[component][node] = value == 0 ? 1 : value << 1;
        }
      }
    }
  }

  static List<List<List<List<int>>>> _copyCoefficients(
    List<List<List<List<int>>>> from,
  ) => [
    for (final type in from)
      [
        for (final band in type) [for (final c in band) List<int>.of(c)],
      ],
  ];
}

final class _Segments {
  bool enabled = false, updateMap = false, absolute = false;
  final _quant = Int8List(4), _filter = Int8List(4);
  final _prob = Uint8List(3);
  late Uint8List _map;

  void reset(int macroblocks) {
    enabled = updateMap = absolute = false;
    _quant.fillRange(0, 4, 0);
    _filter.fillRange(0, 4, 0);
    _map = Uint8List(macroblocks);
  }

  void read(_BoolReader bits) {
    enabled = bits.bit() != 0;
    updateMap = enabled && bits.bit() != 0;
    if (!enabled) return;
    if (bits.bit() != 0) {
      absolute = bits.bit() != 0;
      for (var i = 0; i < 4; i++) {
        _quant[i] = bits.optionalSigned(7);
      }
      for (var i = 0; i < 4; i++) {
        _filter[i] = bits.optionalSigned(6);
      }
    }
    if (updateMap) {
      for (var i = 0; i < 3; i++) {
        _prob[i] = bits.bit() != 0 ? bits.read(8) : 255;
      }
    }
  }

  int at(_BoolReader bits, int index) {
    if (!enabled) return 0;
    if (updateMap) {
      final high = bits.bit(_prob[0]);
      _map[index] = 2 * high + bits.bit(_prob[1 + high]);
    }
    return _map[index];
  }

  int quant(int segment, int base) => _adjust(base, _quant[segment]);
  int filter(int segment, int base) => _adjust(base, _filter[segment]);
  int _adjust(int base, int value) => !enabled
      ? base
      : absolute
      ? value
      : base + value;
}

typedef _Factor = (int, int);

final class _Quant {
  _Quant(int base, List<int> delta)
    : y = (
        kDcTable[(base + delta[0]).clamp(0, 127)],
        kAcTable[base.clamp(0, 127)],
      ),
      dc = (
        2 * kDcTable[(base + delta[1]).clamp(0, 127)],
        math.max(8, (kAcTable[(base + delta[2]).clamp(0, 127)] * 155) ~/ 100),
      ),
      uv = (
        kDcTable[(base + delta[3]).clamp(0, 117)],
        kAcTable[(base + delta[4]).clamp(0, 127)],
      );

  final _Factor y, dc, uv;
}

final class _Block {
  int segment = 0, reference = 0;
  int yMode = dcPred, uvMode = dcPred;
  Uint8List? subModes;
  final bottom = Uint8List(8), right = Uint8List(8);
  int bottomDc = 0, rightDc = 0;
  bool filterInner = false, zeroMotion = false;
  _Vector mv = (0, 0);
  List<_Vector>? split;

  _Vector vector(int block) => split?[block] ?? mv;

  void readIntra(
    _BoolReader bits,
    bool key,
    _Entropy entropy,
    _Block left,
    _Block above,
  ) {
    if (key) {
      yMode = bits.bit(145) == 0
          ? bPred
          : bits.bit(156) == 0
          ? (bits.bit(163) == 0 ? dcPred : vPred)
          : (bits.bit() == 0 ? hPred : tmPred);
    } else {
      final p = entropy.luma;
      yMode = bits.bit(p[0]) == 0
          ? dcPred
          : bits.bit(p[1]) == 0
          ? (bits.bit(p[2]) == 0 ? vPred : hPred)
          : (bits.bit(p[3]) == 0 ? tmPred : bPred);
    }
    if (yMode == bPred) {
      final modes = Uint8List(16);
      for (var i = 0; i < 16; i++) {
        final x = i & 3, y = i >> 2;
        final topMode = y == 0
            ? (above.subModes?[12 + x] ?? above.yMode)
            : modes[i - 4];
        final leftMode = x == 0
            ? (left.subModes?[y * 4 + 3] ?? left.yMode)
            : modes[i - 1];
        final prob = key ? kBModesProba[topMode][leftMode] : _interIntra4;
        var node = 0;
        do {
          node = kYModesIntra4[2 * node + bits.bit(prob[node])];
        } while (node > 0);
        modes[i] = -node;
      }
      subModes = modes;
    }
    final p = key ? const [142, 114, 183] : entropy.chroma;
    uvMode = bits.bit(p[0]) == 0
        ? dcPred
        : bits.bit(p[1]) == 0
        ? vPred
        : bits.bit(p[2]) == 0
        ? hPred
        : tmPred;
  }
}

const _interIntra4 = [120, 90, 79, 133, 87, 85, 80, 111, 151];

Int16List _readResiduals(
  _BoolReader reader,
  _Entropy entropy,
  _Quant quant,
  _Block block,
  _Block above,
  _Block left,
  bool skip,
) {
  final coefficients = Int16List(24 * 16);
  final y2 = block.subModes == null && block.split == null;
  if (!y2) {
    block.bottomDc = above.bottomDc;
    block.rightDc = left.rightDc;
  }
  block.filterInner = block.subModes != null || block.split != null;
  if (skip) return coefficients;
  if (y2) {
    final dc = Int16List(16);
    final hasDc = _readCoefficients(
      reader,
      entropy.coefficients[1],
      dc,
      0,
      0,
      above.bottomDc + left.rightDc,
      quant.dc,
    );
    block.bottomDc = block.rightDc = hasDc ? 1 : 0;
    if (hasDc) {
      _walsh(dc, coefficients);
      block.filterInner = true;
    }
  }
  for (var plane = 0; plane < 3; plane++) {
    final columns = plane == 0 ? 4 : 2;
    final base = plane == 0 ? 0 : 12 + 4 * plane;
    final edgeBase = plane == 0 ? 0 : 2 + 2 * plane;
    final type = plane != 0
        ? 2
        : y2
        ? 0
        : 3;
    final first = plane == 0 && y2 ? 1 : 0;
    final factor = plane == 0 ? quant.y : quant.uv;
    final tops = Uint8List.fromList(
      above.bottom.sublist(edgeBase, edgeBase + columns),
    );
    for (var y = 0; y < columns; y++) {
      var preceding = left.right[edgeBase + y];
      for (var x = 0; x < columns; x++) {
        final nz = _readCoefficients(
          reader,
          entropy.coefficients[type],
          coefficients,
          (base + y * columns + x) * 16,
          first,
          preceding + tops[x],
          factor,
        );
        preceding = tops[x] = nz ? 1 : 0;
        block.filterInner |= nz;
      }
      block.right[edgeBase + y] = preceding;
    }
    block.bottom.setRange(edgeBase, edgeBase + columns, tops);
  }
  return coefficients;
}

bool _readCoefficients(
  _BoolReader reader,
  List<List<List<int>>> bands,
  Int16List out,
  int offset,
  int start,
  int context,
  _Factor factors,
) {
  var nonzero = false;
  var probability = bands[kBands[start]][context];
  for (var position = start; position < 16; position++) {
    if (reader.bit(probability[0]) == 0) break;
    while (reader.bit(probability[1]) == 0) {
      if (++position == 16) return nonzero;
      probability = bands[kBands[position]][0];
    }
    final level = reader.bit(probability[2]) == 0
        ? 1
        : _coefficientValue(reader, probability);
    final signed = reader.bit() == 0 ? level : -level;
    out[offset + kZigzag[position]] =
        signed * (position == 0 ? factors.$1 : factors.$2);
    nonzero = true;
    probability = bands[kBands[position + 1]][level == 1 ? 1 : 2];
  }
  return nonzero;
}

int _coefficientValue(_BoolReader reader, List<int> p) {
  if (reader.bit(p[3]) == 0) {
    return reader.bit(p[4]) == 0 ? 2 : 3 + reader.bit(p[5]);
  }
  if (reader.bit(p[6]) == 0) {
    return reader.bit(p[7]) == 0
        ? 5 + reader.bit(159)
        : 7 + 2 * reader.bit(165) + reader.bit(145);
  }
  final upper = reader.bit(p[8]);
  final category = 2 * upper + reader.bit(p[9 + upper]);
  var extra = 0;
  for (final prob in kCat3456[category]) {
    extra = (extra << 1) | reader.bit(prob);
  }
  return (8 << category) + 3 + extra;
}

void _walsh(Int16List input, Int16List output) {
  final intermediate = Int32List(16);
  for (var x = 0; x < 4; x++) {
    final ends = input[x] + input[12 + x], inner = input[4 + x] + input[8 + x];
    final diff = input[x] - input[12 + x], middle = input[4 + x] - input[8 + x];
    intermediate[x] = ends + inner;
    intermediate[4 + x] = diff + middle;
    intermediate[8 + x] = ends - inner;
    intermediate[12 + x] = diff - middle;
  }
  for (var i = 0; i < 16; i += 4) {
    final a = intermediate[i], b = intermediate[i + 1];
    final c = intermediate[i + 2], d = intermediate[i + 3];
    output[i * 16] = (a + d + b + c + 3) >> 3;
    output[(i + 1) * 16] = (a - d + b - c + 3) >> 3;
    output[(i + 2) * 16] = (a + d - b - c + 3) >> 3;
    output[(i + 3) * 16] = (a - d - b + c + 3) >> 3;
  }
}

final class _LoopFilter {
  bool simple = false, useDelta = false;
  int level = 0, sharpness = 0;
  final _referenceDelta = Int8List(4), _modeDelta = Int8List(4);

  void reset() {
    _referenceDelta.fillRange(0, 4, 0);
    _modeDelta.fillRange(0, 4, 0);
  }

  void read(_BoolReader header) {
    simple = header.bit() != 0;
    level = header.read(6);
    sharpness = header.read(3);
    useDelta = header.bit() != 0;
    if (useDelta && header.bit() != 0) {
      for (final deltas in [_referenceDelta, _modeDelta]) {
        for (var i = 0; i < 4; i++) {
          if (header.bit() == 0) continue;
          final magnitude = header.read(6);
          deltas[i] = header.bit() == 0 ? magnitude : -magnitude;
        }
      }
    }
  }

  void apply(
    Vp8Picture picture,
    VP8Filter dsp,
    _Segments segments,
    List<_Block> blocks,
    bool key,
  ) {
    if (level == 0) return;
    final stride = picture.y.width, columns = stride >> 4;
    final y = picture.y.samples, u = picture.u.samples, v = picture.v.samples;
    final uvStride = picture.u.width;
    for (final (i, block) in blocks.indexed) {
      var strength = segments.filter(block.segment, level);
      if (useDelta) {
        strength += _referenceDelta[block.reference];
        if (block.reference != 0) {
          strength +=
              _modeDelta[block.split != null
                  ? 3
                  : block.zeroMotion
                  ? 1
                  : 2];
        } else if (block.subModes != null) {
          strength += _modeDelta[0];
        }
      }
      strength = strength.clamp(0, 63);
      if (strength == 0) continue;
      var innerLevel = strength;
      if (sharpness != 0) {
        innerLevel = math.min(
          9 - sharpness,
          strength >> (sharpness > 4 ? 2 : 1),
        );
      }
      innerLevel = math.max(1, innerLevel);
      final limit = 2 * strength + innerLevel;
      final hev = strength >= 40
          ? (key ? 2 : 3)
          : !key && strength >= 20
          ? 2
          : strength >= 15
          ? 1
          : 0;
      final x = i % columns, row = i ~/ columns;
      final yo = (row * stride + x) * 16;
      final co = (row * uvStride + x) * 8;
      final inner = block.filterInner;
      if (simple) {
        if (x != 0) dsp.simpleHFilter16(y, yo, stride, limit + 4);
        if (inner) dsp.simpleHFilter16i(y, yo, stride, limit);
        if (row != 0) dsp.simpleVFilter16(y, yo, stride, limit + 4);
        if (inner) dsp.simpleVFilter16i(y, yo, stride, limit);
      } else {
        if (x != 0) {
          dsp.hFilter16(y, yo, stride, limit + 4, innerLevel, hev);
          dsp.hFilter8(u, co, v, co, uvStride, limit + 4, innerLevel, hev);
        }
        if (inner) {
          dsp.hFilter16i(y, yo, stride, limit, innerLevel, hev);
          dsp.hFilter8i(u, co, v, co, uvStride, limit, innerLevel, hev);
        }
        if (row != 0) {
          dsp.vFilter16(y, yo, stride, limit + 4, innerLevel, hev);
          dsp.vFilter8(u, co, v, co, uvStride, limit + 4, innerLevel, hev);
        }
        if (inner) {
          dsp.vFilter16i(y, yo, stride, limit, innerLevel, hev);
          dsp.vFilter8i(u, co, v, co, uvStride, limit, innerLevel, hev);
        }
      }
    }
  }
}
