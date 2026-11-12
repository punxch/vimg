import 'dart:math' as math;
import 'dart:typed_data';

import 'b_motion.dart';
import 'cabac.dart';
import 'motion.dart';
import 'reference.dart';
import 'slice_header.dart';

part 'b_slice.dart';
part 'p_slice.dart';

int blockX(int block) => (block & 1) | ((block >> 1) & 2);
int blockY(int block) => ((block >> 1) & 1) | ((block >> 2) & 2);
int blockIndex(int x, int y) =>
    ((y & 2) << 2) | ((x & 2) << 1) | ((y & 1) << 1) | (x & 1);

final class Macroblock {
  Macroblock(this.slice, this.type);

  final SliceHeader slice;
  final int type;
  bool get intra => type >= 0;
  bool get pcm => type == 25;
  bool get nxn => type == 0;
  bool get intra16 => type > 0 && type < 25;

  var transform8x8 = false;
  var skipped = false, direct = false;
  var lumaPattern = 0, chromaPattern = 0;
  var chromaMode = 0, qp = 0;
  var codedLuma = 0, codedChroma = 0, codedDc = 0;
  Uint8List? modes;

  int predictionMode(int x, int y) => modes?[y * 4 + x] ?? 2;
}

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

/// Coefficients remain in zigzag order here. The reconstruction stage maps
/// them to the transform matrix. These buffers belong to one slice reader
/// and are reused immediately after reconstructing a macroblock.
final class MacroblockCoefficients {
  final luma = Int32List(256);
  final lumaDc = Int32List(16);
  final chroma = Int32List(128);
  final chromaDc = Int32List(8);
  final pcm = Uint8List(384);
}

final class CabacSlice {
  CabacSlice(this.header)
    : _cabac = Cabac(
        header.bits,
        header.qp,
        interInit: header.kind == SliceKind.intra ? null : header.cabacInit,
      ),
      _qp = header.qp;

  final SliceHeader header;
  final Cabac _cabac;
  final coefficients = MacroblockCoefficients();
  final _positions = Uint8List(64);
  var _previousQpDelta = false;
  int _qp;

  bool endOfSlice() => _cabac.terminate();

  void _interResiduals(
    Macroblock block,
    Macroblock? left,
    Macroblock? top,
    bool allow8x8,
  ) {
    _patterns(block, left, top);
    if (header.pps.transform8x8 && block.lumaPattern != 0 && allow8x8) {
      final context = _count(
        left?.transform8x8 == true,
        top?.transform8x8 == true,
      );
      block.transform8x8 = _cabac.decision(399 + context) != 0;
    }
    _readQuantizerAndResiduals(block, left, top);
  }

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

  void _readVector(
    MotionField field,
    MotionPartition part,
    int owner,
    int ref,
  ) {
    final left = field.differenceAt(part.x - 1, part.y, owner);
    final top = field.differenceAt(part.x, part.y - 1, owner);
    final dx = _motionDifference(40, left.x.abs() + top.x.abs());
    final dy = _motionDifference(47, left.y.abs() + top.y.abs());
    final predicted = field.predict(part, owner, ref);
    final vector = (
      x: signedMotion(predicted.x + dx),
      y: signedMotion(predicted.y + dy),
    );
    field.setVector(part, vector, (x: dx, y: dy));
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

  Macroblock readIntra(Macroblock? left, Macroblock? top) {
    final block = Macroblock(header, _type(left, top));
    if (block.pcm) {
      final bits = _cabac.bits;
      bits.align(0);
      final count = header.pps.sps.chromaFormat == 0 ? 256 : 384;
      for (var i = 0; i < count; i++) {
        coefficients.pcm[i] = bits.read(8);
      }
      _cabac.restart();
      _previousQpDelta = false;
      return block;
    }
    if (block.nxn) {
      if (header.pps.transform8x8) {
        final neighbors = _count(
          left?.transform8x8 == true,
          top?.transform8x8 == true,
        );
        block.transform8x8 = _cabac.decision(399 + neighbors) != 0;
      }
      _predictionModes(block, left, top);
    } else {
      block.lumaPattern = block.type >= 13 ? 15 : 0;
      block.chromaPattern = ((block.type - 1) ~/ 4) % 3;
    }
    if (header.pps.sps.chromaFormat == 1) {
      block.chromaMode = _chromaMode(left, top);
    }
    if (block.nxn) _patterns(block, left, top);
    _readQuantizerAndResiduals(block, left, top);
    return block;
  }

  void _readQuantizerAndResiduals(
    Macroblock block,
    Macroblock? left,
    Macroblock? top,
  ) {
    var delta = 0;
    if (block.intra16 || block.lumaPattern != 0 || block.chromaPattern != 0) {
      delta = _qpDelta();
      _qp = (_qp + delta) % 52;
    }
    _previousQpDelta = delta != 0;
    block.qp = _qp;
    _residuals(block, left, top);
  }

  int _type(Macroblock? left, Macroblock? top) {
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

  void _predictionModes(Macroblock block, Macroblock? left, Macroblock? top) {
    block.modes = Uint8List(16);
    final step = block.transform8x8 ? 2 : 1;
    final count = step == 2 ? 4 : 16;
    for (var index = 0; index < count; index++) {
      final x = blockX(index * step * step);
      final y = blockY(index * step * step);
      var a = x == 0 ? left : block;
      var b = y == 0 ? top : block;
      if (header.pps.constrainedIntra) {
        if (a?.intra == false) a = null;
        if (b?.intra == false) b = null;
      }
      var mode = a == null || b == null
          ? 2
          : math.min(
              a.predictionMode((x - 1) & 3, y),
              b.predictionMode(x, (y - 1) & 3),
            );
      if (_cabac.decision(68) == 0) {
        final remainder =
            _cabac.decision(69) |
            (_cabac.decision(69) << 1) |
            (_cabac.decision(69) << 2);
        mode = remainder < mode ? remainder : remainder + 1;
      }
      for (var dy = 0; dy < step; dy++) {
        block.modes!.fillRange((y + dy) * 4 + x, (y + dy) * 4 + x + step, mode);
      }
    }
  }

  int _chromaMode(Macroblock? left, Macroblock? top) {
    final neighbors = _count(
      (left?.chromaMode ?? 0) > 0,
      (top?.chromaMode ?? 0) > 0,
    );
    if (_cabac.decision(64 + neighbors) == 0) return 0;
    if (_cabac.decision(67) == 0) return 1;
    return 2 + _cabac.decision(67);
  }

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
    while (_cabac.decision(value == 1 ? 62 : 63) != 0) {
      if (++value > 52)
        throw const FormatException('Invalid H.264 macroblock QP delta');
    }
    return value.isOdd ? (value + 1) >> 1 : -(value >> 1);
  }

  void _residuals(Macroblock block, Macroblock? left, Macroblock? top) {
    coefficients.luma.fillRange(0, 256, 0);
    coefficients.lumaDc.fillRange(0, 16, 0);
    coefficients.chroma.fillRange(0, 128, 0);
    coefficients.chromaDc.fillRange(0, 8, 0);
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
