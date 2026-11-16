import 'dart:typed_data';

import 'package:image/image.dart' as image;

import 'yuv_image.dart';

enum _Layout { planar, semiplanar, packed422, packedRgb }

/// FourCC pixel layouts shared by Matroska and AVI.
final class RawVideoFormat {
  const RawVideoFormat._(
    this.width,
    this.height,
    this._layout,
    this._order,
    this.depth,
    this.subX,
    this.subY,
    this._endian,
    this._msb,
    this.matrix,
    this.fullRange,
  );

  static bool recognizes(String tag) => _layoutFor(tag) != null;

  factory RawVideoFormat(
    String tag,
    int width,
    int height, {
    int? matrix,
    bool? fullRange,
  }) {
    final spec = _layoutFor(tag);
    if (spec == null)
      throw UnsupportedError('Unsupported raw video FourCC: $tag');
    if (width <= 0 || height <= 0 || width > (32 * 1024 * 1024) ~/ height) {
      throw const FormatException('Invalid raw video dimensions');
    }
    final (:layout, :order, :depth, :sx, :sy, :endian, :msb) = spec;
    final rgb =
        layout == _Layout.packedRgb || order == 'gbr' || order == 'gbra';
    return RawVideoFormat._(
      width,
      height,
      layout,
      order,
      depth,
      sx,
      sy,
      endian,
      msb,
      rgb ? 0 : (matrix ?? (tag.toUpperCase() == 'HDYC' ? 1 : 2)),
      rgb || (fullRange ?? order == 'y'),
    );
  }

  final int width, height, depth, subX, subY, matrix;
  final bool fullRange;
  final _Layout _layout;
  final String _order;
  final Endian _endian;
  final bool _msb;
  bool get hasAlpha => _order.contains('a');

  RawVideoPicture decode(Uint8List bytes, {bool includeAlpha = true}) {
    final cw = (width + (1 << subX) - 1) >> subX;
    final ch = (height + (1 << subY) - 1) >> subY;
    final count = width * height, chroma = cw * ch;
    final sampleBytes = depth > 8 ? 2 : 1;
    final data = ByteData.sublistView(bytes);
    final limit = (1 << depth) - 1;
    int sample(int offset) {
      if (depth == 8) return bytes[offset];
      final word = data.getUint16(offset, _endian);
      return _msb ? word >> (16 - depth) : word & limit;
    }

    List<int> plane(int offset, int length) {
      if (depth == 8)
        return Uint8List.sublistView(bytes, offset, offset + length);
      if (_endian == Endian.host &&
          !_msb &&
          depth == 16 &&
          (bytes.offsetInBytes + offset).isEven) {
        return Uint16List.view(
          bytes.buffer,
          bytes.offsetInBytes + offset,
          length,
        );
      }
      final values = Uint16List(length);
      for (var i = 0; i < length; i++) {
        values[i] = sample(offset + i * 2);
      }
      return values;
    }

    List<int> allocate(int length) =>
        depth == 8 ? Uint8List(length) : Uint16List(length);
    void require(int size) {
      if (bytes.length != size) {
        throw FormatException(
          'Invalid raw video frame size: ${bytes.length} bytes, expected $size',
        );
      }
    }

    final List<int> y, cb, cr;
    List<int>? alpha;
    switch (_layout) {
      case _Layout.planar:
        final hasChroma = _order.length >= 3;
        require(
          (count + (hasChroma ? 2 * chroma : 0) + (hasAlpha ? count : 0)) *
              sampleBytes,
        );
        y = plane(0, count);
        final swap = _order == 'yvu';
        cb = hasChroma
            ? plane((count + (swap ? chroma : 0)) * sampleBytes, chroma)
            : const [];
        cr = hasChroma
            ? plane((count + (swap ? 0 : chroma)) * sampleBytes, chroma)
            : const [];
        if (hasAlpha && includeAlpha) {
          alpha = plane(
            (count + (hasChroma ? 2 * chroma : 0)) * sampleBytes,
            count,
          );
        }
      case _Layout.semiplanar:
        require((count + 2 * chroma) * sampleBytes);
        y = plane(0, count);
        cb = allocate(chroma);
        cr = allocate(chroma);
        final u = _order == 'uv' ? 0 : sampleBytes;
        final v = sampleBytes - u;
        for (var i = 0; i < chroma; i++) {
          final offset = (count + 2 * i) * sampleBytes;
          cb[i] = sample(offset + u);
          cr[i] = sample(offset + v);
        }
      case _Layout.packed422:
        final groups = (width + 1) >> 1;
        require(groups * height * 4 * sampleBytes);
        y = allocate(count);
        cb = allocate(chroma);
        cr = allocate(chroma);
        final u = _order.indexOf('u') * sampleBytes;
        final v = _order.indexOf('v') * sampleBytes;
        final y0 = _order.indexOf('y') * sampleBytes;
        final y1 = _order.lastIndexOf('y') * sampleBytes;
        for (var row = 0; row < height; row++) {
          for (var pair = 0; pair < groups; pair++) {
            final c = row * groups + pair;
            final offset = c * 4 * sampleBytes;
            final pixel = row * width + 2 * pair;
            cb[c] = sample(offset + u);
            cr[c] = sample(offset + v);
            y[pixel] = sample(offset + y0);
            if (2 * pair + 1 < width) y[pixel + 1] = sample(offset + y1);
          }
        }
      case _Layout.packedRgb:
        final pixelBytes = _order.length * sampleBytes;
        final rowBytes = width * pixelBytes;
        final aligned = (rowBytes + 3) & ~3;
        final stride = bytes.length == aligned * height ? aligned : rowBytes;
        require(stride * height);
        y = allocate(count);
        cb = allocate(count);
        cr = allocate(count);
        alpha = hasAlpha && includeAlpha ? allocate(count) : null;
        final green = _order.indexOf('g') * sampleBytes;
        final blue = _order.indexOf('b') * sampleBytes;
        final red = _order.indexOf('r') * sampleBytes;
        final opacity = _order.indexOf('a') * sampleBytes;
        var i = 0;
        for (var row = 0; row < height; row++) {
          for (var x = 0; x < width; x++, i++) {
            final offset = row * stride + x * pixelBytes;
            y[i] = sample(offset + green);
            cb[i] = sample(offset + blue);
            cr[i] = sample(offset + red);
            if (alpha != null) alpha[i] = sample(offset + opacity);
          }
        }
    }
    return RawVideoPicture._(this, y, cb, cr, alpha, cw);
  }
}

