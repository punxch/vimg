// The image package supplies the VP8 block DSP shared with WebP.
// ignore_for_file: implementation_imports, invalid_use_of_internal_member

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as image;
import 'package:image/src/formats/webp/vp8_filter.dart';
import 'package:image/src/formats/webp/vp8_tables.dart';

import '../yuv_image.dart';

part 'blocks.dart';
part 'motion.dart';

/// The uncompressed tag can be inspected without reading residual partitions.
({bool key, bool shown}) vp8FrameTag(Uint8List bytes) {
  if (bytes.length < 3) throw const FormatException('Truncated VP8 frame tag');
  return (key: bytes[0] & 1 == 0, shown: bytes[0] & 16 != 0);
}

final class Vp8Picture {
  Vp8Picture(this.width, this.height, this.fullRange)
    : y = Vp8Plane((width + 15) & ~15, (height + 15) & ~15),
      u = Vp8Plane(((width + 15) & ~15) >> 1, ((height + 15) & ~15) >> 1),
      v = Vp8Plane(((width + 15) & ~15) >> 1, ((height + 15) & ~15) >> 1);

  final int width, height;
  final bool fullRange;
  final Vp8Plane y, u, v;

  image.Image rgb({YuvImageScaler? scaler, Uint8List? alpha}) => yuvImage(
    alpha: alpha,
    y: y.samples,
    cb: u.samples,
    cr: v.samples,
    stride: y.width,
    chromaStride: u.width,
    width: width,
    height: height,
    cropLeft: 0,
    cropTop: 0,
    matrix: 6,
    fullRange: fullRange,
    scaler: scaler,
  );
}

final class Vp8Plane {
  Vp8Plane(this.width, this.height) : samples = Uint8List(width * height);

  final int width, height;
  final Uint8List samples;

  int at(int x, int y) =>
      samples[y.clamp(0, height - 1) * width + x.clamp(0, width - 1)];
}

final class Vp8Decoder {
  final _references = List<Vp8Picture?>.filled(4, null);
  final _segments = _Segments();
  final _filter = _LoopFilter();
  final _dsp = VP8Filter();
  final _blockSamples = Uint8List(32 * 18);
  _Entropy _entropy = _Entropy();
  int _width = 0, _height = 0;
  bool _fullRange = false;

