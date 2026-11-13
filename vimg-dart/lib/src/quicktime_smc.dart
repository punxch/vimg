import 'dart:typed_data';

import 'package:image/image.dart' as image;

import 'quicktime_palette.dart';

/// Index reference blocks and palette writes without reconstructing pixels.
final class SmcPictureOrder {
  SmcPictureOrder(this.blockCount);

  final int blockCount;
  final _paletteAnchors = Int32List(3 * 256)..fillRange(0, 3 * 256, -1);
  final _seekPoints = [-1];
  var _previous = -1;

  int anchor(Uint8List sample, int position) {
    final chunk = _SmcChunk(sample, blockCount);
    var start = position;
    final writes = <int>{};
    while (chunk.next()) {
      if (chunk.mode < 2) {
        if (_previous < start) start = _previous;
      } else if (chunk.mode >= 8 && chunk.mode < 14) {
        final slot = chunk.paletteSlot;
        if (chunk.definesColors) {
          writes.add(slot);
        } else if (chunk.usesPreviousFrame && _paletteAnchors[slot] < start) {
          start = _paletteAnchors[slot];
        }
      }
    }
    if (start == position) {
      _seekPoints.add(position);
    } else {
      // A run also decodes the samples between the anchor and the target.
      // Discard anchors that would omit dependencies of those samples.
      while (_seekPoints.last > start) {
        _seekPoints.removeLast();
      }
      start = _seekPoints.last;
    }
    for (final slot in writes) {
      _paletteAnchors[slot] = start;
    }
    return _previous = start;
  }
}

/// QuickTime Graphics stores one palette index per pixel in 4-by-4 blocks.
final class QuickTimeSmcDecoder {
  factory QuickTimeSmcDecoder(Uint8List description) {
    if (description.length < 78) {
      throw const FormatException('Truncated SMC sample description');
    }
    final data = ByteData.sublistView(description);
    final width = data.getUint16(24), height = data.getUint16(26);
    if (width == 0 || height == 0 || width * height > 36 * 1024 * 1024) {
      throw const FormatException('Invalid SMC picture dimensions');
    }
    final depth = data.getUint16(74);
    if (depth != 8 && depth != 40) {
      throw UnsupportedError('Unsupported QuickTime Graphics depth $depth');
    }
    return QuickTimeSmcDecoder._(
      width,
      height,
      quickTimePalette(data, depth, 8),
    );
  }

  QuickTimeSmcDecoder._(this.width, this.height, this._colors);

  final int width, height;
  final List<int> _colors;
  late final int _columns = (width + 3) ~/ 4;
  late final int blockCount = _columns * ((height + 3) ~/ 4);
  late final _pixels = Uint8List(blockCount * 16);
  final _tables = [Uint8List(256 * 2), Uint8List(256 * 4), Uint8List(256 * 8)];
  final _available = Uint8List(3 * 256);
  bool _ready = false;

  void advance(Uint8List sample) {
    final chunk = _SmcChunk(sample, blockCount);
    while (chunk.next()) {
      if (!_ready && chunk.usesPreviousFrame) {
        throw const FormatException('Missing SMC reference frame');
      }
      final start = chunk.block * 16, end = (chunk.block + chunk.count) * 16;
      switch (chunk.mode) {
        case 0 || 1:
          break;
        case 2 || 3 || 4 || 5:
          final distance = chunk.mode < 4 ? 16 : 32;
          for (var offset = start; offset < end; offset += 16) {
            _pixels.setRange(offset, offset + 16, _pixels, offset - distance);
          }
        case 6 || 7:
          _pixels.fillRange(start, end, sample[chunk.payload]);
        case 14 || 15:
          _pixels.setRange(start, end, sample, chunk.payload);
        default:
          final bits = chunk.indexBits;
          final table = _tables[bits - 1];
          final colors = 1 << bits;
          final base = chunk.tableIndex * colors;
          final slot = chunk.paletteSlot;
          if (chunk.definesColors) {
            table.setRange(base, base + colors, sample, chunk.payload);
            _available[slot] = 1;
          } else if (_available[slot] == 0) {
            throw const FormatException('Missing SMC block palette');
          }
          var flags = chunk.payload + (chunk.definesColors ? colors : 1);
          for (var offset = start; offset < end; offset += 16) {
            final indices = chunk.readIndices(flags);
            flags += 2 * bits;
            for (var i = 0; i < 16; i++) {
              _pixels[offset + i] =
                  table[base + ((indices >> ((15 - i) * bits)) & (colors - 1))];
            }
          }
      }
    }
    _ready = true;
  }

