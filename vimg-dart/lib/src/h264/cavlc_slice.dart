part of 'slice_data.dart';

final class CavlcSlice extends SliceData {
  CavlcSlice(SliceHeader header) : _cavlc = Cavlc(header.bits), super(header);

  final Cavlc _cavlc;
  int? _skipRun;

  @override
  bool endOfSlice() {
    final bits = header.bits;
    if ((_skipRun ?? 0) > 0 || bits.remaining > 8 || bits.hasMoreData)
      return false;
    bits.readStopBit();
    return true;
  }

  @override
  bool _skip(Macroblock? left, Macroblock? top) {
    final sps = header.pps.sps;
    final run =
        _skipRun ?? header.bits.ue(sps.mbWidth * sps.mbHeight - header.firstMb);
    _skipRun = run == 0 ? null : run - 1;
    return run > 0;
  }

  @override
  int _pType() => header.bits.ue(30);

  @override
  int _pSubType() => header.bits.ue(3);

  @override
  int _bType(int context) => header.bits.ue(48);

  @override
  int _bSubType() => header.bits.ue(12);

  @override
  int _intraType(Macroblock? left, Macroblock? top, int? type) =>
      type ?? header.bits.ue(25);

  @override
  bool _transformFlag(Macroblock? left, Macroblock? top) => header.bits.flag();

  @override
  int? _intraRemainder() => header.bits.flag() ? null : header.bits.read(3);

  @override
  int _chromaMode(Macroblock? left, Macroblock? top) => header.bits.ue(3);

  @override
  int _referenceIndex(int context, int active) => switch (active) {
    1 => 0,
    2 => 1 - header.bits.bit(),
    _ => header.bits.ue(active - 1),
  };

  @override
  (int, int) _motionDelta(MotionField field, MotionPartition part, int owner) {
    final dx = header.bits.se(), dy = header.bits.se();
    if (dx < -32768 || dx > 32767 || dy < -32768 || dy > 32767) {
      throw const FormatException(
        'H.264 motion vector difference out of range',
      );
    }
    return (dx, dy);
  }

  @override
  void _patterns(Macroblock block, Macroblock? left, Macroblock? top) {
    final monochrome = header.pps.sps.chromaFormat == 0;
    final table = monochrome
        ? (block.intra ? _monoIntraPattern : _monoInterPattern)
        : (block.intra ? _intraPattern : _interPattern);
    final pattern = table[header.bits.ue(table.length - 1)];
    block.lumaPattern = pattern & 15;
    block.chromaPattern = pattern >> 4;
  }

  @override
  void _readQuantizerAndResiduals(
    Macroblock block,
    Macroblock? left,
    Macroblock? top,
  ) {
    final acOnly = block.intra16;
    if (acOnly || block.lumaPattern != 0 || block.chromaPattern != 0) {
      _updateQp(header.bits.se());
    }
    block.qp = _qp;
    coefficients.clearResiduals();
    if (acOnly &&
        _cavlc.residual(
              coefficients.lumaDc,
              0,
              16,
              _lumaContext(block, left, top, 0),
            ) !=
            0) {
      block.codedDc |= 1;
    }
    if (block.lumaPattern != 0) {
      final counts = block.totalCoefficients ??= Uint8List(24);
      for (var i = 0; i < 16; i++) {
        if (!_set(block.lumaPattern, i >> 2)) continue;
        final count = _cavlc.residual(
          coefficients.luma,
          block.transform8x8
              ? (i >> 2) * 64 + (i & 3)
              : i * 16 + (acOnly ? 1 : 0),
          acOnly ? 15 : 16,
          _lumaContext(block, left, top, i),
          stride: block.transform8x8 ? 4 : 1,
        );
        counts[i] = count;
        if (count != 0) {
          block.codedLuma |= block.transform8x8 ? 15 << (i & ~3) : 1 << i;
        }
      }
    }
    if (block.chromaPattern == 0) return;
    for (var plane = 0; plane < 2; plane++) {
      if (_cavlc.residual(coefficients.chromaDc, plane * 4, 4, -1) != 0) {
        block.codedDc |= 1 << (plane + 1);
      }
    }
    if (block.chromaPattern == 1) return;
    final counts = block.totalCoefficients ??= Uint8List(24);
    for (var i = 0; i < 8; i++) {
      final a = _countAt(i & 1 == 0 ? left : block, 16 + (i ^ 1));
      final b = _countAt(i & 2 == 0 ? top : block, 16 + (i ^ 2));
      final count = _cavlc.residual(
        coefficients.chroma,
        i * 16 + 1,
        15,
        _context(a, b),
      );
      counts[16 + i] = count;
      if (count != 0) block.codedChroma |= 1 << i;
    }
  }
}

int _lumaContext(Macroblock block, Macroblock? left, Macroblock? top, int i) {
  final x = blockX(i), y = blockY(i);
  final a = _countAt(x == 0 ? left : block, blockIndex((x - 1) & 3, y));
  final b = _countAt(y == 0 ? top : block, blockIndex(x, (y - 1) & 3));
  return _context(a, b);
}

int? _countAt(Macroblock? block, int index) => block == null
    ? null
    : (block.pcm ? 16 : block.totalCoefficients?[index] ?? 0);

int _context(int? a, int? b) =>
    a == null || b == null ? a ?? b ?? 0 : (a + b + 1) >> 1;

// H.264 Table 9-4 mapped Exp-Golomb coded block patterns.
// dart format off
const _monoIntraPattern = [15, 0, 7, 11, 13, 14, 3, 5, 10, 12, 1, 2, 4, 8, 6, 9];
const _monoInterPattern = [0, 1, 2, 4, 8, 3, 5, 10, 12, 15, 7, 11, 13, 14, 6, 9];
const _intraPattern = [
  47, 31, 15, 0, 23, 27, 29, 30, 7, 11, 13, 14, 39, 43, 45, 46,
  16, 3, 5, 10, 12, 19, 21, 26, 28, 35, 37, 42, 44, 1, 2, 4,
  8, 17, 18, 20, 24, 6, 9, 22, 25, 32, 33, 34, 36, 40, 38, 41,
];
const _interPattern = [
  0, 16, 1, 2, 4, 8, 32, 3, 5, 10, 12, 15, 47, 7, 11, 13,
  14, 6, 9, 31, 35, 37, 42, 44, 33, 34, 36, 40, 39, 43, 45, 46,
  17, 18, 20, 24, 19, 21, 26, 28, 23, 27, 29, 30, 22, 25, 38, 41,
];
