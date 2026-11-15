part of 'slice_data.dart';

final class CavlcSlice extends SliceData {
  CavlcSlice(SliceHeader header) : _cavlc = Cavlc(header.bits), super(header);

  final Cavlc _cavlc;
  int? _skipRun;

  @override
  bool readMbaffField(Macroblock? leftPair, Macroblock? topPair) =>
      header.bits.flag();

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
        _skipRun ??
        header.bits.ue(sps.mbWidth * header.mbHeight - header.firstMb);
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
    final subsampled = header.pps.sps.subsampledChroma;
    final table = subsampled
        ? (block.intra ? _intraPattern : _interPattern)
        : (block.intra ? _fullIntraPattern : _fullInterPattern);
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
    final planes = header.pps.sps.chromaArrayType == 3 ? 3 : 1;
    for (var plane = 0; plane < planes; plane++) {
      _fullResiduals(block, left, top, plane);
    }
    if (block.chromaPattern == 0) return;
    final countPerPlane = header.pps.sps.chromaBlockCount;
    final dcContext = countPerPlane == 8 ? -2 : -1;
    for (var plane = 0; plane < 2; plane++) {
      if (_cavlc.residual(
            coefficients.dc[plane + 1],
            0,
            countPerPlane,
            dcContext,
          ) !=
          0) {
        block.codedDc |= 1 << (plane + 1);
      }
    }
    if (block.chromaPattern == 1) return;
    final counts = block.totalCoefficients ??= Uint8List(
      16 + 2 * header.pps.sps.chromaBlockCount,
    );
    for (var i = 0; i < 2 * countPerPlane; i++) {
      final local = i % countPerPlane;
      final context = _coefficientContext(
        block,
        left,
        top,
        4 * (local & 1),
        4 * (local >> 1),
        16 + i - local,
        chroma: true,
      );
      final count = _cavlc.residual(
        coefficients.levels[1 + i ~/ countPerPlane],
        (i % countPerPlane) * 16 + 1,
        15,
        context,
      );
      counts[16 + i] = count;
      if (count != 0) block.codedBlocks |= 1 << (16 + i);
    }
  }

  void _fullResiduals(
    Macroblock block,
    Macroblock? left,
    Macroblock? top,
    int plane,
  ) {
    final start = plane * 16;
    final acOnly = block.intra16;
    if (acOnly &&
        _cavlc.residual(
              coefficients.dc[plane],
              0,
              16,
              _coefficientContext(block, left, top, 0, 0, start),
            ) !=
            0) {
      block.codedDc |= 1 << plane;
    }
    if (block.lumaPattern != 0) {
      final counts = block.totalCoefficients ??= Uint8List(
        16 + 2 * header.pps.sps.chromaBlockCount,
      );
      for (var i = 0; i < 16; i++) {
        if (!_set(block.lumaPattern, i >> 2)) continue;
        final count = _cavlc.residual(
          coefficients.levels[plane],
          block.transform8x8
              ? (i >> 2) * 64 + (i & 3)
              : i * 16 + (acOnly ? 1 : 0),
          acOnly ? 15 : 16,
          _coefficientContext(
            block,
            left,
            top,
            4 * blockX(i),
            4 * blockY(i),
            start,
          ),
          stride: block.transform8x8 ? 4 : 1,
        );
        counts[start + i] = count;
        if (count != 0) {
          block.codedBlocks |=
              (block.transform8x8 ? 15 << (i & ~3) : 1 << i) << start;
        }
      }
    }
  }

  int _coefficientContext(
    Macroblock block,
    Macroblock? left,
    Macroblock? top,
    int x,
    int y,
    int start, {
    bool chroma = false,
  }) {
    final a = _residualNeighbor(
      block,
      left,
      top,
      x - 1,
      y,
      start,
      chroma: chroma,
    );
    final b = _residualNeighbor(
      block,
      left,
      top,
      x,
      y - 1,
      start,
      chroma: chroma,
    );
    return _context(_countAt(a.block, a.index), _countAt(b.block, b.index));
  }
}

int? _countAt(Macroblock? block, int index) => block == null
    ? null
    : (block.pcm ? 16 : block.totalCoefficients?[index] ?? 0);

int _context(int? a, int? b) =>
    a == null || b == null ? a ?? b ?? 0 : (a + b + 1) >> 1;

// H.264 Table 9-4 mapped Exp-Golomb coded block patterns.
// dart format off
const _fullIntraPattern = [15, 0, 7, 11, 13, 14, 3, 5, 10, 12, 1, 2, 4, 8, 6, 9];
const _fullInterPattern = [0, 1, 2, 4, 8, 3, 5, 10, 12, 15, 7, 11, 13, 14, 6, 9];
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
