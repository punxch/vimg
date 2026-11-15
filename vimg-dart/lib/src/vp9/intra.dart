import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as image;

import '../yuv_image.dart';
import 'bitstream.dart';
import 'entropy.dart';
import 'tables.dart';
import 'transform.dart';

part 'intra_prediction.dart';
part 'loop_filter.dart';

final class Vp9Plane {
  Vp9Plane(this.paddedWidth, this.paddedHeight)
    : stride = (paddedWidth + 31) & ~31,
      samples = Uint16List(
        ((paddedWidth + 31) & ~31) * ((paddedHeight + 31) & ~31),
      );

  final int paddedWidth, paddedHeight, stride;
  final Uint16List samples;
}

final class Vp9Picture {
  Vp9Picture._(this.header)
    : y = Vp9Plane(header.miColumns * 8, header.miRows * 8),
      u = Vp9Plane(
        (header.miColumns * 8) >> header.color.subX,
        (header.miRows * 8) >> header.color.subY,
      ),
      v = Vp9Plane(
        (header.miColumns * 8) >> header.color.subX,
        (header.miRows * 8) >> header.color.subY,
      );

  final Vp9FrameHeader header;
  final Vp9Plane y, u, v;

  image.Image rgb({YuvImageScaler? scaler}) {
    final color = header.color;
    final matrix = switch (color.space) {
      2 => 1,
      4 => 7,
      5 => 9,
      7 => 0,
      _ => 6,
    };
    final aspect =
        (header.renderWidth / header.width) /
        (header.renderHeight / header.height);
    return yuvImage(
      y: y.samples,
      cb: u.samples,
      cr: v.samples,
      stride: y.stride,
      chromaStride: u.stride,
      width: header.width,
      height: header.height,
      cropLeft: 0,
      cropTop: 0,
      matrix: matrix,
      fullRange: color.fullRange,
      lumaDepth: color.depth,
      chromaDepth: color.depth,
      subsamplingX: color.subX,
      subsamplingY: color.subY,
      sampleAspect: aspect,
      scaler: scaler,
    );
  }
}

final class Vp9Decoder {
  final _references = List<Vp9Picture?>.filled(8, null);

  static Vp9Picture preview(Uint8List bytes) {
    final tag = vp9PacketTag(
      bytes.length,
      (offset, length) => Uint8List.sublistView(bytes, offset, offset + length),
    );
    final frame = tag.preview;
    if (frame == null) {
      throw const FormatException('No independent VP9 display picture');
    }
    final coded = Uint8List.sublistView(
      bytes,
      frame.offset,
      frame.offset + frame.length,
    );
    return _decodeIntra(coded, Vp9FrameHeader.read(coded)!);
  }

  Vp9Picture? decodePacket(Uint8List bytes) {
    final extents = vp9FrameExtents(
      bytes.length,
      (offset, length) => Uint8List.sublistView(bytes, offset, offset + length),
    );
    Vp9Picture? shown;
    for (final extent in extents) {
      final frame = Uint8List.sublistView(
        bytes,
        extent.offset,
        extent.offset + extent.length,
      );
      final tag = vp9FrameTag(frame);
      final header = Vp9FrameHeader.read(
        frame,
        reference: (index) => _references[index]?.header,
      );
      final Vp9Picture picture;
      if (header == null) {
        picture =
            _references[tag.existing!] ??
            (throw const FormatException('Missing VP9 display reference'));
      } else {
        if (!header.intra) {
          throw UnsupportedError('VP9 inter-frame reconstruction');
        }
        picture = _decodeIntra(frame, header);
        for (var slot = 0; slot < 8; slot++) {
          if (header.refreshMask & (1 << slot) != 0) {
            _references[slot] = picture;
          }
        }
      }
      if (tag.shown) {
        if (shown != null) {
          throw UnsupportedError('Multiple VP9 display pictures per sample');
        }
        shown = picture;
      }
    }
    return shown;
  }
}

