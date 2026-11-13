import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as image;

import 'bitstream.dart';
import 'coefficients.dart';
import 'entropy_context.dart';
import 'frame_parameters.dart';
import 'inter_cdfs.dart';
import 'inter_prediction.dart';
import 'inter_syntax.dart';
import 'intra_cdfs.dart';
import 'intra_prediction.dart';
import 'motion_vectors.dart';
import 'quantizer.dart';
import 'quantizer_tables.dart';
import 'range_encoder.dart';
import 'transform.dart';

part 'block_motion_search.dart';

const defaultAvifPreset = 8;
const maxAvifPreset = 13;

/// 10-bit 4:2:0 AV1 with quantized DCT residuals and one temporal reference.
final class Av1DctEncoder {
  Av1DctEncoder(
    this.width,
    this.height, {
    required this.still,
    required this.qIndex,
    this.preset = defaultAvifPreset,
  }) {
    if (width < 1 ||
        height < 1 ||
        width > 4096 ||
        height > 2304 ||
        ((width + 63) ~/ 64) * ((height + 63) ~/ 64) > 2304 ||
        width * height > 8912896) {
      throw const FormatException(
        'AV1 encoder dimensions exceed a Level 5.1 tile',
      );
    }
    if (qIndex < 1 || qIndex > 255) {
      throw const FormatException(
        'AV1 transform quantizer must be between 1 and 255',
      );
    }
    if (preset < 0 || preset > maxAvifPreset) {
      throw const FormatException(
        'AV1 preset must be between 0 and $maxAvifPreset',
      );
    }
  }

  static const profile = 0, level = 13, depth = 10, matrix = 6;
  final int width, height, qIndex, preset;
  final bool still;
  late final Uint8List sequence = _sequence();
  List<Uint16List>? _reference;
  Av1EntropyContext? _referenceContext;
  static const _keyframeInterval = 32;
  int _framesSinceKey = _keyframeInterval;
  bool _referenceShowable = false;
  bool get nextIsKeyframe => still || _framesSinceKey >= _keyframeInterval;

  Uint8List _sequence() {
    final bits = BitWriter()
      ..write(profile, 3)
      ..write(still ? 3 : 0, 2);
    if (!still) bits.write(0, 19); // no timing model, one operating point
    bits.write(level, 5);
    if (!still) bits.write(0, 1); // main tier
    final wb = math.max(1, (width - 1).bitLength);
    final hb = math.max(1, (height - 1).bitLength);
    bits
      ..write(wb - 1, 4)
      ..write(hb - 1, 4)
      ..write(width - 1, wb)
      ..write(height - 1, hb);
    if (!still) bits.write(0, 1); // no frame IDs
    bits.write(0, 3); // 64×64 superblocks, plain intra edges
    if (!still) bits.write(0, 7); // inter tools and screen content disabled
    bits
      ..write(0, 3) // no super-resolution, CDEF or restoration
      ..write(5, 3) // 10-bit, color, explicit color description
      ..write(2, 8) // unspecified primaries
      ..write(2, 8) // unspecified transfer
      ..write(matrix, 8)
      ..write(0, 1) // limited range
      ..write(0, 4); // unspecified chroma location, shared UV delta, no grain
    return obu(1, bits.finish(trailingBit: true));
  }

  Uint8List frame(image.Image pixels) {
    if (pixels.width != width || pixels.height != height) {
      throw const FormatException('AV1 frame dimensions changed');
    }
    return _encode(pixels, keyframe: nextIsKeyframe);
  }

  Uint8List repeat() {
    if (_reference == null || still) {
      throw StateError('No animated AV1 frame to repeat');
    }
    if (_referenceShowable) {
      _framesSinceKey++;
      final bits = BitWriter()..write(8, 4); // show_existing_frame, slot 0
      return obu(3, bits.finish(trailingBit: true));
    }
    // A shown keyframe cannot be selected by show_existing_frame. First
    // publish the same reconstruction as a showable, all-skip inter picture.
    return _encode(null, keyframe: false);
  }