  image.Image rgb() {
    if (!_ready) throw const FormatException('Missing SMC reference frame');
    final frame = image.Image(width: width, height: height);
    for (final pixel in frame) {
      final block = (pixel.y ~/ 4) * _columns + pixel.x ~/ 4;
      final offset = block * 16 + (pixel.y & 3) * 4 + (pixel.x & 3);
      final color = _colors[_pixels[offset]];
      pixel.setRgb(color >> 16, (color >> 8) & 255, color & 255);
    }
    return frame;
  }
}

final class _SmcChunk {
  _SmcChunk(this.bytes, this.blocks) : _data = ByteData.sublistView(bytes) {
    if (bytes.length < 4) {
      throw const FormatException('Truncated SMC chunk header');
    }
    _end = _data.getUint32(0) & 0xffffff;
    if (_end < 4 || _end > bytes.length) {
      throw const FormatException('Invalid SMC chunk size');
    }
  }

  final Uint8List bytes;
  final int blocks;
  final ByteData _data;
  late final int _end;
  // Each frame writes from the start of each table. Unwritten slots retain
  // entries from the previous frame, even when all pixel blocks are replaced.
  final _written = [0, 0, 0];
  var _next = 4, block = 0, count = 0, mode = 0, payload = 0, tableIndex = 0;
  var usesPreviousFrame = false;

  int get indexBits => (mode - 6) ~/ 2;
  bool get definesColors => mode.isEven;
  int get paletteSlot => (indexBits - 1) * 256 + tableIndex;

  bool next() {
    block += count;
    if (block == blocks) return false;
    if (_next == _end) throw const FormatException('Incomplete SMC picture');
    final opcode = bytes[_next++];
    usesPreviousFrame = false;
    mode = opcode >> 4;
    count = (opcode & 15) + 1;
    if (mode < 8 && mode.isOdd) {
      count = _byte() + 1;
    }
    if (mode == 4 || mode == 5) count *= 2;
    if (block + count > blocks) {
      throw const FormatException('Invalid SMC block extent');
    }
    payload = _next;
    switch (mode) {
      case 0 || 1:
        usesPreviousFrame = true;
      case 2 || 3 || 4 || 5:
        if (block < (mode < 4 ? 1 : 2)) {
          throw const FormatException('Invalid SMC block repeat');
        }
      case 6 || 7:
        _next++;
      case 14 || 15:
        _next += 16 * count;
      default:
        final bits = indexBits;
        if (definesColors) {
          tableIndex = _written[bits - 1]++ & 255;
          _next += 1 << bits;
        } else {
          tableIndex = _byte();
          if (tableIndex >= _written[bits - 1]) usesPreviousFrame = true;
        }
        _next += 2 * bits * count;
    }
    if (_next > _end) throw const FormatException('Truncated SMC block');
    return true;
  }

  int _byte() {
    if (_next >= _end) throw const FormatException('Truncated SMC block');
    return bytes[_next++];
  }

  int readIndices(int offset) {
    if (indexBits == 1) return _data.getUint16(offset);
    if (indexBits == 2) return _data.getUint32(offset);
    // The final three nibbles are interleaved with the earlier indices.
    final a = _data.getUint16(offset);
    final b = _data.getUint16(offset + 2);
    final c = _data.getUint16(offset + 4);
    final first = (a >> 4) << 12 | (b >> 4);
    final second = (c >> 4) << 12 | (a & 15) << 8 | (b & 15) << 4 | (c & 15);
    return first << 24 | second;
  }
}