Vp9Picture _decodeIntra(Uint8List bytes, Vp9FrameHeader header) {
  if (header.width * header.height > 64 * 1024 * 1024) {
    throw const FormatException('Invalid VP9 picture dimensions');
  }
  final picture = Vp9Picture._(header);
  _IntraDecoder(picture, Vp9IntraEntropy(bytes, header)).decode(bytes);
  return picture;
}

const _partitionTree = [0, 2, -1, 4, -2, -3];
const _intraModeTree = [
  0,
  2,
  -9,
  4,
  -1,
  6,
  8,
  12,
  -2,
  10,
  -4,
  -5,
  -3,
  14,
  -8,
  16,
  -6,
  -7,
];
const _segmentTree = [2, 4, 6, 8, 10, 12, 0, -1, -2, -3, -4, -5, -6, -7];
const _coefficientTree = [
  0,
  2,
  -1,
  4,
  6,
  10,
  -2,
  8,
  -3,
  -4,
  12,
  14,
  -5,
  -6,
  16,
  18,
  -7,
  -8,
  -9,
  -10,
];
const _coefficientEnergy = [0, 1, 2, 3, 3, 4, 4, 5, 5, 5, 5];
const _coefficientBase = [0, 1, 2, 3, 4, 5, 7, 11, 19, 35, 67];
const _extraCoefficientBits = [
  <int>[],
  <int>[],
  <int>[],
  <int>[],
  <int>[],
  [159],
  [165, 145],
  [173, 148, 140],
  [176, 155, 140, 135],
  [180, 157, 141, 134, 130],
  [254, 254, 254, 252, 249, 243, 230, 196, 177, 153, 140, 133, 130, 129],
];
const _bandsSmall = [0, 1, 1, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 5, 5, 5];
const _scans = [
  [defaultScan4, rowScan4, colScan4, defaultScan4],
  [defaultScan8, rowScan8, colScan8, defaultScan8],
  [defaultScan16, rowScan16, colScan16, defaultScan16],
  [defaultScan32],
];

final class _IntraDecoder {
  _IntraDecoder(this.picture, this.entropy)
    : _abovePartition = Uint8List((picture.header.miColumns + 7) & ~7),
      _aboveModes = Uint8List(picture.header.miColumns * 2),
      _aboveSkip = Uint8List(picture.header.miColumns),
      _aboveTx = Uint8List(picture.header.miColumns),
      _aboveCoefficients = List.generate(
        3,
        (_) => Uint8List(((picture.header.miColumns + 7) & ~7) * 2),
      );

  final Vp9Picture picture;
  final Vp9IntraEntropy entropy;
  Vp9FrameHeader get _header => picture.header;
  final Uint8List _abovePartition, _aboveModes, _aboveSkip, _aboveTx;
  final _leftPartition = Uint8List(8);
  final _leftModes = Uint8List(16);
  final _leftSkip = Uint8List(8);
  final _leftTx = Uint8List(8);
  final List<Uint8List> _aboveCoefficients;
  final _leftCoefficients = List.generate(3, (_) => Uint8List(16));
  late final _loopFilter = _IntraLoopFilter(picture);
  final _predictor = _IntraPrediction();
  final _transform = Vp9InverseTransform();
  final _modes = Uint8List(4);
  final _energy = Uint8List(1024);
  final _residual = Int32List(1024);

  int _tileLeft = 0;
  late Vp9BoolReader _bits;

