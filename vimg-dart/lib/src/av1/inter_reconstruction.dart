part of 'picture_decoder.dart';

extension _InterReconstruction on _PictureTile {
  int _distance(int reference) => frame.sequence.relativeDistance(
    references[reference - 1].header.orderHint,
    frame.header.orderHint,
  );

  bool _scaled(int reference) {
    final size = references[reference - 1].header.size;
    return size.upscaledWidth != frame.header.size.width ||
        size.height != frame.header.size.height;
  }

  void _interBlock(
    int x,
    int y,
    int w4,
    int h4,
    int blockSize,
    int segment,
    bool predictedSegment,
    bool skip,
    bool skipMode,
    bool lossless,
    bool hasChroma,
    List<int?> features,
  ) {
    final motion = _motionSyntax.read(
      x: x,
      y: y,
      width4: w4,
      height4: h4,
      columns: state.columns,
      rows: state.rows,
      blockSize: blockSize,
      skipMode: skipMode,
      segmentFeatures: features,
      neighbor: _motionNeighbor,
      inTile: _inside,
      distance: _distance,
      scaled: _scaled,
      temporal: field?.at,
    );
    final width = w4 * 4, height = h4 * 4;
    final maxTx = lossless
        ? Av1TxSize.tx4x4
        : Av1TxSize.of(math.min(width, 64), math.min(height, 64));
    final varTx =
        params.transformMode == Av1TransformMode.select && !skip && !lossless;
    final transforms = <(int, int, Av1TxSize)>[];
    final topSize =
        math.max(math.min(width, 64), math.min(height, 64)).bitLength - 3;
    final stepX = maxTx.width >> 2, stepY = maxTx.height >> 2;
    for (var r = y; r < y + h4; r += stepY) {
      for (var c = x; c < x + w4; c += stepX) {
        _readInterTx(c, r, maxTx, varTx ? 0 : 2, topSize, transforms);
      }
    }
    _stampBlock(x, y, (
      width: w4,
      height: h4,
      segment: segment,
      skip: skip,
      skipMode: skipMode,
      segmentPredicted: predictedSegment,
      motion: motion,
      txSize: maxTx,
      yMode: Av1IntraMode.dc,
      uvMode: Av1IntraMode.dc,
      filterLevels: _filterLevels(segment, motion),
      paletteY: null,
      paletteU: null,
    ));

    final planeCount = hasChroma ? 3 : 1;
    for (var p = 0; p < planeCount; p++) {
      _interPredict(p, x, y, w4, h4, motion);
      if (motion.obmc) _blendObmc(p, x, y, w4, h4);
      if (motion.interIntraMode != null)
        _blendInterIntra(p, x, y, w4, h4, motion);
    }
    final uvW = math.max(4, width >> sx), uvH = math.max(4, height >> sy);
    final uvTx = hasChroma
        ? lossless
              ? Av1TxSize.tx4x4
              : Av1TxSize.of(math.min(32, uvW), math.min(32, uvH))
        : Av1TxSize.tx4x4;
    if (skip) {
      for (var p = 0; p < planeCount; p++) {
        final (px, py) = p == 0 ? (0, 0) : (sx, sy);
        _neighbors[p].stamp(
          (x - x0) >> px,
          (y - y0) >> py,
          p == 0 ? w4 : uvW >> 2,
          p == 0 ? h4 : uvH >> 2,
          0,
          0,
        );
      }
    }
    for (var cy = 0; cy < h4; cy += 16) {
      for (var cx = 0; cx < w4; cx += 16) {
        final baseX = x + cx, baseY = y + cy;
        if (baseX >= xEnd || baseY >= yEnd) continue;
        if (!skip) {
          for (final (txX, txY, tx) in transforms) {
            if (txX < baseX ||
                txX >= baseX + 16 ||
                txY < baseY ||
                txY >= baseY + 16) {
              continue;
            }
            _interResidual(
              0,
              txX,
              txY,
              tx,
              width,
              height,
              lossless,
              segment,
              x,
              y,
            );
          }
        }
        if (!hasChroma) continue;
        final x4 = baseX >> sx, y4 = baseY >> sy;
        final countX = math.min(uvW >> 2, (16 >> sx));
        final countY = math.min(uvH >> 2, (16 >> sy));
        final tw = uvTx.width >> 2, th = uvTx.height >> 2;
        for (var p = 1; p < 3; p++) {
          for (var j = y4; j < y4 + countY && j < yEnd >> sy; j += th) {
            for (var i = x4; i < x4 + countX && i < xEnd >> sx; i += tw) {
              if (!skip)
                _interResidual(
                  p,
                  i,
                  j,
                  uvTx,
                  uvW,
                  uvH,
                  lossless,
                  segment,
                  x,
                  y,
                );
              planes[p].markDecoded(i, j, uvTx);
            }
          }
        }
      }
    }
  }

