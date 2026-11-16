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
  final gray = RegExp(
    r'^gray(?:(9|10|12|14|16|f32)(?:le|be))?$',
  ).firstMatch(name);
  if (gray != null) {
    return (
      format: _pixelFormat(_PixelColor.gray, _pixelDepth(gray.group(1))),
      alpha: false,
      fullRange: true,
    );
  }
  final planarRgb = RegExp(
    r'^gbr(a?)p(?:(9|10|12|14|16|f32)(?:le|be))?$',
  ).firstMatch(name);
  if (planarRgb != null) {
    return (
      format: _pixelFormat(_PixelColor.rgb, _pixelDepth(planarRgb.group(2))),
      alpha: planarRgb.group(1) == 'a',
      fullRange: true,
    );
  }
  if (!const {
    'rgb24',
    'bgr24',
    'rgba',
    'bgra',
    'argb',
    'abgr',
  }.contains(name)) {
    throw FormatException('Unsupported video pixel format: $name');
  }
  return (
    format: _pixelFormat(
      _PixelColor.rgb,
      8,
      packedRgb: true,
      bgr24: name == 'bgr24',
    ),
    alpha: name != 'rgb24' && name != 'bgr24',
    fullRange: true,
  );
}

int _pixelDepth(String? depth) =>
    depth == 'f32' ? _floatSampleDepth : int.parse(depth ?? '8');

final class _FormatFilter implements _SpatialFilter {
  factory _FormatFilter(String? source) {
    final options = _filterOptions(source, [
      'pix_fmts',
      'color_spaces',
      'color_ranges',
      'alpha_modes',
    ]);
    return _FormatFilter._(
      options['pix_fmts']?.split('|').map(_namedPixelFormat).toList() ??
          const [],
      options['color_spaces']?.split('|').map(_namedColorMatrix).toList() ??
          const [],
      options['color_ranges']?.split('|').map(_namedColorRange).toList() ??
          const [],
      options['alpha_modes']?.split('|').map(_namedAlphaMode).toList() ??
          const [],
    );
  }

  _FormatFilter._(
    this.formats,
    this.matrices,
    this.ranges, [
    this.alphaModes = const [],
    this.restoreAlphaLayout = true,
    this.layoutBeforeAlpha = false,
  ]);
  final List<_NamedPixelFormat> formats;
  final List<int> matrices;
  final List<bool> ranges;
  final List<bool> alphaModes;
  final bool restoreAlphaLayout;
  final bool layoutBeforeAlpha;
  final _PixelFormatConverter _converter = _PixelFormatConverter();

  bool get unrestricted =>
      formats.isEmpty &&
      matrices.isEmpty &&
      ranges.isEmpty &&
      alphaModes.isEmpty;

  bool get onlyAlphaMode =>
      alphaModes.isNotEmpty &&
      formats.isEmpty &&
      matrices.isEmpty &&
      ranges.isEmpty;

  _FormatFilter? intersect(_FormatFilter other) {
    final commonFormats = _intersectFormats(formats, other.formats);
    final commonMatrices = _intersectFormats(matrices, other.matrices);
    final commonRanges = _intersectFormats(ranges, other.ranges);
    final commonAlphaModes = _intersectFormats(alphaModes, other.alphaModes);
    if (commonFormats == null ||
        commonMatrices == null ||
        commonRanges == null ||
        commonAlphaModes == null) {
      return null;
    }
    return _FormatFilter._(
      commonFormats,
      commonMatrices,
      commonRanges,
      commonAlphaModes,
    );
  }

  _FormatFilter withoutAlphaModes() =>
      alphaModes.isEmpty ? this : _FormatFilter._(formats, matrices, ranges);

  _FormatFilter atAlphaStage(
    bool restoreLayout, {
    bool layoutBeforeAlpha = false,
  }) =>
      alphaModes.isEmpty ||
          restoreLayout == restoreAlphaLayout &&
              layoutBeforeAlpha == this.layoutBeforeAlpha
      ? this
      : _FormatFilter._(
          formats,
          matrices,
          ranges,
          alphaModes,
          restoreLayout,
          layoutBeforeAlpha,
        );