final class RawVideoPicture {
  const RawVideoPicture._(
    this.format,
    this._y,
    this._cb,
    this._cr,
    this._alpha,
    this._cw,
  );
  final RawVideoFormat format;
  final List<int> _y, _cb, _cr;
  final List<int>? _alpha;
  final int _cw;

  image.Image rgb({YuvImageScaler? scaler, bool includeAlpha = true}) =>
      yuvImage(
        y: _y,
        cb: _cb,
        cr: _cr,
        stride: format.width,
        chromaStride: _cw,
        width: format.width,
        height: format.height,
        cropLeft: 0,
        cropTop: 0,
        matrix: format.matrix,
        fullRange: format.fullRange,
        packedRgb: format._layout == _Layout.packedRgb && format.depth == 8,
        bgr24:
            format._layout == _Layout.packedRgb &&
            format._order == 'bgr' &&
            format.depth == 8,
        lumaDepth: format.depth,
        chromaDepth: format.depth,
        alphaDepth: format.depth,
        subsamplingX: format.subX,
        subsamplingY: format.subY,
        alpha: includeAlpha ? _alpha : null,
        scaler: scaler,
      );
}

typedef _RawLayout = ({
  _Layout layout,
  String order,
  int depth,
  int sx,
  int sy,
  Endian endian,
  bool msb,
});