  void _readInterTx(
    int x,
    int y,
    Av1TxSize tx,
    int depth,
    int topSize,
    List<(int, int, Av1TxSize)> leaves,
  ) {
    if (x >= xEnd || y >= yEnd) return;
    final w4 = tx.width >> 2, h4 = tx.height >> 2;
    final plane = planes[0];
    int neighborSize(int px, int py, bool above) {
      if (!_inside(px, py)) return 64;
      final neighbor = _at(px, py);
      if (neighbor?.skip == true && neighbor?.motion != null) {
        return 4 * (above ? neighbor!.width : neighbor!.height);
      }
      final index = plane.decoded[py * (plane.stride >> 2) + px];
      final size = Av1TxSize.values[math.max(0, index - 1)];
      return above ? size.width : size.height;
    }

    if (depth < 2 && tx != Av1TxSize.tx4x4) {
      final ctx =
          (tx.squareUp == topSize ? 0 : 3) +
          (4 - topSize) * 6 +
          (neighborSize(x, y - 1, true) < tx.width ? 1 : 0) +
          (neighborSize(x - 1, y, false) < tx.height ? 1 : 0);
      if (_symbol(_Family.txSplit, interTxfmSplitCdf[ctx], ctx) != 0) {
        final sub = Av1TxSize.values[_splitTx[tx.index]];
        for (var j = 0; j < h4; j += sub.height >> 2) {
          for (var i = 0; i < w4; i += sub.width >> 2) {
            _readInterTx(x + i, y + j, sub, depth + 1, topSize, leaves);
          }
        }
        return;
      }
    }
    plane.markDecoded(x, y, tx);
    leaves.add((x, y, tx));
  }

  void _interPredict(
    int p,
    int x4,
    int y4,
    int w4,
    int h4,
    Av1InterMotion motion,
  ) {
    final (px, py) = p == 0 ? (0, 0) : (sx, sy);
    final w = math.max(4, (w4 << 2) >> px), h = math.max(4, (h4 << 2) >> py);
    final x = (x4 >> px) << 2, y = (y4 >> py) << 2;
    final left = w4 == 1 && px != 0, above = h4 == 1 && py != 0;
    final minX = x4 - (left ? 1 : 0), minY = y4 - (above ? 1 : 0);
    if ((left || above) &&
        (motion.compound == null) &&
        _at(minX, minY)?.motion != null &&
        _at(x4, minY)?.motion != null &&
        _at(minX, y4)?.motion != null) {
      final ww = left ? 2 : w, hh = above ? 2 : h;
      for (var r = minY; r <= y4; r++) {
        for (var c = minX; c <= x4; c++) {
          final m = _at(c, r)!.motion!;
          _writePrediction(
            p,
            x + (c - minX) * ww,
            y + (r - minY) * hh,
            ww,
            hh,
            m,
          );
        }
      }
    } else {
      _writePrediction(p, x, y, w, h, motion);
    }
  }

  void _writePrediction(
    int p,
    int x,
    int y,
    int w,
    int h,
    Av1InterMotion motion,
  ) {
    final plane = planes[p];
    final (px, py) = p == 0 ? (0, 0) : (sx, sy);
    final compound = motion.compound;
    for (final (ref, mv, output) in [
      (motion.ref0, motion.mv0, _inter.first),
      if (compound != null) (motion.ref1, motion.mv1, _inter.second),
    ]) {
      final global =
          motion.mode0 == Av1MvMode.global &&
          (compound == null || motion.mode1 == Av1MvMode.global);
      final gm = frame.header.parameters.globalMotion[ref - 1];
      final matrix =
          motion.warp ??
          (global && gm.type.index > 1 && !_scaled(ref) ? gm.matrix : null);
      _convolveReference(
        p,
        x,
        y,
        w,
        h,
        ref,
        mv,
        motion.filterX,
        motion.filterY,
        output,
        compound: compound != null,
        matrix: matrix,
      );
    }
    if (p == 0) {
      if (compound == Av1Compound.wedge) {
        _inter.makeWedgeMask(w, h, motion.wedgeIndex, motion.invertMask);
      } else if (compound == Av1Compound.difference) {
        _inter.makeDifferenceMask(w * h, color.depth, motion.invertMask);
      }
    }
    _inter.write(
      plane.samples,
      stride: plane.stride,
      x: x,
      y: y,
      width: w,
      height: h,
      depth: color.depth,
      compound: compound,
      sx: px,
      sy: py,
      firstWeight: compound == Av1Compound.distance
          ? av1DistanceWeight(_distance(motion.ref0), _distance(motion.ref1))
          : 8,
    );
  }