  bool? alphaMode(_VideoPlanes frame) => alphaModes.isEmpty
      ? null
      : alphaModes.contains(frame.premultiplied)
      ? frame.premultiplied
      : alphaModes.first;

  _FormatSelection select(
    _VideoPlanes frame, {
    int? outputMatrix,
    bool? outputRange,
    _NamedPixelFormat? preferred,
  }) {
    final input = _frameFormat(frame);
    final hasAlpha = frame.alpha != null;
    final target =
        preferred ??
        (formats.isEmpty
            ? (format: input, alpha: hasAlpha, fullRange: null)
            : _chooseFormat(formats, input, hasAlpha, frame.fullRange));
    final yuv = target.format.color == _PixelColor.yuv;
    final preferredMatrix = outputMatrix ?? frame.matrix;
    final matrix = !yuv
        ? null
        : matrices.isEmpty
        ? outputMatrix
        : matrices.contains(preferredMatrix)
        ? preferredMatrix
        : matrices.first;
    final preferredRange = outputRange ?? (frame.rgb ? null : frame.fullRange);
    final fullRange =
        target.fullRange ??
        (!yuv
            ? outputRange
            : ranges.isEmpty
            ? outputRange
            : preferredRange != null && ranges.contains(preferredRange)
            ? preferredRange
            : ranges.first);
    return (
      format: target.format,
      alpha: formats.isEmpty ? null : target.alpha,
      matrix: matrix,
      fullRange: fullRange,
    );
  }

  _NamedPixelFormat? matchingFormat(_VideoPlanes frame) {
    final layout = _frameFormat(frame);
    final alpha = frame.alpha != null;
    return formats
        .where(
          (candidate) =>
              _matchesFormat(candidate, layout, alpha, frame.fullRange),
        )
        .firstOrNull;
  }

  _NamedPixelFormat? get packedAlphaFormat => formats
      .where((candidate) => candidate.alpha && candidate.format.packedRgb)
      .firstOrNull;

  @override
  _VideoPlanes apply(_VideoPlanes frame) {
    if (unrestricted ||
        (alphaModes.isEmpty &&
            formats.isEmpty &&
            _frameFormat(frame).color != _PixelColor.yuv)) {
      return frame;
    }
    var target = select(frame);
    if (layoutBeforeAlpha &&
        _VideoAlphaFilter.supportsInplaceFormat(target.format)) {
      final converted = _convert(frame, target);
      final mode = alphaMode(converted);
      return mode == null
          ? converted
          : _converter.changeAlphaMode(converted, mode);
    }
    final convertsLayout =
        target.format != _frameFormat(frame) ||
        (target.alpha != null && target.alpha != (frame.alpha != null)) ||
        (target.fullRange != null && target.fullRange != frame.fullRange) ||
        (target.matrix != null && target.matrix != frame.matrix);
    // A downstream alpha requirement travels through a real pixel converter.
    // A format that already matches its input leaves association to the next stage.
    final mode = restoreAlphaLayout && !convertsLayout
        ? null
        : alphaMode(frame);
    if (mode != null && frame.alpha != null && target.alpha != false) {
      frame = _converter.changeAlphaMode(
        frame,
        mode,
        restoreLayout: restoreAlphaLayout,
      );
      if (formats.isEmpty) target = select(frame);
    }
    return _convert(frame, target, mode: mode);
  }

  _VideoPlanes _convert(
    _VideoPlanes frame,
    _FormatSelection target, {
    bool? mode,
  }) => _converter.convert(
    frame,
    target.format,
    alpha: target.alpha,
    matrix: target.matrix,
    fullRange: target.fullRange,
    premultiplied: mode,
  );
}

typedef _FormatSelection = ({
  _VideoPixelFormat format,
  bool? alpha,
  int? matrix,
  bool? fullRange,
});

List<T>? _intersectFormats<T>(List<T> left, List<T> right) {
  if (left.isEmpty) return right;
  if (right.isEmpty) return left;
  final common = left.where(right.contains).toList();
  return common.isEmpty ? null : common;
}

