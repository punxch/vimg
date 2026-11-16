part of 'yuv_image.dart';

enum _PixelColor { gray, yuv, rgb }

typedef _VideoPixelFormat = ({
  _PixelColor color,
  int subX,
  int subY,
  int depth,
  bool packedRgb,
  bool bgr24,
});

_VideoPixelFormat _pixelFormat(
  _PixelColor color,
  int depth, {
  int subX = 0,
  int subY = 0,
  bool packedRgb = false,
  bool bgr24 = false,
}) => (
  color: color,
  subX: subX,
  subY: subY,
  depth: depth,
  packedRgb: packedRgb,
  bgr24: bgr24,
);

_VideoPixelFormat _frameFormat(_VideoPlanes frame) => _pixelFormat(
  frame.rgb
      ? _PixelColor.rgb
      : frame.planes.length == 1
      ? _PixelColor.gray
      : _PixelColor.yuv,
  frame.planes.first.depth,
  subX: frame.subX,
  subY: frame.subY,
  packedRgb: frame.packedRgb,
  bgr24: frame.bgr24,
);

typedef _NamedPixelFormat = ({
  _VideoPixelFormat format,
  bool alpha,
  bool? fullRange,
});

_NamedPixelFormat _namedPixelFormat(String name) {
  final layout = RegExp(
    r'^yuv([aj]?)(444|422|420|440|411|410)p(?:(9|10|12|14|16)(?:le|be))?$',
  ).firstMatch(name);
  if (layout != null) {
    final (sx, sy) = switch (layout.group(2)!) {
      '420' => (1, 1),
      '422' => (1, 0),
      '440' => (0, 1),
      '411' => (2, 0),
      '410' => (2, 2),
      _ => (0, 0),
    };
    return (
      format: _pixelFormat(
        _PixelColor.yuv,
        int.parse(layout.group(3) ?? '8'),
        subX: sx,
        subY: sy,
      ),
      alpha: layout.group(1) == 'a',
      fullRange: layout.group(1) == 'j' ? true : null,
    );
  }
  final gray = RegExp(r'^gray(?:(9|10|12|14|16)(?:le|be))?$').firstMatch(name);
  if (gray != null) {
    return (
      format: _pixelFormat(_PixelColor.gray, int.parse(gray.group(1) ?? '8')),
      alpha: false,
      fullRange: true,
    );
  }
  final packed = switch (name) {
    'gbrp' || 'gbrap' => false,
    'rgb24' || 'bgr24' || 'rgba' || 'bgra' || 'argb' || 'abgr' => true,
    _ => throw FormatException('Unsupported video pixel format: $name'),
  };
  return (
    format: _pixelFormat(
      _PixelColor.rgb,
      8,
      packedRgb: packed,
      bgr24: name == 'bgr24',
    ),
    alpha: const {'gbrap', 'rgba', 'bgra', 'argb', 'abgr'}.contains(name),
    fullRange: true,
  );
}

final class _FormatFilter implements _SpatialFilter {
  factory _FormatFilter(String? source) {
    final options = _filterOptions(source, [
      'pix_fmts',
      'color_spaces',
      'color_ranges',
    ]);
    return _FormatFilter._(
      options['pix_fmts']?.split('|').map(_namedPixelFormat).toList() ??
          const [],
      options['color_spaces']?.split('|').map(_namedColorMatrix).toList() ??
          const [],
      options['color_ranges']?.split('|').map(_namedColorRange).toList() ??
          const [],
    );
  }

  _FormatFilter._(this.formats, this.matrices, this.ranges);
  final List<_NamedPixelFormat> formats;
  final List<int> matrices;
  final List<bool> ranges;
  final _PixelFormatConverter _converter = _PixelFormatConverter();

