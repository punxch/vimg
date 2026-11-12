part of 'picture_decoder.dart';

extension _IntraBlockCopy on _PictureTile {
  Av1InterMotion _readIntraCopy(int x, int y, int w4, int h4, bool hasChroma) {
    final stack = av1FindMvStack(
      x: x,
      y: y,
      width4: w4,
      height4: h4,
      columns: state.columns,
      rows: state.rows,
      ref0: 0,
      ref1: -1,
      highPrecision: false,
      integer: true,
      globals: params.globalMotion,
      distance: _distance,
      neighbor: _motionNeighbor,
      temporal: null,
      inTile: _inside,
    );
    var predictor = stack.entries[0].mv.$1;
    if (predictor == av1ZeroMv) predictor = stack.entries[1].mv.$1;
    if (predictor == av1ZeroMv) {
      predictor = y - sb4 < y0
          ? (x: -(sb4 * 4 + 256) * 8, y: 0)
          : (x: 0, y: -sb4 * 32);
    }
    final mv = _motionSyntax.readIntraCopyMv(predictor);
    _validateIntraCopy(x, y, w4, h4, hasChroma, mv);
    return (
      ref0: 0,
      ref1: -1,
      mv0: mv,
      mv1: av1ZeroMv,
      mode0: Av1MvMode.newMv,
      mode1: Av1MvMode.nearest,
      filterX: Av1Interpolation.bilinear.index,
      filterY: Av1Interpolation.bilinear.index,
      compound: null,
      invertMask: false,
      wedgeIndex: 0,
      interIntraMode: null,
      obmc: false,
      warp: null,
    );
  }

  // §6.10.27 constrains the source to the decoded portion of this tile,
  // including the leading chroma samples for a sub-8×8 block.
  void _validateIntraCopy(
    int x,
    int y,
    int w4,
    int h4,
    bool hasChroma,
    Av1Mv mv,
  ) {
    if (((mv.x | mv.y) & 7) != 0 ||
        mv.x.abs() >= 16384 ||
        mv.y.abs() >= 16384) {
      throw const FormatException('Invalid AV1 intra block copy vector');
    }
    final sourceX = (x << 2) + (mv.x >> 3);
    final sourceY = (y << 2) + (mv.y >> 3);
    final right = sourceX + (w4 << 2), bottom = sourceY + (h4 << 2);
    final left = sourceX - (hasChroma && w4 == 1 && sx != 0 ? 4 : 0);
    final top = sourceY - (hasChroma && h4 == 1 && sy != 0 ? 4 : 0);
    if (left < x0 * 4 ||
        top < y0 * 4 ||
        right > xEnd * 4 ||
        bottom > yEnd * 4) {
      throw const FormatException('AV1 intra block copy leaves its tile');
    }

    const delay = 4;
    final columns64 = (xEnd - x0 + 15) >> 4;
    final activeRow = y ~/ sb4, activeCol = x >> 4;
    final sourceRow = (bottom - 1) ~/ (sb4 * 4);
    final sourceCol = (right - 1) >> 6;
    final lead = (sb4 == 32 ? 6 : 5) * (activeRow - sourceRow);
    if (sourceRow > activeRow ||
        sourceRow * columns64 + sourceCol >=
            activeRow * columns64 + activeCol - delay ||
        sourceCol >= activeCol - delay + lead) {
      throw const FormatException('AV1 intra block copy uses undecoded pixels');
    }
  }

  void _predictIntraCopy(
    int p,
    int x,
    int y,
    int width,
    int height,
    Av1Mv mv,
    Int32List output,
  ) {
    final plane = planes[p];
    final frameWidth = state.columns << 2, frameHeight = state.rows << 2;
    _inter.convolve(
      output,
      plane.samples,
      stride: plane.stride,
      referenceWidth: frameWidth,
      referenceHeight: frameHeight,
      frameWidth: frameWidth,
      frameHeight: frameHeight,
      x: x,
      y: y,
      width: width,
      height: height,
      sx: p == 0 ? 0 : sx,
      sy: p == 0 ? 0 : sy,
      mv: mv,
      filterX: Av1Interpolation.bilinear.index,
      filterY: Av1Interpolation.bilinear.index,
      depth: color.depth,
      compound: false,
    );
  }
}
