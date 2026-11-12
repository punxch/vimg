part of 'yuv_image.dart';

typedef _YuvGeometry = ({
  int sourceWidth,
  int sourceHeight,
  int width,
  int height,
  int chromaWidth,
  int chromaHeight,
  int outputChromaWidth,
});

/// Resize video samples before RGB conversion. Reuse filter taps across frames.
final class YuvImageScaler {
  YuvImageScaler({this.width, this.height});

  final int? width, height;
  _YuvGeometry? _geometry;
  late _PlaneScaler _luma;
  _PlaneScaler? _chroma;
  ({int matrix, bool fullRange})? _tableColor;
  late _RgbTable _table;

  image.Image _resize({
    required List<int> y,
    required List<int> cb,
    required List<int> cr,
    required int stride,
    required int chromaStride,
    required int sourceWidth,
    required int sourceHeight,
    required int width,
    required int height,
    required int cropLeft,
    required int cropTop,
    required int matrix,
    required bool fullRange,
    required int lumaDepth,
    required int chromaDepth,
    required int subsamplingX,
    required int subsamplingY,
  }) {
    if (width * height > 100000000) {
      throw const FormatException('Grid exceeds 100 million pixels');
    }
    final gbr = matrix == 0 && cb.isNotEmpty;
    // RGB24 contact sheets use one chroma sample per horizontal pixel pair
    // at even widths. Odd widths and GBR use a sample at every pixel.
    final halfChroma = !gbr && width.isEven && cb.isNotEmpty;
    final geometry = (
      sourceWidth: sourceWidth,
      sourceHeight: sourceHeight,
      width: width,
      height: height,
      chromaWidth: (sourceWidth + (1 << subsamplingX) - 1) >> subsamplingX,
      chromaHeight: (sourceHeight + (1 << subsamplingY) - 1) >> subsamplingY,
      outputChromaWidth: cb.isEmpty ? 0 : (halfChroma ? width >> 1 : width),
    );
    if (geometry != _geometry) {
      _luma = _PlaneScaler(sourceWidth, sourceHeight, width, height);
      _chroma = cb.isEmpty
          ? null
          : _PlaneScaler(
              geometry.chromaWidth,
              geometry.chromaHeight,
              geometry.outputChromaWidth,
              height,
            );
      _geometry = geometry;
    }
    final useTable = halfChroma && lumaDepth == 8 && chromaDepth == 8;
    final fractionalBits = useTable ? 0 : 9;
    final luma = _luma.resize(
      y,
      stride,
      cropTop * stride + cropLeft,
      lumaDepth,
      fractionalBits,
    );
    final chromaOffset =
        (cropTop >> subsamplingY) * chromaStride + (cropLeft >> subsamplingX);
    final blueChroma = _chroma?.resize(
      cb,
      chromaStride,
      chromaOffset,
      chromaDepth,
      fractionalBits,
    );
    final redChroma = _chroma?.resize(
      cr,
      chromaStride,
      chromaOffset,
      chromaDepth,
      fractionalBits,
    );
    final pixels = image.Image(width: width, height: height);
    if (useTable) {
      final color = (matrix: matrix, fullRange: fullRange);
      if (_tableColor != color) {
        _table = _RgbTable(matrix, fullRange);
        _tableColor = color;
      }
      _table.write(pixels, luma, blueChroma!, redChroma!);
    } else {
      _writeRgb(
        pixels,
        luma,
        blueChroma,
        redChroma,
        halfChroma,
        gbr,
        matrix,
        fullRange,
        lumaDepth,
        chromaDepth,
      );
    }
    return pixels;
  }
}

final class _PlaneScaler {
  _PlaneScaler(int sourceWidth, int sourceHeight, this.width, int height)
    : horizontal = _axisTaps(sourceWidth, width, 14),
      vertical = _axisTaps(sourceHeight, height, 12),
      intermediate = Int16List(sourceHeight * width);

  final int width;
  final List<({int start, Int16List weights})> horizontal, vertical;
  final Int16List intermediate;

  Int32List resize(
    List<int> source,
    int stride,
    int offset,
    int depth,
    int fractionalBits,
  ) {
    final horizontalShift = depth - 1;
    var output = 0;
    for (var row = 0; row < intermediate.length; row += width) {
      for (final tap in horizontal) {
        final start = offset + tap.start;
        var sum = 0;
        for (var i = 0; i < tap.weights.length; i++) {
          sum += source[start + i] * tap.weights[i];
        }
        intermediate[output++] = math.min(32767, sum >> horizontalShift);
      }
      offset += stride;
    }
    final result = Int32List(width * vertical.length);
    final shift = 19 - fractionalBits;
    final rounding = 1 << (shift - 1);
    output = 0;
    for (final tap in vertical) {
      final start = tap.start * width;
      for (var x = 0; x < width; x++) {
        var sum = rounding;
        var sample = start + x;
        for (final weight in tap.weights) {
          sum += intermediate[sample] * weight;
          sample += width;
        }
        result[output++] = sum >> shift;
      }
    }
    return result;
  }
}