  @override
  _VideoPlanes apply(_VideoPlanes frame) {
    if (formats.isEmpty && matrices.isEmpty && ranges.isEmpty) return frame;
    final input = _frameFormat(frame);
    final hasAlpha = frame.alpha != null;
    final target = formats.isEmpty
        ? (format: input, alpha: hasAlpha, fullRange: null)
        : formats.firstWhere(
            (item) =>
                item.format == input &&
                item.alpha == hasAlpha &&
                (item.fullRange == null || item.fullRange == frame.fullRange),
            orElse: () => formats.first,
          );
    final yuv = target.format.color == _PixelColor.yuv;
    if (!yuv && formats.isEmpty) return frame;
    final matrix = !yuv || matrices.isEmpty
        ? null
        : matrices.contains(frame.matrix)
        ? frame.matrix
        : matrices.first;
    final fullRange =
        target.fullRange ??
        (!yuv || ranges.isEmpty
            ? null
            : !frame.rgb && ranges.contains(frame.fullRange)
            ? frame.fullRange
            : ranges.first);
    return _converter.convert(
      frame,
      target.format,
      alpha: formats.isEmpty ? null : target.alpha,
      matrix: matrix,
      fullRange: fullRange,
    );
  }
}

int _namedColorMatrix(String name) => switch (name) {
  'bt709' => 1,
  'unknown' => 2,
  'fcc' => 4,
  'bt470bg' => 5,
  'smpte170m' => 6,
  'smpte240m' => 7,
  'bt2020nc' => 9,
  _ => throw FormatException('Unsupported video color space: $name'),
};

bool _namedColorRange(String name) => switch (name) {
  'tv' => false,
  'pc' => true,
  _ => throw FormatException('Unsupported video color range: $name'),
};

final class _PixelFormatConverter {
  final _scalers = <(int, int, int, int), _PlaneScaler>{};
  final _rgbScalers = <(int, int, int, int), YuvImageScaler>{};

  _VideoPlanes convert(
    _VideoPlanes source,
    _VideoPixelFormat target, {
    bool? alpha,
    bool? fullRange,
    int? matrix,
  }) {
    final requestedAlpha = alpha ?? source.alpha != null;
    final full =
        fullRange ??
        (target.color == _PixelColor.yuv
            ? !source.rgb && source.fullRange
            : true);
    final colorMatrix = target.color == _PixelColor.rgb
        ? 0
        : matrix ?? (source.matrix == 0 ? 6 : source.matrix);
    if (_frameFormat(source) == target &&
        source.fullRange == full &&
        source.matrix == colorMatrix &&
        requestedAlpha == (source.alpha != null) &&
        (alpha == null ||
            source.alpha == null ||
            source.alpha!.depth == target.depth) &&
        source.planes.every((plane) => plane.depth == target.depth)) {
      return source;
    }

    final width = source.width, height = source.height;
    _checkFilterSize(width, height);
    var working = source;
    if (!source.rgb && target.color == _PixelColor.rgb) {
      working = _toRgb(source);
    } else if (!source.rgb &&
        source.planes.length == 3 &&
        target.color == _PixelColor.yuv &&
        _rgbCoefficients(source.matrix) != _rgbCoefficients(colorMatrix)) {
      // libswscale cascades both matrices through RGB, using 16-bit channels
      // when the requested YUV output has more than eight bits per component.
      working = target.depth > 8
          ? _toDeepRgb(source)
          : _toRgb(source, bgr24: source.alpha == null || !requestedAlpha);
    }
    if (working.rgb && target.color != _PixelColor.rgb) {
      working = _rgbToYuv(working, target, colorMatrix, full);
    }
    final count = target.color == _PixelColor.gray ? 1 : 3;
    final native = identical(working, source) && !source.rgb;
    final resamplesChroma =
        native &&
        working.planes.length == 3 &&
        target.color == _PixelColor.yuv &&
        (working.subX != target.subX || working.subY != target.subY);
    final planes = <_FilterPlane>[];
    for (var i = 0; i < count; i++) {
      final chroma = target.color == _PixelColor.yuv && i != 0;
      final w = chroma ? _subSize(width, target.subX) : width;
      final h = chroma ? _subSize(height, target.subY) : height;
      planes.add(
        i < working.planes.length
            ? _component(
                working.planes[i],
                w,
                h,
                target.depth,
                chroma: chroma,
                inputFull: working.fullRange,
                outputFull: full,
                channel: native ? i : null,
                resamplesChroma: resamplesChroma,
              )
            : _constantPlane(w, h, target.depth, 1 << (target.depth - 1)),
      );
    }
    final opacity = source.alpha;
    final convertedAlpha = !requestedAlpha
        ? null
        : opacity == null
        ? _constantPlane(width, height, target.depth, (1 << target.depth) - 1)
        : source.packedRgb &&
              opacity.depth == 8 &&
              target.color != _PixelColor.rgb
        ? _packedAlpha(opacity, target.depth)
        : _component(
            opacity,
            width,
            height,
            target.depth,
            inputFull: true,
            outputFull: true,
            channel: native ? 3 : null,
            resamplesChroma: resamplesChroma,
          );
    return _VideoPlanes(
      planes,
      target.subX,
      target.subY,
      matrix: colorMatrix,
      fullRange: full,
      packedRgb: target.packedRgb,
      bgr24: target.bgr24,
      sampleAspect: source.sampleAspect,
      alpha: convertedAlpha,
    );
  }