  Uint8List _encode(image.Image? pixels, {required bool keyframe}) {
    final inter = !keyframe;
    final priorContext = inter ? _referenceContext : null;
    final newSegmentation = inter && priorContext == null;
    final bits = BitWriter();
    if (!still) bits.write(inter ? 3 : 1, 4); // shown inter or keyframe
    if (inter) bits.write(0, 1); // permit the last reference's entropy context
    bits.write(0, 1); // adapt tile probabilities
    if (still) {
      bits.write(0, 1); // no screen content tools
    } else {
      bits.write(0, 1); // use sequence dimensions
    }
    if (inter) {
      bits
        ..write(0, 3) // primary reference is LAST_FRAME
        ..write(1, 8) // update slot 0
        ..write(0, 21); // each reference type points to slot 0
    }
    bits.write(0, 1); // render size matches
    if (inter) {
      bits.write(
        0,
        5,
      ); // no high precision, fixed regular filter, simple motion
    }
    if (!still)
      bits.write(inter ? 0 : 1, 1); // retain adapted inter probabilities
    bits.write(1, 1); // uniform tiles
    if (width > 64) bits.write(0, 1); // one column
    if (height > 64) bits.write(0, 1); // one row
    bits
      ..write(qIndex, 8)
      ..write(0, 4) // no quantizer deltas or matrices
      ..write(inter ? 1 : 0, 1);
    if (inter) {
      bits.write(newSegmentation ? 1 : 0, 1); // update the map after a keyframe
      if (newSegmentation) {
        bits
          ..write(0, 1) // no temporal segment prediction
          ..write(1, 1) // set segmentation features
          ..write(0, 5)
          ..write(9, 4) // segment zero uses LAST_FRAME
          ..write(0, 2) // no forced skip or global motion
          ..write(0, 56); // remaining segments have no enabled features
      } else {
        bits.write(0, 1); // inherit the segment features as well as the map
      }
    }
    bits
      ..write(0, 1) // no delta-Q
      ..write(0, 16) // no loop filter, sharpness or deltas
      ..write(0, 1); // largest transform in each block
    if (inter) bits.write(0, 1); // single reference
    bits.write(1, 1); // reduced transform set
    if (inter) bits.write(0, 7); // identity global motion for every reference
    final tile = _DctTile(
      width,
      height,
      pixels,
      qIndex,
      preset,
      reference: inter ? _reference : null,
      priorContext: priorContext,
    );
    final payload = BytesBuilder(copy: false)
      ..add(bits.finish())
      ..add(tile.encode());
    if (!still && pixels != null) _reference = tile.reconstructed;
    _referenceContext = inter ? tile._context : null;
    _framesSinceKey = keyframe ? 1 : _framesSinceKey + 1;
    _referenceShowable = inter;
    return obu(6, payload.takeBytes());
  }
}

enum _Syntax { partition, segment, skip, luma, angle, chroma, transform }

final class _DctTile {
  _DctTile(
    this.width,
    this.height,
    image.Image? pixels,
    this.q,
    this.preset, {
    required this.reference,
    required Av1EntropyContext? priorContext,
  }) : columns = 2 * ((width + 7) >> 3),
       rows = 2 * ((height + 7) >> 3),
       newSegmentation = reference != null && priorContext == null,
       _context = priorContext?.copy(resetCount: true) ?? Av1EntropyContext(q),
       repeat = pixels == null {
    if (pixels == null) return;
    _planes = [
      _DctPlane(columns * 4, rows * 4),
      _DctPlane(columns * 2, rows * 2),
      _DctPlane(columns * 2, rows * 2),
    ];
    final input = pixels.getBytes(order: image.ChannelOrder.rgb);
    final y = _planes[0], cb = _planes[1], cr = _planes[2];
    for (var row = 0; row < y.height; row += 2) {
      for (var col = 0; col < y.stride; col += 2) {
        var sumU = 0, sumV = 0;
        for (var dy = 0; dy < 2; dy++) {
          final sy = math.min(row + dy, pixels.height - 1);
          for (var dx = 0; dx < 2; dx++) {
            final sx = math.min(col + dx, pixels.width - 1);
            final at = (sy * pixels.width + sx) * 3;
            final r = input[at], g = input[at + 1], b = input[at + 2];
            // BT.601 coefficients scaled to the 10-bit studio range in Q16.
            y.source[(row + dy) * y.stride + col + dx] =
                64 + av1Round(67315 * r + 132155 * g + 25665 * b, 16);
            sumU += -38856 * r - 76282 * g + 115138 * b;
            sumV += 115138 * r - 96413 * g - 18724 * b;
          }
        }
        final uv = (row >> 1) * cb.stride + (col >> 1);
        cb.source[uv] = 512 + av1Round(sumU, 18);
        cr.source[uv] = 512 + av1Round(sumV, 18);
      }
    }
  }

