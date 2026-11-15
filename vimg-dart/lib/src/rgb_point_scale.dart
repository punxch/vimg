part of 'yuv_image.dart';

/// FFmpeg's packed RGB point scaler uses BT.601 with one chroma sample
/// per pair of source pixels when the width shrinks by at least half.
_VideoPlanes _pointScalePackedRgb(_VideoPlanes frame, int width, int height) {
  final sw = frame.width, sh = frame.height;
  final dx = _scaleStep(sw, width), dy = _scaleStep(sh, height);
  final chromaWidth = sw ~/ 2;
  final dc = _scaleStep(chromaWidth, width);
  final columns = Int32List(width), pairs = Int32List(width);
  for (var x = 0; x < width; x++) {
    columns[x] = _nearestIndex(x, dx, sw);
    pairs[x] = 2 * _nearestIndex(x, dc, chromaWidth);
  }

  final green = frame.planes[0], blue = frame.planes[1], red = frame.planes[2];
  final alpha = frame.alpha;
  final outG = Uint8List(width * height);
  final outB = Uint8List(outG.length), outR = Uint8List(outG.length);
  final outA = alpha == null ? null : Uint8List(outG.length);
  var i = 0;
  for (var y = 0; y < height; y++) {
    final row = _nearestIndex(y, dy, sh);
    for (var x = 0; x < width; x++, i++) {
      final at = columns[x], pair = pairs[x];
      final r = red.at(pair, row) + red.at(pair + 1, row);
      final g = green.at(pair, row) + green.at(pair + 1, row);
      final b = blue.at(pair, row) + blue.at(pair + 1, row);
      // Q15 input coefficients yield signed Q6 samples with the studio
      // offsets removed. The chroma shift also divides by the pair size.
      final luma =
          (8414 * red.at(at, row) +
              16519 * green.at(at, row) +
              3208 * blue.at(at, row) +
              256) >>
          9;
      final cb = (14392 * b - 4865 * r - 9528 * g + 512) >> 10;
      final cr = (14392 * r - 12061 * g - 2332 * b + 512) >> 10;
      final yuv = 9539 * luma + (1 << 18);
      outR[i] = ((yuv + 13075 * cr) >> 19).clamp(0, 255);
      outG[i] = ((yuv - 3209 * cb - 6660 * cr) >> 19).clamp(0, 255);
      outB[i] = ((yuv + 16525 * cb) >> 19).clamp(0, 255);
      if (alpha != null) {
        outA![i] = _packedPointAlpha(alpha.at(at, row));
      }
    }
  }

  _FilterPlane plane(Uint8List data) =>
      _FilterPlane(data, width, height, 8, rowStep: width);
  return _VideoPlanes(
    [plane(outG), plane(outB), plane(outR)],
    0,
    0,
    matrix: 0,
    fullRange: true,
    packedRgb: true,
    sampleAspect: frame.sampleAspect * sw * height / (sh * width),
    alpha: outA == null ? null : plane(outA),
  );
}

// The packed alpha path replicates the high bits before rounding.
int _packedPointAlpha(int value) => math.min(255, value + (value >> 7));