  void _convolveReference(
    int p,
    int x,
    int y,
    int w,
    int h,
    int ref,
    Av1Mv mv,
    int filterX,
    int filterY,
    Int32List output, {
    required bool compound,
    List<int>? matrix,
  }) {
    final (px, py) = p == 0 ? (0, 0) : (sx, sy);
    final reference = references[ref - 1];
    final source = reference.picture.planes[p];
    final frameSize = frame.header.size, refSize = reference.header.size;
    if (refSize.upscaledWidth > 2 * frameSize.width ||
        refSize.height > 2 * frameSize.height ||
        frameSize.width > 16 * refSize.upscaledWidth ||
        frameSize.height > 16 * refSize.height) {
      throw const FormatException('Invalid AV1 reference scale');
    }
    if (matrix != null &&
        w >= 8 &&
        h >= 8 &&
        !frame.header.motion.integer &&
        _warp.apply(
          output,
          source.samples,
          matrix,
          x: x,
          y: y,
          width: w,
          height: h,
          stride: source.stride,
          lastX: source.width - 1,
          lastY: source.height - 1,
          sx: px,
          sy: py,
          depth: color.depth,
          compound: compound,
        )) {
      return;
    }
    _inter.convolve(
      output,
      source.samples,
      stride: source.stride,
      referenceWidth: refSize.upscaledWidth,
      referenceHeight: refSize.height,
      frameWidth: frameSize.width,
      frameHeight: frameSize.height,
      x: x,
      y: y,
      width: w,
      height: h,
      sx: px,
      sy: py,
      mv: mv,
      filterX: filterX,
      filterY: filterY,
      depth: color.depth,
      compound: compound,
    );
  }

  void _blendInterIntra(
    int p,
    int x4,
    int y4,
    int w4,
    int h4,
    Av1InterMotion motion,
  ) {
    final plane = planes[p];
    final (px, py) = p == 0 ? (0, 0) : (sx, sy);
    final x = (x4 >> px) << 2, y = (y4 >> py) << 2;
    final w = (w4 << 2) >> px, h = (h4 << 2) >> py;
    final mode = motion.interIntraMode!;
    const modes = [
      Av1IntraMode.dc,
      Av1IntraMode.vertical,
      Av1IntraMode.horizontal,
      Av1IntraMode.smooth,
    ];
    _predictor.predict(
      plane.samples,
      plane.stride,
      x,
      y,
      Av1TxSize.of(w, h),
      depth: color.depth,
      mode: modes[mode],
      angleDelta: 0,
      above: y4 > y0,
      left: x4 > x0,
      aboveRight: false,
      belowLeft: false,
      right: (xEnd >> px) << 2,
      bottom: (yEnd >> py) << 2,
      edgeFilter: false,
      smoothEdge: false,
      recursiveFilter: null,
    );
    final wedge = motion.wedgeIndex >= 0;
    if (wedge && p == 0) _inter.makeWedgeMask(w, h, motion.wedgeIndex, false);
    final scale = 128 ~/ math.max(w, h);
    for (var r = 0, i = 0; r < h; r++) {
      final row = (y + r) * plane.stride + x;
      for (var c = 0; c < w; c++, i++) {
        final weight = wedge
            ? _inter.maskAt(c, r, w << px, px, py)
            : switch (mode) {
                1 => av1IiWeights1D[r * scale],
                2 => av1IiWeights1D[c * scale],
                3 => av1IiWeights1D[math.min(r, c) * scale],
                _ => 32,
              };
        plane.samples[row + c] = av1Round(
          weight * _predictor.samples[i] +
              (64 - weight) * plane.samples[row + c],
          6,
        );
      }
    }
  }

  void _blendObmc(int p, int x4, int y4, int w4, int h4) {
    final plane = planes[p];
    final (px, py) = p == 0 ? (0, 0) : (sx, sy);
    final width = (w4 << 2) >> px, height = (h4 << 2) >> py;
    final maximum = (1 << color.depth) - 1;
    for (final above in [true, false]) {
      if (above ? y4 <= y0 || (width * height < 64) : x4 <= x0) continue;
      final limit = math.min(4, (above ? w4 : h4).bitLength - 1);
      final extent = above ? math.min(w4, xEnd - x4) : math.min(h4, yEnd - y4);
      var count = 0;
      for (var i = 0; i < extent && count < limit;) {
        final b = _at(
          above ? (x4 + i) | 1 : x4 - 1,
          above ? y4 - 1 : (y4 + i) | 1,
        );
        final step = (above ? b?.width ?? 2 : b?.height ?? 2).clamp(2, 16);
        final m = b?.motion;
        if (m != null) {
          count++;
          final x = ((x4 + (above ? i : 0)) >> px) << 2;
          final y = ((y4 + (above ? 0 : i)) >> py) << 2;
          final w = above
              ? (math.min(step, w4 - i) << 2) >> px
              : math.min(width >> 1, 32 >> px);
          final h = above
              ? math.min(height >> 1, 32 >> py)
              : (math.min(step, h4 - i) << 2) >> py;
          _convolveReference(
            p,
            x,
            y,
            w,
            h,
            m.ref0,
            m.mv0,
            m.filterX,
            m.filterY,
            _inter.first,
            compound: false,
          );
          final mask = _obmcMasks[(above ? h : w).bitLength - 2];
          for (var r = 0, k = 0; r < h; r++) {
            final row = (y + r) * plane.stride + x;
            for (var c = 0; c < w; c++, k++) {
              final weight = mask[above ? r : c];
              final predicted = _inter.first[k].clamp(0, maximum);
              plane.samples[row + c] = av1Round(
                weight * plane.samples[row + c] + (64 - weight) * predicted,
                6,
              );
            }
          }
        }
        i += step;
      }
    }
  }