  Vp8Picture decode(Uint8List bytes) {
    final (:key, shown: _) = vp8FrameTag(bytes);
    final profile = (bytes[0] >> 1) & 7;
    if (profile > 3) throw UnsupportedError('VP8 profile $profile');
    final headerLength = (bytes[0] | bytes[1] << 8 | bytes[2] << 16) >> 5;
    final headerStart = key ? 10 : 3;
    final headerEnd = headerStart + headerLength;
    if (headerLength == 0 || headerEnd > bytes.length) {
      throw const FormatException('Invalid VP8 header partition');
    }
    if (key) {
      if (bytes[3] != 0x9d || bytes[4] != 1 || bytes[5] != 0x2a) {
        throw const FormatException('Invalid VP8 keyframe signature');
      }
      _width = bytes[6] | ((bytes[7] & 63) << 8);
      _height = bytes[8] | ((bytes[9] & 63) << 8);
      if (_width == 0 || _height == 0 || _width * _height > 64 * 1024 * 1024) {
        throw const FormatException('Invalid VP8 dimensions');
      }
      _entropy = _Entropy();
      _segments.reset(((_width + 15) >> 4) * ((_height + 15) >> 4));
      _filter.reset();
    } else if (_references[1] == null) {
      throw const FormatException('Missing VP8 reference picture');
    }

    final header = _BoolReader(bytes, headerStart, headerEnd);
    if (key) {
      header.bit(); // Color space
      _fullRange = header.bit() != 0;
    }
    _segments.read(header);
    _filter.read(header);
    final tokens = _tokenReaders(bytes, headerEnd, 1 << header.read(2));
    final base = header.read(7);
    final deltas = List.generate(5, (_) => header.optionalSigned(4));
    final quant = List.generate(
      4,
      (i) => _Quant(_segments.quant(i, base), deltas),
    );

    var golden = 0, alternate = 0;
    final biases = List.filled(4, false);
    if (!key) {
      final refreshGolden = header.bit() != 0;
      final refreshAlternate = header.bit() != 0;
      golden = refreshGolden ? 0 : _copySource(header.read(2), 2, 3);
      alternate = refreshAlternate ? 0 : _copySource(header.read(2), 3, 2);
      biases[2] = header.bit() != 0;
      biases[3] = header.bit() != 0;
    }
    final refreshEntropy = header.bit() != 0;
    final last = key || header.bit() != 0;
    final entropy = refreshEntropy ? _entropy : _entropy.copy();
    entropy.updateCoefficients(header);
    final skipProbability = header.bit() == 0 ? null : header.read(8);
    final references = key
        ? const <int>[]
        : List.generate(3, (_) => header.read(8));
    if (!key) entropy.updateInter(header);

    final picture = Vp8Picture(_width, _height, _fullRange);
    final columns = picture.y.width >> 4, rows = picture.y.height >> 4;
    final edge = _Block();
    final blocks = <_Block>[];
    for (var row = 0; row < rows; row++) {
      for (var column = 0; column < columns; column++) {
        final index = row * columns + column;
        final above = row == 0 ? edge : blocks[index - columns];
        final left = column == 0 ? edge : blocks[index - 1];
        final aboveLeft = row == 0 || column == 0
            ? edge
            : blocks[index - columns - 1];
        final block = _Block();
        blocks.add(block);
        block.segment = _segments.at(header, index);
        final skipped =
            skipProbability != null && header.bit(skipProbability) != 0;
        if (key || header.bit(references[0]) == 0) {
          block.readIntra(header, key, entropy, left, above);
        } else {
          block.reference = header.bit(references[1]) == 0
              ? 1
              : 2 + header.bit(references[2]);
          _readMotion(
            header,
            entropy,
            block,
            above,
            left,
            aboveLeft,
            biases,
            column,
            row,
            columns,
            rows,
          );
        }
        final coefficients = _readResiduals(
          tokens[row % tokens.length],
          entropy,
          quant[block.segment],
          block,
          above,
          left,
          skipped,
        );
        _reconstruct(picture, block, coefficients, column, row, profile);
      }
    }
    _filter.apply(picture, _dsp, _segments, blocks, key);

    final nextGolden = golden == 0 ? picture : _references[golden];
    final nextAlternate = alternate == 0 ? picture : _references[alternate];
    _references[2] = nextGolden;
    _references[3] = nextAlternate;
    if (last) _references[1] = picture;
    return picture;
  }

  int _copySource(int code, int unchanged, int other) => switch (code) {
    0 => unchanged,
    1 => 1,
    2 => other,
    _ => throw const FormatException('Invalid VP8 reference update'),
  };

  void _reconstruct(
    Vp8Picture pic,
    _Block block,
    Int16List coeffs,
    int x,
    int y,
    int profile,
  ) {
    final reference = block.reference == 0
        ? null
        : _references[block.reference];
    if (block.reference != 0 && reference == null) {
      throw const FormatException('Unavailable VP8 reference');
    }
    for (var plane = 0; plane < 3; plane++) {
      final dest = [pic.y, pic.u, pic.v][plane];
      final size = plane == 0 ? 16 : 8;
      final left = x * size, top = y * size;
      if (reference == null) {
        _predictIntra(dest, block, coeffs, plane, left, top, size);
      } else {
        final source = [reference.y, reference.u, reference.v][plane];
        _predictInter(
          _blockSamples,
          source,
          block,
          plane,
          left,
          top,
          size,
          profile,
        );
        _addResiduals(coeffs, plane, size);
      }
      for (var row = 0; row < size; row++) {
        dest.samples.setRange(
          (top + row) * dest.width + left,
          (top + row) * dest.width + left + size,
          _blockSamples,
          _scratchOrigin + row * kBps,
        );
      }
    }
  }