_RawLayout? _layoutFor(String tag) {
  if (tag.length != 4) return null;
  _RawLayout spec(
    _Layout layout,
    String order, {
    int depth = 8,
    int sx = 0,
    int sy = 0,
    Endian endian = Endian.little,
    bool msb = false,
  }) => (
    layout: layout,
    order: order,
    depth: depth,
    sx: sx,
    sy: sy,
    endian: endian,
    msb: msb,
  );
  final upper = tag.toUpperCase();
  switch (upper) {
    case 'I420' || 'IYUV':
      return spec(_Layout.planar, 'yuv', sx: 1, sy: 1);
    case 'YV12':
      return spec(_Layout.planar, 'yvu', sx: 1, sy: 1);
    case 'YUV9' || 'I410':
      return spec(_Layout.planar, 'yuv', sx: 2, sy: 2);
    case 'YVU9':
      return spec(_Layout.planar, 'yvu', sx: 2, sy: 2);
    case '411P' || 'Y41B' || 'I411':
      return spec(_Layout.planar, 'yuv', sx: 2);
    case '422P' || 'Y42B' || 'P422' || 'I422':
      return spec(_Layout.planar, 'yuv', sx: 1);
    case 'YV16':
      return spec(_Layout.planar, 'yvu', sx: 1);
    case '440P' || 'I440':
      return spec(_Layout.planar, 'yuv', sy: 1);
    case '444P' || 'I444':
      return spec(_Layout.planar, 'yuv');
    case 'YV24':
      return spec(_Layout.planar, 'yvu');
    case 'GREY' || 'Y800' || 'Y8  ':
      return spec(_Layout.planar, 'y');
    case 'NV12':
      return spec(_Layout.semiplanar, 'uv', sx: 1, sy: 1);
    case 'NV21':
      return spec(_Layout.semiplanar, 'vu', sx: 1, sy: 1);
    case 'YUVA':
      return spec(_Layout.planar, 'yuva');
    case 'I40A':
      return spec(_Layout.planar, 'yuva', sx: 1, sy: 1);
    case 'I42A':
      return spec(_Layout.planar, 'yuva', sx: 1);
    case 'YUY2' || 'YUYV' || 'YUNV' || 'Y422' || 'V422' || 'VYUY':
      return spec(_Layout.packed422, 'yuyv', sx: 1);
    case 'YVYU':
      return spec(_Layout.packed422, 'yvyu', sx: 1);
    case 'UYVY' || 'HDYC' || 'UYNV' || 'UYNY' || '2VUY':
      return spec(_Layout.packed422, 'uyvy', sx: 1);
    case 'Y210':
      return spec(_Layout.packed422, 'yuyv', sx: 1, depth: 10, msb: true);
    case 'Y216':
      return spec(_Layout.packed422, 'yuyv', sx: 1, depth: 16);
    case 'RGBA' || 'BGRA' || 'ARGB' || 'ABGR':
      return spec(_Layout.packedRgb, upper.toLowerCase());
  }

  final little =
      tag.startsWith('Y') ||
      tag.startsWith('G') ||
      tag.startsWith('RGB') ||
      tag.startsWith('BGR');
  final canonical = little ? tag : String.fromCharCodes(tag.codeUnits.reversed);
  final endian = little ? Endian.little : Endian.big;
  final depth = canonical.codeUnitAt(3);
  if (canonical.startsWith('RGB') || canonical.startsWith('BGR')) {
    final order = canonical.substring(0, 3).toLowerCase();
    if (depth == 0 && little) return spec(_Layout.packedRgb, '${order}x');
    if (depth == 24 && little) return spec(_Layout.packedRgb, order);
    if (depth == 48)
      return spec(_Layout.packedRgb, order, depth: 16, endian: endian);
  }
  if (tag.startsWith('\x00') && (tag.endsWith('RGB') || tag.endsWith('BGR'))) {
    return spec(_Layout.packedRgb, tag.replaceFirst('\x00', 'x').toLowerCase());
  }
  if (!const {8, 9, 10, 12, 14, 16}.contains(depth)) return null;
  final sampling = canonical.codeUnitAt(2);
  switch (canonical.substring(0, 2)) {
    case 'Y1' when sampling == 0:
      return spec(_Layout.planar, 'y', depth: depth, endian: endian);
    case 'G3' || 'G4' when sampling == 0:
      return spec(
        _Layout.planar,
        canonical[1] == '4' ? 'gbra' : 'gbr',
        depth: depth,
        endian: endian,
      );
    case 'Y3' || 'Y4' when const {0, 10, 11}.contains(sampling):
      return spec(
        _Layout.planar,
        canonical[1] == '4' ? 'yuva' : 'yuv',
        depth: depth,
        sx: sampling == 0 ? 0 : 1,
        sy: sampling == 11 ? 1 : 0,
        endian: endian,
      );
    default:
      return null;
  }
}
