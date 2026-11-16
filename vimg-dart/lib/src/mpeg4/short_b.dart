part of 'decoder.dart';

typedef _H263Reference = ({
  H263Picture picture,
  int temporal,
  bool? resamplingRound,
  bool reduced,
  _PictureMotion motion,
  Uint8List? intraWithMotion,
});

// Table O.1, with COD included in the VLC so the first entry is skipped.
final _h263BMode = _Vlc([
  1,
  1,
  3,
  3,
  1,
  5,
  4,
  4,
  5,
  4,
  6,
  6,
  2,
  4,
  3,
  4,
  7,
  6,
  4,
  6,
  5,
  6,
  1,
  6,
  1,
  7,
  1,
  8,
  1,
  10,
]);
final _h263BChroma = _Vlc([0, 1, 2, 2, 7, 3, 6, 3]);

enum _H263BPrediction { direct, forward, backward, both, intra }

const _h263BModes = [
  (_H263BPrediction.direct, false, false),
  (_H263BPrediction.direct, true, false),
  (_H263BPrediction.direct, true, true),
  (_H263BPrediction.forward, false, false),
  (_H263BPrediction.forward, true, false),
  (_H263BPrediction.forward, true, true),
  (_H263BPrediction.backward, false, false),
  (_H263BPrediction.backward, true, false),
  (_H263BPrediction.backward, true, true),
  (_H263BPrediction.both, false, false),
  (_H263BPrediction.both, true, false),
  (_H263BPrediction.both, true, true),
  (_H263BPrediction.intra, true, false),
  (_H263BPrediction.intra, true, true),
];

