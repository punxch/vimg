part of 'yuv_image.dart';

typedef _YuvGeometry = ({
  int sourceWidth,
  int sourceHeight,
  int width,
  int height,
  int chromaWidth,
  int chromaHeight,
  int outputChromaWidth,
  _ScaleKernel chromaKernel,
  bool scalarTaps,
});

bool _needsChromaResampling(
  int width,
  int horizontal,
  int vertical,
  int depth,
) => (horizontal != 0 || vertical != 0) && (width.isOdd || depth > 8);

/// Owned decoded components for a graph with more than one source picture.
final class VideoFilterPicture {
  const VideoFilterPicture._(this._planes);
  final _VideoPlanes _planes;
}

/// Resize video samples before RGB conversion. Reuse filter taps across frames.
final class YuvImageScaler {
  YuvImageScaler({
    this.width,
    this.height,
    this.filters,
    this.enlarge = true,
    this.packedOutput = false,
  }) : _exact = false,
       _algorithm = _ScaleAlgorithm.bicubic,
       _sampleAspect = null;

  YuvImageScaler._fixed(int this.width, int this.height, this._algorithm)
    : _exact = true,
      enlarge = true,
      packedOutput = false,
      _sampleAspect = null,
      filters = null;

  YuvImageScaler._presentation(
    this.width,
    this.height,
    this.filters,
    this._sampleAspect,
    this.enlarge,
    this.packedOutput,
  ) : _exact = false,
      _algorithm = _ScaleAlgorithm.bicubic;

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
    scaler?.enlarge ?? true,
    scaler?.packedOutput ?? false,
  );

  final int? width, height;
  final VideoFilterChain? filters;
  final double? _sampleAspect;
  final bool enlarge, packedOutput, _exact;
  final _ScaleAlgorithm _algorithm;
  YuvImageScaler? _outputScale;
  late final YuvImageScaler? unscaled = filters == null
      ? null
      : width == null && height == null
      ? this
      : YuvImageScaler._presentation(
          null,
          null,
          filters,
          _sampleAspect,
          enlarge,
          packedOutput,
        );
  _YuvGeometry? _geometry;
  late _PlaneScaler _luma;
  _PlaneScaler? _chroma;
  ({int matrix, bool fullRange})? _tableColor;
  late _RgbTable _table;
  List<FilterFramePosition> _positions = const [];
  void Function(VideoFilterPicture)? _receivePicture;
  static final _capturePlaceholder = image.Image(width: 1, height: 1);

  VideoFilterPicture captureFilterPicture(image.Image Function() render) {
    VideoFilterPicture? picture;
    _receivePicture = (value) => picture = value;
    try {
      final rgb = render();
      if (picture == null) filterRgb(rgb);
      return picture!;
    } finally {
      _receivePicture = null;
    }
  }

  image.Image renderFilterPicture(
    FilterPicture picture,
    VideoFilterPicture Function(FramePacket) source,
  ) {
    final graph = filters!._graph!;
    final operation = picture is FilterOperationPicture ? picture : null;
    final terminal = operation == null
        ? null
        : graph.steps[operation.step].filter;
    final scale = width == null && height == null && terminal is _Scale
        ? terminal
        : null;
    final evaluated = <FilterPicture, _VideoPlanes>{};
    _VideoPlanes evaluate(FilterPicture node) => evaluated.putIfAbsent(
      node,
      () {
        return switch (node) {
          FilterInputPicture(:final packet) => source(packet)._planes,
          FilterOperationPicture(:final step, :final inputs, :final position) =>
            _applyFilterStep(
              graph.steps[step].filter,
              inputs.map(evaluate).toList(),
              position,
            ),
        };
      },
    );
    return _convertFiltered(
      evaluate(scale == null ? picture : operation!.inputs.single),
      scale,
      operation?.position,
    );
  }

  image.Image renderCapture(
    List<FilterFramePosition> positions,
    image.Image Function() render,
  ) {
    final previous = _positions;
    _positions = positions;
    try {
      return render();
    } finally {
      _positions = previous;
    }
  }

  image.Image filterRgb(
    image.Image frame, {
    double sampleAspect = 1,
    bool bgr24 = false,
  }) {
    if (filters == null) return frame;
    return _renderFiltered(
      _imagePlanes(frame, _sampleAspect ?? sampleAspect, bgr24: bgr24),
    );
  }

  /// Receive full-size grayscale or planar GBR samples in G, B, R order.
  image.Image filterFloatPlanes(
    List<Float32List> samples, {
    required int width,
    required int height,
    required int matrix,
    required bool fullRange,
    Float32List? alpha,
  }) {
    _checkFilterSize(width, height);
    final count = width * height;
    if ((samples.length != 1 && (samples.length != 3 || matrix != 0)) ||
        samples.any((plane) => plane.length != count) ||
        (alpha != null && alpha.length != count)) {
      throw const FormatException('Invalid planar float video frame');
    }
    final frame = _VideoPlanes(
      [for (final plane in samples) _FilterPlane.f32(plane, width, height)],
      0,
      0,
      matrix: matrix,
      fullRange: fullRange,
      sampleAspect: _sampleAspect ?? 1,
      alpha: alpha == null ? null : _FilterPlane.f32(alpha, width, height),
    );
    return filters == null
        ? _convertFiltered(frame, null, null)
        : _renderFiltered(frame);
  }

  static _VideoPlanes _imagePlanes(
    image.Image frame,
    double sampleAspect, {
    bool bgr24 = false,
  }) {
    _checkFilterSize(frame.width, frame.height);
    if (frame.format == image.Format.float32) {
      final channels = List.generate(
        frame.hasAlpha ? 4 : 3,
        (_) => Float32List(frame.width * frame.height),
      );
      var i = 0;
      for (final pixel in frame) {
        channels[0][i] = pixel.g.toDouble();
        channels[1][i] = pixel.b.toDouble();
        channels[2][i] = pixel.r.toDouble();
        if (frame.hasAlpha) channels[3][i] = pixel.a.toDouble();
        i++;
      }
      final planes = [
        for (final samples in channels)
          _FilterPlane.f32(samples, frame.width, frame.height),
      ];
      return _VideoPlanes(
        planes.sublist(0, 3),
        0,
        0,
        matrix: 0,
        fullRange: true,
        sampleAspect: sampleAspect,
        alpha: frame.hasAlpha ? planes.last : null,
      );
    }
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
    return _VideoPlanes(
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
      packedRgb: true,
      bgr24: bgr24,
      sampleAspect: sampleAspect,
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
  }

  image.Image _renderFiltered(_VideoPlanes source) {
    final scale = width == null && height == null ? filters!._finalScale : null;
    final frame = filters!._apply(
      source,
      _positions,
      deferScale: scale != null,
    );
    if (_receivePicture case final receive?) {
      // Decoder buffers may be reused as soon as the next packet is read.
      receive(VideoFilterPicture._(frame.map((plane, _, _) => plane._copy())));
      return _capturePlaceholder;
    }
    return _convertFiltered(frame, scale, _positions.lastOrNull);
  }

  image.Image _convertFiltered(
    _VideoPlanes frame,
    _Scale? scale,
    FilterFramePosition? position,
  ) {
    YuvImageScaler? outputScale;
    if ((packedOutput || filters?.bitmapOutput == true) &&
        scale == null &&
        frame.alpha?.depth == 8 &&
        !frame.rgb &&
        frame.planes.length == 3 &&
        frame.planes.every((plane) => plane.depth == 8) &&
        _dimensions(frame.width, frame.height) == (frame.width, frame.height)) {
      // The unscaled filter sink converts YUVA directly to packed RGB.
      if (frame.usesUnscaledRgbTable) {
        return _rgbTable(frame.matrix, frame.fullRange).writeUnscaled(frame);
      }
      if (frame.subX == 0 && frame.subY == 0) {
        final [y, cb, cr] = frame.planes;
        final alpha = frame.alpha!;
        final matrix = _PackedYuvMatrix(frame.matrix, frame.fullRange);
        final pixels = image.Image(
          width: frame.width,
          height: frame.height,
          numChannels: 4,
        );
        for (final pixel in pixels) {
          final x = pixel.x, row = pixel.y;
          final (r, g, b) = matrix.rgb(
            y.at(x, row) << 9,
            cb.at(x, row) << 9,
            cr.at(x, row) << 9,
          );
          pixel.setRgba(r, g, b, alpha.at(x, row));
        }
        return pixels;
      }
    }
    if (scale != null) {
      // The terminal scale can upsample chroma while converting to RGB.
      // RGB output uses the input interpretation and has its own full range.
      frame = scale.interpretInputColor(frame);
      final (w, h) = scale.dimensions(
        frame,
        scale.usesFramePosition ? position : null,
      );
      if (w == frame.width &&
          h == frame.height &&
          frame.usesUnscaledRgbTable &&
          (frame.alpha?.depth ?? 8) == 8) {
        // The unscaled 8-bit RGB kernel reads chroma directly from its grid.
        return _rgbTable(frame.matrix, frame.fullRange).writeUnscaled(frame);
      }
      if (frame.floating && !frame.usesDeepRgbPacking ||
          frame.usesDeepRgbPacking && scale.nearest ||
          frame.packedRgb &&
              (scale.algorithm != _ScaleAlgorithm.bicubic ||
                  scale._subsamplesRgb(frame, w))) {
        frame = scale.resize(frame, w, h);
      } else {
        outputScale = _fixedOutput(w, h, scale.algorithm);
      }
    } else if (width != null || height != null) {
      outputScale = _outputScale ??= YuvImageScaler(
        width: width,
        height: height,
        enlarge: enlarge,
      );
    }
    if (frame.floating) {
      if (outputScale case final scaler? when !frame.usesDeepRgbPacking) {
        final (w, h) = scaler._dimensions(frame.width, frame.height);
        _checkFilterSize(w, h);
        frame = frame.map(
          (plane, _, _) => _resizeFloatPlane(
            plane,
            w,
            h,
            scaler._algorithm.kernel(chroma: false),
          ),
        );
        outputScale = null;
      }
      frame = _quantizeFloatFrame(frame);
    }
    if (outputScale == null &&
        frame.planes.length == 3 &&
        !frame.rgb &&
        _needsChromaResampling(
          frame.width,
          frame.subX,
          frame.subY,
          math.max(frame.planes.first.depth, frame.planes[1].depth),
        )) {
      // RGB conversion can resample chroma even when the luma size is fixed.
      outputScale = _fixedOutput(
        frame.width,
        frame.height,
        _ScaleAlgorithm.bicubic,
      );
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
      packedRgb: frame.packedRgb,
      lumaDepth: y.depth,
      chromaDepth: cb?.depth ?? y.depth,
      subsamplingX: frame.subX,
      subsamplingY: frame.subY,
      alpha: alpha?.samples,
      alphaDepth: alpha?.depth ?? 8,
      scaler: outputScale,
    );
  }

  YuvImageScaler _fixedOutput(
    int width,
    int height,
    _ScaleAlgorithm algorithm,
  ) {
    final previous = _outputScale;
    if (previous != null &&
        previous.width == width &&
        previous.height == height &&
        previous._algorithm == algorithm) {
      return previous;
    }
    return _outputScale = YuvImageScaler._fixed(width, height, algorithm);
  }

  (int, int) _dimensions(int sourceWidth, int sourceHeight) => _exact
      ? (width!, height!)
      : fitDimensions(
          sourceWidth,
          sourceHeight,
          width: width,
          height: height,
          enlarge: enlarge,
        );

  _RgbTable _rgbTable(int matrix, bool fullRange) {
    final color = (matrix: matrix, fullRange: fullRange);
    if (_tableColor != color) {
      _table = _RgbTable(matrix, fullRange);
      _tableColor = color;
    }
    return _table;
  }

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
    bool packedRgb = false,
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
    final deepYuv =
        cb.isNotEmpty && _hasDeepYuvDepth(matrix, lumaDepth, chromaDepth);
    final deepGray = cb.isEmpty && _hasDeepGrayPacking(lumaDepth, fullRange);
    final studio =
        gbr &&
            !packedRgb &&
            fullRange &&
            lumaDepth > 8 &&
            lumaDepth == chromaDepth &&
            subsamplingX == 0 &&
            subsamplingY == 0
        ? _RgbStudioConverter(lumaDepth)
        : null;
    // FFmpeg reuses chroma across pixel pairs for even-width RGB output when
    // the input already has chroma subsampling.
    final halfChroma =
        !gbr &&
        width.isEven &&
        cb.isNotEmpty &&
        (subsamplingX != 0 || subsamplingY != 0);
    final geometry = (
      sourceWidth: sourceWidth,
      sourceHeight: sourceHeight,
      width: width,
      height: height,
      chromaWidth: (sourceWidth + (1 << subsamplingX) - 1) >> subsamplingX,
      chromaHeight: (sourceHeight + (1 << subsamplingY) - 1) >> subsamplingY,
      outputChromaWidth: cb.isEmpty ? 0 : (halfChroma ? width >> 1 : width),
      chromaKernel: _algorithm.kernel(chroma: !gbr || studio != null),
      scalarTaps: studio != null || deepYuv || deepGray,
    );
    if (geometry != _geometry) {
      final lumaKernel = _algorithm.kernel(chroma: false);
      _luma = _PlaneScaler(
        sourceWidth,
        sourceHeight,
        width,
        height,
        kernel: lumaKernel,
        scalarTaps: geometry.scalarTaps,
      );
      _chroma = cb.isEmpty
          ? null
          : geometry.scalarTaps &&
                subsamplingX == 0 &&
                subsamplingY == 0 &&
                geometry.chromaKernel == lumaKernel
          ? _luma
          : _PlaneScaler(
              geometry.chromaWidth,
              geometry.chromaHeight,
              geometry.outputChromaWidth,
              height,
              kernel: geometry.chromaKernel,
              scalarTaps: geometry.scalarTaps,
            );
      _geometry = geometry;
    }
    // The paired-chroma filter output quantizes its YUV samples before the
    // RGB lookup, including when the decoded planes use more than eight bits.
    final useTable =
        halfChroma && (deepYuv || _exact || lumaDepth == 8 && chromaDepth == 8);
    final fractionalBits = useTable ? 0 : 9;
    final lumaOffset = cropTop * stride + cropLeft;
    final chromaOffset =
        (cropTop >> subsamplingY) * chromaStride + (cropLeft >> subsamplingX);
    (Uint16List, Uint16List, Uint16List)? studioPlanes;
    if (studio != null) {
      final y16 = Uint16List(sourceWidth * sourceHeight);
      final u16 = Uint16List(y16.length), v16 = Uint16List(y16.length);
      var index = 0;
      for (var row = 0; row < sourceHeight; row++) {
        final yi = lumaOffset + row * stride;
        final ci = chromaOffset + row * chromaStride;
        for (var x = 0; x < sourceWidth; x++) {
          final (luma, u, v) = studio.toStudio(
            cr[ci + x],
            y[yi + x],
            cb[ci + x],
          );
          y16[index] = luma;
          u16[index] = u;
          v16[index++] = v;
        }
      }
      studioPlanes = (y16, u16, v16);
    }
    bool truncateMatrix(int row) =>
        _luma.hasPackedPair(row) && (_chroma?.hasPackedPair(row) ?? true);
    final truncateRows = geometry.scalarTaps ? truncateMatrix : null;
    final luma = _luma.resize(
      studioPlanes?.$1 ?? y,
      studio == null ? stride : sourceWidth,
      studio == null ? lumaOffset : 0,
      studio?.studioDepth ?? lumaDepth,
      fractionalBits,
      truncateRows: truncateRows,
    );
    final blueChroma = _chroma?.resize(
      studioPlanes?.$2 ?? cb,
      studio == null ? chromaStride : sourceWidth,
      studio == null ? chromaOffset : 0,
      studio?.studioDepth ?? chromaDepth,
      fractionalBits,
      truncateRows: truncateRows,
    );
    final redChroma = _chroma?.resize(
      studioPlanes?.$3 ?? cr,
      studio == null ? chromaStride : sourceWidth,
      studio == null ? chromaOffset : 0,
      studio?.studioDepth ?? chromaDepth,
      fractionalBits,
      truncateRows: truncateRows,
    );
    final pixels = image.Image(
      width: width,
      height: height,
      numChannels: alpha == null ? 3 : 4,
    );
    if (studio != null) {
      var i = 0;
      for (final pixel in pixels) {
        final (r, g, b) = studio.fromStudio(
          luma[i],
          blueChroma![i],
          redChroma![i],
        );
        pixel.setRgb(r, g, b);
        i++;
      }
    } else if (useTable) {
      _rgbTable(matrix, fullRange).write(pixels, luma, blueChroma!, redChroma!);
    } else if (deepYuv || deepGray) {
      final packed = _PackedYuvMatrix(matrix, fullRange);
      var i = 0;
      for (final pixel in pixels) {
        final (r, g, b) = packed.rgb(
          luma[i],
          blueChroma?[i] ?? 128 << 9,
          redChroma?[i] ?? 128 << 9,
        );
        pixel.setRgb(r, g, b);
        i++;
      }
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
      final pairedAlpha = deepYuv && halfChroma;
      final scaled = _luma.resize(
        alpha,
        stride,
        lumaOffset,
        alphaDepth,
        geometry.scalarTaps ? 0 : 9,
        truncateRows: pairedAlpha ? truncateRows : null,
      );
      // A paired identity row rescales its Q7 alpha by 255. The packed
      // two-tap path truncates alpha together with the YUV samples.
      if (pairedAlpha && _luma.vertical.first.weights.length == 1) {
        for (var row = 0; row < height; row++) {
          final chroma = _chroma!.vertical[row].weights;
          if (chroma.length != 1 &&
              !(_chroma!.hasPackedPair(row) && chroma[1] == 0)) {
            continue;
          }
          final start = _luma.vertical[row].start * width;
          for (var x = 0; x < width; x++) {
            scaled[row * width + x] =
                (_luma.intermediate[start + x] * 255 + 16384) >> 15;
          }
        }
      }
      final maximum = ((1 << alphaDepth) - 1) << (17 - alphaDepth);
      var index = 0;
      for (final pixel in pixels) {
        final sample = scaled[index++];
        pixel.a = geometry.scalarTaps
            ? sample.clamp(0, 255)
            : (sample.clamp(0, maximum) * 255 + (maximum >> 1)) ~/ maximum;
      }
    }
    return pixels;
  }
}

