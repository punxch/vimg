import 'dart:typed_data';

import 'package:image/image.dart' as image;

import 'grid.dart' show resizeToFit;
import 'iso_media.dart';
import 'rgb555.dart';
import 'yuv_image.dart';

bool isQuickTimeRawCodec(String name) => name == 'rawvideo' || name == 'v210';

/// Packed RGB and component video from a QuickTime visual sample entry.
final class QuickTimeRawFormat {
  factory QuickTimeRawFormat(IsoMedia media, MediaBox entry) {
    final (width, height, rgbDepth) = _dimensions(media, entry);
    final (matrix, fullRange) = _color(media, entry);
    return QuickTimeRawFormat._(
      entry.type,
      width,
      height,
      rgbDepth,
      matrix,
      fullRange,
      _aspect(media, entry),
      _splitFields(media, entry),
      _componentDepth(media, entry),
    );
  }

  const QuickTimeRawFormat._(
    this.tag,
    this.width,
    this.height,
    this.rgbDepth,
    this.matrix,
    this.fullRange,
    this.sampleAspect,
    this.fieldOrder,
    this.componentDepth,
  );

  final String tag;
  final int width, height, rgbDepth, matrix, fieldOrder, componentDepth;
  final bool fullRange;
  final double sampleAspect;
  bool get hasAlpha => tag == 'v408' || (tag == 'raw ' && rgbDepth == 32);

  static (int, int, int) _dimensions(IsoMedia media, MediaBox entry) {
    media.requireBytes(entry, 78);
    final width = media.file.unsigned(entry.data + 24, 2);
    final height = media.file.unsigned(entry.data + 26, 2);
    if (width == 0 || height == 0 || width * height > 36 * 1024 * 1024) {
      throw const FormatException('Invalid uncompressed QuickTime dimensions');
    }
    return (width, height, media.file.unsigned(entry.data + 74, 2));
  }

  static (int, bool) _color(IsoMedia media, MediaBox entry) {
    final color = media.visualExtension(entry, 'colr');
    if (color != null && color.end - color.data >= 4) {
      final type = media.tag(color.data);
      if (type == 'nclc' || type == 'nclx') {
        media.requireBytes(color, type == 'nclx' ? 11 : 10);
        final matrix = media.file.unsigned(color.data + 8, 2);
        final full =
            type == 'nclx' &&
            media.file.unsigned(color.data + 10, 1) & 128 != 0;
        return (matrix == 0 ? 2 : matrix, full || entry.type == 'yuv2');
      }
    }
    return (2, entry.type == 'yuv2');
  }

  static double _aspect(IsoMedia media, MediaBox entry) {
    final aspect = media.visualExtension(entry, 'pasp');
    if (aspect == null) return 1;
    media.requireBytes(aspect, 8);
    final h = media.file.unsigned(aspect.data, 4);
    final v = media.file.unsigned(aspect.data + 4, 4);
    return h == 0 || v == 0 ? 1 : h / v;
  }

  static int _splitFields(IsoMedia media, MediaBox entry) {
    final fields = media.visualExtension(entry, 'fiel');
    if (fields == null) return 0;
    media.requireBytes(fields, 2);
    if (media.file.unsigned(fields.data, 1) != 2) return 0;
    return switch (media.file.unsigned(fields.data + 1, 1)) {
      1 => 1,
      6 => 2,
      _ => 0, // woven fields are already in spatial order
    };
  }

  static int _componentDepth(IsoMedia media, MediaBox entry) {
    switch (entry.type) {
      case 'v210' || 'v410':
        return 10;
      case 'v216':
        final bits = media.visualExtension(entry, 'sgbt');
        if (bits == null) return 16;
        media.requireBytes(bits, 1);
        final depth = media.file.unsigned(bits.data, 1);
        if (depth != 10 && depth != 12 && depth != 14 && depth != 16) {
          throw const FormatException('Invalid v216 component depth');
        }
        return depth;
      default:
        return 8;
    }
  }

