part of 'decoder.dart';

final class _H263Overlap {
  _H263Overlap(
    this.picture,
    this.reference,
    this.motion,
    this.sampler,
    H263Header header,
  ) : _segments = Uint16List(picture.columns * picture.rows),
      _structured = header.format.structured,
      _noRound = header.noRound;

  final H263Picture picture, reference;
  final _PictureMotion motion;
  final _Mpeg4MotionCompensation sampler;
  final bool _structured, _noRound;
  // Zero denotes an intra macroblock. Skipped inter macroblocks have zero
  // motion but can still contribute to and receive overlapped prediction.
  final Uint16List _segments;
  final residuals = List.generate(6, (_) => Int16List(64));
  final _samples = List.generate(5, (_) => Uint8List(64));

  void markInter(int index, int start) {
    _segments[index] = _structured ? start + 1 : 1;
  }

  void predict(int x, int y) {
    final columns = picture.columns;
    final segment = _segments[y * columns + x];
    var sumX = 0, sumY = 0;
    for (var block = 0; block < 4; block++) {
      final bx = x * 2 + (block & 1), by = y * 2 + (block >> 1);
      final center = motion.at(bx, by);
      _Vector remote(int rx, int ry) {
        if (rx < 0 ||
            rx >= columns * 2 ||
            ry < 0 ||
            _segments[(ry >> 1) * columns + (rx >> 1)] != segment) {
          return center;
        }
        return motion.at(rx, ry);
      }

      _predictBlock(bx * 8, by * 8, [
        center,
        remote(bx, by - 1),
        block < 2 ? remote(bx, by + 1) : center,
        remote(bx - 1, by),
        remote(bx + 1, by),
      ]);
      sumX += center.x;
      sumY += center.y;
    }
    sampler._predictChroma(
      picture,
      reference,
      x,
      y,
      (x: sumX, y: sumY),
      split: true,
      noRound: _noRound,
    );
  }

  void _predictBlock(int x, int y, List<_Vector> vectors) {
    final output = picture.planes[0], source = reference.planes[0];
    final stride = picture.stride, height = picture.rows * 16;
    final center = vectors.first;
    if (vectors.every((vector) => vector == center)) {
      sampler._half(
        output,
        source,
        stride,
        height,
        x,
        y,
        8,
        center.x,
        center.y,
        _noRound,
        false,
      );
      return;
    }
    for (final (i, vector) in vectors.indexed) {
      if (i != 0 && vector == center) continue;
      sampler._half(
        _samples[i],
        source,
        stride,
        height,
        x,
        y,
        8,
        vector.x,
        vector.y,
        _noRound,
        false,
        packed: true,
      );
    }
    Uint8List samples(int i) => _samples[vectors[i] == center ? 0 : i];
    final middle = _samples[0], left = samples(3), right = samples(4);
    // Annex F weights depend on distance to the nearest horizontal and
    // vertical block edges. The three weights sum to eight at each pixel.
    for (var j = 0; j < 8; j++) {
      final vertical = samples(j < 4 ? 1 : 2);
      final edgeY = math.min(j, 7 - j);
      for (var i = 0; i < 8; i++) {
        final horizontal = i < 4 ? left : right;
        final edgeX = math.min(i, 7 - i);
        final wY = edgeY == 0 || (edgeY == 1 && edgeX >= 2) ? 2 : 1;
        final wX = edgeX == 0 || (edgeX == 1 && edgeY != 0) ? 2 : 1;
        final k = j * 8 + i;
        output[(y + j) * stride + x + i] =
            ((8 - wX - wY) * middle[k] +
                wX * horizontal[k] +
                wY * vertical[k] +
                4) >>
            3;
      }
    }
  }
}
