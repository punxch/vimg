import 'dart:typed_data';

import 'package:image/image.dart' as image;

final class MsRleFormat {
  MsRleFormat(this.width, this.height, this.bits, {required this.topDown}) {
    if (width <= 0 || height <= 0 || width * height > 36 * 1024 * 1024) {
      throw const FormatException('Invalid Microsoft RLE picture dimensions');
    }
    if (bits != 4 && bits != 8) {
      throw const FormatException('Invalid Microsoft RLE bit depth');
    }
  }

  final int width, height, bits;
  final bool topDown;
  late final int bitmapStride = ((width * bits + 31) ~/ 32) * 4;
  int get bitmapSize => bitmapStride * height;

  bool isComplete(Uint8List bytes) => _readRuns(bytes) == width * height;

  int _readRuns(Uint8List bytes, [Uint8List? pixels]) {
    var offset = 0, x = 0, row = 0, written = 0;
    final packed = bits == 4;
    while (offset + 2 <= bytes.length) {
      final count = bytes[offset++];
      final command = bytes[offset++];
      if (count == 0) {
        if (command == 1) return written;
        if (command == 0) {
          if (row == height) {
            throw const FormatException('Invalid Microsoft RLE end of line');
          }
          row++;
          x = 0;
          continue;
        }
        if (command == 2) {
          if (offset + 2 > bytes.length) {
            throw const FormatException('Truncated Microsoft RLE delta');
          }
          x += bytes[offset++];
          row += bytes[offset++];
          if (x > width || row >= height) {
            throw const FormatException('Invalid Microsoft RLE delta');
          }
          continue;
        }
      }
      var length = count == 0 ? command : count;
      // Some RLE4 encoders round the last encoded run to a full byte.
      if (packed && count != 0 && width.isOdd && x + length == width + 1) {
        length--;
      }
      if (row >= height || length > width - x) {
        throw const FormatException(
          'Microsoft RLE run crosses the picture edge',
        );
      }
      final start = row * width + x;
      if (count == 0) {
        final used = packed ? (length + 1) ~/ 2 : length;
        final end = offset + used + (used & 1);
        if (end > bytes.length) {
          throw const FormatException('Truncated Microsoft RLE absolute run');
        }
        if (pixels != null) {
          if (packed) {
            for (var i = 0; i < length; i++) {
              pixels[start + i] = _nibble(bytes[offset + (i >> 1)], i);
            }
          } else {
            pixels.setRange(start, start + length, bytes, offset);
          }
        }
        offset = end;
      } else if (pixels != null) {
        if (packed) {
          for (var i = 0; i < length; i++) {
            pixels[start + i] = _nibble(command, i);
          }
        } else {
          pixels.fillRange(start, start + length, command);
        }
      }
      written += length;
      x += length;
    }
    // Some encoders finish at the last row without the end-of-bitmap escape.
    if (offset == bytes.length &&
        (row == height || (row == height - 1 && x == width))) {
      return written;
    }
    throw const FormatException('Truncated Microsoft RLE picture');
  }

  static int _nibble(int byte, int i) => i.isEven ? byte >> 4 : byte & 15;
}

final class MsRleDecoder {
  MsRleDecoder(this.format);

  final MsRleFormat format;
  late final _indices = Uint8List(format.width * format.height);

  void advance(Uint8List bytes, {required bool raw}) {
    if (!raw) {
      format._readRuns(bytes, _indices);
      return;
    }
    if (bytes.length != format.bitmapSize) {
      throw const FormatException('Invalid Microsoft RLE bitmap size');
    }
    final width = format.width, height = format.height, bits = format.bits;
    final bitmapStride = format.bitmapStride;
    for (var row = 0; row < height; row++) {
      final input = row * bitmapStride, output = row * width;
      if (bits == 8) {
        _indices.setRange(output, output + width, bytes, input);
      } else {
        for (var x = 0; x < width; x++) {
          _indices[output + x] = MsRleFormat._nibble(
            bytes[input + (x >> 1)],
            x,
          );
        }
      }
    }
  }

  image.Image rgb(List<int> palette) {
    final width = format.width, height = format.height;
    final frame = image.Image(width: width, height: height);
    for (final pixel in frame) {
      final row = format.topDown ? pixel.y : height - 1 - pixel.y;
      final color = palette[_indices[row * width + pixel.x]];
      pixel.setRgb(color >> 16, color >> 8 & 255, color & 255);
    }
    return frame;
  }
}