enum _ScaleAlgorithm {
  neighbor,
  bilinear,
  bicubic,
  bicublin;

  _ScaleKernel kernel({required bool chroma}) => switch (this) {
    neighbor => _ScaleKernel.point,
    bilinear => _ScaleKernel.triangle,
    bicublin when chroma => _ScaleKernel.triangle,
    bicubic || bicublin => _ScaleKernel.cubic,
  };
}

enum _ScaleKernel { point, triangle, cubic }

_FilterPlane _resizeFloatPlane(
  _FilterPlane source,
  int width,
  int height,
  _ScaleKernel kernel,
) {
  if (width == source.width && height == source.height) return source;
  if (width * source.height > 100000000) {
    throw const FormatException(
      'Floating-point resize exceeds the sample limit',
    );
  }
  final horizontal = _axisTaps(source.width, width, 14, kernel);
  final vertical = _axisTaps(source.height, height, 12, kernel);
  final rows = Float32List(width * source.height);
  var output = 0;
  for (var y = 0; y < source.height; y++) {
    for (final tap in horizontal) {
      var sum = 0.0;
      for (var k = 0; k < tap.weights.length; k++) {
        final weight = tap.weights[k];
        if (weight != 0) sum += source.floatAt(tap.start + k, y) * weight;
      }
      rows[output++] = sum / (1 << 14);
    }
  }
  final result = Float32List(width * height);
  output = 0;
  for (final tap in vertical) {
    for (var x = 0; x < width; x++) {
      var sum = 0.0;
      var sample = tap.start * width + x;
      for (final weight in tap.weights) {
        if (weight != 0) sum += rows[sample] * weight;
        sample += width;
      }
      result[output++] = sum / (1 << 12);
    }
  }
  return _FilterPlane.f32(result, width, height);
}

