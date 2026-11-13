import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as image;

import 'binary_file.dart';
import 'yuv_image.dart';

enum _Prediction { left, plane, median }

HuffYuvDecoder readHuffYuvFormat(BinaryFile file, int start, int end) {
  if (end - start < 40 || end - start > 1024 * 1024) {
    throw const FormatException('Invalid HuffYUV bitmap header');
  }
  final header = ByteData.sublistView(file.read(start, 40));
  final size = header.getUint32(0, Endian.little);
  if (size < 40 || size > end - start) {
    throw const FormatException('Invalid HuffYUV bitmap header size');
  }
  return HuffYuvDecoder(
    header.getInt32(4, Endian.little),
    header.getInt32(8, Endian.little).abs(),
    header.getUint16(14, Endian.little),
    file.read(start + 40, end - start - 40),
  );
}

final class HuffYuvDecoder {
  HuffYuvDecoder(this.width, this.height, int bitmapBits, Uint8List extra) {
    if (width <= 0 || height <= 0 || width * height > 36 * 1024 * 1024) {
      throw const FormatException('Invalid HuffYUV picture dimensions');
    }
    final classic = extra.isEmpty || (bitmapBits & 7 != 0 && bitmapBits != 12);
    if (classic) {
      _bpp = bitmapBits == 12 ? 12 : bitmapBits & ~7;
      _prediction = switch (bitmapBits & 7) {
        3 => _Prediction.plane,
        4 => _Prediction.median,
        _ => _Prediction.left,
      };
      _decorrelate = bitmapBits & 7 == 2 || (bitmapBits & 7 == 3 && _bpp >= 24);
      _tables = _classicTables(_bpp >= 24);
    } else {
      if (extra.length < 4) {
        throw const FormatException('Truncated HuffYUV configuration');
      }
      final method = extra[0] & 63;
      if (method >= _Prediction.values.length) {
        throw UnsupportedError('HuffYUV prediction method $method');
      }
      _prediction = _Prediction.values[method];
      _decorrelate = extra[0] & 64 != 0;
      _planar = extra[3] != 0;
      _context = extra[2] & 64 != 0;
      _fieldRows = switch ((extra[2] >> 4) & 3) {
        1 => 2,
        2 => 1,
        _ => height > 288 ? 2 : 1,
      };
      if (_planar) {
        _depth = (extra[1] >> 4) + 1;
        _sx = extra[1] & 3;
        _sy = extra[1] >> 2 & 3;
        _yuv = extra[2] & 1 != 0;
        _chroma = extra[2] & 3 != 0;
        _alpha = extra[2] & 4 != 0;
      } else {
        _bpp = extra[1] == 0
            ? (bitmapBits == 12 ? 12 : bitmapBits & ~7)
            : extra[1];
      }
      _tables = _readTables(_TableBytes(extra, 4));
    }
    if (!_planar) {
      if (_bpp != 12 && _bpp != 16 && _bpp != 24 && _bpp != 32) {
        throw UnsupportedError('HuffYUV bitmap depth $_bpp');
      }
      _yuv = _bpp < 24;
      _alpha = _bpp == 32;
      _sx = _yuv ? 1 : 0;
      _sy = _bpp == 12 ? 1 : 0;
      if (classic) _fieldRows = height > 288 ? 2 : 1;
      if (!_yuv && _prediction == _Prediction.median) {
        throw UnsupportedError('HuffYUV median prediction for packed RGB');
      }
    }
    if (!_planar &&
        _yuv &&
        (width.isOdd ||
            (_sy == 1 && height.isOdd) ||
            (_prediction == _Prediction.median &&
                height > _fieldRows &&
                width < 4))) {
      throw const FormatException('Invalid HuffYUV subsampled dimensions');
    }
  }

  final int width, height;
  var _bpp = 0, _depth = 8, _sx = 0, _sy = 0, _fieldRows = 1;
  var _planar = false, _context = false, _yuv = false;
  var _chroma = true, _alpha = false;
  late final _Prediction _prediction;
  late final bool _decorrelate;
  late final List<_HuffTable> _tables;

  int get _tableCount => _planar ? 1 + (_chroma ? 2 : 0) + (_alpha ? 1 : 0) : 3;

  List<_HuffTable> _readTables(_TableBytes bytes) => [
    for (var i = 0; i < _tableCount; i++)
      _HuffTable.canonical(bytes.lengths(1 << math.min(_depth, 14))),
  ];

