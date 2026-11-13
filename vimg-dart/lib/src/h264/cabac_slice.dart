part of 'slice_data.dart';

enum _Residual {
  lumaDc(85, 105, 166, 227),
  lumaAc(89, 120, 181, 237),
  luma4(93, 134, 195, 247),
  chromaDc(97, 149, 210, 257),
  chromaAc(101, 152, 213, 266),
  luma8(0, 402, 417, 426);

  const _Residual(this.coded, this.significant, this.last, this.level);

  final int coded, significant, last, level;
}

final class CabacSlice extends SliceData {
  CabacSlice(SliceHeader header)
    : _cabac = Cabac(
        header.bits,
        header.qp,
        interInit: header.kind == SliceKind.intra ? null : header.cabacInit,
      ),
      super(header);

  final Cabac _cabac;
  final _positions = Uint8List(64);

  @override
  bool endOfSlice() => _cabac.terminate();

  @override
  void _restartAfterPcm() => _cabac.restart();

  @override
  bool _skip(Macroblock? left, Macroblock? top) {
    final base = header.kind == SliceKind.b ? 24 : 11;
    return _cabac.decision(
          base +
              _count(
                left != null && !left.skipped,
                top != null && !top.skipped,
              ),
        ) !=
        0;
  }

  @override
  int _pType() {
    if (_cabac.decision(14) != 0) return 5;
    return _cabac.decision(15) == 0
        ? 3 * _cabac.decision(16)
        : 2 - _cabac.decision(17);
  }

  @override
  bool _transformFlag(Macroblock? left, Macroblock? top) =>
      _cabac.decision(
        399 + _count(left?.transform8x8 == true, top?.transform8x8 == true),
      ) !=
      0;

  @override
  int? _intraRemainder() {
    if (_cabac.decision(68) != 0) return null;
    return _cabac.decision(69) |
        (_cabac.decision(69) << 1) |
        (_cabac.decision(69) << 2);
  }

  @override
  (int, int) _motionDelta(MotionField field, MotionPartition part, int owner) {
    final left = field.differenceAt(part.x - 1, part.y, owner);
    final top = field.differenceAt(part.x, part.y - 1, owner);
    return (
      _motionDifference(40, left.x.abs() + top.x.abs()),
      _motionDifference(47, left.y.abs() + top.y.abs()),
    );
  }

  @override
  int _pSubType() {
    if (_cabac.decision(21) != 0) return 0;
    if (_cabac.decision(22) == 0) return 1;
    return _cabac.decision(23) != 0 ? 2 : 3;
  }

  @override
  int _bType(int context) {
    if (_cabac.decision(27 + context) == 0) return 0;
    if (_cabac.decision(30) == 0) return 1 + _cabac.decision(32);
    var prefix = _cabac.decision(31);
    for (var i = 0; i < 3; i++) {
      prefix = (prefix << 1) | _cabac.decision(32);
    }
    return switch (prefix) {
      < 8 => prefix + 3,
      13 => 23,
      14 => 11,
      15 => 22,
      _ => (prefix << 1) + _cabac.decision(32) - 4,
    };
  }

  @override
  int _bSubType() {
    if (_cabac.decision(36) == 0) return 0;
    if (_cabac.decision(37) == 0) return 1 + _cabac.decision(39);
    var offset = 3;
    if (_cabac.decision(38) != 0) {
      if (_cabac.decision(39) != 0) return 11 + _cabac.decision(39);
      offset = 7;
    }
    return offset + 2 * _cabac.decision(39) + _cabac.decision(39);
  }

  @override
  int _referenceIndex(int context, int active) {
    if (active == 1) return 0;
    var index = 0;
    while (_cabac.decision(54 + context) != 0) {
      if (++index >= active) {
        throw const FormatException('H.264 reference index is out of range');
      }
      context = (context >> 2) + 4;
    }
    return index;
  }

  int _motionDifference(int base, int difference) {
    final context = difference > 32 ? 2 : (difference > 2 ? 1 : 0);
    if (_cabac.decision(base + context) == 0) return 0;
    var magnitude = 1;
    while (magnitude < 9 &&
        _cabac.decision(base + 3 + math.min(3, magnitude - 1)) != 0) {
      magnitude++;
    }
    if (magnitude == 9) {
      var bits = 3;
      while (_cabac.bypass() != 0) {
        magnitude += 1 << bits++;
        if (bits >= 16)
          throw const FormatException(
            'Oversized H.264 motion vector difference',
          );
      }
      for (var i = bits - 1; i >= 0; i--) {
        magnitude += _cabac.bypass() << i;
      }
    }
    if (magnitude > 32767)
      throw const FormatException('H.264 motion vector is out of range');
    return _cabac.bypass() == 0 ? magnitude : -magnitude;
  }