  int _storedRow(int row) => switch (fieldOrder) {
    1 => (row >> 1) + (row.isOdd ? (height + 1) ~/ 2 : 0),
    2 => (row >> 1) + (row.isEven ? height ~/ 2 : 0),
    _ => row,
  };

  int _stride(Uint8List bytes, List<int> rowSizes) {
    for (final size in rowSizes) {
      if (bytes.length == height * size) return size;
    }
    throw FormatException('Invalid $tag QuickTime sample size');
  }

  image.Image decode(
    Uint8List bytes, {
    YuvImageScaler? scaler,
    bool includeAlpha = false,
  }) {
    if (tag == 'raw ') {
      return _decodeRgb(bytes, scaler: scaler, includeAlpha: includeAlpha);
    }
    final picture = components(bytes, includeAlpha: includeAlpha);
    return picture.rgb(scaler: scaler);
  }

  QuickTimeComponents components(Uint8List bytes, {bool includeAlpha = false}) {
    final subsampled = const {
      '2vuy',
      '2vuY',
      'yuv2',
      'v210',
      'v216',
    }.contains(tag);
    final chromaWidth = subsampled ? (width + 1) ~/ 2 : width;
    final rowSizes = switch (tag) {
      '2vuy' || '2vuY' || 'yuv2' => [chromaWidth * 4],
      'v216' => [chromaWidth * 8],
      'v308' => [width * 3],
      'v408' || 'v410' => [width * 4],
      'v210' => [
        for (final align in [48, 24, 12, 6])
          (width + align - 1) ~/ align * (align * 8 ~/ 3),
      ],
      _ => throw UnsupportedError('Unsupported QuickTime pixel format $tag'),
    };
    final stride = _stride(bytes, rowSizes);
    final depth = componentDepth;
    final luma = depth == 8
        ? Uint8List(width * height)
        : Uint16List(width * height);
    final cb = depth == 8
        ? Uint8List(chromaWidth * height)
        : Uint16List(chromaWidth * height);
    final cr = depth == 8 ? Uint8List(cb.length) : Uint16List(cb.length);
    final alpha = includeAlpha && tag == 'v408' ? Uint8List(luma.length) : null;
    final words = ByteData.sublistView(bytes);
    final shift = 16 - depth;
    for (var row = 0; row < height; row++) {
      var source = _storedRow(row) * stride;
      final yStart = row * width, cStart = row * chromaWidth;
      if (tag == 'v210') {
        _v210(words, source, luma, cb, cr, yStart, cStart);
        continue;
      }
      if (subsampled) {
        for (var x = 0; x < width; x += 2) {
          final c = cStart + (x >> 1);
          final y = yStart + x;
          switch (tag) {
            case 'v216':
              cb[c] = words.getUint16(source, Endian.little) >> shift;
              luma[y] = words.getUint16(source + 2, Endian.little) >> shift;
              cr[c] = words.getUint16(source + 4, Endian.little) >> shift;
              if (x + 1 < width)
                luma[y + 1] =
                    words.getUint16(source + 6, Endian.little) >> shift;
              source += 8;
            case 'yuv2':
              luma[y] = bytes[source];
              cb[c] = bytes[source + 1] ^ 128;
              cr[c] = bytes[source + 3] ^ 128;
              if (x + 1 < width) luma[y + 1] = bytes[source + 2];
              source += 4;
            default:
              cb[c] = bytes[source];
              luma[y] = bytes[source + 1];
              cr[c] = bytes[source + 2];
              if (x + 1 < width) luma[y + 1] = bytes[source + 3];
              source += 4;
          }
        }
      } else {
        for (var x = yStart; x < yStart + width; x++) {
          switch (tag) {
            case 'v308':
              cr[x] = bytes[source++];
              luma[x] = bytes[source++];
              cb[x] = bytes[source++];
            case 'v408':
              cb[x] = bytes[source++];
              luma[x] = bytes[source++];
              cr[x] = bytes[source++];
              final value = bytes[source++];
              alpha?[x] = ((value - 16) * 255 / 219).round().clamp(0, 255);
            case 'v410':
              final word = words.getUint32(source, Endian.little);
              cb[x] = (word >> 2) & 1023;
              luma[x] = (word >> 12) & 1023;
              cr[x] = word >> 22;
              source += 4;
          }
        }
      }
    }
    return QuickTimeComponents._(
      this,
      luma,
      cb,
      cr,
      alpha,
      chromaWidth,
      subsampled,
    );
  }