_NamedPixelFormat _chooseFormat(
  List<_NamedPixelFormat> candidates,
  _VideoPixelFormat input,
  bool hasAlpha,
  bool fullRange,
) {
  var best = candidates.first;
  var bestLoss = 1 << 30;
  for (final candidate in candidates) {
    final format = candidate.format;
    if (_matchesFormat(candidate, input, hasAlpha, fullRange)) {
      return candidate;
    }
    // Use the comparable losses for the layouts vimg represents natively.
    var loss = hasAlpha && !candidate.alpha ? 65536 : 0;
    final grayToRgb =
        input.color == _PixelColor.gray && format.color == _PixelColor.rgb;
    final channels =
        input.color == _PixelColor.gray || format.color == _PixelColor.gray
        ? 1
        : 3;
    if (input.color != format.color && !grayToRgb) {
      loss += format.color == _PixelColor.gray
          ? 2 * 65536
          : (channels * 65536) >> (math.min(input.depth, format.depth) - 1);
    }
    if (input.depth > format.depth) {
      loss += (channels * 65536) >> (format.depth - 1);
    } else {
      loss += format.depth - input.depth;
    }
    for (final (from, to) in [
      (input.subX, format.subX),
      (input.subY, format.subY),
    ]) {
      loss += to > from
          ? 256 << to
          : to < from
          ? 1 << (from - to)
          : 0;
    }
    if (loss < bestLoss) {
      best = candidate;
      bestLoss = loss;
    }
  }
  return best;
}

bool _matchesFormat(
  _NamedPixelFormat candidate,
  _VideoPixelFormat format,
  bool alpha,
  bool fullRange,
) =>
    candidate.format == format &&
    candidate.alpha == alpha &&
    (candidate.fullRange == null || candidate.fullRange == fullRange);

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

bool _namedAlphaMode(String name) => switch (name) {
  'premultiplied' => true,
  'straight' || 'unspecified' => false,
  _ => throw FormatException('Unsupported video alpha mode: $name'),
};

typedef _ColorScale = ({
  int width,
  int height,
  double sampleAspect,
  _ScaleAlgorithm algorithm,
  bool fullChromaInput,
});

_FilterPlane _opaqueFloatPlane(int width, int height) {
  final samples = Float32List(width * height);
  samples.fillRange(0, samples.length, 1.0);
  return _FilterPlane.f32(samples, width, height);
}

_VideoPlanes _quantizeFloatFrame(_VideoPlanes source) {
  final scaled = Float32List(1);
  return source.map((plane, _, _) {
    final samples = Uint16List(plane.width * plane.height);
    var i = 0;
    for (var y = 0; y < plane.height; y++) {
      for (var x = 0; x < plane.width; x++) {
        final sample = plane.floatAt(x, y);
        scaled[0] = sample.isNaN ? 0 : sample.clamp(0.0, 1.0) * 65535;
        final value = scaled[0];
        final low = value.toInt();
        // Float input to swscale is rounded to nearest, with ties to even.
        final fraction = value - low;
        samples[i++] =
            low + (fraction > 0.5 || fraction == 0.5 && low.isOdd ? 1 : 0);
      }
    }
    return _FilterPlane(
      samples,
      plane.width,
      plane.height,
      16,
      rowStep: plane.width,
    );
  });
}

/// Scalar RGB depth conversion via the studio-range matrix.
final class _RgbStudioConverter {
  _RgbStudioConverter(int depth, {int outputDepth = 8})
    : studioDepth = depth == 16 ? 16 : 14,
      _inputShift = depth == 16 ? 15 : depth + 1,
      _matrix = _PackedYuvMatrix(6, false, outputDepth: outputDepth),
      _lumaBias = (16 << (depth + 7)) + (1 << (depth == 16 ? 14 : depth)),
      _chromaBias = (128 << (depth + 7)) + (1 << (depth == 16 ? 14 : depth));

  final int studioDepth, _inputShift, _lumaBias, _chromaBias;
  final _PackedYuvMatrix _matrix;

  (int, int, int) toStudio(int r, int g, int b) => (
    (_rgbProduct(_bt601RgbToYuv[0], r, g, b) + _lumaBias) >> _inputShift,
    (_rgbProduct(_bt601RgbToYuv[1], r, g, b) + _chromaBias) >> _inputShift,
    (_rgbProduct(_bt601RgbToYuv[2], r, g, b) + _chromaBias) >> _inputShift,
  );

