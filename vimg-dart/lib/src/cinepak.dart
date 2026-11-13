import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as image;

import 'quicktime_palette.dart';

/// Find seek points from the vectors a picture reads and the blocks it retains.
final class CinepakPictureOrder {
  CinepakPictureOrder(this.width, this.height);

  final int width, height;
  final _books = <Int32List>[];
  final _seekPoints = [-1];
  var _previous = -1;

  int anchor(Uint8List sample, int position) {
    var start = position;
    final complete = _readPicture(sample, width, height, (i, inherit, strip) {
      if (i == _books.length) {
        _books.add(Int32List(512)..fillRange(0, 512, -1));
      }
      final books = _books[i];
      if (inherit) books.setAll(0, _books[i - 1]);
      strip.read(
        onEntry: (slot, _, _) => books[slot] = position,
        onBlock: (_, _, indices) {
          if (indices == null) {
            start = math.min(start, _previous);
          } else {
            final base = indices.length == 1 ? 0 : 256;
            for (final index in indices) {
              start = math.min(start, books[base + index]);
            }
          }
        },
      );
    });
    if (!complete) start = math.min(start, _previous);
    if (start == position) {
      _seekPoints.add(position);
    } else {
      // A decode run visits every intervening sample. A seek point after a
      // required codebook write cannot be used for this or later pictures.
      while (_seekPoints.last > start) {
        _seekPoints.removeLast();
      }
      start = _seekPoints.last;
    }
    return _previous = start;
  }
}

final class CinepakDecoder {
  CinepakDecoder(Uint8List description) {
    if (description.length < 78) {
      throw const FormatException('Truncated Cinepak sample description');
    }
    final data = ByteData.sublistView(description);
    width = data.getUint16(24);
    height = data.getUint16(26);
    if (width == 0 || height == 0 || width * height > 36 * 1024 * 1024) {
      throw const FormatException('Invalid Cinepak picture dimensions');
    }
    final depth = data.getUint16(74);
    _palette = depth == 8 ? quickTimePalette(data, depth, 8) : null;
  }

  late final int width, height;
  late final List<int>? _palette;
  late final int _stride = (width + 3) & ~3;
  late final _pixels = Uint32List(_stride * ((height + 3) & ~3));
  final _books = <Uint32List>[];
  var _ready = false;

  void advance(Uint8List sample) {
    final complete = _readPicture(sample, width, height, (i, inherit, strip) {
      if (i == _books.length) _books.add(Uint32List(512 * 4));
      final books = _books[i];
      if (inherit) books.setAll(0, _books[i - 1]);
      strip.read(
        onEntry: (slot, bytes, color) => _define(books, slot, bytes, color),
        onBlock: (x, y, indices) => _paint(books, x, y, indices),
      );
    });
    if (!complete && !_ready) {
      throw const FormatException('Missing Cinepak reference frame');
    }
    _ready = true;
  }

  void _define(Uint32List books, int slot, Uint8List bytes, bool color) {
    final u = color ? bytes[4].toSigned(8) : 0;
    final v = color ? bytes[5].toSigned(8) : 0;
    for (var j = 0; j < 4; j++) {
      final y = bytes[j];
      books[4 * slot + j] = _palette == null
          ? (y + 2 * v).clamp(0, 255) << 16 |
                (y - u ~/ 2 - v).clamp(0, 255) << 8 |
                (y + 2 * u).clamp(0, 255)
          : _palette[y];
    }
  }

  void _paint(Uint32List books, int x, int y, Uint8List? indices) {
    if (indices == null) {
      if (!_ready)
        throw const FormatException('Missing Cinepak reference frame');
      return;
    }
    for (var q = 0; q < 4; q++) {
      final start = (y + 2 * (q >> 1)) * _stride + x + 2 * (q & 1);
      if (indices.length == 4) {
        final at = (256 + indices[q]) * 4;
        _pixels[start] = books[at];
        _pixels[start + 1] = books[at + 1];
        _pixels[start + _stride] = books[at + 2];
        _pixels[start + _stride + 1] = books[at + 3];
      } else {
        final color = books[indices[0] * 4 + q];
        _pixels[start] = _pixels[start + 1] = _pixels[start + _stride] =
            _pixels[start + _stride + 1] = color;
      }
    }
  }

  image.Image rgb() {
    if (!_ready) throw const FormatException('Missing Cinepak reference frame');
    final frame = image.Image(width: width, height: height);
    for (final pixel in frame) {
      final color = _pixels[pixel.y * _stride + pixel.x];
      pixel.setRgb(color >> 16, color >> 8 & 255, color & 255);
    }
    return frame;
  }
}

