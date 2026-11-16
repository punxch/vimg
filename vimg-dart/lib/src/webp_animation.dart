import 'dart:typed_data';

import 'package:image/image.dart' as image;

/// Builds an animation from opaque, full-canvas VP8 frames. Only compressed
/// frames are kept after encoding, and repeated grids reuse the VP8 chunk.
final class WebpAnimationEncoder {
  WebpAnimationEncoder(this.width, this.height, {required int quality})
    : _encoder = image.WebPEncoder(
        lossless: false,
        quality: quality,
        method: 1,
      );

  final int width, height;
  final image.WebPEncoder _encoder;
  late final _bytes = BytesBuilder(copy: false)..add(_animationHeader());
  Uint8List? _previous;

  void addFrame(image.Image grid, int durationMs) {
    if (grid.width != width || grid.height != height || grid.hasAlpha) {
      throw const FormatException(
        'WebP animation requires opaque canvas frames',
      );
    }
    final riff = _encoder.encode(grid, singleFrame: true);
    if (riff.length < 20 || String.fromCharCodes(riff, 12, 16) != 'VP8 ') {
      throw const FormatException('Expected a single VP8 frame');
    }
    _previous = Uint8List.sublistView(riff, 12);
    repeatFrame(durationMs);
  }

  void repeatFrame(int durationMs) {
    final frame = _previous;
    if (frame == null || durationMs < 0 || durationMs > 0xffffff) {
      throw const FormatException('Invalid WebP animation frame');
    }
    final header = _header('ANMF', 16 + frame.length, extra: 16);
    // The frame covers the whole canvas at (0, 0).
    _uint24(header, 14, width - 1);
    _uint24(header, 17, height - 1);
    _uint24(header, 20, durationMs);
    header[23] = 3; // Replace the canvas and dispose to the background.
    _bytes
      ..add(header)
      ..add(frame);
  }

  Uint8List finish() {
    final size = _bytes.length - 8;
    if (_previous == null || size > 0xfffffffe) {
      throw const FormatException('Invalid WebP animation size');
    }
    final bytes = _bytes.takeBytes();
    ByteData.sublistView(bytes).setUint32(4, size, Endian.little);
    _previous = null;
    return bytes;
  }

  Uint8List _animationHeader() {
    final extended = _header('VP8X', 10, extra: 10)..[8] = 2;
    _uint24(extended, 12, width - 1);
    _uint24(extended, 15, height - 1);
    // An all-zero ANIM payload means a transparent background and infinite
    // looping. Full-canvas opaque frames cover the background completely.
    return (BytesBuilder(copy: false)
          ..add(_header('RIFF', 0))
          ..add('WEBP'.codeUnits)
          ..add(extended)
          ..add(_header('ANIM', 6, extra: 6)))
        .takeBytes();
  }
}

Uint8List _header(String tag, int size, {int extra = 0}) {
  final bytes = Uint8List(8 + extra)..setRange(0, 4, tag.codeUnits);
  ByteData.sublistView(bytes).setUint32(4, size, Endian.little);
  return bytes;
}

void _uint24(Uint8List bytes, int offset, int value) {
  bytes[offset] = value & 255;
  bytes[offset + 1] = (value >> 8) & 255;
  bytes[offset + 2] = (value >> 16) & 255;
}