  @override
  void _readQuantizerAndResiduals(
    Macroblock block,
    Macroblock? left,
    Macroblock? top,
  ) {
    var delta = 0;
    if (block.intra16 || block.lumaPattern != 0 || block.chromaPattern != 0) {
      delta = _qpDelta();
      _updateQp(delta);
    }
    _previousQpDelta = delta != 0;
    block.qp = _qp;
    _residuals(block, left, top);
  }

  @override
  int _intraType(Macroblock? left, Macroblock? top, int? type) {
    final intraSlice = header.kind == SliceKind.intra;
    final base = switch (header.kind) {
      SliceKind.intra => 3,
      SliceKind.p => 17,
      SliceKind.b => 32,
    };
    final neighbors = intraSlice
        ? _count(left != null && !left.nxn, top != null && !top.nxn)
        : 0;
    if (_cabac.decision(base + neighbors) == 0) return 0;
    if (_cabac.terminate()) return 25;
    final state = intraSlice ? base + 2 : base;
    final luma = _cabac.decision(state + 1);
    final chroma = _cabac.decision(state + 2) == 0
        ? 0
        : 1 + _cabac.decision(state + (intraSlice ? 3 : 2));
    final prediction =
        2 * _cabac.decision(state + (intraSlice ? 4 : 3)) +
        _cabac.decision(state + (intraSlice ? 5 : 3));
    return 1 + 12 * luma + 4 * chroma + prediction;
  }

  @override
  int _chromaMode(Macroblock? left, Macroblock? top) {
    final neighbors = _count(
      (left?.chromaMode ?? 0) > 0,
      (top?.chromaMode ?? 0) > 0,
    );
    if (_cabac.decision(64 + neighbors) == 0) return 0;
    if (_cabac.decision(67) == 0) return 1;
    return 2 + _cabac.decision(67);
  }

  @override
  void _patterns(Macroblock block, Macroblock? left, Macroblock? top) {
    for (var i = 0; i < 4; i++) {
      final x = i & 1;
      final y = i >> 1;
      final a = x == 0 ? left : block;
      final b = y == 0 ? top : block;
      final neighbors = _pair(
        a != null && !a.pcm && !_set(a.lumaPattern, (y << 1) | (x ^ 1)),
        b != null && !b.pcm && !_set(b.lumaPattern, ((y ^ 1) << 1) | x),
      );
      block.lumaPattern |= _cabac.decision(73 + neighbors) << i;
    }
    if (header.pps.sps.chromaFormat != 1) return;
    int pattern(Macroblock? block) =>
        block?.pcm == true ? 2 : block?.chromaPattern ?? 0;
    final a = pattern(left);
    final b = pattern(top);
    if (_cabac.decision(77 + _pair(a > 0, b > 0)) != 0) {
      block.chromaPattern = 1 + _cabac.decision(81 + _pair(a > 1, b > 1));
    }
  }

  int _qpDelta() {
    if (_cabac.decision(_previousQpDelta ? 61 : 60) == 0) return 0;
    var value = 1;
    final maximum = 52 + header.pps.sps.lumaQpOffset;
    while (_cabac.decision(value == 1 ? 62 : 63) != 0) {
      if (++value > maximum)
        throw const FormatException('Invalid H.264 macroblock QP delta');
    }
    return value.isOdd ? (value + 1) >> 1 : -(value >> 1);
  }

  void _residuals(Macroblock block, Macroblock? left, Macroblock? top) {
    coefficients.clearResiduals();
    if (block.intra16 &&
        _decode(
          _Residual.lumaDc,
          _pair(_dcFlag(left, 0, block.intra), _dcFlag(top, 0, block.intra)),
          coefficients.lumaDc,
          0,
          16,
        )) {
      block.codedDc |= 1;
    }
    if (block.transform8x8) {
      for (var i = 0; i < 4; i++) {
        if (_set(block.lumaPattern, i)) {
          _decode(_Residual.luma8, 0, coefficients.luma, 64 * i, 64);
          block.codedLuma |= 15 << (4 * i);
        }
      }
    } else {
      for (var i = 0; i < 16; i++) {
        if (!_set(block.lumaPattern, i >> 2)) continue;
        final x = blockX(i);
        final y = blockY(i);
        final context = _pair(
          _lumaFlag(
            x == 0 ? left : block,
            blockIndex((x - 1) & 3, y),
            block.intra,
          ),
          _lumaFlag(
            y == 0 ? top : block,
            blockIndex(x, (y - 1) & 3),
            block.intra,
          ),
        );
        final ac = block.intra16;
        if (_decode(
          ac ? _Residual.lumaAc : _Residual.luma4,
          context,
          coefficients.luma,
          i * 16 + (ac ? 1 : 0),
          ac ? 15 : 16,
        )) {
          block.codedLuma |= 1 << i;
        }
      }
    }
    if (block.chromaPattern == 0) return;
    for (var plane = 0; plane < 2; plane++) {
      if (_decode(
        _Residual.chromaDc,
        _pair(
          _dcFlag(left, plane + 1, block.intra),
          _dcFlag(top, plane + 1, block.intra),
        ),
        coefficients.chromaDc,
        plane * 4,
        4,
      )) {
        block.codedDc |= 1 << (plane + 1);
      }
    }
    if (block.chromaPattern == 1) return;
    for (var i = 0; i < 8; i++) {
      final x = i & 1;
      final y = (i >> 1) & 1;
      final context = _pair(
        _chromaFlag(x == 0 ? left : block, i ^ 1, block.intra),
        _chromaFlag(y == 0 ? top : block, i ^ 2, block.intra),
      );
      if (_decode(
        _Residual.chromaAc,
        context,
        coefficients.chroma,
        i * 16 + 1,
        15,
      )) {
        block.codedChroma |= 1 << i;
      }
    }
  }

