part of 'yuv_image.dart';

/// FFmpeg's packed RGB point scaler uses BT.601 with one chroma sample
/// per pair of source pixels when the width shrinks by at least half.
_VideoPlanes _pointScalePackedRgb(
  _VideoPlanes frame,
  int width,
  int height,
  double sampleAspect,
) {
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
      final luma = _packedLuma(
        red.at(at, row),
        green.at(at, row),
        blue.at(at, row),
      );
      final cb = _packedCb(r, g, b);
      final cr = _packedCr(r, g, b);
      final yuv = 9539 * luma + (1 << 18);
      outR[i] = ((yuv + 13075 * cr) >> 19).clamp(0, 255);
      outG[i] = ((yuv - 3209 * cb - 6660 * cr) >> 19).clamp(0, 255);
      outB[i] = ((yuv + 16525 * cb) >> 19).clamp(0, 255);
      if (alpha != null) {
        outA![i] = _packedPointAlpha(alpha.at(at, row));
      }
    }
  }

  return _packedRgbPlanes(
    width,
    height,
    sampleAspect,
    [outG, outB, outR],
    outA,
    bgr24: frame.bgr24,
  );
}

_VideoPlanes _scaleSubsampledRgb(
  _VideoPlanes frame,
  int width,
  int height,
  double sampleAspect,
  _Scale scale,
) {
  final sw = frame.width, sh = frame.height, cw = sw ~/ 2;
  final green = frame.planes[0], blue = frame.planes[1], red = frame.planes[2];
  final alpha = frame.alpha;
  final y = Uint16List(sw * sh),
      cb = Uint16List(cw * sh),
      cr = Uint16List(cw * sh);
  final a = alpha == null ? null : Uint16List(y.length);
  for (var row = 0; row < sh; row++) {
    for (var x = 0; x < sw; x += 2) {
      final r0 = red.at(x, row), r1 = red.at(x + 1, row);
      final g0 = green.at(x, row), g1 = green.at(x + 1, row);
      final b0 = blue.at(x, row), b1 = blue.at(x + 1, row);
      final luma = row * sw + x, chroma = row * cw + (x >> 1);
      y[luma] = _packedLuma(r0, g0, b0) + (16 << 6);
      y[luma + 1] = _packedLuma(r1, g1, b1) + (16 << 6);
      cb[chroma] = _packedCb(r0 + r1, g0 + g1, b0 + b1) + (128 << 6);
      cr[chroma] = _packedCr(r0 + r1, g0 + g1, b0 + b1) + (128 << 6);
      if (alpha != null) {
        final first = alpha.at(x, row), second = alpha.at(x + 1, row);
        a![luma] = (first << 6) + (first >> 2);
        a[luma + 1] = (second << 6) + (second >> 2);
      }
    }
  }
  final lumaScaler = scale._planeScaler(
    sw,
    sh,
    width,
    height,
    scale.algorithm.kernel(chroma: false),
  );
  final chromaScaler = scale._planeScaler(
    cw,
    sh,
    width,
    height,
    scale.algorithm.kernel(chroma: true),
  );
  final luma = lumaScaler.resize(y, sw, 0, 14, 9);
  final u = chromaScaler.resize(cb, cw, 0, 14, 9);
  final v = chromaScaler.resize(cr, cw, 0, 14, 9);
  final opacity = a == null ? null : lumaScaler.resize(a, sw, 0, 14, 0);
  final outG = Uint8List(width * height);
  final outB = Uint8List(outG.length), outR = Uint8List(outG.length);
  final outA = opacity == null ? null : Uint8List(outG.length);
  for (var i = 0; i < outG.length; i++) {
    final yuv = 9539 * (luma[i] - (16 << 9)) + (1 << 21);
    final b = u[i] - (128 << 9), r = v[i] - (128 << 9);
    outR[i] = ((yuv + 13075 * r) >> 22).clamp(0, 255);
    outG[i] = ((yuv - 3209 * b - 6660 * r) >> 22).clamp(0, 255);
    outB[i] = ((yuv + 16525 * b) >> 22).clamp(0, 255);
    if (opacity != null) outA![i] = opacity[i].clamp(0, 255);
  }
  return _packedRgbPlanes(
    width,
    height,
    sampleAspect,
    [outG, outB, outR],
    outA,
    bgr24: frame.bgr24,
  );
}

_VideoPlanes _packedRgbPlanes(
  int width,
  int height,
  double sampleAspect,
  List<Uint8List> gbr,
  Uint8List? alpha, {
  required bool bgr24,
}) {
  _FilterPlane plane(Uint8List data) =>
      _FilterPlane(data, width, height, 8, rowStep: width);
  return _VideoPlanes(
    gbr.map(plane).toList(),
    0,
    0,
    matrix: 0,
    fullRange: true,
    packedRgb: true,
    bgr24: bgr24,
    sampleAspect: sampleAspect,
    alpha: alpha == null ? null : plane(alpha),
  );
}

const _bt601RgbToYuv = [
  (8414, 16519, 3208),
  (-4865, -9528, 14392),
  (14392, -12061, -2332),
];

int _packedLuma(int r, int g, int b) =>
    (_rgbProduct(_bt601RgbToYuv[0], r, g, b) + 256) >> 9;
int _packedCb(int r, int g, int b) =>
    (_rgbProduct(_bt601RgbToYuv[1], r, g, b) + 512) >> 10;
int _packedCr(int r, int g, int b) =>
    (_rgbProduct(_bt601RgbToYuv[2], r, g, b) + 512) >> 10;

int _rgbProduct((int, int, int) coefficients, int r, int g, int b) =>
    coefficients.$1 * r + coefficients.$2 * g + coefficients.$3 * b;

// The packed alpha path replicates the high bits before rounding.
int _packedPointAlpha(int value) => math.min(255, value + (value >> 7));