  final int width, height, q, preset, columns, rows;
  final List<Uint16List>? reference;
  final bool repeat;
  final bool newSegmentation;
  bool get inter => reference != null;
  List<Uint16List> get reconstructed => [
    for (final plane in _planes) plane.reconstructed,
  ];
  final _range = RangeEncoder();
  final Av1EntropyContext _context;
  late final _coefficients = Av1CoefficientEncoder(
    _range,
    _context.coefficients,
  );
  late final _quantizer = Av1Quantizer((
    base: q,
    yDc: 0,
    uDc: 0,
    uAc: 0,
    vDc: 0,
    vAc: 0,
    matrix: null,
  ), Av1DctEncoder.depth);
  final _predictor = Av1IntraPredictor();
  late final _interPredictor = Av1InterPredictor();
  late final _motionWriter = Av1SingleReferenceMotionEncoder(_range, _context);
  late final _motionSearch = _BlockMotionSearch(
    width,
    height,
    _planes[0].stride,
    _planes[0].source,
    reference![0],
    av1AcQuantizers[1][q],
    preset,
  );
  final _forward = _ForwardDct();
  final _inverse = Av1InverseTransform();
  final _residual = Int32List(256);
  final _dequantizedTrial = Int32List(256);
  late final List<_DctPlane> _planes;
  late final _blockSizes = Uint8List(columns * rows);
  late final _skips = Uint8List(columns * rows);
  late final _lumaContexts = Uint8List(columns * rows);
  late final _motionBlocks = List<Av1InterNeighbor?>.filled(
    columns * rows,
    null,
  );

  Uint8List encode() {
    for (var y = 0; y < rows; y += 16) {
      for (var x = 0; x < columns; x += 16) {
        _partition(x, y, 16);
      }
    }
    return _range.finish();
  }

  void _partition(int x, int y, int side) {
    if (x >= columns || y >= rows) return;
    final half = side >> 1;
    final hasRows = y + half < rows, hasCols = x + half < columns;
    final split = side > 4 || !hasRows || !hasCols;
    if (hasRows || hasCols) {
      final level = side.bitLength - 2;
      final at = y * columns + x;
      final context =
          (y > 0 && _blockSizes[at - columns] < side ? 1 : 0) +
          (x > 0 && _blockSizes[at - 1] < side ? 2 : 0);
      final table = _context.cdf((
        _Syntax.partition,
        level,
        context,
      ), partitionCdf[level][context]);
      if (hasRows && hasCols) {
        _range.adaptive(table, split ? 3 : 0);
      } else {
        _range.symbol(
          partitionEdgeCdf(table.cumulative, rightEdge: !hasCols),
          1,
        );
      }
    }
    if (!split) {
      _block(x, y, side);
      return;
    }
    _partition(x, y, half);
    _partition(x + half, y, half);
    _partition(x, y + half, half);
    _partition(x + half, y + half, half);
  }