  void _predictIntra(
    Vp8Plane plane,
    _Block block,
    Int16List coeffs,
    int index,
    int x,
    int y,
    int size,
  ) {
    final scratch = _blockSamples;
    final corner = _scratchOrigin - kBps - 1;
    scratch[corner] = y == 0
        ? 127
        : x == 0
        ? 129
        : plane.at(x - 1, y - 1);
    for (var i = 0; i < size; i++) {
      scratch[_scratchOrigin - kBps + i] = y == 0
          ? 127
          : plane.at(x + i, y - 1);
      scratch[_scratchOrigin + i * kBps - 1] = x == 0
          ? 129
          : plane.at(x - 1, y + i);
    }

    final modes = index == 0 ? block.subModes : null;
    if (modes != null) {
      for (var i = 0; i < 4; i++) {
        final sample = y == 0 ? 127 : plane.at(x + 16 + i, y - 1);
        for (var row = -1; row < 15; row += 4) {
          scratch[_scratchOrigin + row * kBps + 16 + i] = sample;
        }
      }
      for (var part = 0; part < 16; part++) {
        final dst = image.InputBuffer(
          scratch,
          offset: _scratchOrigin + (part >> 2) * 4 * kBps + (part & 3) * 4,
        );
        VP8Filter.predLuma4[modes[part]](dst);
        _transform(coeffs, part, dst);
      }
    } else {
      final mode = index == 0 ? block.yMode : block.uvMode;
      final prediction = mode == dcPred
          ? (y == 0 ? (x == 0 ? 6 : 4) : (x == 0 ? 5 : dcPred))
          : mode;
      final predictors = index == 0
          ? VP8Filter.predLuma16
          : VP8Filter.predChroma8;
      predictors[prediction](
        image.InputBuffer(scratch, offset: _scratchOrigin),
      );
      _addResiduals(coeffs, index, size);
    }
  }

  void _addResiduals(Int16List coeffs, int plane, int size) {
    final first = plane == 0 ? 0 : 12 + 4 * plane;
    for (var row = 0; row < size; row += 4) {
      for (var x = 0; x < size; x += 4) {
        final dst = image.InputBuffer(
          _blockSamples,
          offset: _scratchOrigin + row * kBps + x,
        );
        _transform(coeffs, first + ((row * size + x * 4) >> 4), dst);
      }
    }
  }

  void _transform(Int16List coeffs, int block, image.InputBuffer dst) {
    final start = block * 16;
    for (var i = start; i < start + 16; i++) {
      if (coeffs[i] != 0) {
        _dsp.transformOne(image.InputBuffer(coeffs, offset: start), dst);
        return;
      }
    }
  }
}

const _scratchOrigin = kBps + 4;

List<_BoolReader> _tokenReaders(Uint8List bytes, int start, int count) {
  var offset = start + (count - 1) * 3;
  if (offset > bytes.length)
    throw const FormatException('Truncated VP8 partition lengths');
  return List.generate(count, (i) {
    final entry = start + i * 3;
    final length = i == count - 1
        ? bytes.length - offset
        : bytes[entry] | bytes[entry + 1] << 8 | bytes[entry + 2] << 16;
    final end = offset + length;
    if (end > bytes.length)
      throw const FormatException('Invalid VP8 token partition');
    final reader = _BoolReader(bytes, offset, end);
    offset = end;
    return reader;
  });
}

final class _BoolReader {
  _BoolReader(this.bytes, int start, this.end)
    : position = (start + 2) * 8,
      _value =
          (start < end ? bytes[start] << 8 : 0) |
          (start + 1 < end ? bytes[start + 1] : 0);

  final Uint8List bytes;
  final int end;
  int position;
  int _value, _range = 255;

  int bit([int probability = 128]) {
    final split = 1 + ((_range - 1) * probability >> 8);
    final threshold = split << 8;
    final high = _value >= threshold;
    if (high) {
      _value -= threshold;
      _range -= split;
    } else {
      _range = split;
    }
    while (_range < 128) {
      if (position >= end * 8 + 16)
        throw const FormatException('Truncated VP8 boolean partition');
      _range <<= 1;
      _value <<= 1;
      if (position < end * 8)
        _value |= bytes[position >> 3] >> (7 - (position & 7)) & 1;
      position++;
    }
    return high ? 1 : 0;
  }

  int read(int bits) {
    var value = 0;
    for (var i = 0; i < bits; i++) {
      value = value << 1 | bit();
    }
    return value;
  }

  int optionalSigned(int bits) {
    if (bit() == 0) return 0;
    final value = read(bits);
    return bit() == 0 ? value : -value;
  }
}