  _FilterPlane _component(
    _FilterPlane source,
    int width,
    int height,
    int depth, {
    bool chroma = false,
    required bool inputFull,
    required bool outputFull,
    int? channel,
    bool resamplesChroma = false,
  }) {
    final sameLevels = inputFull == outputFull && source.depth == depth;
    final sameSize = width == source.width && height == source.height;
    if (sameLevels && sameSize) return source;
    final out = _paintSamples(depth, width * height);
    final limit = (1 << depth) - 1;
    final srcDepth = source.depth;
    final drop = srcDepth - depth;
    final dither = channel != null && drop > 0 && inputFull == outputFull;
    final filterDither = dither && resamplesChroma && depth == 8;
    final phase = channel == 2 ? 3 : 0;
    if (dither && sameSize && (filterDither || !resamplesChroma)) {
      var index = 0;
      for (var row = 0; row < height; row++) {
        final thresholds = _conversionDither[row & 7];
        for (var col = 0; col < width; col++) {
          final value = source.at(col, row);
          final threshold = thresholds[(col + (filterDither ? phase : 0)) & 7];
          final rounded = filterDither
              ? (((value << 14) >> (srcDepth - 1)) + (threshold << 1)) >> 7
              : (value -
                        (inputFull && !chroma ? value >> depth : 0) +
                        _depthDither(threshold, drop)) >>
                    drop;
          out[index++] = math.min(rounded, limit);
        }
      }
      return _FilterPlane(out, width, height, depth, rowStep: width);
    }
    final preserveRange = !inputFull && !outputFull;
    var sampledDepth = srcDepth;
    _FilterPlane sampled = source;
    if (!sameSize) {
      sampledDepth = preserveRange || filterDither ? depth : srcDepth;
      sampled = _FilterPlane(
        _resample(
          source,
          width,
          height,
          sampledDepth - 8,
          ditherOffset: filterDither ? phase : null,
        ),
        width,
        height,
        sampledDepth,
        rowStep: width,
      );
    }
    // Range conversion maps the endpoints of the coded interval, including
    // for chroma where the full-range midpoint falls between two codes.
    final changingRange = inputFull != outputFull;
    final (lo, span) = _componentLevels(
      sampledDepth,
      inputFull,
      chroma,
      fromMinimum: changingRange,
    );
    final (newLo, newSpan) = _componentLevels(
      depth,
      outputFull,
      chroma,
      fromMinimum: changingRange,
    );
    var index = 0;
    for (var row = 0; row < height; row++) {
      for (var col = 0; col < width; col++) {
        final value = sampled.at(col, row);
        out[index++] =
            (lo == newLo && span == newSpan
                    ? value
                    : newLo + _roundComponent((value - lo) * newSpan, span))
                .clamp(0, limit);
      }
    }
    return _FilterPlane(out, width, height, depth, rowStep: width);
  }