  void _block(int x4, int y4, int side) {
    final at = y4 * columns + x4;
    final skipContext =
        (y4 == 0 ? 0 : _skips[at - columns]) + (x4 == 0 ? 0 : _skips[at - 1]);
    final stack = inter ? _stack(x4, y4, side) : null;
    var mv = stack == null || repeat
        ? av1ZeroMv
        : _motionSearch.find(x4 * 4, y4 * 4, side * 4, stack);
    var skip = true;
    var luma = Av1IntraMode.dc;
    if (!repeat) {
      final moving = mv != av1ZeroMv;
      final searchIntra =
          !inter && preset < defaultAvifPreset && (x4 > 0 || y4 > 0);
      final candidate = _prepareBlock(
        x4,
        y4,
        side,
        mv,
        measure: moving || searchIntra,
      );
      skip = candidate.rate == 0;
      if (searchIntra) {
        final best = _searchIntra(x4, y4, side, candidate);
        luma = best.mode;
        skip = best.rate == 0;
      } else if (moving) {
        for (final plane in _planes) {
          plane.swapTrial();
        }
        final stationary = _prepareBlock(
          x4,
          y4,
          side,
          av1ZeroMv,
          measure: true,
        );
        final motionRate =
            candidate.rate +
            Av1SingleReferenceMotionEncoder.estimatedBits(stack!, mv);
        // Check all planes after transform quantization. A luma match can
        // leave more chroma residual or less accurately reconstructed detail.
        if (motionRate < stationary.rate &&
            candidate.error <= stationary.error) {
          for (final plane in _planes) {
            plane.swapTrial();
          }
        } else {
          mv = av1ZeroMv;
          skip = stationary.rate == 0;
        }
      }
    }
    if (newSegmentation) {
      final ctx = x4 == 0 || y4 == 0 ? 0 : 2;
      _range.adaptive(
        _context.cdf((_Syntax.segment, ctx), intraSegmentCdfs[ctx]),
        0,
      );
    }
    _range.adaptive(
      _context.cdf((_Syntax.skip, skipContext), skipCdf[skipContext]),
      skip ? 1 : 0,
    );
    if (!inter) {
      final above = y4 == 0 ? 0 : _lumaContexts[at - columns];
      final left = x4 == 0 ? 0 : _lumaContexts[at - 1];
      _range.adaptive(
        _context.cdf((_Syntax.luma, above, left), intraLumaCdfs[above][left]),
        luma.index,
      );
      if (luma.directional) {
        final angle = intraAngleCdfs[luma.index - 1];
        _range.adaptive(_context.cdf((_Syntax.angle, luma.index), angle), 3);
      }
      _range.adaptive(
        _context.cdf((_Syntax.chroma, luma.index), intraUvCdfs[1][luma.index]),
        0,
      );
    }
    final motion = stack == null ? null : _motionWriter.write(stack, mv);
    final motionBlock = motion == null
        ? null
        : (width4: side, height4: side, motion: motion);
    for (var row = y4; row < y4 + side; row++) {
      final start = row * columns + x4;
      _blockSizes.fillRange(start, start + side, side);
      _skips.fillRange(start, start + side, skip ? 1 : 0);
      if (!inter) {
        _lumaContexts.fillRange(
          start,
          start + side,
          intraLumaModeContext[luma.index],
        );
      }
      if (motionBlock != null)
        _motionBlocks.fillRange(start, start + side, motionBlock);
    }
    if (repeat) return;
    for (final (p, plane) in _planes.indexed) {
      final shift = p == 0 ? 2 : 1;
      final x = x4 << shift, y = y4 << shift;
      final n = side << shift, size = Av1TxSize.of(n, n);
      if (skip) {
        plane.neighbors.stamp(x >> 2, y >> 2, n >> 2, n >> 2, 0, 0);
      } else {
        _coefficients.write(
          plane.coefficients,
          neighbors: plane.neighbors,
          x4: x >> 2,
          y4: y >> 2,
          blockWidth: n,
          blockHeight: n,
          size: size,
          type: Av1TxType.dctDct,
          chroma: p != 0,
          writeType: () {
            if (p == 0) {
              final table = inter
                  ? interInterTxTypeSet3Cdf[size.square]
                  : intraTxTypeCdfs[1][size.square][luma.index];
              final key = (_Syntax.transform, size.square, luma.index);
              _range.adaptive(_context.cdf(key, table), 1);
            }
          },
        );
        _inverseResidual(plane.coefficients, size, p);
      }
      for (var row = 0; row < n; row++) {
        final start = (y + row) * plane.stride + x;
        if (skip) {
          plane.reconstructed.setRange(
            start,
            start + n,
            plane.prediction,
            row * n,
          );
        } else {
          for (var col = 0; col < n; col++) {
            final i = row * n + col;
            plane.reconstructed[start +
                col] = (plane.prediction[i] + _residual[i]).clamp(
              0,
              (1 << Av1DctEncoder.depth) - 1,
            );
          }
        }
      }
    }
  }

  ({Av1IntraMode mode, int rate}) _searchIntra(
    int x4,
    int y4,
    int side,
    ({int rate, int error}) dc,
  ) {
    final quantStep = av1AcQuantizers[1][q];
    final lambda = math.max(1, quantStep * quantStep >> 4);
    var bestCost = dc.error + lambda * dc.rate;
    var bestMode = Av1IntraMode.dc, bestRate = dc.rate;
    for (final mode in [
      if (y4 > 0) Av1IntraMode.vertical,
      if (x4 > 0) Av1IntraMode.horizontal,
      if (preset <= 3 && x4 > 0 && y4 > 0) ...[
        Av1IntraMode.smooth,
        Av1IntraMode.paeth,
      ],
    ]) {
      for (final plane in _planes) {
        plane.swapTrial();
      }
      final trial = _prepareBlock(
        x4,
        y4,
        side,
        av1ZeroMv,
        measure: true,
        luma: mode,
      );
      // Include the mode symbol and, for directional modes, its zero angle.
      final cost =
          trial.error + lambda * (trial.rate + (mode.directional ? 4 : 2));
      if (cost < bestCost) {
        bestMode = mode;
        bestCost = cost;
        bestRate = trial.rate;
      } else {
        for (final plane in _planes) {
          plane.swapTrial();
        }
      }
    }
    return (mode: bestMode, rate: bestRate);
  }