  (int, int, int) rgb(int r, int g, int b) {
    final (y, u, v) = toStudio(r, g, b);
    int q9(int sample) => _unscaledSampleQ9(sample, studioDepth);
    return fromStudio(q9(y), q9(u), q9(v));
  }

  (int, int, int) fromStudio(int y, int cb, int cr) => _matrix.rgb(y, cb, cr);
}

_VideoPlanes _convertRgbViaStudio(
  _VideoPlanes source,
  _VideoPixelFormat target, {
  required bool alpha,
  required bool premultiplied,
}) {
  final width = source.width, height = source.height;
  final depth = target.depth;
  final green = _paintSamples(depth, width * height);
  final blue = _paintSamples(depth, green.length);
  final red = _paintSamples(depth, green.length);
  final opacity = alpha && depth == 8 ? Uint8List(green.length) : null;
  final [g, b, r] = source.planes;
  final inputAlpha = source.alpha;
  final converter = _RgbStudioConverter(g.depth, outputDepth: depth);
  var i = 0;
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final (rr, gg, bb) = converter.rgb(r.at(x, y), g.at(x, y), b.at(x, y));
      green[i] = gg;
      blue[i] = bb;
      red[i] = rr;
      if (opacity != null) {
        opacity[i] = inputAlpha == null
            ? 255
            : _packedAlphaSample8(inputAlpha.at(x, y), inputAlpha.depth);
      }
      i++;
    }
  }
  _FilterPlane plane(List<int> data) =>
      _FilterPlane(data, width, height, depth, rowStep: width);
  final outputAlpha = !alpha
      ? null
      : opacity != null
      ? plane(opacity)
      : inputAlpha == null
      ? _constantPlane(width, height, depth, (1 << depth) - 1)
      : _expandRgbAlpha(inputAlpha, depth, packed: source.packedRgb);
  return _VideoPlanes(
    [plane(green), plane(blue), plane(red)],
    0,
    0,
    matrix: 0,
    fullRange: true,
    packedRgb: target.packedRgb,
    bgr24: target.bgr24,
    sampleAspect: source.sampleAspect,
    alpha: outputAlpha,
    premultiplied: outputAlpha != null && premultiplied,
  );
}

final class _PixelFormatConverter {
  final _scalers = <(int, int, int, int, _ScaleKernel, int), _PlaneScaler>{};
  final _rgbScalers = <(int, int, _ScaleAlgorithm), YuvImageScaler>{};

