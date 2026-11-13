import 'dart:typed_data';

import 'package:image/image.dart' as image;

import 'rgb555.dart';

/// A sync flag from the container can also appear on a dependent RPZA frame.
bool isRpzaKeyframe(Uint8List sample, int blockCount) {
  final chunk = _RpzaChunk(sample, blockCount);
  while (chunk.next()) {
    if (chunk.mode == _RpzaMode.skip) return false;
  }
  return chunk.block == blockCount;
}

/// Apple Video stores RGB555 in 4-by-4 blocks and reuses skipped blocks.
final class QuickTimeRpzaDecoder {
  factory QuickTimeRpzaDecoder(Uint8List description) {
    if (description.length < 28) {
      throw const FormatException('Truncated RPZA sample description');
    }
    final entry = ByteData.sublistView(description);
    final width = entry.getUint16(24), height = entry.getUint16(26);
    if (width == 0 || height == 0 || width * height > 36 * 1024 * 1024) {
      throw const FormatException('Invalid RPZA picture dimensions');
    }
    return QuickTimeRpzaDecoder._(width, height);
  }

  QuickTimeRpzaDecoder._(this.width, this.height);

  final int width, height;
  late final int _columns = (width + 3) ~/ 4;
  late final int _stride = _columns * 4;
  late final int blockCount = _columns * ((height + 3) ~/ 4);
  late final _pixels = Uint16List(blockCount * 16);
  bool _ready = false;

  void advance(Uint8List sample) {
    final chunk = _RpzaChunk(sample, blockCount);
    while (chunk.next()) {
      final start = chunk.block - chunk.count;
      switch (chunk.mode) {
        case _RpzaMode.skip:
          if (!_ready)
            throw const FormatException('Missing RPZA reference frame');
        case _RpzaMode.solid:
          final color = chunk.word(chunk.payload);
          for (var block = start; block < chunk.block; block++) {
            var offset = _offset(block);
            for (var y = 0; y < 4; y++, offset += _stride) {
              _pixels.fillRange(offset, offset + 4, color);
            }
          }
        case _RpzaMode.palette || _RpzaMode.inlinePalette:
          final a = chunk.word(chunk.payload);
          final b = chunk.word(chunk.payload + 2);
          final colors = [b, _blend(b, a), _blend(a, b), a];
          var indices = chunk.payload + 4;
          for (var block = start; block < chunk.block; block++) {
            var offset = _offset(block);
            for (var y = 0; y < 4; y++, offset += _stride) {
              final row = sample[indices++];
              for (var x = 0; x < 4; x++) {
                _pixels[offset + x] = colors[(row >> (6 - 2 * x)) & 3];
              }
            }
          }
        case _RpzaMode.literal:
          var source = chunk.payload;
          var offset = _offset(start);
          for (var y = 0; y < 4; y++, offset += _stride) {
            for (var x = 0; x < 4; x++, source += 2) {
              _pixels[offset + x] = chunk.word(source);
            }
          }
      }
    }
    if (!_ready && chunk.block != blockCount) {
      throw const FormatException('Incomplete RPZA keyframe');
    }
    _ready = true;
  }

  int _offset(int block) =>
      (block ~/ _columns) * 4 * _stride + (block % _columns) * 4;

  image.Image rgb() {
    if (!_ready) throw const FormatException('Missing RPZA reference frame');
    final frame = image.Image(width: width, height: height);
    for (final pixel in frame) {
      setRgb555(pixel, _pixels[pixel.y * _stride + pixel.x]);
    }
    return frame;
  }
}

int _blend(int main, int other) {
  var color = 0;
  for (final shift in [0, 5, 10]) {
    final a = (main >> shift) & 31;
    final b = (other >> shift) & 31;
    color |= ((21 * a + 11 * b) >> 5) << shift;
  }
  return color;
}

enum _RpzaMode { skip, solid, palette, inlinePalette, literal }

final class _RpzaChunk {
  _RpzaChunk(this.bytes, this.blocks) : data = ByteData.sublistView(bytes) {
    if (bytes.length < 4 || bytes[0] != 0xe1) {
      throw const FormatException('Invalid RPZA chunk header');
    }
    end = data.getUint32(0) & 0xffffff;
    if (end < 4 || end > bytes.length) {
      throw const FormatException('Invalid RPZA chunk size');
    }
  }

  final Uint8List bytes;
  final ByteData data;
  final int blocks;
  late final int end;
  var _offset = 4, block = 0, count = 0, payload = 0;
  late _RpzaMode mode;

  int word(int offset) => data.getUint16(offset);

  bool next() {
    if (_offset == end) return false;
    final opcode = bytes[_offset];
    if (opcode < 128) {
      if (end - _offset < 3) {
        throw const FormatException('Truncated RPZA block');
      }
      // An unflagged first color followed by a flagged second color is
      // a one-block palette. Otherwise all sixteen colors are literal.
      mode = bytes[_offset + 2] & 128 != 0
          ? _RpzaMode.inlinePalette
          : _RpzaMode.literal;
      count = 1;
      payload = _offset;
    } else {
      mode = switch (opcode >> 5) {
        4 => _RpzaMode.skip,
        5 => _RpzaMode.solid,
        6 => _RpzaMode.palette,
        _ => throw const FormatException('Invalid RPZA opcode'),
      };
      count = (opcode & 31) + 1;
      payload = _offset + 1;
    }
    _offset =
        payload +
        switch (mode) {
          _RpzaMode.skip => 0,
          _RpzaMode.solid => 2,
          _RpzaMode.palette || _RpzaMode.inlinePalette => 4 + count * 4,
          _RpzaMode.literal => 32,
        };
    block += count;
    if (_offset > end || block > blocks) {
      throw const FormatException('Invalid RPZA block extent');
    }
    return true;
  }
}