  HuffYuvPicture decode(Uint8List packet) {
    if (packet.length < 4 || packet.length & 3 != 0) {
      throw const FormatException('Invalid HuffYUV frame size');
    }
    final data = ByteData.sublistView(packet);
    final reordered = Uint8List(packet.length);
    final words = ByteData.sublistView(reordered);
    for (var i = 0; i < packet.length; i += 4) {
      words.setUint32(i, data.getUint32(i, Endian.little));
    }
    final header = _TableBytes(reordered, 0);
    final tables = _context ? _readTables(header) : _tables;
    final bits = _HuffBits(reordered, header.offset);
    final planes = _planar
        ? _decodePlanar(bits, tables)
        : (_yuv ? _decodeYuv(bits, tables) : _decodeRgb(bits, tables));
    return HuffYuvPicture._(
      width,
      height,
      _depth,
      _sx,
      _sy,
      _yuv,
      _chroma,
      _alpha,
      planes,
    );
  }

  List<List<int>> _decodeRgb(_HuffBits bits, List<_HuffTable> tables) {
    final count = _alpha ? 4 : 3;
    final channels = [
      for (var i = 0; i < count; i++) Uint8List(width * height),
    ];
    final left = Uint8List(count);
    if (_alpha) left[3] = bits.read(8);
    for (final c in [2, 0, 1]) {
      left[c] = bits.read(8);
    }
    if (!_alpha) bits.read(8);
    for (var row = 0; row < height; row++) {
      final start = (height - 1 - row) * width;
      for (var x = 0; x < width; x++) {
        if (row != 0 || x != 0) {
          if (_decorrelate) {
            final green = tables[1].read(bits);
            left[0] += green;
            left[1] += tables[0].read(bits) + green;
            left[2] += tables[2].read(bits) + green;
          } else {
            left[1] += tables[0].read(bits);
            left[0] += tables[1].read(bits);
            left[2] += tables[2].read(bits);
          }
          if (_alpha) left[3] += tables[2].read(bits);
        }
        final at = start + x;
        for (var c = 0; c < count; c++) {
          final above = _prediction == _Prediction.plane && row >= _fieldRows
              ? channels[c][at + _fieldRows * width]
              : 0;
          channels[c][at] = left[c] + above;
        }
      }
    }
    return channels;
  }

  List<List<int>> _decodeYuv(_HuffBits bits, List<_HuffTable> tables) {
    final widths = [width, width >> 1, width >> 1];
    final chromaRows = height >> _sy;
    final planes = [
      Uint8List(width * height),
      Uint8List((width >> 1) * chromaRows),
      Uint8List((width >> 1) * chromaRows),
    ];
    final left = Uint8List(3);
    final aboveLeft = Uint8List(3);
    planes[2][0] = left[2] = bits.read(8);
    planes[0][1] = left[0] = bits.read(8);
    planes[1][0] = left[1] = bits.read(8);
    planes[0][0] = bits.read(8);

    void put(int c, int row, int x, {bool gradient = true}) {
      final plane = planes[c], stride = widths[c];
      final at = row * stride + x;
      final residual = tables[c].read(bits);
      if (row >= _fieldRows) {
        final above = plane[at - _fieldRows * stride];
        if (_prediction == _Prediction.median) {
          final prefix = c == 0 ? 4 : 2;
          if (row > _fieldRows || x >= prefix) {
            if (row == _fieldRows && x == prefix) {
              aboveLeft[c] = plane[x - 1];
            }
            left[c] = _median(left[c], above, aboveLeft[c], 255) + residual;
            aboveLeft[c] = above;
            plane[at] = left[c];
            return;
          }
        } else if (_prediction == _Prediction.plane && gradient) {
          left[c] += residual;
          plane[at] = left[c] + above;
          return;
        }
      }
      plane[at] = left[c] += residual;
    }

    var chromaRow = 0;
    for (var row = 0; row < height; row++) {
      final warmup = _prediction == _Prediction.median && row <= _fieldRows;
      final hasChroma =
          chromaRow < chromaRows &&
          (_sy == 0 || warmup || chromaRow * 2 <= row);
      final gradient = !hasChroma || chromaRow >= _fieldRows;
      for (var x = row == 0 ? 2 : 0; x < width; x += 2) {
        put(0, row, x, gradient: gradient);
        if (hasChroma) put(1, chromaRow, x >> 1);
        put(0, row, x + 1, gradient: gradient);
        if (hasChroma) put(2, chromaRow, x >> 1);
      }
      if (_prediction == _Prediction.median &&
          row == _fieldRows &&
          width == 4) {
        aboveLeft[0] = planes[0][3];
        if (hasChroma && chromaRow == _fieldRows) {
          aboveLeft[1] = planes[1][1];
          aboveLeft[2] = planes[2][1];
        }
      }
      if (hasChroma) chromaRow++;
    }
    return planes;
  }

