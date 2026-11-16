part of 'yuv_image.dart';

final class _ExtractAlpha implements _SpatialFilter {
  const _ExtractAlpha();

  @override
  _VideoPlanes apply(_VideoPlanes frame) {
    final alpha = frame.alpha;
    if (alpha == null) {
      throw const FormatException('alphaextract requires an alpha plane');
    }
    return _VideoPlanes(
      [alpha],
      0,
      0,
      matrix: frame.matrix,
      fullRange: true,
      sampleAspect: frame.sampleAspect,
    );
  }
}

final class _VideoAlphaFilter implements _SpatialFilter {
  factory _VideoAlphaFilter(String name, String? source) {
    final dynamicMode = name == 'premultiply_dynamic';
    final options = _filterOptions(source, [
      'planes',
      if (!dynamicMode) 'inplace',
    ]);
    final planes = _filterInteger(options, 'planes', minimum: 0) ?? 15;
    if (planes > 15) {
      throw const FormatException(
        'Alpha filter planes must be between 0 and 15',
      );
    }
    final inplace = dynamicMode || _filterFlag(options['inplace'], 'inplace');
    final mode = dynamicMode ? null : name == 'premultiply';
    final formats = inplace ? _alphaLayouts : _maskLayouts;
    return _VideoAlphaFilter._(
      inplace,
      mode,
      planes,
      _FormatFilter._(formats, const [], const [], [if (mode != null) mode]),
    );
  }

  _VideoAlphaFilter._(this.inplace, this.mode, this.planes, this.format);

  final bool inplace;
  final bool? mode;
  final int planes;
  final _FormatFilter format;
  final _converter = _PixelFormatConverter();

  int get inputs => inplace ? 1 : 2;

  static final _alphaLayouts = [
    for (final name in [
      'yuva444p',
      'yuva444p9le',
      'yuva444p10le',
      'yuva444p12le',
      'yuva444p16le',
      'gbrap',
      'gbrap10le',
      'gbrap12le',
      'gbrap16le',
    ])
      _namedPixelFormat(name),
  ];

  static final _maskLayouts = [
    for (final name in ['yuv444p', 'yuvj444p', 'gbrp', 'gray'])
      _namedPixelFormat(name),
    for (final depth in [9, 10, 12, 14, 16])
      for (final name in ['yuv444p', 'gbrp', 'gray'])
        _namedPixelFormat('$name${depth}le'),
  ];

  _VideoAlphaFilter withFormat(_FormatFilter format) =>
      _VideoAlphaFilter._(inplace, mode, planes, format);

  @override
  _VideoPlanes apply(_VideoPlanes frame) {
    final target = format.select(frame);
    final base = _prepare(frame, target);
    final associated = mode ?? format.alphaMode(base);
    if (associated == null ||
        mode == null && base.premultiplied == associated) {
      return base;
    }
    final input = _converter.changeAlphaMode(base, !associated);
    return _multiplyAlphaPlanes(
      input,
      input.alpha!,
      associated,
      planes: planes,
    );
  }

  _VideoPlanes applyMask(_VideoPlanes frame, _VideoPlanes mask) {
    if (frame.width != mask.width || frame.height != mask.height) {
      throw const FormatException(
        'Alpha mask and video must have the same size',
      );
    }
    final target = format.select(frame);
    final base = _prepare(frame, target);
    final opacity = _converter
        .convert(
          mask,
          target.format,
          alpha: false,
          matrix: base.matrix,
          fullRange: base.fullRange,
        )
        .planes
        .first;
    return _multiplyAlphaPlanes(base, opacity, mode!, planes: planes);
  }

  _VideoPlanes _prepare(_VideoPlanes frame, _FormatSelection target) =>
      _converter.convert(
        frame,
        target.format,
        alpha: inplace,
        matrix: target.matrix,
        fullRange: target.fullRange,
      );
}

_VideoPlanes _multiplyAlphaPlanes(
  _VideoPlanes frame,
  _FilterPlane opacity,
  bool premultiplied, {
  int planes = 15,
}) {
  return frame.mapComponents((plane, _, _, index) {
    if (index == 3 || (planes & (1 << index)) == 0) return plane;
    final chroma = !frame.rgb && index != 0;
    final depth = plane.depth;
    final half = 1 << (depth - 1), max = (1 << depth) - 1;
    final offset = chroma
        ? half
        : frame.fullRange
        ? 0
        : 16 << (depth - 8);
    final samples = _paintSamples(depth, plane.width * plane.height);
    var i = 0;
    for (var y = 0; y < plane.height; y++) {
      for (var x = 0; x < plane.width; x++) {
        final value = plane.at(x, y), alpha = opacity.at(x, y);
        if (premultiplied) {
          final rounding = chroma ? 0 : half;
          samples[i++] =
              (((value - offset) * alpha + rounding) >> depth) + offset;
        } else if (alpha == 0 || alpha == max) {
          samples[i++] = value;
        } else {
          final delta = !chroma && offset != 0
              ? math.max(value - offset, 0)
              : value - offset;
          final straight = delta * max ~/ alpha + offset;
          samples[i++] = chroma && depth == 8
              ? math.min(straight, max) & max
              : straight.clamp(0, max);
        }
      }
    }
    return _FilterPlane(
      samples,
      plane.width,
      plane.height,
      depth,
      rowStep: plane.width,
    );
  }, premultiplied: premultiplied);
}
