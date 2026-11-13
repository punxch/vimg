import 'dart:typed_data';

import 'package:image/image.dart' as image;

import 'rgb555.dart';

final class MsVideo1Format {
  MsVideo1Format(this.width, this.height, int bits) : indexed = bits == 8 {
    if (width <= 0 ||
        height <= 0 ||
        (width | height) & 3 != 0 ||
        width * height > 36 * 1024 * 1024) {
      throw const FormatException('Invalid Microsoft Video 1 dimensions');
    }
    if (bits != 8 && bits != 15 && bits != 16) {
      throw const FormatException('Invalid Microsoft Video 1 bit depth');
    }
  }

  final int width, height;
  final bool indexed;
  int get _columns => width ~/ 4;

  bool isComplete(Uint8List bytes) => _readBlocks(bytes);

  bool _readBlocks(Uint8List bytes, [Uint16List? pixels]) {
    final data = ByteData.sublistView(bytes);
    final blocks = _columns * (height ~/ 4);
    final bytesPerColor = indexed ? 1 : 2;
    var offset = 0, block = 0;
    var complete = true;
    while (block < blocks) {
      if (offset + 2 > bytes.length) {
        throw const FormatException('Truncated Microsoft Video 1 block');
      }
      final code = data.getUint16(offset, Endian.little);
      offset += 2;
      if (code & 0xfc00 == 0x8400) {
        final count = code & 0x03ff;
        if (count > blocks - block) {
          throw const FormatException(
            'Microsoft Video 1 skip crosses the picture edge',
          );
        }
        if (count > 0) complete = false;
        block += count;
        continue;
      }

      var colors = 0;
      if (code < 0x8000) {
        if (offset + 2 * bytesPerColor > bytes.length) {
          throw const FormatException('Truncated Microsoft Video 1 colors');
        }
        colors = !indexed && data.getUint16(offset, Endian.little) & 0x8000 != 0
            ? 8
            : 2;
      } else if (indexed && code >= 0x9000) {
        colors = 8;
      }
      final end = offset + colors * bytesPerColor;
      if (end > bytes.length) {
        throw const FormatException('Truncated Microsoft Video 1 colors');
      }
      if (pixels != null) {
        final x = (block % _columns) * 4;
        final y = height - 1 - (block ~/ _columns) * 4;
        if (colors == 0) {
          final color = code & (indexed ? 0xff : 0x7fff);
          for (var row = 0; row < 4; row++) {
            final start = (y - row) * width + x;
            pixels.fillRange(start, start + 4, color);
          }
        } else {
          _paintBlock(pixels, data, x, y, code, colors, offset);
        }
      }
      offset = end;
      block++;
    }
    // The block count determines the end of the picture. Encoders can append
    // a zero word or alignment bytes.
    return complete;
  }

  void _paintBlock(
    Uint16List pixels,
    ByteData data,
    int x,
    int y,
    int flags,
    int colors,
    int offset,
  ) {
    for (var row = 0; row < 4; row++) {
      final start = (y - row) * width + x;
      for (var col = 0; col < 4; col++) {
        final pair = colors == 8 ? (row & 2) * 2 + (col & 2) : 0;
        final color = pair + (1 - (flags & 1));
        pixels[start + col] = indexed
            ? data.getUint8(offset + color)
            : data.getUint16(offset + 2 * color, Endian.little) & 0x7fff;
        flags >>= 1;
      }
    }
  }
}

final class MsVideo1Decoder {
  MsVideo1Decoder(this.format);

  final MsVideo1Format format;
  late final _pixels = Uint16List(format.width * format.height);

  void advance(Uint8List bytes) => format._readBlocks(bytes, _pixels);

  image.Image rgb(List<int>? palette) {
    final width = format.width, height = format.height;
    final frame = image.Image(width: width, height: height);
    if (format.indexed) {
      if (palette == null) {
        throw const FormatException('Missing Microsoft Video 1 palette');
      }
      for (final pixel in frame) {
        final color = palette[_pixels[pixel.y * width + pixel.x]];
        pixel.setRgb(color >> 16, color >> 8 & 255, color & 255);
      }
    } else {
      for (final pixel in frame) {
        setRgb555(pixel, _pixels[pixel.y * width + pixel.x]);
      }
    }
    return frame;
  }
}