  ({int rate, int error}) _prepareBlock(
    int x4,
    int y4,
    int side,
    Av1Mv mv, {
    required bool measure,
    Av1IntraMode luma = Av1IntraMode.dc,
  }) {
    var rate = 0;
    var error = 0;
    final dc = av1DcQuantizers[1][q], ac = av1AcQuantizers[1][q];
    // A wider zero bin omits small inter AC differences while retaining the
    // same quantizer step for DC and larger AC coefficients.
    final acDeadZone = inter ? 0.75 : 0.5;
    for (final (p, plane) in _planes.indexed) {
      final shift = p == 0 ? 2 : 1;
      final n = side << shift;
      final x = x4 << shift, y = y4 << shift;
      final size = Av1TxSize.of(n, n);
      _predict(plane, p, x, y, size, mv, p == 0 ? luma : Av1IntraMode.dc);
      final levels = _forward.quantize(plane, x, y, size, dc, ac, acDeadZone);
      rate += levels;
      if (measure) {
        error +=
            _reconstructionError(plane, p, x, y, size, levels != 0) *
            (p == 0 ? 1 : 3);
      }
    }
    return (rate: rate, error: error);
  }

  int _reconstructionError(
    _DctPlane plane,
    int p,
    int x,
    int y,
    Av1TxSize size,
    bool residual,
  ) {
    final n = size.width;
    if (residual) {
      _dequantizedTrial.setRange(0, n * n, plane.coefficients);
      _inverseResidual(_dequantizedTrial, size, p);
    }
    final sub = p == 0 ? 0 : 1;
    final w = math.min(n, ((width + sub) >> sub) - x);
    final h = math.min(n, ((height + sub) >> sub) - y);
    const maximum = (1 << Av1DctEncoder.depth) - 1;
    var error = 0;
    for (var row = 0; row < h; row++) {
      final start = (y + row) * plane.stride + x;
      for (var col = 0; col < w; col++) {
        final i = row * n + col;
        final sample = (plane.prediction[i] + (residual ? _residual[i] : 0))
            .clamp(0, maximum);
        final delta = plane.source[start + col] - sample;
        error += delta * delta;
      }
    }
    return error;
  }

  void _inverseResidual(Int32List coefficients, Av1TxSize size, int p) {
    _quantizer.apply(
      coefficients,
      size,
      Av1TxType.dctDct,
      p,
      currentQ: q,
      segmentDelta: 0,
    );
    _inverse.apply(
      coefficients,
      _residual,
      size,
      Av1TxType.dctDct,
      Av1DctEncoder.depth,
      lossless: false,
    );
  }

  bool _inside(int x, int y) => x >= 0 && x < columns && y >= 0 && y < rows;

  Av1InterNeighbor? _neighbor(int x, int y) =>
      _inside(x, y) ? _motionBlocks[y * columns + x] : null;

  Av1MvStack _stack(int x, int y, int side) => av1FindMvStack(
    x: x,
    y: y,
    width4: side,
    height4: side,
    columns: columns,
    rows: rows,
    ref0: 1,
    ref1: -1,
    highPrecision: false,
    integer: false,
    globals: const [av1IdentityGlobalMotion],
    distance: (_) => 0,
    neighbor: _neighbor,
    temporal: null,
    inTile: _inside,
  );