extension _H263Bidirectional on _H263Macroblocks {
  void decodeB(_H263Reference latest) {
    final columns = _columns, rows = _rows;
    final backward = _PictureMotion(columns, rows, false);
    final backwardPictures = <H263Picture, H263Picture>{};
    (H263Picture, _H263Reference) backwardAt(int index) {
      final source = erps?.backward(_erpsGroup!, index) ?? latest;
      final aligned = backwardPictures.putIfAbsent(
        source.picture,
        () => _h263AlignReference(source.picture, reduced: header.reduced),
      );
      _validateTemporalSegments(aligned);
      return (aligned, source);
    }

    late final pictureTiming = erps?.directTiming();
    _decodeMacroblocks((index) {
      final bounds = _boundsAt(index);
      final x = index % columns, y = index ~/ columns;
      final (mode, shortcut) = _readLayerMacroblock(
        _h263BMode,
        _h263BModes.length,
      );
      if (shortcut != 0) {
        _prediction.predictH263(
          picture,
          _forwardAt(shortcut).picture,
          x,
          y,
          [_zeroVector],
          reduced: header.reduced,
          bounds: bounds,
        );
        if (header.reduced) _filterQuant[index] = _quant;
        return;
      }
      final (prediction, texture, changeQuant) = _h263BModes[mode];
      final intra = prediction == _H263BPrediction.intra;
      final aic = intra && header.format.advancedIntra;
      final fromLeft = aic ? _readIntraDirection() : null;
      final chroma = texture ? _h263BChroma.read(_bits) : 0;
      var pattern = 0;
      if (texture) {
        final luma = _lumaPattern.read(_bits);
        final normal = intra || (header.format.alternateVlc && chroma == 3);
        pattern = ((normal ? luma : luma ^ 15) << 2) | chroma;
      }
      if (changeQuant) _readQuantChange();
      _stagePartitionTexture(
        pattern,
        intra: intra,
        advanced: aic,
        fromLeft: fromLeft,
      );
      switch (prediction) {
        case _H263BPrediction.direct:
          final forward = _forwardAt();
          final (newer, source) = backwardAt(0);
          _predictBDirect(
            forward.picture,
            newer,
            source,
            x,
            y,
            pictureTiming?.offset ?? forward.offset,
            pictureTiming?.distance ?? forward.distance,
            bounds,
          );
        case _H263BPrediction.forward:
        case _H263BPrediction.both:
          final forward = _forwardAt(_readErpsMotionReference());
          final vector = _readBVector(_motion, x, y);
          _prediction.predictH263(
            picture,
            forward.picture,
            x,
            y,
            [vector],
            reduced: header.reduced,
            bounds: bounds,
          );
        case _H263BPrediction.backward:
        case _H263BPrediction.intra:
          break;
      }
      if (prediction == _H263BPrediction.both ||
          prediction == _H263BPrediction.backward) {
        final (newer, _) = backwardAt(_readErpsBackwardReference());
        final vector = _readBVector(backward, x, y, reverse: true);
        _prediction.predictH263(
          picture,
          newer,
          x,
          y,
          [vector],
          reduced: header.reduced,
          average: prediction == _H263BPrediction.both,
          bounds: bounds,
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
            advanced: aic,
            fromLeft: fromLeft,
          );
        }
      }
      if (header.reduced && mode != 0) _filterQuant[index] = _quant;
    });
    _finishFilter();
  }

  int _readErpsBackwardReference() {
    if (_erpsGroup?.syntax.twoBackward != true) return 0;
    final position = _bits.position;
    final index = _bits.bit();
    if (index == 0 && !header.format.unrestricted) {
      _bits.position = position - 5;
      final zeroes = _bits.read(5) == 0;
      _bits.skip(1);
      if (zeroes) h263Marker(_bits);
    }
    return index;
  }

  _Vector _readBVector(
    _PictureMotion motion,
    int x,
    int y, {
    bool reverse = false,
  }) {
    final vectors = _partition?.motion;
    final vector = vectors != null && !reverse
        ? vectors.single
        : _readSecondaryVector(_h263MotionPrediction(motion, x, y, 0));
    for (var block = 0; block < 4; block++) {
      motion.store(x, y, block, vector);
    }
    return vector;
  }

  void _predictBDirect(
    H263Picture older,
    H263Picture newer,
    _H263Reference latest,
    int x,
    int y,
    int offset,
    int period,
    _MotionBounds? bounds,
  ) {
    final forward = <_Vector>[], backward = <_Vector>[];
    final size = header.macroblockSize >> 1;
    final referenceSize = latest.reduced ? 16 : 8;
    final referenceColumns =
        (newer.width + 2 * referenceSize - 1) ~/ (2 * referenceSize);
    final referenceRows =
        (newer.height + 2 * referenceSize - 1) ~/ (2 * referenceSize);
    int scale(int component, int elapsed) {
      if (header.reduced && !latest.reduced) {
        // Convert a full-resolution anchor to the pseudo-motion domain
        // before temporal scaling, retaining any fractional pseudo-vector.
        return component.sign * (component.abs() + 1) * elapsed ~/ (2 * period);
      }
      return component * elapsed ~/ period;
    }

    for (var block = 0; block < 4; block++) {
      final bx = math.min(
        (x * 2 + (block & 1)) * size ~/ referenceSize,
        2 * referenceColumns - 1,
      );
      final by = math.min(
        (y * 2 + (block >> 1)) * size ~/ referenceSize,
        2 * referenceRows - 1,
      );
      final referenceIndex = (by >> 1) * referenceColumns + (bx >> 1);
      var vector = latest.intraWithMotion?[referenceIndex] == 1
          ? _zeroVector
          : latest.motion.at(bx, by);
      if (latest.reduced && !header.reduced) vector = _h263ExpandVector(vector);
      forward.add((x: scale(vector.x, offset), y: scale(vector.y, offset)));
      backward.add((
        x: scale(vector.x, offset - period),
        y: scale(vector.y, offset - period),
      ));
    }
    _prediction.predictH263(
      picture,
      older,
      x,
      y,
      forward,
      reduced: header.reduced,
      bounds: bounds,
    );
    _prediction.predictH263(
      picture,
      newer,
      x,
      y,
      backward,
      reduced: header.reduced,
      average: true,
      bounds: bounds,
    );
  }
}