  _VideoPlanes convert(
    _VideoPlanes source,
    _VideoPixelFormat target, {
    bool? alpha,
    int? alphaDepth,
    bool? fullRange,
    int? matrix,
    _ColorScale? scale,
    bool? premultiplied,
  }) {
    final requestedAlpha = alpha ?? source.alpha != null;
    if (premultiplied != null && requestedAlpha) {
      source = changeAlphaMode(source, premultiplied);
    }
    final opacityDepth =
        alphaDepth ??
        (scale != null && alpha == null
            ? source.alpha?.depth ?? target.depth
            : target.depth);
    final full =
        fullRange ??
        (target.color == _PixelColor.yuv
            ? !source.rgb && source.planes.length == 3 && source.fullRange
            : true);
    final colorMatrix = target.color == _PixelColor.rgb
        ? 0
        : matrix ?? (source.matrix == 0 ? 6 : source.matrix);
    if (scale == null &&
        _frameFormat(source) == target &&
        source.fullRange == full &&
        source.matrix == colorMatrix &&
        requestedAlpha == (source.alpha != null) &&
        (alpha == null && alphaDepth == null ||
            source.alpha == null ||
            source.alpha!.depth == opacityDepth) &&
        source.planes.every((plane) => plane.depth == target.depth)) {
      return source;
    }

    final width = scale?.width ?? source.width;
    final height = scale?.height ?? source.height;
    final algorithm = scale?.algorithm ?? _ScaleAlgorithm.bicubic;
    _checkFilterSize(width, height);
    final replicateGray =
        source.planes.length == 1 && target.color == _PixelColor.rgb;
    if (target.depth == _floatSampleDepth &&
        source.floating &&
        (_frameFormat(source) == target || replicateGray) &&
        source.fullRange == full) {
      final resized = source.map(
        (plane, _, _) => _resizeFloatPlane(
          plane,
          width,
          height,
          algorithm.kernel(chroma: false),
        ),
        sampleAspect: scale?.sampleAspect,
      );
      return _VideoPlanes(
        replicateGray ? List.filled(3, resized.planes.first) : resized.planes,
        0,
        0,
        matrix: colorMatrix,
        fullRange: full,
        sampleAspect: resized.sampleAspect,
        alpha: !requestedAlpha
            ? null
            : resized.alpha ?? _opaqueFloatPlane(width, height),
        premultiplied:
            requestedAlpha && (premultiplied ?? resized.premultiplied),
      );
    }
    if (source.floating) source = _quantizeFloatFrame(source);
    final packsDeepLuma =
        target.packedRgb &&
        target.depth == 8 &&
        (source.usesDeepYuvPacking ||
            source.planes.length == 1 &&
                _hasDeepGrayPacking(
                  source.planes.first.depth,
                  source.fullRange,
                ));
    final packsDeep =
        target.packedRgb &&
        target.depth == 8 &&
        (packsDeepLuma || source.usesDeepRgbPacking);
    final expandsRgb8 =
        source.rgb &&
        source.subX == 0 &&
        source.subY == 0 &&
        source.planes.every((plane) => plane.depth == 8) &&
        (source.alpha?.depth ?? 8) == 8 &&
        target.color == _PixelColor.rgb &&
        target.depth > 8 &&
        target.depth < 16;
    if ((packsDeep || expandsRgb8) &&
        (source.fullRange || packsDeepLuma) &&
        full &&
        opacityDepth == target.depth &&
        (packsDeep || scale == null)) {
      if (packsDeepLuma ||
          scale != null && (width != source.width || height != source.height)) {
        return _toRgb(
          source,
          width,
          height,
          algorithm,
          bgr24: target.bgr24,
          includeAlpha: requestedAlpha,
        ).mapComponents(
          (plane, _, _, _) => plane,
          sampleAspect: scale?.sampleAspect,
          premultiplied:
              requestedAlpha && (premultiplied ?? source.premultiplied),
        );
      }
      return _convertRgbViaStudio(
        source,
        target,
        alpha: requestedAlpha,
        premultiplied: premultiplied ?? source.premultiplied,
      );
    }
    if (target.depth == _floatSampleDepth) {
      final deep = convert(
        source,
        _pixelFormat(target.color, 16),
        alpha: requestedAlpha,
        matrix: colorMatrix,
        fullRange: full,
        scale: scale,
        premultiplied: premultiplied,
      );
      return deep.map((plane, _, _) {
        final samples = Float32List(width * height);
        var i = 0;
        // libswscale multiplies by a single-precision reciprocal.
        const normalize = 1.0000152587890625 / 65536;
        for (var y = 0; y < height; y++) {
          for (var x = 0; x < width; x++) {
            samples[i++] = plane.at(x, y) * normalize;
          }
        }
        return _FilterPlane.f32(samples, width, height);
      });
    }
    final integerOpacityDepth = opacityDepth == _floatSampleDepth
        ? target.depth
        : opacityDepth;
    var working = source;
    if (!source.rgb && target.color == _PixelColor.rgb) {
      working = target.depth == 8
          ? _toRgb(source, width, height, algorithm)
          : source.planes.length == 1
          ? _VideoPlanes(
              List.filled(3, source.planes.first),
              0,
              0,
              matrix: 0,
              fullRange: source.fullRange,
            )
          : _toDeepRgb(
              source,
              width,
              height,
              algorithm,
              rgb48: !requestedAlpha,
            );
    } else if (!source.rgb &&
        source.planes.length == 3 &&
        target.color == _PixelColor.yuv &&
        _rgbCoefficients(source.matrix) != _rgbCoefficients(colorMatrix)) {
      // libswscale cascades both matrices through RGB, using 16-bit channels
      // when the requested YUV output has more than eight bits per component.
      // Resize in the stage that keeps the intermediate at the smaller size.
      final reduce = width * height < source.width * source.height;
      final w = reduce ? width : source.width;
      final h = reduce ? height : source.height;
      working = target.depth > 8
          ? _toDeepRgb(
              source,
              w,
              h,
              algorithm,
              rgb48: source.alpha == null || !requestedAlpha,
            )
          : _toRgb(
              source,
              w,
              h,
              algorithm,
              bgr24: source.alpha == null || !requestedAlpha,
            );
    }
    if (source.rgb &&
        source.planes.first.depth == 8 &&
        target.color == _PixelColor.rgb &&
        target.depth == 16) {
      // The 16-bit planar output reconstructs RGB from studio-range Q6
      // components before quantizing the destination samples.
      final yuv = _rgbToYuv(
        source,
        _pixelFormat(_PixelColor.yuv, 16),
        6,
        false,
        outputWidth: width,
        outputHeight: height,
        fullChromaInput: true,
      );
      working = _toDeepRgb(yuv, width, height, algorithm, rgb48: false);
    }
    if (working.rgb && target.color != _PixelColor.rgb) {
      working = _rgbToYuv(
        working,
        target,
        colorMatrix,
        full,
        outputWidth: width,
        outputHeight: height,
        fullChromaInput: scale?.fullChromaInput ?? false,
      );
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
                scale: scale?.algorithm,
                expandRgb:
                    target.color == _PixelColor.rgb &&
                    working.planes[i].depth == 8 &&
                    target.depth > 8,
              )
            : _constantPlane(w, h, target.depth, 1 << (target.depth - 1)),
      );
    }
    var opacity = source.alpha;
    if (requestedAlpha &&
        opacity != null &&
        source.packedRgb &&
        opacity.depth == 8 &&
        target.color != _PixelColor.rgb) {
      final sameSize = opacity.width == width && opacity.height == height;
      opacity = _packedAlpha(
        opacity,
        sameSize ? integerOpacityDepth : 14,
        round: sameSize,
      );
    }
    final convertedAlpha = !requestedAlpha
        ? null
        : opacity == null
        ? _constantPlane(
            width,
            height,
            integerOpacityDepth,
            (1 << integerOpacityDepth) - 1,
          )
        : (source.packedRgb || source.rgb) &&
              target.color == _PixelColor.rgb &&
              opacity.depth == 8 &&
              integerOpacityDepth > 8 &&
              opacity.width == width &&
              opacity.height == height
        ? _expandRgbAlpha(
            opacity,
            integerOpacityDepth,
            packed: source.packedRgb,
          )
        : _component(
            opacity,
            width,
            height,
            integerOpacityDepth,
            inputFull: true,
            outputFull: true,
            channel: native ? 3 : null,
            resamplesChroma: resamplesChroma,
            scale: scale?.algorithm,
          );
    return _VideoPlanes(
      planes,
      target.subX,
      target.subY,
      matrix: colorMatrix,
      fullRange: full,
      packedRgb: target.packedRgb,
      bgr24: target.bgr24,
      sampleAspect: scale?.sampleAspect ?? source.sampleAspect,
      alpha: convertedAlpha,
      premultiplied:
          convertedAlpha != null && (premultiplied ?? source.premultiplied),
    );
  }

  _VideoPlanes changeAlphaMode(
    _VideoPlanes source,
    bool premultiplied, {
    bool restoreLayout = true,
  }) {
    if (source.alpha == null || source.premultiplied == premultiplied) {
      return source;
    }
    final layout = _frameFormat(source);
    // Alpha association happens on the full-resolution color planes.
    final planar = _pixelFormat(layout.color, layout.depth);
    final frame = convert(
      source,
      planar,
      alpha: true,
      fullRange: source.fullRange,
      matrix: source.matrix,
    );
    final result = _multiplyAlphaPlanes(frame, frame.alpha!, premultiplied);
    if (!restoreLayout) return result;
    return convert(
      result,
      layout,
      alpha: true,
      alphaDepth: source.alpha!.depth,
      fullRange: source.fullRange,
      matrix: source.matrix,
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
    _ScaleAlgorithm? scale,
    bool expandRgb = false,
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
    final range = inputFull == outputFull
        ? null
        : _VideoSampleRange(depth, inputFull, outputFull, chroma);
    final preserveRange = !inputFull && !outputFull;
    var sampledDepth = srcDepth;
    _FilterPlane sampled = source;
    if (!sameSize || range != null) {
      sampledDepth =
          scale != null ||
              range != null ||
              preserveRange ||
              filterDither ||
              expandRgb
          ? depth
          : srcDepth;
      sampled = _FilterPlane(
        _resample(
          source,
          width,
          height,
          sampledDepth - 8,
          ditherOffset: filterDither ? phase : null,
          kernel: scale?.kernel(chroma: chroma) ?? _ScaleKernel.cubic,
          precision: (scale != null || range != null || expandRgb) && depth > 14
              ? 19
              : 15,
          range: range,
        ),
        width,
        height,
        sampledDepth,
        rowStep: width,
      );
    }
    final (lo, span) = _componentLevels(sampledDepth, outputFull, chroma);
    final (newLo, newSpan) = _componentLevels(depth, outputFull, chroma);
    var index = 0;
    for (var row = 0; row < height; row++) {
      for (var col = 0; col < width; col++) {
        final value = sampled.at(col, row);
        out[index++] =
            (lo == newLo && span == newSpan
                    ? value
                    : expandRgb && range == null
                    ? value << (depth - sampledDepth)
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
    _ScaleKernel kernel = _ScaleKernel.cubic,
    int precision = 15,
    _VideoSampleRange? range,
  }) {
    if (width * source.height > 100000000) {
      throw const FormatException(
        'Pixel format conversion exceeds the sample limit',
      );
    }
    final geometry = (
      source.width,
      source.height,
      width,
      height,
      kernel,
      precision,
    );
    if (_scalers.length == 6 && !_scalers.containsKey(geometry))
      _scalers.clear();
    final scaler = _scalers.putIfAbsent(
      geometry,
      () => _PlaneScaler(
        source.width,
        source.height,
        width,
        height,
        kernel: kernel,
        precision: precision,
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
      range: range,
    );
  }

  _VideoPlanes _toRgb(
    _VideoPlanes frame,
    int width,
    int height,
    _ScaleAlgorithm algorithm, {
    bool bgr24 = false,
    bool includeAlpha = false,
  }) {
    final geometry = (width, height, algorithm);
    if (_rgbScalers.length == 4 && !_rgbScalers.containsKey(geometry)) {
      _rgbScalers.clear();
    }
    // Convert using the same two-stage chroma resampler as the video scaler.
    final scaler = _rgbScalers.putIfAbsent(
      geometry,
      () => YuvImageScaler._fixed(width, height, algorithm),
    );
    if (!includeAlpha &&
        width == frame.width &&
        height == frame.height &&
        frame.usesUnscaledRgbTable) {
      final pixels = scaler
          ._rgbTable(frame.matrix, frame.fullRange)
          .writeUnscaled(frame, preserveAlpha: false);
      return YuvImageScaler._imagePlanes(
        pixels,
        frame.sampleAspect,
        bgr24: bgr24,
      );
    }
    final y = includeAlpha
        ? frame.planes.first.packed
        : frame.planes.first.atOrigin;
    final cb = frame.planes.length == 3 ? frame.planes[1].packed : null;
    final cr = frame.planes.length == 3 ? frame.planes[2].packed : null;
    final alpha = includeAlpha ? frame.alpha?.packed : null;
    final result = scaler._resize(
      y: y.samples,
      cb: cb?.samples ?? const [],
      cr: cr?.samples ?? const [],
      stride: y.rowStep,
      chromaStride: cb?.width ?? 0,
      sourceWidth: y.width,
      sourceHeight: y.height,
      width: width,
      height: height,
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
    );
    final packed = YuvImageScaler._imagePlanes(
      result,
      frame.sampleAspect,
      bgr24: bgr24,
    );
    if (!includeAlpha || alpha != null) return packed;
    return _VideoPlanes(
      packed.planes,
      0,
      0,
      matrix: 0,
      fullRange: true,
      packedRgb: true,
      bgr24: bgr24,
      sampleAspect: frame.sampleAspect,
      alpha: _constantPlane(width, height, 8, 255),
    );
  }

  _VideoPlanes _toDeepRgb(
    _VideoPlanes frame,
    int width,
    int height,
    _ScaleAlgorithm algorithm, {
    required bool rgb48,
  }) {
    final resizing = width != frame.width || height != frame.height;
    if (!resizing && rgb48 && frame.usesUnscaledRgbTable) {
      // The unscaled packed RGB48 kernel repeats each table output byte.
      final table = _RgbTable(frame.matrix, frame.fullRange);
      final red = Uint16List(width * height);
      final green = Uint16List(red.length), blue = Uint16List(red.length);
      var i = 0;
      for (var y = 0; y < height; y++) {
        for (var x = 0; x < width; x++) {
          final (r, g, b) = table.unscaledSample(frame, x, y);
          red[i] = r * 257;
          green[i] = g * 257;
          blue[i++] = b * 257;
        }
      }
      return _deepRgbPlanes(frame, width, height, green, blue, red);
    }
    final paired = width.isEven && (frame.subX != 0 || frame.subY != 0);
    final chromaWidth = paired ? width >> 1 : width;
    final y = frame.planes.first;
    // Match the precision of the packed RGB48 conversion. The chroma
    // resampler returns Q9 values on an eight-bit sample scale.
    final lumaSamples = resizing
        ? _resample(
            y,
            width,
            height,
            9,
            kernel: algorithm.kernel(chroma: false),
            precision: 19,
          )
        : null;
    final kernel = algorithm.kernel(chroma: true);
    final precision = resizing ? 19 : 15;
    final u = _resample(
      frame.planes[1],
      chromaWidth,
      height,
      9,
      kernel: kernel,
      precision: precision,
    );
    final v = _resample(
      frame.planes[2],
      chromaWidth,
      height,
      9,
      kernel: kernel,
      precision: precision,
    );
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
        final luma =
            ((lumaSamples?[i] ?? y.at(x, row) << (17 - y.depth)) - black) * yc;
        final cb = u[c] - (128 << 9), cr = v[c] - (128 << 9);
        red[i] = sample(luma + vr * cr);
        blue[i] = sample(luma + ub * cb);
        green[i++] = sample(luma + ug * cb + vg * cr);
      }
    }
    return _deepRgbPlanes(frame, width, height, green, blue, red);
  }

  _VideoPlanes _deepRgbPlanes(
    _VideoPlanes frame,
    int width,
    int height,
    Uint16List green,
    Uint16List blue,
    Uint16List red,
  ) => _VideoPlanes(
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

_FilterPlane _packedAlpha(_FilterPlane source, int depth, {bool round = true}) {
  final width = source.width, height = source.height;
  final out = _paintSamples(depth, width * height);
  final shift = 16 - depth, limit = (1 << depth) - 1;
  final rounding = round ? (1 << shift) >> 1 : 0;
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

_FilterPlane _expandRgbAlpha(
  _FilterPlane source,
  int depth, {
  required bool packed,
}) {
  final width = source.width, height = source.height;
  final values = Uint16List(width * height);
  final maximum = (1 << depth) - 1;
  var i = 0;
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final value = source.at(x, y);
      final scaled = packed ? value * 257 & ~3 : value << 8;
      values[i++] = depth == 16
          ? scaled
          : math.min(maximum, (scaled + 128) >> (16 - depth));
    }
  }
  return _FilterPlane(values, width, height, depth, rowStep: width);
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
  bool outputFull, {
  required int outputWidth,
  required int outputHeight,
  required bool fullChromaInput,
}) {
  final width = frame.width, height = frame.height;
  final green = frame.planes[0], blue = frame.planes[1], red = frame.planes[2];
  // Keep six fraction bits while making limited-range BT.601 components.
  // A packed RGB input can be averaged in pairs before vertical chroma scaling.
  final hasChroma = target.color == _PixelColor.yuv;
  final pair =
      (frame.packedRgb || red.depth == 8) &&
      hasChroma &&
      width.isEven &&
      (outputWidth >> target.subX) <= (width >> 1) &&
      !fullChromaInput;
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
  if (width == outputWidth &&
      height == outputHeight &&
      frame.bgr24 &&
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