  void decode(Uint8List bytes) {
    int tileEdge(int tile, int extent, int log) =>
        math.min(((tile * ((extent + 7) >> 3)) >> log) * 8, extent);
    for (final tile in _header.tiles(bytes)) {
      _bits = Vp9BoolReader(bytes, tile.offset, tile.length);
      final rowStart = tileEdge(tile.row, _header.miRows, _header.tileRowLog);
      final rowEnd = tileEdge(tile.row + 1, _header.miRows, _header.tileRowLog);
      _tileLeft = tileEdge(
        tile.column,
        _header.miColumns,
        _header.tileColumnLog,
      );
      final right = tileEdge(
        tile.column + 1,
        _header.miColumns,
        _header.tileColumnLog,
      );
      if (rowStart == rowEnd || _tileLeft == right) {
        throw const FormatException('Empty VP9 tile');
      }
      for (var y = rowStart; y < rowEnd; y += 8) {
        _leftPartition.fillRange(0, 8, 0);
        for (final left in _leftCoefficients) {
          left.fillRange(0, left.length, 0);
        }
        for (var x = _tileLeft; x < right; x += 8) {
          _partition(x, y, 3);
        }
      }
    }
    if (_header.filter.level != 0) _loopFilter.apply();
  }

  void _partition(int x, int y, int level) {
    if (x >= _header.miColumns || y >= _header.miRows) return;
    final size = 1 << level, half = size >> 1;
    final hasRight = x + half < _header.miColumns;
    final hasBottom = y + half < _header.miRows;
    final aboveSplit = (_abovePartition[x] >> (3 - level)) & 1;
    final leftSplit = (_leftPartition[y & 7] >> (3 - level)) & 1;
    final context = (4 * level + 2 * leftSplit + aboveSplit) * 3;
    final partition = hasRight && hasBottom
        ? _bits.tree(_partitionTree, keyPartitionProbabilities, context)
        : hasRight
        ? (_bits.bit(keyPartitionProbabilities[context + 1]) == 0 ? 1 : 3)
        : hasBottom
        ? (_bits.bit(keyPartitionProbabilities[context + 2]) == 0 ? 2 : 3)
        : 3;
    final splitX = partition >= 2;
    final splitY = partition.isOdd;
    if (level == 0 || partition != 3) {
      final width = (size * 8) >> (splitX ? 1 : 0);
      final height = (size * 8) >> (splitY ? 1 : 0);
      _block(x, y, width, height);
      if (level != 0 && partition == 1 && hasBottom)
        _block(x, y + half, width, height);
      if (level != 0 && partition == 2 && hasRight)
        _block(x + half, y, width, height);
      _abovePartition.fillRange(x, x + size, 15 >> (width.bitLength - 3));
      _leftPartition.fillRange(
        y & 7,
        (y & 7) + size,
        15 >> (height.bitLength - 3),
      );
    } else {
      _partition(x, y, level - 1);
      _partition(x + half, y, level - 1);
      _partition(x, y + half, level - 1);
      _partition(x + half, y + half, level - 1);
    }
  }

