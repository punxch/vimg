part of 'decoder.dart';

final class _H263Overlap {
  _H263Overlap(this.picture, this.motion, this.sampler, H263Header header)
    : _segments = Uint16List(header.macroblockColumns * header.macroblockRows),
      _columns = header.macroblockColumns,
      _scale = header.reduced ? 1 : 0,
      _segmented =
          header.format.structured || header.format.independentSegments,
      _noRound = header.noRound;

  final H263Picture picture;
  final _PictureMotion motion;
  final _Mpeg4MotionCompensation sampler;
  final int _columns, _scale;
  final bool _segmented, _noRound;
  // Zero denotes an intra macroblock with no transmitted motion vector.
  // Skipped inter blocks contribute a zero vector to their neighbors.
  final Uint16List _segments;
  final residuals = List.generate(6, (_) => Int16List(64));
  late final _samples = List.generate(5, (_) => Uint8List(64 << (2 * _scale)));

  void markMotion(int index, int start) {
    _segments[index] = _segmented ? start + 1 : 1;
  }

  void predict(
    int x,
    int y,
    H263Picture reference,
    _MotionBounds? bounds,
    List<H263Picture>? lumaReferences,
  ) {
    final columns = _columns, size = 8 << _scale;
    final segment = _segments[y * columns + x];
    _Vector motionAt(int x, int y) {
      final vector = motion.at(x, y);
      return _scale == 0 ? vector : _h263ExpandVector(vector);
    }

    var sumX = 0, sumY = 0;
    for (var block = 0; block < 4; block++) {
      final bx = x * 2 + (block & 1), by = y * 2 + (block >> 1);
      final center = motionAt(bx, by);
      _Vector remote(int rx, int ry) {
        if (rx < 0 ||
            rx >= columns * 2 ||
            ry < 0 ||
            _segments[(ry >> 1) * columns + (rx >> 1)] != segment) {
          return center;
        }
        return motionAt(rx, ry);
      }

      _predictBlock(lumaReferences?[block] ?? reference, bx * size, by * size, [
        center,
        remote(bx, by - 1),
        block < 2 ? remote(bx, by + 1) : center,
        remote(bx - 1, by),
        remote(bx + 1, by),
      ], bounds);
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
      blockSize: size,
      bounds: bounds,
    );
  }

  void _predictBlock(
    H263Picture reference,
    int x,
    int y,
    List<_Vector> vectors,
    _MotionBounds? bounds,
  ) {
    final output = picture.planes[0], source = reference._referencePlane(0);
    final stride = picture.stride, height = picture.rows * 16;
    final size = 8 << _scale;
    final center = vectors.first;
    if (vectors.every((vector) => vector == center)) {
      sampler._half(
        output,
        source,
        stride,
        height,
        x,
        y,
        size,
        center.x,
        center.y,
        _noRound,
        false,
        bounds: bounds,
      );
      return;
    }
    for (final (i, vector) in vectors.indexed) {
      if (i != 0 && vector == center) continue;
      // A remote vector contributes only to the corresponding half.
      final vertical = i == 1 || i == 2;
      final horizontal = i == 3 || i == 4;
      final startY = i == 2 ? size ~/ 2 : 0;
      final startX = i == 4 ? size ~/ 2 : 0;
      sampler._half(
        _samples[i],
        source,
        stride,
        height,
        x + startX,
        y + startY,
        size,
        vector.x,
        vector.y,
        _noRound,
        false,
        packed: true,
        rows: vertical ? size ~/ 2 : size,
        columns: horizontal ? size ~/ 2 : size,
        outputOffset: startY * size + startX,
        bounds: bounds,
      );
    }
    Uint8List samples(int i) => _samples[vectors[i] == center ? 0 : i];
    final middle = _samples[0], left = samples(3), right = samples(4);
    // Annex Q doubles the Annex F weighting grid along both axes.
    for (var j = 0; j < size; j++) {
      final vertical = samples(j < size ~/ 2 ? 1 : 2);
      final edgeY = math.min(j, size - 1 - j) >> _scale;
      for (var i = 0; i < size; i++) {
        final horizontal = i < size ~/ 2 ? left : right;
        final edgeX = math.min(i, size - 1 - i) >> _scale;
        final wY = edgeY == 0 || (edgeY == 1 && edgeX >= 2) ? 2 : 1;
        final wX = edgeX == 0 || (edgeX == 1 && edgeY != 0) ? 2 : 1;
        final k = j * size + i;
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
