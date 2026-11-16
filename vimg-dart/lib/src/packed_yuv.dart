part of 'yuv_image.dart';

bool _hasDeepYuvDepth(int matrix, int lumaDepth, int chromaDepth) =>
    matrix != 0 && lumaDepth > 8 && lumaDepth == chromaDepth;

bool _hasDeepGrayPacking(int depth, bool fullRange) => depth > 8 && fullRange;

// The horizontal identity stage produces Q7, which the matrix reads as Q9.
int _unscaledSampleQ9(int value, int depth) =>
    depth == 16 ? (value >> 1) << 2 : value << (17 - depth);

int _packedAlphaSample8(int value, int depth) =>
    math.min(255, ((value << (16 - depth)) + 128) >> 8);

/// YUV-to-RGB matrix for the full horizontal chroma path.
final class _PackedYuvMatrix {
  _PackedYuvMatrix(int matrix, bool fullRange, {int outputDepth = 8})
    : _black = fullRange ? 0 : 16 << 9,
      _luma = fullRange ? 8192 : 9539,
      _shift = 30 - outputDepth,
      _rounding = 1 << (29 - outputDepth),
      _maximum = (1 << outputDepth) - 1,
      _chroma = _coefficients(matrix, fullRange);

  final int _black, _luma, _shift, _rounding, _maximum;
  final (int, int, int, int) _chroma;

  static (int, int, int, int) _coefficients(int matrix, bool fullRange) {
    final (rv, bu, gu, gv) = _rgbCoefficients(matrix);
    int q13(int coefficient) =>
        ((fullRange ? coefficient * 224 ~/ 255 : coefficient) + 4) >> 3;
    return (q13(rv), q13(bu), q13(gu), q13(gv));
  }

  (int, int, int) rgb(int y, int cb, int cr) {
    final luma = (y - _black) * _luma + _rounding;
    final u = cb - (128 << 9), v = cr - (128 << 9);
    final (rv, bu, gu, gv) = _chroma;
    return (
      _sample(luma + rv * v),
      _sample(luma + gu * u + gv * v),
      _sample(luma + bu * u),
    );
  }

  // The scalar packed kernel clips after a signed 32-bit accumulation.
  int _sample(int value) => (value.toSigned(32) >> _shift).clamp(0, _maximum);
}