  Int32List _resample(
    _FilterPlane source,
    int width,
    int height,
    int fractionBits, {
    int? ditherOffset,
  }) {
    if (width * source.height > 100000000) {
      throw const FormatException(
        'Pixel format conversion exceeds the sample limit',
      );
    }
    final geometry = (source.width, source.height, width, height);
    if (_scalers.length == 6 && !_scalers.containsKey(geometry))
      _scalers.clear();
    final scaler = _scalers.putIfAbsent(
      geometry,
      () => _PlaneScaler(
        source.width,
        source.height,
        width,
        height,
        kernel: _ScaleKernel.cubic,
      ),
    );
    final input = source.forward;
    return scaler.resize(
      input.samples,
      input.rowStep,
      input.offset,
      input.depth,
      fractionBits,
      ditherOffset: ditherOffset,
    );
  }

  _VideoPlanes _toRgb(_VideoPlanes frame, {bool bgr24 = false}) {
    final y = frame.planes.first.atOrigin;
    final cb = frame.planes.length == 3 ? frame.planes[1].packed : null;
    final cr = frame.planes.length == 3 ? frame.planes[2].packed : null;
    final width = y.width, height = y.height;
    final geometry = (width, height, frame.subX, frame.subY);
    if (_rgbScalers.length == 4 && !_rgbScalers.containsKey(geometry)) {
      _rgbScalers.clear();
    }
    // Convert using the same two-stage chroma resampler as the video scaler.
    final scaler = _rgbScalers.putIfAbsent(
      geometry,
      () => YuvImageScaler._fixed(width, height, _ScaleAlgorithm.bicubic),
    );
    final result = scaler._resize(
      y: y.samples,
      cb: cb?.samples ?? const [],
      cr: cr?.samples ?? const [],
      stride: y.rowStep,
      chromaStride: cb?.width ?? 0,
      sourceWidth: width,
      sourceHeight: height,
      width: width,
      height: height,
      cropLeft: 0,
      cropTop: 0,
      matrix: frame.matrix,
      fullRange: frame.fullRange,
      lumaDepth: y.depth,
      chromaDepth: cb?.depth ?? y.depth,
      subsamplingX: frame.subX,
      subsamplingY: frame.subY,
      alpha: null,
      alphaDepth: 8,
    );
    return YuvImageScaler._imagePlanes(
      result,
      frame.sampleAspect,
      bgr24: bgr24,
    );
  }

  _VideoPlanes _toDeepRgb(_VideoPlanes frame) {
    final width = frame.width, height = frame.height;
    final paired = width.isEven && (frame.subX != 0 || frame.subY != 0);
    final chromaWidth = paired ? width >> 1 : width;
    final y = frame.planes.first;
    // Match the precision of the packed RGB48 conversion. The chroma
    // resampler returns Q9 values on an eight-bit sample scale.
    final u = _resample(frame.planes[1], chromaWidth, height, 9);
    final v = _resample(frame.planes[2], chromaWidth, height, 9);
    final (rv, bu, gu, gv) = _rgbCoefficients(frame.matrix);
    int coefficient(int value) =>
        ((frame.fullRange ? value * 224 ~/ 255 : value) + 4) >> 3;
    final vr = coefficient(rv), ub = coefficient(bu);
    final ug = coefficient(gu), vg = coefficient(gv);
    final yc = frame.fullRange ? 8192 : 9539;
    final black = frame.fullRange ? 0 : 16 << 9;
    final green = Uint16List(width * height);
    final blue = Uint16List(green.length);
    final red = Uint16List(green.length);
    int sample(int value) => ((value + 8192) >> 14).clamp(0, 65535);
    var i = 0;
    for (var row = 0; row < height; row++) {
      for (var x = 0; x < width; x++) {
        final c = row * chromaWidth + (paired ? x >> 1 : x);
        final luma = ((y.at(x, row) << (17 - y.depth)) - black) * yc;
        final cb = u[c] - (128 << 9), cr = v[c] - (128 << 9);
        red[i] = sample(luma + vr * cr);
        blue[i] = sample(luma + ub * cb);
        green[i++] = sample(luma + ug * cb + vg * cr);
      }
    }
    return _VideoPlanes(
      [
        for (final values in [green, blue, red])
          _FilterPlane(values, width, height, 16, rowStep: width),
      ],
      0,
      0,
      matrix: 0,
      fullRange: true,
      packedRgb: true,
      sampleAspect: frame.sampleAspect,
    );
  }
}

