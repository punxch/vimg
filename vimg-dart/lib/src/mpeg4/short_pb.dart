part of 'decoder.dart';

enum _PbMode { direct, forward, backward }

final class _H263Pb {
  _H263Pb(
    this.header,
    this.previous,
    this.current,
    this.sampler,
    this.distance,
    this.output,
  );

  final H263Header header;
  final H263Picture previous, current;
  final H263Picture? output;
  final _Mpeg4MotionCompensation sampler;
  final int distance;
  late final residuals = List.generate(6, (_) => Int16List(64));
  late final _blockSize = header.macroblockSize >> 1;
  late final _backward = Uint8List(_blockSize * _blockSize);
  _PbMode _mode = _PbMode.direct;
  _Vector _motion = _zeroVector;
  int _pattern = 0;

  _Vector get leftForward => _mode == _PbMode.forward ? _motion : _zeroVector;

  void queue(_PbMode mode, _Vector vector, int pattern) {
    _mode = mode;
    _motion = vector;
    _pattern = pattern;
  }

  void reconstruct(
    int x,
    int y,
    _PictureMotion motion,
    MpegIdct transform,
    Int16List? reducedSamples,
  ) {
    final picture = output!;
    switch (_mode) {
      case _PbMode.direct:
        _predictDirect(picture, x, y, motion);
      case _PbMode.forward:
        sampler.predictH263(picture, previous, x, y, [
          _motion,
        ], reduced: header.reduced);
      case _PbMode.backward:
        sampler.predictH263(picture, current, x, y, [
          _zeroVector,
        ], reduced: header.reduced);
    }
    for (var block = 0; block < 6; block++) {
      if (_pattern & (32 >> block) != 0) {
        _writeH263Block(
          transform,
          picture,
          x,
          y,
          block,
          residuals[block],
          false,
          reducedSamples,
        );
      }
    }
  }

  void _predictDirect(
    H263Picture picture,
    int x,
    int y,
    _PictureMotion motion,
  ) {
    final forward = <_Vector>[], backward = <_Vector>[];
    final offset = header.pb!.offset;
    (int, int) scale(int component, int delta) {
      final scaled = component * offset ~/ distance;
      if (delta == 0)
        return (scaled, component * (offset - distance) ~/ distance);
      final forward = _addMotionDifference(
        scaled,
        delta,
        32,
        header.longVectors,
      );
      return (forward, forward - component);
    }

    var sumX = 0, sumY = 0;
    for (var i = 0; i < 4; i++) {
      final p = motion.at(x * 2 + (i & 1), y * 2 + (i >> 1));
      final (fx, bx) = scale(p.x, _motion.x);
      final (fy, by) = scale(p.y, _motion.y);
      forward.add((x: fx, y: fy));
      final vector = (x: bx, y: by);
      final actual = header.reduced ? _h263ExpandVector(vector) : vector;
      backward.add(actual);
      sumX += actual.x;
      sumY += actual.y;
    }
    // RTYPE does not apply to the B-part of Improved PB-pictures.
    sampler.predictH263(
      picture,
      previous,
      x,
      y,
      forward,
      reduced: header.reduced,
    );
    final chroma = _chromaMotion((x: sumX, y: sumY), split: true);
    for (var block = 0; block < 4; block++) {
      _blendBlock(
        picture,
        0,
        x * 2 * _blockSize,
        y * 2 * _blockSize,
        _blockSize * (block & 1),
        _blockSize * (block >> 1),
        backward[block],
      );
    }
    for (var plane = 1; plane < 3; plane++) {
      _blendBlock(picture, plane, x * _blockSize, y * _blockSize, 0, 0, chroma);
    }
  }

  void _blendBlock(
    H263Picture picture,
    int plane,
    int mx,
    int my,
    int bx,
    int by,
    _Vector motion,
  ) {
    final subsample = plane == 0 ? 0 : 1;
    final stride = picture.stride >> subsample;
    final height = picture.rows * 16 >> subsample;
    final last = ((header.macroblockSize >> subsample) - 1) * 2;
    sampler._half(
      _backward,
      current.planes[plane],
      stride,
      height,
      mx + bx,
      my + by,
      _blockSize,
      motion.x,
      motion.y,
      false,
      false,
      packed: true,
    );
    final destination = picture.planes[plane];
    // Annex G only uses backward prediction where both interpolation
    // samples lie inside the colocated, reconstructed P macroblock.
    for (var j = 0; j < _blockSize; j++) {
      final sy = 2 * (by + j) + motion.y;
      if (sy < 0 || sy > last) continue;
      for (var i = 0; i < _blockSize; i++) {
        final sx = 2 * (bx + i) + motion.x;
        if (sx < 0 || sx > last) continue;
        final position = (my + by + j) * stride + mx + bx + i;
        destination[position] =
            (destination[position] + _backward[j * _blockSize + i]) >> 1;
      }
    }
  }
}