  void _block(int x, int y, int width, int height) {
    final haveAbove = y != 0, haveLeft = x > _tileLeft;
    final skipContext =
        (haveAbove ? _aboveSkip[x] : 0) + (haveLeft ? _leftSkip[y & 7] : 0);
    final tree = _header.segmentation.tree;
    final segment = tree == null ? 0 : _bits.tree(_segmentTree, tree, 0);
    final features = _header.segmentation.features?[segment];
    final skip =
        features?[3] != null || _bits.bit(entropy.skip[skipContext]) != 0;
    final maxTx = math.min(3, math.min(width, height).bitLength - 3);
    var tx = math.min(maxTx, entropy.largestTransform);
    if (maxTx > 0 && entropy.selectTransform) {
      var above = haveAbove && _aboveSkip[x] == 0 ? _aboveTx[x] : maxTx;
      var left = haveLeft && _leftSkip[y & 7] == 0 ? _leftTx[y & 7] : maxTx;
      if (!haveLeft) left = above;
      if (!haveAbove) above = left;
      final offset = maxTx * 6 + (above + left > maxTx ? 3 : 0);
      tx = 0;
      while (tx < maxTx && _bits.bit(entropy.transform[offset + tx]) != 0) {
        tx++;
      }
    }

    final subBlock = width < 8 || height < 8;
    final modeWidth = width == 4 ? 1 : 2, modeHeight = height == 4 ? 1 : 2;
    for (var j = 0; j < 2; j += modeHeight) {
      for (var i = 0; i < 2; i += modeWidth) {
        final above = j > 0
            ? _modes[i]
            : haveAbove
            ? _aboveModes[x * 2 + i]
            : 0;
        final left = i > 0
            ? _modes[j * 2]
            : haveLeft
            ? _leftModes[(y & 7) * 2 + j]
            : 0;
        final mode = _bits.tree(
          _intraModeTree,
          keyYModeProbabilities,
          (10 * above + left) * 9,
        );
        for (var v = j; v < j + modeHeight; v++) {
          _modes.fillRange(v * 2 + i, v * 2 + i + modeWidth, mode);
        }
      }
    }
    final yMode = _modes[3];
    final uvMode = _bits.tree(
      _intraModeTree,
      keyUvModeProbabilities,
      yMode * 9,
    );
    var quant = _header.quantization.base;
    if (features?[0] case final delta?) {
      quant = (_header.segmentation.absolute ? delta : quant + delta).clamp(
        0,
        255,
      );
    }
    final blockWidth = math.max(width, 8), blockHeight = math.max(height, 8);
    final planes = [picture.y, picture.u, picture.v];
    for (var i = 0; i < 3; i++) {
      final chroma = i != 0;
      final sx = chroma ? _header.color.subX : 0,
          sy = chroma ? _header.color.subY : 0;
      final planeWidth = blockWidth >> sx, planeHeight = blockHeight >> sy;
      final planeTx = math.min(
        tx,
        math.min(planeWidth, planeHeight).bitLength - 3,
      );
      final plane = planes[i];
      final size = 4 << planeTx;
      for (var j = 0; j < planeHeight; j += size) {
        for (var k = 0; k < planeWidth; k += size) {
          final px = ((x * 8) >> sx) + k, py = ((y * 8) >> sy) + j;
          final mode = chroma
              ? uvMode
              : subBlock
              ? _modes[(j >> 2) * 2 + (k >> 2)]
              : yMode;
          var nonzero = 0;
          if (px < plane.paddedWidth && py < plane.paddedHeight) {
            _predictor.predict(
              plane,
              px,
              py,
              size,
              mode,
              haveAbove: haveAbove || j > 0,
              haveLeft: haveLeft || k > 0,
              haveAboveRight: k + size < planeWidth,
              midpoint: 1 << (_header.color.depth - 1),
            );
            if (!skip)
              nonzero = _coefficients(plane, i, px, py, planeTx, mode, quant);
          }
          final c = _aboveCoefficients[i], r = _leftCoefficients[i];
          final startY = (py >> 2) & (15 >> sy);
          c.fillRange(px >> 2, (px + size) >> 2, nonzero);
          r.fillRange(startY, startY + (size >> 2), nonzero);
        }
      }
    }
    if (_header.filter.level != 0) {
      _loopFilter.remember(x, y, width, height, tx, segment);
    }
    final right = math.min(x + (blockWidth >> 3), _header.miColumns);
    final bottom = math.min(y + (blockHeight >> 3), _header.miRows);
    for (var i = x; i < right; i++) {
      _aboveSkip[i] = skip ? 1 : 0;
      _aboveTx[i] = tx;
      _aboveModes[i * 2] = _modes[2];
      _aboveModes[i * 2 + 1] = _modes[3];
    }
    for (var i = y; i < bottom; i++) {
      _leftSkip[i & 7] = skip ? 1 : 0;
      _leftTx[i & 7] = tx;
      _leftModes[(i & 7) * 2] = _modes[1];
      _leftModes[(i & 7) * 2 + 1] = _modes[3];
    }
  }

