part of 'decoder.dart';

// Tables O.2 and O.3, with the COD bit included in the codeword.
final _h263EpMode = _Vlc([
  1,
  1,
  1,
  2,
  1,
  4,
  2,
  4,
  3,
  4,
  1,
  6,
  2,
  6,
  3,
  6,
  1,
  7,
  1,
  8,
  1,
  9,
  1,
  10,
]);
final _h263EiMode = _Vlc([
  1,
  1,
  1,
  2,
  1,
  4,
  2,
  4,
  3,
  4,
  1,
  5,
  1,
  8,
  2,
  8,
  3,
  8,
  1,
  9,
  9,
  9,
  10,
  9,
  11,
  9,
  12,
  9,
  13,
  9,
  14,
  9,
  15,
  9,
  1,
  10,
]);

enum _LayerPrediction { forward, upward, blend, intra }

const _h263EpModes = [
  (_LayerPrediction.forward, false, false),
  (_LayerPrediction.forward, true, false),
  (_LayerPrediction.forward, true, true),
  (_LayerPrediction.upward, false, false),
  (_LayerPrediction.upward, true, false),
  (_LayerPrediction.upward, true, true),
  (_LayerPrediction.blend, false, false),
  (_LayerPrediction.blend, true, false),
  (_LayerPrediction.blend, true, true),
  (_LayerPrediction.intra, true, false),
  (_LayerPrediction.intra, true, true),
];

extension _H263Enhancement on _H263Macroblocks {
  void decodeEnhancement(H263Picture lower) {
    final columns = _columns;
    final segments = header.format.independentSegments
        ? _upwardSegments(lower)
        : null;
    final upward = _h263AlignReference(
      _h263Upsample(lower, header.format, segments: segments),
      reduced: header.reduced,
    );
    final ei = header.enhancementIntra;
    final modes = ei ? _h263EiMode : _h263EpMode;
    final stuffing = ei ? 17 : _h263EpModes.length;
    for (final index in _macroblockOrder()) {
      final (code, shortcut) = _readLayerMacroblock(modes, stuffing);
      final (prediction, texture, changeQuant) = ei
          ? (
              code >= 9 ? _LayerPrediction.intra : _LayerPrediction.upward,
              code != 0,
              code != 0 && (code - 1) & 4 != 0,
            )
          : _h263EpModes[code];
      final intra = prediction == _LayerPrediction.intra;
      final advanced = intra && header.format.advancedIntra;
      final fromLeft = advanced ? _readIntraDirection() : null;
      var pattern = 0;
      if (texture) {
        final chroma = ei ? (code - 1) & 3 : _h263BChroma.read(_bits);
        final cbpy = _lumaPattern.read(_bits);
        final normal =
            prediction != _LayerPrediction.forward ||
            header.format.alternateVlc && chroma == 3;
        pattern = ((normal ? cbpy : cbpy ^ 15) << 2) | chroma;
      }
      if (changeQuant) _readQuantChange();
      final x = index % columns, y = index ~/ columns;
      final usesForward =
          prediction == _LayerPrediction.forward ||
          prediction == _LayerPrediction.blend;
      if (usesForward) {
        final referenceIndex = texture ? _readErpsMotionReference() : shortcut;
        final vectors = texture ? _readMotion(x, y, false) : [_zeroVector];
        _prediction.predictH263(
          picture,
          _forwardAt(referenceIndex).picture,
          x,
          y,
          vectors,
          reduced: header.reduced,
          noRound: header.noRound,
          bounds: _boundsAt(index),
        );
      }
      if (prediction == _LayerPrediction.upward ||
          prediction == _LayerPrediction.blend) {
        _prediction.predictH263(
          picture,
          upward,
          x,
          y,
          [_zeroVector],
          reduced: header.reduced,
          average: usesForward,
          bounds: _boundsAt(index),
        );
      }
      for (var block = 0; block < 6; block++) {
        final coded = pattern & (32 >> block) != 0;
        if (intra || coded) {
          _readBlock(
            x,
            y,
            block,
            intra: intra,
            coded: coded,
            advanced: advanced,
            fromLeft: fromLeft,
          );
        }
      }
      if ((header.reduced || header.format.loopFilter) &&
          (code != 0 || shortcut != 0)) {
        _filterQuant[index] = _quant;
      }
    }
    _finishFilter();
  }
}

H263Picture _h263Upsample(
  H263Picture lower,
  H263Format target, {
  Iterable<_MotionBounds>? segments,
}) {
  if (_h263Matches(lower, target)) return lower;
  final doubleX = lower.width * 2 == target.width;
  final doubleY = lower.height * 2 == target.height;
  if ((!doubleX && lower.width != target.width) ||
      (!doubleY && lower.height != target.height)) {
    throw UnsupportedError('Invalid H.263+ spatial scalability ratio');
  }
  final picture = H263Picture._(target);
  final regions =
      segments ??
      [(left: 0, top: 0, right: picture.stride, bottom: picture.rows * 16)];
  for (var plane = 0; plane < 3; plane++) {
    final sub = plane == 0 ? 0 : 1;
    final source = lower.planes[plane], output = picture.planes[plane];
    final stride = lower.stride >> sub, outStride = picture.stride >> sub;
    final lastX = (lower.width >> sub) - 1, lastY = (lower.height >> sub) - 1;
    final height = picture.rows * 16 >> sub;
    final shift = (doubleX ? 2 : 0) + (doubleY ? 2 : 0);
    final bias = 1 << (shift - 1);
    // Annex O uses quarter-pixel phases between source samples. Multiply
    // the two axes' weights before rounding, including at replicated edges.
    for (final region in regions) {
      final (:left, :top, :right, :bottom) = _scaleMotionBounds(region, sub);
      final dx = doubleX ? 1 : 0, dy = doubleY ? 1 : 0;
      final minX = math.min(left >> dx, lastX);
      final minY = math.min(top >> dy, lastY);
      final maxX = math.min((right >> dx) - 1, lastX);
      final maxY = math.min((bottom >> dy) - 1, lastY);
      final endX = math.min(right, outStride), endY = math.min(bottom, height);
      for (var y = top; y < endY; y++) {
        final y0 = doubleY ? (y - 1) >> 1 : y;
        final lowerRow = (y0 + dy).clamp(minY, maxY) * stride;
        final upperRow = y0.clamp(minY, maxY) * stride;
        final wy = doubleY ? (y.isOdd ? 1 : 3) : 0;
        final ty = doubleY ? 4 - wy : 1;
        for (var x = left; x < endX; x++) {
          final x0 = doubleX ? (x - 1) >> 1 : x;
          final l = x0.clamp(minX, maxX);
          final r = (x0 + dx).clamp(minX, maxX);
          final wx = doubleX ? (x.isOdd ? 1 : 3) : 0;
          final tx = doubleX ? 4 - wx : 1;
          final a = source[upperRow + l] * tx + source[upperRow + r] * wx;
          final b = source[lowerRow + l] * tx + source[lowerRow + r] * wx;
          output[y * outStride + x] = (a * ty + b * wy + bias) >> shift;
        }
      }
    }
  }
  return picture;
}