bool _readPicture(
  Uint8List sample,
  int width,
  int height,
  void Function(int index, bool inherit, _CinepakStrip strip) onStrip,
) {
  final data = _CinepakReader(sample);
  final flags = data.byte();
  final length = data.size24();
  if (length < 10 || length > sample.length) {
    throw const FormatException('Invalid Cinepak frame size');
  }
  data.end = length;
  final frameWidth = data.word(), frameHeight = data.word();
  final strips = data.word();
  final stride = (width + 3) & ~3, rows = (height + 3) & ~3;
  if (frameWidth == 0 ||
      frameHeight == 0 ||
      frameWidth > stride ||
      frameHeight > rows ||
      strips > 32) {
    throw const FormatException('Invalid Cinepak frame header');
  }
  var complete = true;
  var bottom = 0;
  for (var i = 0; i < strips; i++) {
    data.byte(); // Strip type. Vector chunks determine picture dependencies.
    final strip = data.section(data.size24(), 12);
    var top = strip.word();
    final left = strip.word();
    var end = strip.word();
    final right = strip.word();
    if (top == 0) {
      top = bottom;
      end += top;
    }
    if (top < bottom ||
        top >= end ||
        end > rows ||
        left >= right ||
        right > stride ||
        (top | left) & 3 != 0) {
      throw const FormatException('Invalid Cinepak strip coordinates');
    }
    complete &= top <= ((bottom + 3) & ~3) && left == 0 && right > stride - 4;
    onStrip(
      i,
      i > 0 && flags & 1 == 0,
      _CinepakStrip(strip, left, top, right, end),
    );
    bottom = end;
  }
  return complete && bottom > rows - 4;
}

final class _CinepakStrip {
  _CinepakStrip(this.data, this.left, this.top, this.right, this.bottom);

  final _CinepakReader data;
  final int left, top, right, bottom;

  void read({
    required void Function(int slot, Uint8List values, bool color) onEntry,
    required void Function(int x, int y, Uint8List? indices) onBlock,
  }) {
    while (data.offset < data.end) {
      final type = data.byte();
      final chunk = data.section(data.size24(), 4);
      if (type >= 0x20 && type <= 0x27) {
        final color = type & 4 == 0;
        final base = type & 2 == 0 ? 256 : 0;
        final selective = type & 1 != 0;
        for (var i = 0; i < 256 && chunk.hasEntry(selective); i++) {
          if (selective && !chunk.flag()) continue;
          onEntry(base + i, chunk.take(color ? 6 : 4), color);
        }
      } else if (type >= 0x30 && type <= 0x32) {
        final v1 = Uint8List(1), v4 = Uint8List(4);
        for (var y = top; y < bottom; y += 4) {
          for (var x = left; x < right; x += 4) {
            if (type == 0x31 && !chunk.flag()) {
              onBlock(x, y, null);
              continue;
            }
            final indices = type != 0x32 && chunk.flag() ? v4 : v1;
            for (var i = 0; i < indices.length; i++) {
              indices[i] = chunk.byte();
            }
            onBlock(x, y, indices);
          }
        }
        return;
      }
    }
    throw const FormatException('Missing Cinepak strip vectors');
  }
}

final class _CinepakReader {
  _CinepakReader(this.bytes) : end = bytes.length;
  _CinepakReader._(this.bytes, this.offset, this.end);

  final Uint8List bytes;
  int offset = 0;
  int end;
  int _flags = 0, _remaining = 0;

  bool hasEntry(bool selective) =>
      offset < end || (selective && _remaining > 0);

  void _require(int length) {
    if (length > end - offset) {
      throw const FormatException('Truncated Cinepak bitstream');
    }
  }

  int byte() {
    _require(1);
    return bytes[offset++];
  }

  int word() => byte() << 8 | byte();
  int size24() => byte() << 16 | word();

  Uint8List take(int length) {
    _require(length);
    final start = offset;
    offset += length;
    return Uint8List.sublistView(bytes, start, offset);
  }

  _CinepakReader section(int length, int minimum) {
    final limit = offset + length - 4;
    if (length < minimum || limit > end) {
      throw const FormatException('Invalid Cinepak chunk size');
    }
    final child = _CinepakReader._(bytes, offset, limit);
    offset = limit;
    return child;
  }

  bool flag() {
    if (_remaining == 0) {
      _flags = word() << 16 | word();
      _remaining = 32;
    }
    return _flags & (1 << --_remaining) != 0;
  }
}