  List<List<int>> _decodePlanar(_HuffBits bits, List<_HuffTable> tables) {
    final mask = (1 << _depth) - 1;
    return [
      for (var c = 0; c < _tableCount; c++)
        _decodePlane(
          bits,
          tables[c],
          _chroma && (c == 1 || c == 2) ? width >> _sx : width,
          _chroma && (c == 1 || c == 2) ? height >> _sy : height,
          _chroma && (c == 1 || c == 2) ? _chromaSize(width, _sx) : width,
          _chroma && (c == 1 || c == 2) ? _chromaSize(height, _sy) : height,
          mask,
        ),
    ];
  }

  List<int> _decodePlane(
    _HuffBits bits,
    _HuffTable table,
    int w,
    int h,
    int stride,
    int rows,
    int mask,
  ) {
    // The planar bitstream rounds subsampled dimensions down. The displayed
    // planes still include any uncoded right or bottom edge samples.
    final plane = _depth <= 8
        ? Uint8List(stride * rows)
        : Uint16List(stride * rows);
    final lowBits = math.max(0, _depth - 14);
    var left = 0, aboveLeft = 0;
    for (var row = 0; row < h; row++) {
      final start = row * stride;
      final median = _prediction == _Prediction.median && row >= _fieldRows;
      final gradient = _prediction == _Prediction.plane && row >= _fieldRows;
      if (median && row == _fieldRows) aboveLeft = plane[0] & 255;
      for (var x = 0; x < w; x++) {
        final at = start + x;
        final residual = (table.read(bits) << lowBits) | bits.read(lowBits);
        if (median) {
          final above = plane[at - _fieldRows * stride];
          left = (_median(left, above, aboveLeft, mask) + residual) & mask;
          aboveLeft = above;
          plane[at] = left;
        } else {
          left = (left + residual) & mask;
          plane[at] = gradient
              ? (left + plane[at - _fieldRows * stride]) & mask
              : left;
        }
      }
    }
    return plane;
  }

  static int _median(int left, int above, int aboveLeft, int mask) =>
      ((left + above - aboveLeft) & mask).clamp(
        math.min(left, above),
        math.max(left, above),
      );
}

int _chromaSize(int value, int shift) => (value + (1 << shift) - 1) >> shift;

final class HuffYuvPicture {
  const HuffYuvPicture._(
    this.width,
    this.height,
    this.depth,
    this.subsamplingX,
    this.subsamplingY,
    this.yuv,
    this.chroma,
    this.hasAlpha,
    this.planes,
  );

  final int width, height, depth, subsamplingX, subsamplingY;
  final bool yuv, chroma, hasAlpha;
  final List<List<int>> planes;

  image.Image rgb({YuvImageScaler? scaler, bool includeAlpha = true}) {
    final alpha = includeAlpha && hasAlpha ? planes.last : null;
    return yuvImage(
      y: planes[0],
      cb: chroma ? planes[1] : const [],
      cr: chroma ? planes[2] : const [],
      stride: width,
      chromaStride: _chromaSize(width, subsamplingX),
      width: width,
      height: height,
      cropLeft: 0,
      cropTop: 0,
      matrix: yuv ? 2 : 0,
      fullRange: !yuv,
      lumaDepth: depth,
      chromaDepth: depth,
      subsamplingX: subsamplingX,
      subsamplingY: subsamplingY,
      alpha: alpha,
      alphaDepth: depth,
      scaler: scaler,
    );
  }
}

final class _TableBytes {
  _TableBytes(this.bytes, this.offset);
  final Uint8List bytes;
  int offset;

  int _byte() {
    if (offset >= bytes.length) {
      throw const FormatException('Truncated HuffYUV Huffman table');
    }
    return bytes[offset++];
  }

  Uint8List lengths(int size) {
    final lengths = Uint8List(size);
    for (var i = 0; i < size;) {
      final field = _byte();
      final run = field >> 5;
      final count = run == 0 ? _byte() : run;
      if (count == 0 || count > size - i) {
        throw const FormatException('Invalid HuffYUV Huffman table run');
      }
      lengths.fillRange(i, i + count, field & 31);
      i += count;
    }
    return lengths;
  }
}

final class _HuffTable {
  _HuffTable(Uint8List lengths, List<int> codes) {
    for (var symbol = 0; symbol < lengths.length; symbol++) {
      final length = lengths[symbol];
      if (length == 0) continue;
      final code = codes[symbol];
      if (length <= _lookupBits) {
        final start = code << (_lookupBits - length);
        final end = start + (1 << (_lookupBits - length));
        if (start < 0 || end > _lookup.length) {
          throw const FormatException('Invalid HuffYUV Huffman code');
        }
        _lookup.fillRange(start, end, (symbol << 5) | length);
      }
      _codes[(1 << length) | code] = symbol;
    }
  }