  void _interResidual(
    int p,
    int x4,
    int y4,
    Av1TxSize size,
    int width,
    int height,
    bool lossless,
    int segment,
    int blockX,
    int blockY,
  ) {
    final plane = planes[p];
    final (sx4, sy4) = p == 0 ? (0, 0) : (sx, sy);
    final (eob: eob, type: type) = _coefficientDecoder.read(
      _quantized,
      neighbors: _neighbors[p],
      x4: x4 - (x0 >> sx4),
      y4: y4 - (y0 >> sy4),
      blockWidth: width,
      blockHeight: height,
      size: size,
      chroma: p != 0,
      readType: () =>
          _interTxType(p, size, x4, y4, lossless, segment, blockX, blockY),
    );
    if (p == 0) {
      final right = math.min(xEnd, x4 + (size.width >> 2));
      for (var r = y4; r < math.min(yEnd, y4 + (size.height >> 2)); r++) {
        final at = r * state.columns;
        state.txTypes.fillRange(at + x4, at + right, type.index);
      }
    }
    if (eob == 0) return;
    _quantizer.apply(
      _quantized,
      size,
      type,
      p,
      currentQ: _currentQ,
      segmentDelta: params.segmentation.features[segment][0] ?? 0,
    );
    _inverse.apply(
      _quantized,
      _residual,
      size,
      type,
      color.depth,
      lossless: lossless,
    );
    final max = (1 << color.depth) - 1;
    for (var r = 0, j = 0; r < size.height; r++) {
      final at = ((y4 << 2) + r) * plane.stride + (x4 << 2);
      for (var c = 0; c < size.width; c++, j++) {
        plane.samples[at + c] = (plane.samples[at + c] + _residual[j]).clamp(
          0,
          max,
        );
      }
    }
  }

  Av1TxType _interTxType(
    int p,
    Av1TxSize size,
    int x4,
    int y4,
    bool lossless,
    int segment,
    int blockX,
    int blockY,
  ) {
    if (lossless || size.squareUp > 3) return Av1TxType.dctDct;
    const sets = [
      [9, 10, 11, 12, 13, 14, 15, 0, 1, 2, 4, 5, 3, 6, 7, 8],
      [9, 10, 11, 0, 1, 2, 4, 5, 3, 6, 7, 8],
      [9, 0],
    ];
    final set = params.reducedTransforms || size.squareUp == 3
        ? 2
        : size.square == 2
        ? 1
        : 0;
    if (p != 0) {
      final col = math.max(blockX, x4 << sx), row = math.max(blockY, y4 << sy);
      final type = state.txTypes[row * state.columns + col];
      return sets[set].contains(type)
          ? Av1TxType.values[type]
          : Av1TxType.dctDct;
    }
    if (params.quantization.base +
            (params.segmentation.features[segment][0] ?? 0) <=
        0) {
      return Av1TxType.dctDct;
    }
    final square = size.square;
    final table = switch (set) {
      0 => interInterTxTypeSet1Cdf[square],
      1 => interInterTxTypeSet2Cdf,
      _ => interInterTxTypeSet3Cdf[square],
    };
    final symbol = _symbol(_Family.interTx, table, set, square);
    return Av1TxType.values[sets[set][symbol]];
  }
}

const _obmcMasks = [
  [45, 64],
  [39, 50, 59, 64],
  [36, 42, 48, 53, 57, 61, 64, 64],
  [34, 37, 40, 43, 46, 49, 52, 54, 56, 58, 60, 61, 64, 64, 64, 64],
  [
    33,
    35,
    36,
    38,
    40,
    41,
    43,
    44,
    45,
    47,
    48,
    50,
    51,
    52,
    53,
    55,
    56,
    57,
    58,
    59,
    60,
    60,
    61,
    62,
    64,
    64,
    64,
    64,
    64,
    64,
    64,
    64,
  ],
];