  void _v210(
    ByteData words,
    int source,
    List<int> y,
    List<int> cb,
    List<int> cr,
    int luma,
    int chroma,
  ) {
    // The twelve components in each four-word block form three Cb-Y-Cr-Y pairs.
    final components = ((width + 1) ~/ 2) * 4;
    var word = 0;
    for (var component = 0; component < components; component++) {
      if (component % 3 == 0) {
        word = words.getUint32(source, Endian.little);
        source += 4;
      }
      final value = word & 1023;
      word >>= 10;
      switch (component & 3) {
        case 0:
          cb[chroma + (component >> 2)] = value;
        case 2:
          cr[chroma + (component >> 2)] = value;
        default:
          final x = component >> 1;
          if (x < width) y[luma + x] = value;
      }
    }
  }

  image.Image _decodeRgb(
    Uint8List bytes, {
    required YuvImageScaler? scaler,
    required bool includeAlpha,
  }) {
    final step = switch (rgbDepth) {
      16 => 2,
      24 => 3,
      32 => 4,
      _ => throw UnsupportedError('Unsupported QuickTime RGB depth $rgbDepth'),
    };
    final stride = _stride(bytes, [width * step, (width * step + 3) & ~3]);
    final words = ByteData.sublistView(bytes);
    final keepAlpha = includeAlpha && step == 4;
    final frame = image.Image(
      width: width,
      height: height,
      numChannels: keepAlpha ? 4 : 3,
    );
    for (final pixel in frame) {
      final offset = _storedRow(pixel.y) * stride + pixel.x * step;
      if (step == 2) {
        final word = words.getUint16(offset);
        setRgb555(pixel, word);
      } else {
        final rgb = offset + step - 3;
        pixel.setRgb(bytes[rgb], bytes[rgb + 1], bytes[rgb + 2]);
        if (keepAlpha) pixel.a = bytes[offset];
      }
    }
    return scaler?.filters != null
        ? scaler!.filterRgb(frame, sampleAspect: sampleAspect)
        : resizeToFit(frame, width: scaler?.width, height: scaler?.height);
  }
}

final class QuickTimeComponents {
  const QuickTimeComponents._(
    this.format,
    this.y,
    this.cb,
    this.cr,
    this.alpha,
    this._chromaWidth,
    this._subsampled,
  );

  final QuickTimeRawFormat format;
  final List<int> y, cb, cr;
  final Uint8List? alpha;
  final int _chromaWidth;
  final bool _subsampled;

  image.Image rgb({YuvImageScaler? scaler, bool includeAlpha = true}) =>
      yuvImage(
        y: y,
        cb: cb,
        cr: cr,
        stride: format.width,
        chromaStride: _chromaWidth,
        width: format.width,
        height: format.height,
        cropLeft: 0,
        cropTop: 0,
        matrix: format.matrix,
        fullRange: format.fullRange,
        lumaDepth: format.componentDepth,
        chromaDepth: format.componentDepth,
        subsamplingX: _subsampled ? 1 : 0,
        subsamplingY: 0,
        alpha: includeAlpha ? alpha : null,
        sampleAspect: format.sampleAspect,
        scaler: scaler,
      );
}