final class _PlaneScaler {
  _PlaneScaler(
    int sourceWidth,
    int sourceHeight,
    this.width,
    int height, {
    required _ScaleKernel kernel,
    this.precision = 15,
    bool scalarTaps = false,
  }) : horizontal = _axisTaps(
         sourceWidth,
         width,
         14,
         kernel,
         scalar: scalarTaps,
       ),
       vertical = _axisTaps(
         sourceHeight,
         height,
         12,
         kernel,
         scalar: scalarTaps,
       ),
       intermediate = precision == 15
           ? Int16List(sourceHeight * width)
           : Int32List(sourceHeight * width);

  final int width, precision;
  final List<_AxisTap> horizontal, vertical;
  final List<int> intermediate;
  bool hasPackedPair(int row) {
    final weights = vertical[row].weights;
    return weights.length == 2 &&
        weights[1] >= 0 &&
        weights[1] <= 4096 &&
        weights[0] + weights[1] == 4096;
  }

  Int32List resize(
    List<int> source,
    int stride,
    int offset,
    int depth,
    int fractionalBits, {
    int? ditherOffset,
    _VideoSampleRange? range,
    bool Function(int)? truncateRows,
  }) {
    final horizontalShift = depth + 14 - precision;
    final maximum = (1 << precision) - 1;
    var output = 0;
    for (var row = 0; row < intermediate.length; row += width) {
      for (final tap in horizontal) {
        final start = offset + tap.start;
        var sum = 0;
        for (var i = 0; i < tap.weights.length; i++) {
          sum += source[start + i] * tap.weights[i];
        }
        final filtered = math.min(maximum, sum >> horizontalShift);
        intermediate[output++] = range?.convert(filtered) ?? filtered;
      }
      offset += stride;
    }
    final result = Int32List(width * vertical.length);
    final shift = precision + 4 - fractionalBits;
    final rounding = 1 << (shift - 1);
    output = 0;
    for (var row = 0; row < vertical.length; row++) {
      final tap = vertical[row];
      final start = tap.start * width;
      // The packed RGB two-tap kernel truncates the interpolated Q9 values.
      final rowRounding = truncateRows?.call(row) == true ? 0 : rounding;
      for (var x = 0; x < width; x++) {
        var sum = ditherOffset == null
            ? rowRounding
            : _conversionDither[row & 7][(x + ditherOffset) & 7] <<
                  (precision - 2);
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

List<_AxisTap> _axisTaps(
  int from,
  int to,
  int bits,
  _ScaleKernel kernel, {
  bool scalar = false,
}) {
  final unit = 1 << bits;
  final step = _scaleStep(from, to);
  if (scalar && (step - 65536).abs() < 10) {
    final identity = Int16List.fromList([unit]);
    return List.generate(
      to,
      (x) => (start: math.min(x, from - 1), weights: identity),
    );
  }
  if (from == to || from == 1 || kernel == _ScaleKernel.point) {
    final identity = Int16List.fromList([unit]);
    return List.generate(
      to,
      (x) => (start: _nearestIndex(x, step, from), weights: identity),
    );
  }
  final scale = math.min(1.0, to / from);
  final support = kernel == _ScaleKernel.triangle ? 2 : 4;
  final filterSize = scalar
      ? (support * math.max(from, to) + to - 1) ~/ to
      : (support / scale).ceil();
  final count = math.min(math.max(1, from - 2), 1 + filterSize);
  if (scalar) return _scalarAxisTaps(from, to, unit, step, count, kernel);
  return List.generate(to, (x) {
    // A pixel center is at x + 0.5. Widen the kernel when shrinking.
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
        _ when kernel == _ScaleKernel.triangle => math.max(0.0, 1 - d),
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
      final u = cb[offset >> 1], v = cr[offset >> 1];
      _writePixel(pixel, y[offset++], u, v);
    }
  }

  image.Image writeUnscaled(_VideoPlanes frame, {bool preserveAlpha = true}) {
    final alpha = preserveAlpha ? frame.alpha : null;
    final pixels = image.Image(
      width: frame.width,
      height: frame.height,
      numChannels: alpha == null ? 3 : 4,
    );
    for (final pixel in pixels) {
      final (r, g, b) = unscaledSample(frame, pixel.x, pixel.y);
      pixel.setRgb(r, g, b);
      if (alpha != null) pixel.a = alpha.at(pixel.x, pixel.y);
    }
    return pixels;
  }

  void _writePixel(image.Pixel pixel, int y, int u, int v) {
    final (r, g, b) = _sample(y, u, v);
    pixel.setRgb(r, g, b);
  }

  (int, int, int) unscaledSample(_VideoPlanes frame, int x, int y) {
    final cx = x >> frame.subX, cy = y >> frame.subY;
    return _sample(
      frame.planes[0].at(x, y),
      frame.planes[1].at(cx, cy),
      frame.planes[2].at(cx, cy),
    );
  }

  (int, int, int) _sample(int y, int u, int v) {
    u = u.clamp(0, 255);
    v = v.clamp(0, 255);
    final luma = y * scale + bias;
    return (
      ((luma + red[v] * scale) >> 16).clamp(0, 255),
      ((luma + (greenU[u] + greenV[v]) * scale) >> 16).clamp(0, 255),
      ((luma + blue[u] * scale) >> 16).clamp(0, 255),
    );
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
