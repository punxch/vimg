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
  void decodeEnhancement(H263Picture? previous, H263Picture upward) {
    final columns = picture.columns;
    final count = columns * picture.rows;
    final ei = header.enhancementIntra;
    final modes = ei ? _h263EiMode : _h263EpMode;
    final stuffing = ei ? 17 : _h263EpModes.length;
    for (var index = 0; index < count; index++) {
      if (index != 0) _readGroupHeader(index, count);
      var code = modes.read(_bits);
      while (code == stuffing) {
        code = modes.read(_bits);
      }
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
        final vectors = texture ? _readMotion(x, y, false) : [_zeroVector];
        _prediction.predict(
          picture,
          previous!,
          x,
          y,
          vectors,
          noRound: header.noRound,
        );
      }
      if (prediction == _LayerPrediction.upward ||
          prediction == _LayerPrediction.blend) {
        _prediction.predict(
          picture,
          upward,
          x,
          y,
          [_zeroVector],
          average: usesForward,
          truncateAverage: true,
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
      if (header.format.loopFilter && code != 0) _filterQuant[index] = _quant;
    }
    if (header.format.loopFilter) {
      _deblockH263(
        picture,
        _filterQuant,
        modifiedQuant: header.format.modifiedQuant,
      );
    }
  }
}

H263Picture _h263Upsample(H263Picture lower, H263Format target) {
  if (_h263Matches(lower, target)) return lower;
  final doubleX = lower.width * 2 == target.width;
  final doubleY = lower.height * 2 == target.height;
  if ((!doubleX && lower.width != target.width) ||
      (!doubleY && lower.height != target.height)) {
    throw UnsupportedError('Invalid H.263+ spatial scalability ratio');
  }
  final picture = H263Picture._(target);
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
    for (var y = 0; y < height; y++) {
      final y0 = doubleY ? (y - 1) >> 1 : y;
      final bottom = ((doubleY ? y0 + 1 : y0).clamp(0, lastY)) * stride;
      final top = y0.clamp(0, lastY) * stride;
      final wy = doubleY ? (y.isOdd ? 1 : 3) : 0;
      final ty = doubleY ? 4 - wy : 1;
      for (var x = 0; x < outStride; x++) {
        final x0 = doubleX ? (x - 1) >> 1 : x;
        final left = x0.clamp(0, lastX);
        final right = (doubleX ? x0 + 1 : x0).clamp(0, lastX);
        final wx = doubleX ? (x.isOdd ? 1 : 3) : 0;
        final tx = doubleX ? 4 - wx : 1;
        final a = source[top + left] * tx + source[top + right] * wx;
        final b = source[bottom + left] * tx + source[bottom + right] * wx;
        output[y * outStride + x] = (a * ty + b * wy + bias) >> shift;
      }
    }
  }
  return picture;
}