int _depthDither(int sample, int bits) =>
    bits <= 6 ? sample >> (6 - bits) : sample << (bits - 7);

// Ordered thresholds for quantizing high-depth video components.
const _conversionDither = [
  [18, 34, 30, 46, 17, 33, 29, 45],
  [50, 2, 62, 14, 49, 1, 61, 13],
  [26, 42, 22, 38, 25, 41, 21, 37],
  [58, 10, 54, 6, 57, 9, 53, 5],
  [16, 32, 28, 44, 19, 35, 31, 47],
  [48, 0, 60, 12, 51, 3, 63, 15],
  [24, 40, 20, 36, 27, 43, 23, 39],
  [56, 8, 52, 4, 59, 11, 55, 7],
];

_FilterPlane _packedAlpha(_FilterPlane source, int depth) {
  final width = source.width, height = source.height;
  final out = _paintSamples(depth, width * height);
  final shift = 16 - depth, limit = (1 << depth) - 1;
  final rounding = (1 << shift) >> 1;
  // The packed input expands alpha by repeating its eight bits.
  var index = 0;
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      out[index++] = math.min(
        limit,
        (source.at(x, y) * 257 + rounding) >> shift,
      );
    }
  }
  return _FilterPlane(out, width, height, depth, rowStep: width);
}

_FilterPlane _constantPlane(int width, int height, int depth, int sample) {
  final values = _paintSamples(depth, width * height)
    ..fillRange(0, width * height, sample);
  return _FilterPlane(values, width, height, depth, rowStep: width);
}

(int, int) _componentLevels(
  int depth,
  bool full,
  bool chroma, {
  bool fromMinimum = false,
}) => (
  chroma && !fromMinimum
      ? 1 << (depth - 1)
      : full
      ? 0
      : 16 << (depth - 8),
  full ? (1 << depth) - 1 : (chroma ? 224 : 219) << (depth - 8),
);

int _roundComponent(int numerator, int denominator) {
  // Round the signed ratio to nearest, choosing the larger value on ties.
  final biased = numerator + (denominator >> 1);
  return biased >= 0
      ? biased ~/ denominator
      : (biased - denominator + 1) ~/ denominator;
}

_VideoPlanes _rgbToYuv(
  _VideoPlanes frame,
  _VideoPixelFormat target,
  int matrix,
  bool outputFull,
) {
  final width = frame.width, height = frame.height;
  final green = frame.planes[0], blue = frame.planes[1], red = frame.planes[2];
  // Keep six fraction bits while making limited-range BT.601 components.
  // A packed RGB input can be averaged in pairs before vertical chroma scaling.
  final hasChroma = target.color == _PixelColor.yuv;
  final pair = frame.packedRgb && hasChroma && width.isEven && target.subX != 0;
  final sub = pair ? 1 : 0;
  final cw = _subSize(width, sub);
  final (kr, kb) = _filterLumaWeights(matrix);
  final kg = 1 - kr - kb;
  final coefficients = matrix == 6 || matrix == 5 || matrix == 2
      ? _bt601RgbToYuv
      : [
          for (final (r, g, b) in [
            (kr * 219, kg * 219, kb * 219),
            (-kr * 112 / (1 - kb), -kg * 112 / (1 - kb), 112.0),
            (112.0, -kg * 112 / (1 - kr), -kb * 112 / (1 - kr)),
          ])
            (
              (r * 32768 / 255).round(),
              (g * 32768 / 255).round(),
              (b * 32768 / 255).round(),
            ),
        ];
  if (frame.bgr24 &&
      frame.fullRange &&
      width.isEven &&
      !outputFull &&
      target.depth == 8 &&
      target.subX == 1 &&
      target.subY == 1) {
    return _bgrToYuv420(frame, coefficients, matrix);
  }
  final y = Uint16List(width * height),
      cb = hasChroma ? Uint16List(cw * height) : null,
      cr = hasChroma ? Uint16List(cw * height) : null;
  final (black, levels) = _componentLevels(red.depth, frame.fullRange, false);
  final deep = frame.packedRgb && red.depth == 16 && frame.fullRange;
  final intermediateDepth = deep ? 16 : 14;
  int sample(int component, int r, int g, int b, int count) {
    final bias = count * black;
    final rgb = _rgbProduct(
      coefficients[component],
      r - bias,
      g - bias,
      b - bias,
    );
    final offset = component == 0 ? 16 : 128;
    if (deep) return ((rgb + (offset << 23) + 16384) >> 15).clamp(0, 65535);
    return ((offset << 6) + _roundComponent(rgb * 255, levels * count * 512))
        .clamp(0, 16383);
  }

  for (var row = 0; row < height; row++) {
    final offset = row * width, chroma = row * cw;
    for (var col = 0; col < width; col++) {
      y[offset + col] = sample(
        0,
        red.at(col, row),
        green.at(col, row),
        blue.at(col, row),
        1,
      );
    }
    if (cb == null) continue;
    for (var col = 0; col < cw; col++) {
      final x = col << sub;
      var r = red.at(x, row), g = green.at(x, row), b = blue.at(x, row);
      if (pair) {
        r += red.at(x + 1, row);
        g += green.at(x + 1, row);
        b += blue.at(x + 1, row);
        if (deep) {
          r = (r + 1) >> 1;
          g = (g + 1) >> 1;
          b = (b + 1) >> 1;
        }
      }
      cb[chroma + col] = sample(1, r, g, b, 1 << sub);
      cr![chroma + col] = sample(2, r, g, b, 1 << sub);
    }
  }
  return _VideoPlanes(
    [
      _FilterPlane(y, width, height, intermediateDepth, rowStep: width),
      if (cb != null)
        for (final plane in [cb, cr!])
          _FilterPlane(plane, cw, height, intermediateDepth, rowStep: cw),
    ],
    sub,
    0,
    matrix: matrix,
    fullRange: false,
    sampleAspect: frame.sampleAspect,
  );
}