List<({int start, Int16List weights})> _axisTaps(int from, int to, int bits) {
  final unit = 1 << bits;
  if (from == to || from == 1) {
    final identity = Int16List.fromList([unit]);
    return List.generate(
      to,
      (x) => (start: from == 1 ? 0 : x, weights: identity),
    );
  }
  final scale = math.min(1.0, to / from);
  final step = ((from << 16) + (to >> 1)) ~/ to;
  final count = math.min(math.max(1, from - 2), 1 + (4 / scale).ceil());
  return List.generate(to, (x) {
    // A pixel center is at x + 0.5. Widen the cubic kernel when shrinking.
    final center = (2 * x + 1) * step - 65536;
    final start = (center - (count - 2) * 65536) ~/ 131072;
    final left = start.clamp(0, from - 1);
    final right = (start + count - 1).clamp(left, from - 1);
    final weights = Float64List(right - left + 1);
    var total = 0.0;
    for (var i = 0; i < count; i++) {
      final source = start + i;
      final d = (source * 131072 - center).abs() / 131072 * scale;
      final weight = switch (d) {
        < 1 => (1.4 * d - 2.4) * d * d + 1,
        < 2 => ((-0.6 * d + 3) * d - 4.8) * d + 2.4,
        _ => 0.0,
      };
      weights[source.clamp(left, right) - left] += weight;
      total += weight;
    }
    if (total <= 0) {
      return (
        start: ((center + 65536) >> 17).clamp(0, from - 1),
        weights: Int16List.fromList([unit]),
      );
    }
    // Carry quantization error across the row to preserve its DC gain.
    var error = 0.0;
    final quantized = Int16List(weights.length);
    for (var i = 0; i < weights.length; i++) {
      final value = weights[i] / total * unit + error;
      quantized[i] = value.round();
      error = value - quantized[i];
    }
    return (start: left, weights: quantized);
  });
}

// Limited-range YCbCr-to-RGB coefficients in Q16.
(int, int, int, int) _rgbCoefficients(int matrix) => switch (matrix) {
  1 => (117489, 138438, -13975, -34925),
  4 => (104448, 132798, -24759, -53109),
  7 => (117579, 136230, -16907, -35559),
  9 || 10 => (110013, 140363, -12277, -42626),
  _ => (104597, 132201, -25675, -53279),
};

/// Integer RGB24 conversion for the 8-bit paired-chroma path.
final class _RgbTable {
  _RgbTable(int matrix, bool fullRange)
    : scale = fullRange ? 65536 : (65536 * 255) ~/ 219 {
    bias =
        (fullRange ? 384 : 326) * scale -
        ((fullRange ? 384 : 400) << 16) +
        32768;
    final (rv, bu, gu, gv) = _rgbCoefficients(matrix);
    red = _offsets(rv, fullRange);
    blue = _offsets(bu, fullRange);
    greenU = _offsets(gu, fullRange);
    greenV = _offsets(gv, fullRange);
  }

  final int scale;
  late final int bias;
  late final Int16List red, blue, greenU, greenV;

  Int16List _offsets(int coefficient, bool fullRange) {
    if (fullRange) coefficient = coefficient * 224 ~/ 255;
    final step = ((coefficient << 16) + 32768) ~/ scale;
    return Int16List.fromList([
      for (var i = 0; i < 256; i++) ((i * step) >> 16) - (step >> 9),
    ]);
  }

  void write(image.Image pixels, Int32List y, Int32List cb, Int32List cr) {
    var offset = 0;
    for (final pixel in pixels) {
      final u = cb[offset >> 1].clamp(0, 255);
      final v = cr[offset >> 1].clamp(0, 255);
      final luma = y[offset++] * scale + bias;
      pixel.setRgb(
        ((luma + red[v] * scale) >> 16).clamp(0, 255),
        ((luma + (greenU[u] + greenV[v]) * scale) >> 16).clamp(0, 255),
        ((luma + blue[u] * scale) >> 16).clamp(0, 255),
      );
    }
  }
}

void _writeRgb(
  image.Image pixels,
  Int32List y,
  Int32List? cb,
  Int32List? cr,
  bool halfChroma,
  bool gbr,
  int matrix,
  bool fullRange,
  int lumaDepth,
  int chromaDepth,
) {
  // Filtered values are in Q9 on an 8-bit scale, including for deep sources.
  const half = 1 << 24;
  final bias = fullRange ? 0 : 16 << 9;
  final lumaRange = fullRange ? 256 - 1 / (1 << (lumaDepth - 8)) : 219;
  final scale = (65536 * 255 / lumaRange).round();
  final chromaRange = fullRange ? 256 - 1 / (1 << (chromaDepth - 8)) : 224;
  final (rv, bu, gu, gv) = _rgbCoefficients(matrix);
  final red = (rv * 224 / chromaRange).round();
  final blue = (bu * 224 / chromaRange).round();
  final greenU = (gu * 224 / chromaRange).round();
  final greenV = (gv * 224 / chromaRange).round();
  var offset = 0;
  for (final pixel in pixels) {
    final chroma = halfChroma ? offset >> 1 : offset;
    final luma = (y[offset++] - bias) * scale + half;
    final u = cb?[chroma] ?? (128 << 9);
    final v = cr?[chroma] ?? (128 << 9);
    if (gbr) {
      pixel.setRgb(
        (((v - bias) * scale + half) >> 25).clamp(0, 255),
        (luma >> 25).clamp(0, 255),
        (((u - bias) * scale + half) >> 25).clamp(0, 255),
      );
    } else {
      final uDelta = u - (128 << 9);
      final vDelta = v - (128 << 9);
      pixel.setRgb(
        ((luma + red * vDelta) >> 25).clamp(0, 255),
        ((luma + greenU * uDelta + greenV * vDelta) >> 25).clamp(0, 255),
        ((luma + blue * uDelta) >> 25).clamp(0, 255),
      );
    }
  }
}
