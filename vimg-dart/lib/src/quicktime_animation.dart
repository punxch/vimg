import 'dart:typed_data';

import 'package:image/image.dart' as image;

import 'quicktime_palette.dart';
import 'rgb555.dart';

/// QuickTime Animation keeps the unchanged parts of the last decoded frame.
final class QuickTimeAnimationDecoder {
  factory QuickTimeAnimationDecoder(Uint8List description) {
    if (description.length < 78) {
      throw const FormatException('Truncated QuickTime Animation description');
    }
    final header = ByteData.sublistView(description);
    final width = header.getUint16(24);
    final height = header.getUint16(26);
    final codedDepth = header.getUint16(74);
    final depth = codedDepth == 32 ? 32 : codedDepth & 31;
    if (width == 0 || height == 0 || width * height > 36 * 1024 * 1024) {
      throw const FormatException('Invalid QuickTime Animation dimensions');
    }
    if (!const [1, 2, 4, 8, 16, 24, 32].contains(depth) ||
        (codedDepth != depth && (codedDepth != depth + 32 || depth > 8))) {
      throw UnsupportedError(
        'Unsupported QuickTime Animation depth $codedDepth',
      );
    }
    final palette = depth <= 8
        ? quickTimePalette(header, codedDepth, depth)
        : null;
    return QuickTimeAnimationDecoder._(width, height, depth, palette);
  }

  QuickTimeAnimationDecoder._(
    this.width,
    this.height,
    this.depth,
    this._colors,
  );

  final int width, height, depth;
  final List<int>? _colors;
  late final int _unitPixels = depth == 1
      ? 16
      : depth <= 8
      ? 32 ~/ depth
      : 1;
  late final int _unitBytes = depth == 1
      ? 2
      : depth <= 8
      ? 4
      : depth ~/ 8;
  late final int _unitsPerRow = (width + _unitPixels - 1) ~/ _unitPixels;
  late final int _stride = _unitsPerRow * _unitBytes;
  late final Uint8List _pixels = Uint8List(_stride * height);
  bool _ready = false;

  void advance(Uint8List sample) {
    // Animation encoders emit a short chunk for an unchanged frame.
    if (sample.length < 8) {
      if (!_ready)
        throw const FormatException(
          'Missing QuickTime Animation reference frame',
        );
      return;
    }
    final data = ByteData.sublistView(sample);
    final size = data.getUint32(0) & 0x3fffffff;
    if (size < 8 || size > sample.length) {
      throw const FormatException('Invalid QuickTime Animation chunk size');
    }
    final partial = data.getUint16(4) & 8 != 0;
    if (partial && size < 14) {
      throw const FormatException('Truncated QuickTime Animation row header');
    }
    final first = partial ? data.getUint16(6) : 0;
    final rows = partial ? data.getUint16(10) : height;
    if (first + rows > height || (!_ready && (first != 0 || rows != height))) {
      throw const FormatException('Invalid QuickTime Animation row range');
    }
    final reader = _AnimationChunk(sample, partial ? 14 : 6, size);
    if (depth == 1) {
      _monochrome(reader, first, rows);
    } else {
      for (var row = first; row < first + rows; row++) {
        final initialSkip = reader.byte();
        if (initialSkip == 0) break;
        var unit = initialSkip - 1;
        while (true) {
          final code = reader.code();
          if (code == -1) break;
          if (code == 0) {
            final skip = reader.byte();
            if (skip == 0)
              throw const FormatException('Invalid QuickTime Animation skip');
            unit += skip - 1;
          } else {
            unit = _writeRun(reader, row, unit, code);
          }
        }
        if (unit < 0 || unit > _unitsPerRow) {
          throw const FormatException('Invalid QuickTime Animation row offset');
        }
      }
    }
    _ready = true;
  }

  void _monochrome(_AnimationChunk reader, int first, int rows) {
    // One-bit chunks put a skip before every run, with its high bit
    // advancing to the next row. The first such skip selects the first row.
    var row = first - 1, unit = 0;
    while (reader.hasBytes) {
      final skip = reader.byte();
      final code = reader.code();
      if (code == 0) return;
      if (skip & 128 != 0) {
        row++;
        unit = 0;
      }
      if (row < first || row >= first + rows) {
        throw const FormatException('Invalid monochrome Animation row');
      }
      unit += skip & 127;
      if (unit > _unitsPerRow) {
        throw const FormatException('Invalid QuickTime Animation row offset');
      }
      if (code != -1) unit = _writeRun(reader, row, unit, code);
    }
  }

  int _writeRun(_AnimationChunk reader, int row, int unit, int code) {
    final count = code.abs();
    if (unit < 0 || unit + count > _unitsPerRow) {
      throw const FormatException('QuickTime Animation run exceeds its row');
    }
    var offset = row * _stride + unit * _unitBytes;
    final length = count * _unitBytes;
    final data = reader.take(code > 0 ? length : _unitBytes);
    if (code > 0) {
      _pixels.setRange(offset, offset + length, data);
    } else {
      for (var i = 0; i < count; i++) {
        _pixels.setRange(offset, offset + _unitBytes, data);
        offset += _unitBytes;
      }
    }
    return unit + count;
  }

  image.Image rgb({bool includeAlpha = true}) {
    if (!_ready) {
      throw const FormatException(
        'Missing QuickTime Animation reference frame',
      );
    }
    final alpha = depth == 32 && includeAlpha;
    final frame = image.Image(
      width: width,
      height: height,
      numChannels: alpha ? 4 : 3,
    );
    final colors = _colors;
    for (final pixel in frame) {
      final row = pixel.y * _stride;
      if (colors != null) {
        final bit = pixel.x * depth;
        final index =
            (_pixels[row + (bit >> 3)] >> (8 - depth - (bit & 7))) &
            ((1 << depth) - 1);
        final color = colors[index];
        pixel.setRgb(color >> 16, (color >> 8) & 255, color & 255);
      } else if (depth == 16) {
        final offset = row + pixel.x * 2;
        final word = _pixels[offset] << 8 | _pixels[offset + 1];
        setRgb555(pixel, word);
      } else {
        final offset = row + pixel.x * _unitBytes;
        final rgb = offset + _unitBytes - 3;
        pixel.setRgb(_pixels[rgb], _pixels[rgb + 1], _pixels[rgb + 2]);
        if (alpha) pixel.a = _pixels[offset];
      }
    }
    return frame;
  }
}

final class _AnimationChunk {
  _AnimationChunk(this.bytes, this.offset, this.end);

  final Uint8List bytes;
  final int end;
  int offset;

  bool get hasBytes => offset < end;

  int byte() {
    if (!hasBytes)
      throw const FormatException('Truncated QuickTime Animation run');
    return bytes[offset++];
  }

  int code() => byte().toSigned(8);

  Uint8List take(int length) {
    final start = offset;
    offset += length;
    if (offset > end)
      throw const FormatException('Truncated QuickTime Animation pixels');
    return Uint8List.sublistView(bytes, start, offset);
  }
}