  int _coefficients(
    Vp9Plane plane,
    int index,
    int x,
    int y,
    int tx,
    int mode,
    int quant,
  ) {
    final chroma = index != 0, lossless = _header.lossless;
    final sy = chroma ? _header.color.subY : 0;
    final y4 = (y >> 2) & (15 >> sy), x4 = x >> 2;
    final size = 4 << tx;
    var a = 0, l = 0;
    for (var i = 0; i < 1 << tx; i++) {
      if (x + i * 4 < plane.paddedWidth) a |= _aboveCoefficients[index][x4 + i];
      if (y + i * 4 < plane.paddedHeight) l |= _leftCoefficients[index][y4 + i];
    }
    final type = chroma || tx == 3 || lossless
        ? Vp9TransformType.dct
        : vp9IntraTransforms[mode];
    final scan = _scans[tx][type.index];
    final q = _header.quantization, depth = _header.color.depth;
    final row = ((depth - 8) >> 1) * 256;
    final dc =
        dcQuantizers[row + (quant + (chroma ? q.uvDc : q.yDc)).clamp(0, 255)];
    final ac =
        acQuantizers[row + (quant + (chroma ? q.uvAc : 0)).clamp(0, 255)];
    var context = a + l, count = 0;
    var checkEnd = true;
    for (final (i, position) in scan.indexed) {
      final band = tx == 0
          ? _bandsSmall[i]
          : i < 10
          ? _bandsSmall[i]
          : i < 21
          ? 4
          : 5;
      if (i > 0) {
        final col = position % size;
        final above = position - size, left = position - 1;
        final first =
            above < 0 || col > 0 && type == Vp9TransformType.verticalAdst
            ? left
            : above;
        final second =
            col == 0 || above >= 0 && type == Vp9TransformType.horizontalAdst
            ? above
            : left;
        context = (1 + _energy[first] + _energy[second]) >> 1;
      }
      final offset = Vp9IntraEntropy.coefficientOffset(
        tx,
        chroma ? 1 : 0,
        0,
        band,
        context,
      );
      final probabilities = entropy.coefficients;
      if (checkEnd && _bits.bit(probabilities[offset]) == 0) break;
      var node = 0;
      do {
        final p = node >> 1;
        final probability = p < 2
            ? probabilities[offset + p + 1]
            : _pareto(probabilities[offset + 2], p - 2);
        node = _coefficientTree[node + _bits.bit(probability)];
      } while (node > 0);
      final token = -node;
      _energy[position] = _coefficientEnergy[token];
      if (i == 0) _residual.fillRange(0, size * size, 0);
      checkEnd = token != 0;
      if (checkEnd) {
        var extra = 0;
        if (token == 10) {
          for (var k = 8; k < depth; k++) {
            extra = (extra << 1) | _bits.bit(255);
          }
        }
        for (final probability in _extraCoefficientBits[token]) {
          extra = (extra << 1) | _bits.bit(probability);
        }
        var value = (_coefficientBase[token] + extra) * (i == 0 ? dc : ac);
        if (tx == 3) value >>= 1;
        if (_bits.bit(128) != 0) value = -value;
        _residual[position] = value;
      }
      count++;
    }
    if (count == 0) return 0;
    _transform.apply(_residual, tx, type, lossless);
    final max = (1 << depth) - 1;
    for (var j = 0; j < size; j++) {
      final start = (y + j) * plane.stride + x;
      for (var i = 0; i < size; i++) {
        plane.samples[start + i] =
            (plane.samples[start + i] + _residual[j * size + i]).clamp(0, max);
      }
    }
    return 1;
  }
}

int _pareto(int probability, int node) {
  final index = ((probability - 1) >> 1) * 8 + node;
  final lower = coefficientParetoProbabilities[index];
  return probability.isOdd
      ? lower
      : (lower + coefficientParetoProbabilities[index + 8]) >> 1;
}
