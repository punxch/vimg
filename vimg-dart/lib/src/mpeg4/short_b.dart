part of 'decoder.dart';

typedef _H263Reference = ({
  H263Picture picture,
  int temporal,
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
  void decodeB(
    H263Picture older,
    _H263Reference latest,
    int offset,
    int period,
  ) {
    final columns = picture.columns, rows = picture.rows;
    final backward = _PictureMotion(columns, rows, false);
    for (var index = 0; index < columns * rows; index++) {
      if (index != 0) _readGroupHeader(index, columns * rows);
      final x = index % columns, y = index ~/ columns;
      var mode = _h263BMode.read(_bits);
      while (mode == _h263BModes.length) {
        mode = _h263BMode.read(_bits);
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
      switch (prediction) {
        case _H263BPrediction.direct:
          _predictBDirect(older, latest, x, y, index, offset, period);
        case _H263BPrediction.forward:
        case _H263BPrediction.both:
          final forward = _readBVector(_motion, x, y);
          _prediction.predict(picture, older, x, y, [forward]);
          if (prediction == _H263BPrediction.both) {
            final vector = _readBVector(backward, x, y);
            _prediction.predict(
              picture,
              latest.picture,
              x,
              y,
              [vector],
              average: true,
              truncateAverage: true,
            );
          }
        case _H263BPrediction.backward:
          final vector = _readBVector(backward, x, y);
          _prediction.predict(picture, latest.picture, x, y, [vector]);
        case _H263BPrediction.intra:
          break;
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
    }
  }

  _Vector _readBVector(_PictureMotion motion, int x, int y) {
    final guess = _motionPrediction(
      motion,
      picture.columns,
      _sliceStart,
      x,
      y,
      0,
      h263: true,
    );
    final vector = _readVector(guess);
    for (var block = 0; block < 4; block++) {
      motion.store(x, y, block, vector);
    }
    return vector;
  }

  void _predictBDirect(
    H263Picture older,
    _H263Reference latest,
    int x,
    int y,
    int index,
    int offset,
    int period,
  ) {
    final forward = <_Vector>[], backward = <_Vector>[];
    for (var block = 0; block < 4; block++) {
      final vector = latest.intraWithMotion?[index] == 1
          ? _zeroVector
          : latest.motion.at(x * 2 + (block & 1), y * 2 + (block >> 1));
      forward.add((
        x: vector.x * offset ~/ period,
        y: vector.y * offset ~/ period,
      ));
      backward.add((
        x: vector.x * (offset - period) ~/ period,
        y: vector.y * (offset - period) ~/ period,
      ));
    }
    _prediction.predict(picture, older, x, y, forward);
    _prediction.predict(
      picture,
      latest.picture,
      x,
      y,
      backward,
      average: true,
      truncateAverage: true,
    );
  }
}