  factory _HuffTable.canonical(Uint8List lengths) {
    final count = Uint32List(32);
    for (final length in lengths) {
      count[length]++;
    }
    final next = Uint32List(32);
    var carry = 0;
    for (var length = 31; length > 0; length--) {
      next[length] = carry;
      carry += count[length];
      if (carry.isOdd) {
        throw const FormatException('Invalid HuffYUV Huffman lengths');
      }
      carry >>= 1;
    }
    if (carry != 1) {
      throw const FormatException('Invalid HuffYUV Huffman lengths');
    }
    return _HuffTable(lengths, [
      for (final length in lengths) length == 0 ? 0 : next[length]++,
    ]);
  }

  static const _lookupBits = 10;
  final _lookup = Uint32List(1 << _lookupBits);
  final _codes = <int, int>{};

  int read(_HuffBits bits) {
    final entry = _lookup[bits.peek(_lookupBits)];
    if (entry != 0 && (entry & 31) <= bits.remaining) {
      bits.consume(entry & 31);
      return entry >> 5;
    }
    var code = 1;
    for (var i = 0; i < 31; i++) {
      code = (code << 1) | bits.read(1);
      final symbol = _codes[code];
      if (symbol != null) return symbol;
    }
    throw const FormatException('Invalid HuffYUV Huffman code');
  }
}

final class _HuffBits {
  _HuffBits(this.bytes, int offset)
    : _next = offset,
      _remaining = (bytes.length - offset) * 8;

  final Uint8List bytes;
  int _next, _remaining;
  int _cache = 0, _cached = 0;
  int get remaining => _remaining;

  int peek(int count) {
    while (_cached < count && _next < bytes.length) {
      _cache = (_cache << 8) | bytes[_next++];
      _cached += 8;
    }
    final shift = _cached - count;
    return (shift < 0 ? _cache << -shift : _cache >> shift) &
        ((1 << count) - 1);
  }

  void consume(int count) {
    _remaining -= count;
    _cached -= count;
    _cache &= (1 << _cached) - 1;
  }

  int read(int count) {
    if (count > remaining) {
      throw const FormatException('Truncated HuffYUV residual data');
    }
    final value = peek(count);
    consume(count);
    return value;
  }
}

List<_HuffTable> _classicTables(bool rgb) {
  Uint8List fromHex(String hex) => Uint8List.fromList([
    for (var i = 0; i < hex.length; i += 2)
      int.parse(hex.substring(i, i + 2), radix: 16),
  ]);

  final luma = _HuffTable(
    _TableBytes(fromHex(_classicLumaLengths), 0).lengths(256),
    fromHex(_classicLumaCodes),
  );
  final chroma = rgb
      ? luma
      : _HuffTable(
          _TableBytes(fromHex(_classicChromaLengths), 0).lengths(256),
          fromHex(_classicChromaCodes),
        );
  return [luma, chroma, chroma];
}

// HuffYUV 1.x fixed codebooks, stored as byte values in hexadecimal.
const _classicLumaLengths =
    '2224234587e809100a180b170c100d0a0e080f0810081114100acfcecdec0b080a150917'
    '0808c7464544';

const _classicChromaLengths =
    '422425262728294b4c4d6eef90515253545576b73839585938599a393a391a8d39383a39'
    '3a39b877d6f574535231504f4e4d2c4b29282726252422';

const _classicLumaCodes =
    '0309050c0a23201d1b32302d2c29272549464441403d3a383532312e2c29262444413f3d'
    '3a373533302e2d2b292726242321201e1d1b1a19302f2e2c2b29282725242322201f1e1c'
    '1b1a1817161413252322211f1e1d1b1a1817151412110f1d1b1a1816151311100e1a1917'
    '151312100f1b1917151311100e1a19171512110e0c11130d0409020b0107080010030e06'
    '0c0a050f120b0a0d0f10131416181b0f121416181a0e111416181b0f121417191c101316'
    '191c202415191d21262a2d311c1f2225282a2c2f3132343638393b3c3e40424345232527'
    '282a2b2d2f3033343637393b3c3e3f424345474826282a2b2e2f31331a1c1e1f21221213'
    '0b0d0708';

const _classicChromaCodes =
    '03010202020203030705070508060b09070d0b0a0908070509070604070508070b080d0b'
    '130f16171421201c1b1d334d2b2d4c512e524b3738903a503c4a933f8f41424344454647'
    '48494a4b4c4d4e4f505152535455565758595a5b1b1e1516110e050664362f3233356a6b'
    '6c6d6e6f707172730475765c5e797a037c6702010081828378777e7d88898a8b8c8d8e86'
    '8784856840653e39665f5d3b3d1c61603431301d2019182e17622d2c2b142a2913126328'
    '0f2726100d0c0b250a09082407807f697b74232221911f4f2a924e1a533031322c2f1a1f'
    '1e1211131518190d0e10111214150c0e0f090a0609060508060c080a0709060406020203'
    '03030302';