  bool _decode(
    _Residual category,
    int context,
    Int32List output,
    int offset,
    int length,
  ) {
    final large = category == _Residual.luma8;
    if (!large && _cabac.decision(category.coded + context) == 0) return false;
    var used = 0;
    for (var i = 0; i < length; i++) {
      if (i == length - 1) {
        _positions[used++] = i;
      } else if (_cabac.decision(
            category.significant + (large ? _significant8[i] : i),
          ) !=
          0) {
        _positions[used++] = i;
        if (_cabac.decision(category.last + (large ? _last8[i] : i)) != 0)
          break;
      }
    }
    var node = 0;
    for (var i = used - 1; i >= 0; i--) {
      var magnitude = 1;
      if (_cabac.decision(category.level + _levelOne[node]) == 0) {
        node = _nextOne[node];
      } else {
        final levelContext = category.level + _levelMore[node];
        node = _nextMore[node];
        magnitude = 2;
        while (magnitude < 15 && _cabac.decision(levelContext) != 0) {
          magnitude++;
        }
        if (magnitude == 15) magnitude += _cabac.coefficientSuffix();
      }
      output[offset + _positions[i]] = _cabac.bypass() == 0
          ? magnitude
          : -magnitude;
    }
    return true;
  }
}

bool _dcFlag(Macroblock? block, int index, bool intra) =>
    block == null ? intra : block.pcm || _set(block.codedDc, index);
bool _lumaFlag(Macroblock? block, int index, bool intra) =>
    block == null ? intra : block.pcm || _set(block.codedLuma, index);
bool _chromaFlag(Macroblock? block, int index, bool intra) =>
    block == null ? intra : block.pcm || _set(block.codedChroma, index);
bool _set(int flags, int index) => flags & (1 << index) != 0;
int _count(bool a, bool b) => (a ? 1 : 0) + (b ? 1 : 0);
int _pair(bool a, bool b) => (a ? 1 : 0) + (b ? 2 : 0);

const _levelOne = [1, 2, 3, 4, 0, 0, 0, 0];
const _levelMore = [5, 5, 5, 5, 6, 7, 8, 9];
const _nextOne = [1, 2, 3, 3, 4, 5, 6, 7];
const _nextMore = [4, 4, 4, 4, 5, 6, 7, 7];

// Tables 9-43 and 9-44 for the progressive 8×8 coefficient scan.
const _significant8 = [
  0,
  1,
  2,
  3,
  4,
  5,
  5,
  4,
  4,
  3,
  3,
  4,
  4,
  4,
  5,
  5,
  4,
  4,
  4,
  4,
  3,
  3,
  6,
  7,
  7,
  7,
  8,
  9,
  10,
  9,
  8,
  7,
  7,
  6,
  11,
  12,
  13,
  11,
  6,
  7,
  8,
  9,
  14,
  10,
  9,
  8,
  6,
  11,
  12,
  13,
  11,
  6,
  9,
  14,
  10,
  9,
  11,
  12,
  13,
  11,
  14,
  10,
  12,
];
const _last8 = [
  0,
  1,
  1,
  1,
  1,
  1,
  1,
  1,
  1,
  1,
  1,
  1,
  1,
  1,
  1,
  1,
  2,
  2,
  2,
  2,
  2,
  2,
  2,
  2,
  2,
  2,
  2,
  2,
  2,
  2,
  2,
  2,
  3,
  3,
  3,
  3,
  3,
  3,
  3,
  3,
  4,
  4,
  4,
  4,
  4,
  4,
  4,
  4,
  5,
  5,
  5,
  5,
  6,
  6,
  6,
  6,
  7,
  7,
  7,
  7,
  8,
  8,
  8,
];
