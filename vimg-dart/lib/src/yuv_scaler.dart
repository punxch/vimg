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
  YuvImageScaler({this.width, this.height, this.filters})
    : _exact = false,
      _nearest = false,
      _sampleAspect = null;

  YuvImageScaler._fixed(int this.width, int this.height, this._nearest)
    : _exact = true,
      _sampleAspect = null,
      filters = null;

  YuvImageScaler._presentation(
    this.width,
    this.height,
    this.filters,
    this._sampleAspect,
  ) : _exact = false,
      _nearest = false;

  factory YuvImageScaler.presentation(
    YuvImageScaler? scaler, {
    VideoCrop? crop,
    VideoOrientation? orientation,
    double? sampleAspect,
  }) => YuvImageScaler._presentation(
    scaler?.width,
    scaler?.height,
    crop == null && orientation == null
        ? scaler?.filters
        : VideoFilterChain._presentation(crop, orientation, scaler?.filters),
    sampleAspect,
  );

  final int? width, height;
  final VideoFilterChain? filters;
  final double? _sampleAspect;
  final bool _exact, _nearest;
  YuvImageScaler? _outputScale;
  late final YuvImageScaler? unscaled = filters == null
      ? null
      : width == null && height == null
      ? this
      : YuvImageScaler._presentation(null, null, filters, _sampleAspect);
  _YuvGeometry? _geometry;
  late _PlaneScaler _luma;
  _PlaneScaler? _chroma;
  ({int matrix, bool fullRange})? _tableColor;
  late _RgbTable _table;

  image.Image filterRgb(image.Image frame, {double sampleAspect = 1}) {
    if (filters == null) return frame;
    _checkFilterSize(frame.width, frame.height);
    final green = Uint8List(frame.width * frame.height);
    final blue = Uint8List(green.length);
    final red = Uint8List(green.length);
    final alpha = frame.hasAlpha ? Uint8List(green.length) : null;
    var i = 0;
    for (final pixel in frame) {
      green[i] = pixel.g.toInt();
      blue[i] = pixel.b.toInt();
      red[i] = pixel.r.toInt();
      alpha?[i] = pixel.a.toInt();
      i++;
    }
    final planes = _VideoPlanes(
      [
        for (final samples in [green, blue, red])
          _FilterPlane(
            samples,
            frame.width,
            frame.height,
            8,
            rowStep: frame.width,
          ),
      ],
      0,
      0,
      matrix: 0,
      fullRange: true,
      sampleAspect: _sampleAspect ?? sampleAspect,
      alpha: alpha == null
          ? null
          : _FilterPlane(
              alpha,
              frame.width,
              frame.height,
              8,
              rowStep: frame.width,
            ),
    );
    return _renderFiltered(planes);
  }

  image.Image _renderFiltered(_VideoPlanes source) {
    final scale = width == null && height == null ? filters!._finalScale : null;
    final frame = filters!._apply(source, deferScale: scale != null);
    if (scale != null) {
      // The terminal scale can upsample chroma while converting to RGB.
      final (w, h) = scale.dimensions(frame);
      if (_outputScale?.width != w || _outputScale?.height != h) {
        _outputScale = YuvImageScaler._fixed(w, h, scale.nearest);
      }
    } else if (width != null || height != null) {
      _outputScale ??= YuvImageScaler(width: width, height: height);
    }
    var y = frame.planes.first.atOrigin;
    var cb = frame.planes.length == 3 ? frame.planes[1].atOrigin : null;
    var cr = frame.planes.length == 3 ? frame.planes[2].atOrigin : null;
    var alpha = frame.alpha?.atOrigin;
    // Painting one component can give it a different stride from its
    // companion plane. The RGB converter shares strides for these pairs.
    if (cb != null && cr != null && cb.rowStep != cr.rowStep) {
      cb = cb.packed;
      cr = cr.packed;
    }
    if (alpha != null && y.rowStep != alpha.rowStep) {
      y = y.packed;
      alpha = alpha.packed;
    }
    return yuvImage(
      y: y.samples,
      cb: cb?.samples ?? const [],
      cr: cr?.samples ?? const [],
      stride: y.rowStep,
      chromaStride: cb?.rowStep ?? 0,
      width: y.width,
      height: y.height,
      cropLeft: 0,
      cropTop: 0,
      matrix: frame.matrix,
      fullRange: frame.fullRange,
      lumaDepth: y.depth,
      chromaDepth: cb?.depth ?? y.depth,
      subsamplingX: frame.subX,
      subsamplingY: frame.subY,
      alpha: alpha?.samples,
      alphaDepth: alpha?.depth ?? 8,
      scaler: _outputScale,
    );
  }

  (int, int) _dimensions(int sourceWidth, int sourceHeight) => _exact
      ? (width!, height!)
      : fitDimensions(sourceWidth, sourceHeight, width: width, height: height);

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
    required List<int>? alpha,
    required int alphaDepth,
  }) {
    if (width * height > 100000000) {
      throw const FormatException('Grid exceeds 100 million pixels');
    }
    if (width * sourceHeight > 100000000) {
      throw const FormatException(
        'Video scaling exceeds 100 million intermediate samples',
      );
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
      _luma = _PlaneScaler(
        sourceWidth,
        sourceHeight,
        width,
        height,
        nearest: _nearest,
      );
      _chroma = cb.isEmpty
          ? null
          : _PlaneScaler(
              geometry.chromaWidth,
              geometry.chromaHeight,
              geometry.outputChromaWidth,
              height,
              nearest: _nearest,
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
    final pixels = image.Image(
      width: width,
      height: height,
      numChannels: alpha == null ? 3 : 4,
    );
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
    if (alpha != null) {
      const fractionalBits = 9;
      final scaled = _luma.resize(
        alpha,
        stride,
        cropTop * stride + cropLeft,
        alphaDepth,
        fractionalBits,
      );
      final maximum = ((1 << alphaDepth) - 1) << (17 - alphaDepth);
      var index = 0;
      for (final pixel in pixels) {
        final sample = scaled[index++].clamp(0, maximum);
        pixel.a = (sample * 255 + (maximum >> 1)) ~/ maximum;
      }
    }
    return pixels;
  }
}

final class _PlaneScaler {
  _PlaneScaler(
    int sourceWidth,
    int sourceHeight,
    this.width,
    int height, {
    bool nearest = false,
  }) : horizontal = _axisTaps(sourceWidth, width, 14, nearest),
       vertical = _axisTaps(sourceHeight, height, 12, nearest),
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

int _scaleStep(int from, int to) => ((from << 16) + (to >> 1)) ~/ to;

int _nearestIndex(int index, int step, int size) =>
    math.min(size - 1, ((2 * index + 1) * step) >> 17);

List<({int start, Int16List weights})> _axisTaps(
  int from,
  int to,
  int bits,
  bool nearest,
) {
  final unit = 1 << bits;
  final step = _scaleStep(from, to);
  if (from == to || from == 1 || nearest) {
    final identity = Int16List.fromList([unit]);
    return List.generate(
      to,
      (x) => (start: _nearestIndex(x, step, from), weights: identity),
    );
  }
  final scale = math.min(1.0, to / from);
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
  final rgbScale = gbr && fullRange && chromaDepth != lumaDepth
      ? (65536 * 255 / chromaRange).round()
      : scale;
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
        (((v - bias) * rgbScale + half) >> 25).clamp(0, 255),
        (luma >> 25).clamp(0, 255),
        (((u - bias) * rgbScale + half) >> 25).clamp(0, 255),
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