  void _predict(
    _DctPlane plane,
    int p,
    int x,
    int y,
    Av1TxSize size,
    Av1Mv mv,
    Av1IntraMode mode,
  ) {
    final n = size.width;
    if (reference case final prior?) {
      final sub = p == 0 ? 0 : 1;
      final fractionBits = 3 + sub;
      if ((mv.x | mv.y) & ((1 << fractionBits) - 1) != 0) {
        final output = _interPredictor.first;
        _interPredictor.convolve(
          output,
          prior[p],
          stride: plane.stride,
          referenceWidth: width,
          referenceHeight: height,
          frameWidth: width,
          frameHeight: height,
          x: x,
          y: y,
          width: n,
          height: n,
          sx: sub,
          sy: sub,
          mv: mv,
          filterX: 0,
          filterY: 0,
          depth: Av1DctEncoder.depth,
          compound: false,
        );
        final maximum = (1 << Av1DctEncoder.depth) - 1;
        for (var i = 0; i < n * n; i++) {
          plane.prediction[i] = output[i].clamp(0, maximum);
        }
        return;
      }
      final w = (width + sub) >> sub, h = (height + sub) >> sub;
      final startX = x + (mv.x >> fractionBits),
          startY = y + (mv.y >> fractionBits);
      for (var row = 0; row < n; row++) {
        final at = (startY + row).clamp(0, h - 1) * plane.stride;
        for (var col = 0; col < n; col++) {
          plane.prediction[row * n + col] =
              prior[p][at + (startX + col).clamp(0, w - 1)];
        }
      }
    } else {
      _predictor.predict(
        plane.reconstructed,
        plane.stride,
        x,
        y,
        size,
        depth: Av1DctEncoder.depth,
        mode: mode,
        angleDelta: 0,
        above: y > 0,
        left: x > 0,
        aboveRight: false,
        belowLeft: false,
        right: plane.stride,
        bottom: plane.height,
        edgeFilter: false,
        smoothEdge: false,
        recursiveFilter: null,
      );
      plane.prediction.setRange(0, n * n, _predictor.samples);
    }
  }
}

final class _DctPlane {
  _DctPlane(this.stride, this.height)
    : source = Uint16List(stride * height),
      reconstructed = Uint16List(stride * height),
      neighbors = Av1CoefficientNeighbors(stride >> 2, height >> 2);

  final int stride, height;
  final Uint16List source;
  final Uint16List reconstructed;
  final Av1CoefficientNeighbors neighbors;
  var _block = _DctBlock(), _trial = _DctBlock();
  Int32List get coefficients => _block.coefficients;
  Uint16List get prediction => _block.prediction;

  void swapTrial() {
    final prior = _block;
    _block = _trial;
    _trial = prior;
  }
}

final class _DctBlock {
  final coefficients = Int32List(256);
  final prediction = Uint16List(256);
}

final class _ForwardDct {
  static const _bits = 12;
  static final _basis = {
    for (final n in [4, 8, 16])
      n: Int32List.fromList([
        for (var f = 0; f < n; f++)
          for (var i = 0; i < n; i++)
            ((f == 0
                        ? math.sqrt1_2
                        : math.cos((2 * i + 1) * f * math.pi / (2 * n))) *
                    (1 << _bits))
                .round(),
      ]),
  };
  final _rows = Int32List(256);

  int quantize(
    _DctPlane plane,
    int x,
    int y,
    Av1TxSize size,
    int dc,
    int ac,
    double deadZone,
  ) {
    final n = size.width;
    final basis = _basis[n]!;
    for (var row = 0; row < n; row++) {
      final source = (y + row) * plane.stride + x;
      for (var f = 0; f < n; f++) {
        var sum = 0;
        for (var i = 0; i < n; i++) {
          sum +=
              basis[f * n + i] *
              (plane.source[source + i] - plane.prediction[row * n + i]);
        }
        _rows[row * n + f] = sum;
      }
    }
    // The inverse kernels use unnormalized cosines and the final 4-bit shift.
    // Apply the inverse of that gain while dividing by the AV1 quantizer step.
    final denominator = (n * n) << (2 * _bits);
    final gain = 1 << (size.rowShift + size.quantShift + 6);
    final scaleDc = gain / (denominator * dc);
    final scaleAc = gain / (denominator * ac);
    var rate = 0;
    for (var f = 0; f < n; f++) {
      for (var col = 0; col < n; col++) {
        var sum = 0;
        for (var i = 0; i < n; i++) {
          sum += basis[f * n + i] * _rows[i * n + col];
        }
        final idx = f * n + col;
        final scaled = sum * (idx == 0 ? scaleDc : scaleAc);
        final level = idx != 0 && scaled.abs() < deadZone ? 0 : scaled.round();
        plane.coefficients[idx] = level;
        if (level != 0) rate += 2 + level.abs().bitLength;
      }
    }
    return rate;
  }
}