_VideoPlanes _bgrToYuv420(
  _VideoPlanes frame,
  List<(int, int, int)> coefficients,
  int matrix,
) {
  final width = frame.width, height = frame.height;
  final cw = width >> 1, ch = _subSize(height, 1);
  final y = Uint8List(width * height),
      u = Uint8List(cw * ch),
      v = Uint8List(cw * ch);
  final green = frame.planes[0], blue = frame.planes[1], red = frame.planes[2];
  // The unscaled BGR24 conversion averages a 2×2 RGB block before
  // converting its chroma. Odd heights repeat the last source row.
  for (var row = 0; row < height; row++) {
    for (var x = 0; x < width; x++) {
      y[row * width + x] =
          16 +
          (_rgbProduct(
                coefficients[0],
                red.at(x, row),
                green.at(x, row),
                blue.at(x, row),
              ) >>
              15);
    }
  }
  int block(_FilterPlane p, int x, int y, int next) =>
      (p.at(x, y) + p.at(x + 1, y) + p.at(x, next) + p.at(x + 1, next)) >> 2;
  for (var row = 0; row < ch; row++) {
    final top = row * 2, below = math.min(top + 1, height - 1);
    for (var col = 0; col < cw; col++) {
      final x = col * 2;
      final r = block(red, x, top, below), g = block(green, x, top, below);
      final b = block(blue, x, top, below);
      final offset = row * cw + col;
      u[offset] = 128 + (_rgbProduct(coefficients[1], r, g, b) >> 15);
      v[offset] = 128 + (_rgbProduct(coefficients[2], r, g, b) >> 15);
    }
  }
  return _VideoPlanes(
    [
      _FilterPlane(y, width, height, 8, rowStep: width),
      _FilterPlane(u, cw, ch, 8, rowStep: cw),
      _FilterPlane(v, cw, ch, 8, rowStep: cw),
    ],
    1,
    1,
    matrix: matrix,
    fullRange: false,
    sampleAspect: frame.sampleAspect,
  );
}

(double, double) _filterLumaWeights(int matrix) => switch (matrix) {
  1 => (0.2126, 0.0722),
  4 => (0.30, 0.11),
  7 => (0.212, 0.087),
  9 || 10 => (0.2627, 0.0593),
  _ => (0.299, 0.114),
};
