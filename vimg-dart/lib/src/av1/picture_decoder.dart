import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as image;

import '../yuv_image.dart';
import 'access_units.dart';
import 'bitstream.dart';
import 'cdef.dart';
import 'coefficients.dart';
import 'entropy_context.dart';
import 'frame_header.dart';
import 'frame_parameters.dart';
import 'inter_cdfs.dart';
import 'inter_prediction.dart';
import 'inter_prediction_tables.dart' show av1IiWeights1D;
import 'inter_syntax.dart';
import 'intra_cdfs.dart';
import 'intra_prediction.dart';
import 'loop_filter.dart';
import 'motion_vectors.dart';
import 'palette_reader.dart';
import 'quantizer.dart';
import 'range_decoder.dart';
import 'sequence_header.dart';
import 'tile_group.dart';
import 'transform.dart';
import 'warp.dart';

part 'film_grain.dart';
part 'film_grain_table.dart';
part 'inter_reconstruction.dart';
part 'motion_field.dart';
part 'restoration.dart';
part 'superres.dart';

final class Av1Plane {
  Av1Plane(this.width, this.height, int paddedWidth, int paddedHeight)
    : stride = paddedWidth,
      samples = Uint16List(paddedWidth * paddedHeight),
      decoded = Uint8List((paddedWidth >> 2) * (paddedHeight >> 2));

  final int width, height, stride;
  final Uint16List samples;
  final Uint8List decoded;

  bool isDecoded(int x, int y) {
    final w4 = stride >> 2;
    return x >= 0 &&
        x < w4 &&
        y >= 0 &&
        y * w4 + x < decoded.length &&
        decoded[y * w4 + x] != 0;
  }

  void markDecoded(int x4, int y4, Av1TxSize size) {
    final w4 = stride >> 2;
    for (var j = 0; j < size.height >> 2; j++) {
      final start = (y4 + j) * w4 + x4;
      decoded.fillRange(start, start + (size.width >> 2), size.index + 1);
    }
  }
}

/// AV1 sample planes at the upscaled frame dimensions.
final class Av1Picture {
  Av1Picture(this.color, this.planes);

  final Av1ColorConfig color;
  final List<Av1Plane> planes;

  image.Image rgb() => yuvImage(
    y: planes[0].samples,
    cb: color.monochrome ? const [] : planes[1].samples,
    cr: color.monochrome ? const [] : planes[2].samples,
    stride: planes[0].stride,
    chromaStride: color.monochrome ? 0 : planes[1].stride,
    width: planes[0].width,
    height: planes[0].height,
    cropLeft: 0,
    cropTop: 0,
    matrix: color.matrix,
    fullRange: color.fullRange,
    lumaDepth: color.depth,
    chromaDepth: color.depth,
    subsamplingX: color.subsamplingX,
    subsamplingY: color.subsamplingY,
  );
}

image.Image decodeAv1IntraImage(Av1CodedFrame frame) => applyAv1FilmGrain(
  decodeAv1Intra(frame),
  frame.header.parameters.filmGrain,
).rgb();

Av1Picture decodeAv1Intra(
  Av1CodedFrame frame, {
  bool deblock = true,
  bool cdef = true,
}) {
  if (!frame.header.type.intra || frame.syntax.existingSlot != null) {
    throw const FormatException('Expected a coded AV1 intra picture');
  }
  return _decodePicture(frame, const [], deblock, cdef).picture;
}

typedef _DecodedPicture = ({
  Av1Picture picture,
  _FrameState state,
  Av1EntropyContext context,
  Av1FrameHeader header,
  List<int> referenceHints,
});

/// Decode-order picture buffers and probability state for AV1 references.
final class Av1StreamDecoder {
  Av1StreamDecoder({this.deblock = true, this.cdef = true});

  final bool deblock, cdef;
  final _slots = List<_DecodedPicture?>.filled(8, null);
  Av1SequenceHeader? _sequence;

  Av1Picture decode(Av1CodedFrame frame) {
    final sequence = _sequence;
    if (sequence != null && !frame.sequence.sameCodedSequence(sequence)) {
      _slots.fillRange(0, 8, null);
    }
    _sequence = frame.sequence;
    final existing = frame.syntax.existingSlot;
    final _DecodedPicture result;
    if (existing != null) {
      final slot = _slots[existing];
      if (slot == null || !identical(slot.header, frame.header)) {
        throw const FormatException('Missing decoded AV1 reference picture');
      }
      result = slot;
    } else {
      result = _decodePicture(frame, _slots, deblock, cdef);
    }
    for (var i = 0; i < 8; i++) {
      if (frame.refreshFlags & (1 << i) != 0) {
        _slots[i] = result;
      } else if (existing == null &&
          frame.header.invalidatedSlots & (1 << i) != 0) {
        _slots[i] = null;
      }
    }
    return result.picture;
  }

  image.Image display(Av1CodedFrame frame, Av1Picture picture) =>
      applyAv1FilmGrain(picture, frame.header.parameters.filmGrain).rgb();
}

_DecodedPicture _decodePicture(
  Av1CodedFrame frame,
  List<_DecodedPicture?> slots,
  bool deblock,
  bool cdef,
) {
  final header = frame.header;
  final primary = header.primaryReference == null
      ? null
      : slots[header.primaryReference!];
  if (header.primaryReference != null && primary == null) {
    throw const FormatException('Missing AV1 primary reference context');
  }
  final references = [
    for (final slot in header.references)
      slots[slot] ??
          (throw const FormatException('Missing AV1 reference picture')),
  ];
  final startCdfs =
      primary?.context ??
      Av1EntropyContext(header.parameters.quantization.base);
  var endCdfs = startCdfs;
  final size = header.size, color = frame.sequence.color;
  if (size.upscaledWidth * size.height > 33554432) {
    throw UnsupportedError(
      'AV1 picture exceeds the 32 megapixel decoder limit',
    );
  }
  final sb = frame.sequence.tools.superblock128 ? 128 : 64;
  final paddedWidth = (size.width + sb - 1) & -sb;
  final paddedHeight = (size.height + sb - 1) & -sb;
  final planes = [
    Av1Plane(size.width, size.height, paddedWidth, paddedHeight),
    if (!color.monochrome)
      for (var i = 0; i < 2; i++)
        Av1Plane(
          (size.width + color.subsamplingX) >> color.subsamplingX,
          (size.height + color.subsamplingY) >> color.subsamplingY,
          paddedWidth >> color.subsamplingX,
          paddedHeight >> color.subsamplingY,
        ),
  ];
  final state = _FrameState(frame);
  final restoration = _RestorationFrame(frame, planes);
  final field = header.motion.referenceMvs
      ? _MotionField(frame, references, state)
      : null;
  for (final tile in frame.tiles) {
    final cdfs = startCdfs.copy(resetCount: true);
    _PictureTile(
      frame,
      tile,
      planes,
      state,
      cdfs,
      references,
      primary?.state,
      field,
      restoration,
    ).decode();
    if (header.refreshContext && tile.index == header.tiles.contextTile)
      endCdfs = cdfs;
  }
  final parameters = header.parameters;
  final filter = parameters.loopFilter;
  if (deblock && (filter.levels[0] != 0 || filter.levels[1] != 0)) {
    final sx = color.subsamplingX, sy = color.subsamplingY;
    for (final (i, plane) in planes.indexed) {
      if (i != 0 && filter.levels[i + 1] == 0) continue;
      av1DeblockPlane(
        plane.samples,
        plane.decoded,
        plane.stride,
        plane.width,
        plane.height,
        color.depth,
        filter.sharpness,
        chroma: i != 0,
        filterEdge: header.type.intra
            ? null
            : (x, y, pass) {
                final block = state.block(
                  i == 0 ? x : (x << sx) | sx,
                  i == 0 ? y : (y << sy) | sy,
                );
                if (block?.skip != true || block?.motion == null) return true;
                final sub = i == 0
                    ? 0
                    : pass == 0
                    ? sx
                    : sy;
                final span = pass == 0 ? block!.width : block!.height;
                return (pass == 0 ? x : y) % math.max(1, span >> sub) == 0;
              },
        levelAt: (x, y, pass) {
          final block = state.block(
            i == 0 ? x : (x << sx) | sx,
            i == 0 ? y : (y << sy) | sy,
          );
          if (block == null) return 0;
          final k = i == 0 ? pass : i + 1;
          return block.filterLevels[k];
        },
      );
    }
  }
  final upscalers = size.width == size.upscaledWidth
      ? null
      : [
          for (final (p, plane) in planes.indexed)
            _SuperresPlane.forPlane(
              plane,
              size,
              p == 0 ? 0 : color.subsamplingX,
            ),
        ];
  restoration.saveBoundaries(planes, upscalers, color.depth);
  final strengths = parameters.cdef;
  if (cdef && strengths != null) {
    Av1CdefFilter(
      strengths,
      color.depth,
      color.subsamplingX,
      color.subsamplingY,
    ).apply(
      [for (final plane in planes) plane.samples],
      [for (final plane in planes) plane.stride],
      size.width,
      size.height,
      index: (x, y) => state.cdef[(y >> 4) * state.cdefStride + (x >> 4)],
      skip: (x, y) => state.block(x, y)?.skip ?? true,
    );
  }
  final output = upscalers == null
      ? planes
      : [
          for (final (p, plane) in planes.indexed)
            upscalers[p]?.upscale(plane, color.depth) ?? plane,
        ];
  restoration.apply(output, color.depth);
  return (
    picture: Av1Picture(color, output),
    state: state,
    context: endCdfs,
    header: header,
    referenceHints: [
      for (final reference in references) reference.header.orderHint,
    ],
  );
}

// AV1 block-size ordinals index the mode and transform syntax tables.
const _blockSizes = [
  (4, 4),
  (4, 8),
  (8, 4),
  (8, 8),
  (8, 16),
  (16, 8),
  (16, 16),
  (16, 32),
  (32, 16),
  (32, 32),
  (32, 64),
  (64, 32),
  (64, 64),
  (64, 128),
  (128, 64),
  (128, 128),
  (4, 16),
  (16, 4),
  (8, 32),
  (32, 8),
  (16, 64),
  (64, 16),
];
final _blockIndex = {
  for (final (index, size) in _blockSizes.indexed) size: index,
};

const _splitTx = [0, 0, 1, 2, 3, 0, 0, 1, 1, 2, 2, 3, 3, 5, 6, 7, 8, 9, 10];
const _intraSet1 = [
  Av1TxType.identity,
  Av1TxType.dctDct,
  Av1TxType.vDct,
  Av1TxType.hDct,
  Av1TxType.adstAdst,
  Av1TxType.adstDct,
  Av1TxType.dctAdst,
];
const _intraSet2 = [
  Av1TxType.identity,
  Av1TxType.dctDct,
  Av1TxType.adstAdst,
  Av1TxType.adstDct,
  Av1TxType.dctAdst,
];
const _chromaTx = [
  Av1TxType.dctDct,
  Av1TxType.adstDct,
  Av1TxType.dctAdst,
  Av1TxType.dctDct,
  Av1TxType.adstAdst,
  Av1TxType.adstDct,
  Av1TxType.dctAdst,
  Av1TxType.dctAdst,
  Av1TxType.adstDct,
  Av1TxType.adstAdst,
  Av1TxType.adstDct,
  Av1TxType.dctAdst,
  Av1TxType.adstAdst,
  Av1TxType.dctDct,
];

enum _Partition {
  none,
  horizontal,
  vertical,
  split,
  horizontalA,
  horizontalB,
  verticalA,
  verticalB,
  horizontal4,
  vertical4,
}

enum _Family {
  partition,
  skip,
  segment,
  deltaQ,
  deltaLf,
  intrabc,
  luma,
  uv,
  angle,
  filter,
  filterMode,
  cflSign,
  cflAlpha,
  txSize,
  txType,
  paletteY,
  paletteUv,
  paletteYSize,
  paletteUvSize,
  inter,
  interLuma,
  skipMode,
  segmentPred,
  interTx,
  txSplit,
}

typedef _Block = ({
  int width,
  int height,
  int segment,
  bool skip,
  Av1IntraMode yMode,
  Av1IntraMode uvMode,
  Av1TxSize txSize,
  List<int> filterLevels,
  List<int>? paletteY,
  List<int>? paletteU,
  Av1InterMotion? motion,
  bool skipMode,
  bool segmentPredicted,
});

typedef _Palette = ({Uint8List map, List<int> colors, int offset});

final class _FrameState {
  _FrameState(Av1CodedFrame frame)
    : columns = frame.header.tiles.columns.last,
      rows = frame.header.tiles.rows.last;

  final int columns, rows;
  late final blocks = List<_Block?>.filled(columns * rows, null);
  late final txTypes = Uint8List(columns * rows);
  late final cdefStride = (columns + 15) >> 4;
  late final cdef = Int8List(cdefStride * ((rows + 15) >> 4))
    ..fillRange(0, cdefStride * ((rows + 15) >> 4), -1);

  _Block? block(int x, int y) => blocks[y * columns + x];
}

final class _PictureTile {
  _PictureTile(
    this.frame,
    this.tile,
    this.planes,
    this.state,
    this._context,
    this.references,
    this.prior,
    this.field,
    _RestorationFrame restoration,
  ) {
    final columns = frame.header.tiles.columns;
    final rows = frame.header.tiles.rows;
    final count = columns.length - 1;
    final col = tile.index % count, row = tile.index ~/ count;
    x0 = columns[col];
    y0 = rows[row];
    xEnd = columns[col + 1];
    yEnd = rows[row + 1];
    _width = xEnd - x0;
    _restoration = restoration.planes.any((plane) => plane != null)
        ? _RestorationTile(restoration, _reader, _context)
        : null;
    _neighbors = [
      for (var p = 0; p < planes.length; p++)
        Av1CoefficientNeighbors(
          _width >> (p == 0 ? 0 : sx),
          (yEnd - y0) >> (p == 0 ? 0 : sy),
        ),
    ];
  }

  final Av1CodedFrame frame;
  final Av1Tile tile;
  final List<Av1Plane> planes;
  final _FrameState state;
  final _FrameState? prior;
  final _MotionField? field;
  late final _RestorationTile? _restoration;
  final List<_DecodedPicture> references;
  final Av1EntropyContext _context;
  late final int x0, y0, xEnd, yEnd, _width;
  late final _reader = RangeDecoder(
    Av1Bits(tile.payload),
    updateCdf: !frame.header.disableCdfUpdate,
  );
  late final _coefficientDecoder = Av1CoefficientDecoder(
    _reader,
    _context.coefficients,
  );
  late final _quantizer = Av1Quantizer(params.quantization, color.depth);
  final _predictor = Av1IntraPredictor();
  late final _palette = Av1PaletteReader(
    _reader,
    color.depth,
    context: _context,
  );
  late final _motionSyntax = Av1InterSyntax(
    _reader,
    _context,
    frame.header,
    frame.sequence.tools,
  );
  late final _inter = Av1InterPredictor();
  late final _warp = Av1WarpPredictor();
  final _yMap = Uint8List(64 * 64);
  final _uvMap = Uint8List(64 * 64);
  final _inverse = Av1InverseTransform();
  final _quantized = Int32List(1024);
  final _residual = Int32List(4096);
  late final List<Av1CoefficientNeighbors> _neighbors;
  late final sb4 = frame.sequence.tools.superblock128 ? 32 : 16;
  late final _segPreSkip = params.segmentation.features.any(
    (features) => features.skip(5).any((feature) => feature != null),
  );
  late final _segmentCount =
      1 +
      params.segmentation.features
          .lastIndexWhere(
            (features) => features.any((feature) => feature != null),
          )
          .clamp(0, 7);
  late var _currentQ = params.quantization.base;
  var _readDeltas = false;
  final _deltaLf = Int8List(4);
  final _lfLevels = <int, List<int>>{};
  var _lumaRight = 0, _lumaBottom = 0;

  Av1FrameParameters get params => frame.header.parameters;
  Av1ColorConfig get color => frame.sequence.color;
  int get sx => color.subsamplingX;
  int get sy => color.subsamplingY;

  void decode() {
    for (var y = y0; y < yEnd; y += sb4) {
      for (var x = x0; x < xEnd; x += sb4) {
        _restoration?.readSuperblock(x, y, sb4);
        _readDeltas = params.deltaQShift != null;
        _partition(x, y, sb4);
      }
    }
    _reader.finish();
  }

  _Block? _at(int x, int y) =>
      x < x0 || y < y0 || x >= xEnd || y >= yEnd ? null : state.block(x, y);

  Av1Cdf _cdf(
    _Family family,
    List<int> initial, [
    int a = 0,
    int b = 0,
    int c = 0,
  ]) => _context.cdf((family, a, b, c), initial);

  int _symbol(
    _Family family,
    List<int> initial, [
    int a = 0,
    int b = 0,
    int c = 0,
  ]) => _reader.adaptive(_cdf(family, initial, a, b, c));

  void _partition(int x, int y, int side) {
    if (x >= xEnd || y >= yEnd) return;
    if (side == 1) {
      _block(x, y, 1, 1);
      return;
    }
    final half = side >> 1, quarter = side >> 2;
    final hasRows = y + half < yEnd, hasCols = x + half < xEnd;
    var partition = _Partition.split;
    if (hasRows || hasCols) {
      final level = side.bitLength - 2;
      final above = _at(x, y - 1), left = _at(x - 1, y);
      final ctx =
          (above != null && above.width < side ? 1 : 0) +
          (left != null && left.height < side ? 2 : 0);
      final table = _cdf(
        _Family.partition,
        partitionCdf[level][ctx],
        level,
        ctx,
      );
      if (hasRows && hasCols) {
        partition = _Partition.values[_reader.adaptive(table)];
      } else {
        final edge = partitionEdgeCdf(table.cumulative, rightEdge: !hasCols);
        if (_reader.symbol(edge) == 0) {
          partition = hasCols ? _Partition.horizontal : _Partition.vertical;
        }
      }
    }
    switch (partition) {
      case _Partition.none:
        _block(x, y, side, side);
      case _Partition.horizontal:
        _block(x, y, side, half);
        if (hasRows) _block(x, y + half, side, half);
      case _Partition.vertical:
        _block(x, y, half, side);
        if (hasCols) _block(x + half, y, half, side);
      case _Partition.split:
        _partition(x, y, half);
        _partition(x + half, y, half);
        _partition(x, y + half, half);
        _partition(x + half, y + half, half);
      case _Partition.horizontalA:
        _block(x, y, half, half);
        _block(x + half, y, half, half);
        _block(x, y + half, side, half);
      case _Partition.horizontalB:
        _block(x, y, side, half);
        _block(x, y + half, half, half);
        _block(x + half, y + half, half, half);
      case _Partition.verticalA:
        _block(x, y, half, half);
        _block(x, y + half, half, half);
        _block(x + half, y, half, side);
      case _Partition.verticalB:
        _block(x, y, half, side);
        _block(x + half, y, half, half);
        _block(x + half, y + half, half, half);
      case _Partition.horizontal4:
        for (var r = y; r < y + side && r < yEnd; r += quarter) {
          _block(x, r, side, quarter);
        }
      case _Partition.vertical4:
        for (var c = x; c < x + side && c < xEnd; c += quarter) {
          _block(c, y, quarter, side);
        }
    }
  }

  void _block(int x, int y, int w4, int h4) {
    final w = w4 << 2, h = h4 << 2;
    final blockSize = _blockIndex[(w, h)]!;
    final above = _at(x, y - 1), left = _at(x - 1, y);
    final skipContext =
        (above?.skip == true ? 1 : 0) + (left?.skip == true ? 1 : 0);
    final intraFrame = frame.header.type.intra;
    var segment = 0;
    var predictedSegment = false;
    final segmentation = params.segmentation;
    void readSegment(bool skip) {
      if (!segmentation.enabled) return;
      if (intraFrame) {
        segment = _readSegment(x, y, above, left, skip);
        return;
      }
      if (segmentation.temporal && !skip) {
        final ctx =
            (above?.segmentPredicted == true ? 1 : 0) +
            (left?.segmentPredicted == true ? 1 : 0);
        predictedSegment =
            _symbol(
              _Family.segmentPred,
              interSegmentIdPredictedCdf[ctx],
              ctx,
            ) !=
            0;
      }
      segment = predictedSegment || !segmentation.updateMap
          ? _previousSegment(x, y, w4, h4)
          : _readSegment(x, y, above, left, skip);
    }

    if (_segPreSkip || !segmentation.updateMap) readSegment(false);
    final earlyFeatures = segmentation.features[segment];
    final skipCtx =
        (above?.skipMode == true ? 1 : 0) + (left?.skipMode == true ? 1 : 0);
    final skipMode =
        frame.header.motion.skipMode != null &&
        w4 >= 2 &&
        h4 >= 2 &&
        earlyFeatures[5] == null &&
        earlyFeatures[6] == null &&
        earlyFeatures[7] == null &&
        _symbol(_Family.skipMode, interSkipModeCdf[skipCtx], skipCtx) != 0;
    final skip =
        skipMode ||
        (_segPreSkip && earlyFeatures[6] != null) ||
        _symbol(_Family.skip, skipCdf[skipContext], skipContext) != 0;
    if (!_segPreSkip && segmentation.updateMap) readSegment(skip);
    _readCdef(x, y, w4, h4, skip);
    _readBlockDeltas(w4, h4, skip);
    if (frame.header.intrabc && _symbol(_Family.intrabc, const [30531]) != 0) {
      throw UnsupportedError('AV1 intra block copy');
    }

    final lossless = params.losslessSegments[segment];
    final hasChroma =
        !color.monochrome &&
        !(sx != 0 && w4 == 1 && x.isEven) &&
        !(sy != 0 && h4 == 1 && y.isEven);
    final features = segmentation.features[segment];
    if (!intraFrame && _isInter(above, left, features, skipMode)) {
      this._interBlock(
        x,
        y,
        w4,
        h4,
        blockSize,
        segment,
        predictedSegment,
        skip,
        skipMode,
        lossless,
        hasChroma,
        features,
      );
      return;
    }

    const modeContext = [0, 1, 2, 3, 4, 4, 4, 4, 3, 0, 1, 2, 0];
    final am = modeContext[(above?.yMode ?? Av1IntraMode.dc).index];
    final lm = modeContext[(left?.yMode ?? Av1IntraMode.dc).index];
    final group = (math.min(w4, h4).bitLength - 1).clamp(0, 3);
    final ym =
        Av1IntraMode.values[intraFrame
            ? _symbol(_Family.luma, intraLumaCdfs[am][lm], am, lm)
            : _symbol(_Family.interLuma, interYModeCdf[group], group)];
    final ya = _angle(ym, blockSize);
    final uvW = math.max(4, w >> sx), uvH = math.max(4, h >> sy);
    var um = Av1IntraMode.dc;
    var ua = 0, alphaU = 0, alphaV = 0;
    if (hasChroma) {
      final allowCfl = (lossless ? uvW == 4 && uvH == 4 : w <= 32 && h <= 32)
          ? 1
          : 0;
      um =
          Av1IntraMode.values[_symbol(
            _Family.uv,
            intraUvCdfs[allowCfl][ym.index],
            allowCfl,
            ym.index,
          )];
      if (um == Av1IntraMode.cfl) {
        final sign = 1 + _symbol(_Family.cflSign, intraCflSignCdf);
        alphaU = _alpha(sign ~/ 3, sign % 3);
        alphaV = _alpha(sign % 3, sign ~/ 3);
      }
      ua = _angle(um, blockSize);
    }
    List<int>? paletteY, paletteU, paletteV;
    if (frame.header.screenContent && blockSize >= 3 && w <= 64 && h <= 64) {
      final size = w.bitLength + h.bitLength - 8;
      final yCtx =
          (above?.paletteY == null ? 0 : 1) + (left?.paletteY == null ? 0 : 1);
      if (ym == Av1IntraMode.dc &&
          _symbol(
                _Family.paletteY,
                intraPaletteYCdfs[size][yCtx],
                size,
                yCtx,
              ) !=
              0) {
        final count =
            2 +
            _symbol(_Family.paletteYSize, intraPaletteYSizeCdfs[size], size);
        paletteY = _palette.colors(
          count,
          y % 16 == 0 ? null : above?.paletteY,
          left?.paletteY,
          chroma: false,
        );
      }
      final uvCtx = paletteY == null ? 0 : 1;
      if (hasChroma &&
          um == Av1IntraMode.dc &&
          _symbol(_Family.paletteUv, intraPaletteUvCdfs[uvCtx], uvCtx) != 0) {
        final count =
            2 +
            _symbol(_Family.paletteUvSize, intraPaletteUvSizeCdfs[size], size);
        paletteU = _palette.colors(
          count,
          y % 16 == 0 ? null : above?.paletteU,
          left?.paletteU,
          chroma: true,
        );
        paletteV = _palette.vColors(count);
      }
    }

    final filter =
        frame.sequence.tools.filterIntra &&
            paletteY == null &&
            ym == Av1IntraMode.dc &&
            w <= 32 &&
            h <= 32 &&
            _symbol(_Family.filter, intraFilterCdfs[blockSize], blockSize) != 0
        ? _symbol(_Family.filterMode, intraFilterModeCdf)
        : null;
    final visibleW = math.min(w, (xEnd - x) << 2);
    final visibleH = math.min(h, (yEnd - y) << 2);
    if (paletteY != null) {
      _palette.readMap(
        _yMap,
        paletteY.length,
        w,
        h,
        visibleWidth: visibleW,
        visibleHeight: visibleH,
        chroma: false,
      );
    }
    if (paletteU != null) {
      _palette.readMap(
        _uvMap,
        paletteU.length,
        uvW,
        uvH,
        visibleWidth: math.max(4, visibleW >> sx),
        visibleHeight: math.max(4, visibleH >> sy),
        chroma: true,
      );
    }
    final lumaTx = _lumaTx(w, h, above, left, lossless);
    final chromaTx = lossless
        ? Av1TxSize.tx4x4
        : Av1TxSize.of(math.min(32, uvW), math.min(32, uvH));
    final block = (
      width: w4,
      height: h4,
      segment: segment,
      skip: skip,
      yMode: ym,
      uvMode: um,
      txSize: lumaTx,
      filterLevels: _filterLevels(segment),
      paletteY: paletteY,
      paletteU: paletteU,
      motion: null,
      skipMode: false,
      segmentPredicted: predictedSegment,
    );
    _stampBlock(x, y, block);

    final blockAbove = [above != null, y - (sy != 0 && h4 == 1 ? 2 : 1) >= y0];
    final blockLeft = [left != null, x - (sx != 0 && w4 == 1 ? 2 : 1) >= x0];
    final smooth = [
      above?.yMode.smoothEdge == true || left?.yMode.smoothEdge == true,
      (blockAbove[1] &&
              _at(
                    x + (sx != 0 && x.isEven ? 1 : 0),
                    y - (sy != 0 && y.isOdd ? 2 : 1),
                  )?.uvMode.smoothEdge ==
                  true) ||
          (blockLeft[1] &&
              _at(
                    x - (sx != 0 && x.isOdd ? 2 : 1),
                    y + (sy != 0 && y.isEven ? 1 : 0),
                  )?.uvMode.smoothEdge ==
                  true),
    ];
    final planeCount = hasChroma ? 3 : 1;
    for (var p = 0; p < planeCount; p++) {
      if (!skip) continue;
      final (px, py) = p == 0 ? (0, 0) : (sx, sy);
      _neighbors[p].stamp(
        (x - x0) >> px,
        (y - y0) >> py,
        p == 0 ? w4 : uvW >> 2,
        p == 0 ? h4 : uvH >> 2,
        0,
        0,
      );
    }
    _lumaRight = 0;
    _lumaBottom = 0;
    for (var cy = 0; cy < h; cy += 64) {
      for (var cx = 0; cx < w; cx += 64) {
        for (var p = 0; p < planeCount; p++) {
          final (px, py) = p == 0 ? (0, 0) : (sx, sy);
          final pw = p == 0 ? w : uvW, ph = p == 0 ? h : uvH;
          final tx = p == 0 ? lumaTx : chromaTx;
          final typeIndex = p == 0 ? 0 : 1;
          final colors = switch (p) {
            0 => paletteY,
            1 => paletteU,
            _ => paletteV,
          };
          final planeX = (x >> px) << 2, planeY = (y >> py) << 2;
          final xLimit = math.min(pw, (cx + 64) >> px);
          final yLimit = math.min(ph, (cy + 64) >> py);
          for (var dy = cy >> py; dy < yLimit; dy += tx.height) {
            for (var dx = cx >> px; dx < xLimit; dx += tx.width) {
              _transform(
                p,
                planeX + dx,
                planeY + dy,
                tx,
                width: pw,
                height: ph,
                mode: p == 0 ? ym : um,
                angle: p == 0 ? ya : ua,
                above: dy > 0 || blockAbove[typeIndex],
                left: dx > 0 || blockLeft[typeIndex],
                smooth: smooth[typeIndex],
                filter: p == 0 ? filter : null,
                palette: colors == null
                    ? null
                    : (
                        map: p == 0 ? _yMap : _uvMap,
                        colors: colors,
                        offset: dy * pw + dx,
                      ),
                skip: skip,
                lossless: lossless,
                segment: segment,
                alpha: p == 1
                    ? alphaU
                    : p == 2
                    ? alphaV
                    : 0,
              );
            }
          }
        }
      }
    }
  }

  bool _inside(int x, int y) => x >= x0 && x < xEnd && y >= y0 && y < yEnd;

  Av1InterNeighbor? _motionNeighbor(int x, int y) {
    final block = _at(x, y);
    return block == null
        ? null
        : (width4: block.width, height4: block.height, motion: block.motion);
  }

  bool _isInter(
    _Block? above,
    _Block? left,
    List<int?> features,
    bool skipMode,
  ) {
    if (skipMode || features[7] != null) return true;
    if (features[5] case final reference?) return reference != 0;
    final available = (above == null ? 0 : 1) + (left == null ? 0 : 1);
    final intra =
        (above != null && above.motion == null ? 1 : 0) +
        (left != null && left.motion == null ? 1 : 0);
    final ctx = available == 2 ? (intra == 2 ? 3 : intra) : intra * 2;
    return _symbol(_Family.inter, interIsInterCdf[ctx], ctx) != 0;
  }

  int _previousSegment(int x, int y, int w4, int h4) {
    final previous = prior;
    if (previous == null ||
        previous.rows != state.rows ||
        previous.columns != state.columns)
      return 0;
    var segment = 7;
    for (var r = y; r < math.min(y + h4, yEnd); r++) {
      for (var c = x; c < math.min(x + w4, xEnd); c++) {
        segment = math.min(segment, previous.block(c, r)?.segment ?? 0);
      }
    }
    return segment;
  }

  void _stampBlock(int x, int y, _Block block) {
    for (var r = y; r < math.min(y + block.height, yEnd); r++) {
      final start = r * state.columns + x;
      state.blocks.fillRange(
        start,
        start + math.min(block.width, xEnd - x),
        block,
      );
    }
  }

  int _readSegment(int x, int y, _Block? above, _Block? left, bool skip) {
    final u = above?.segment ?? -1, l = left?.segment ?? -1;
    final ul = _at(x - 1, y - 1)?.segment ?? -1;
    final ref = u < 0
        ? math.max(l, 0)
        : l < 0 || ul == u
        ? u
        : l;
    if (skip) return ref;
    final ctx = ul < 0
        ? 0
        : u == l && u == ul
        ? 2
        : u == l || u == ul || l == ul
        ? 1
        : 0;
    final diff = _symbol(_Family.segment, intraSegmentCdfs[ctx], ctx);
    if (diff >= _segmentCount) {
      throw const FormatException('Invalid AV1 segment index');
    }
    if (ref == 0) return diff;
    if (ref >= _segmentCount - 1) return _segmentCount - diff - 1;
    final lower = 2 * ref < _segmentCount;
    if (diff <= 2 * (lower ? ref : _segmentCount - ref - 1)) {
      return diff.isOdd ? ref + ((diff + 1) >> 1) : ref - (diff >> 1);
    }
    return lower ? diff : _segmentCount - diff - 1;
  }

  void _readCdef(int x, int y, int w4, int h4, bool skip) {
    final cdef = params.cdef;
    if (skip || cdef == null) return;
    final stride = state.cdefStride;
    final start = (y >> 4) * stride + (x >> 4);
    if (state.cdef[start] >= 0) return;
    final value = _reader.literal(cdef.y.length.bitLength - 1);
    for (var r = y; r < math.min(y + h4, yEnd); r += 16) {
      for (var c = x; c < math.min(x + w4, xEnd); c += 16) {
        state.cdef[(r >> 4) * stride + (c >> 4)] = value;
      }
    }
  }

  void _readBlockDeltas(int w4, int h4, bool skip) {
    if (!_readDeltas) return;
    _readDeltas = false;
    if (skip && w4 == sb4 && h4 == sb4) return;
    final dq = _readDelta(_Family.deltaQ, intraDeltaQCdf, 0);
    _currentQ = (_currentQ + (dq << params.deltaQShift!)).clamp(1, 255);
    final filter = params.deltaFilter;
    if (filter != null) {
      final count = !filter.multi
          ? 1
          : color.monochrome
          ? 2
          : 4;
      for (var i = 0; i < count; i++) {
        final delta = _readDelta(_Family.deltaLf, intraDeltaLfCdf, i);
        _deltaLf[i] = (_deltaLf[i] + (delta << filter.shift)).clamp(-63, 63);
      }
    }
  }

  List<int> _filterLevels(int segment, [Av1InterMotion? motion]) {
    final filter = params.loopFilter;
    if (filter.levels[0] == 0 && filter.levels[1] == 0) {
      return const [0, 0, 0, 0];
    }
    final reference = motion?.ref0 ?? 0;
    final moving =
        motion != null &&
        (motion.mode0 != Av1MvMode.global ||
            (motion.ref1 > 0 && motion.mode1 != Av1MvMode.global));
    final key =
        segment |
        ((_deltaLf[0] + 63) << 3) |
        ((_deltaLf[1] + 63) << 10) |
        ((_deltaLf[2] + 63) << 17) |
        ((_deltaLf[3] + 63) << 24) |
        (reference << 31) |
        (moving ? 1 << 34 : 0);
    return _lfLevels.putIfAbsent(key, () {
      final features = params.segmentation.features[segment];
      final multi = params.deltaFilter?.multi == true;
      return List.generate(4, (i) {
        var level = (filter.levels[i] + _deltaLf[multi ? i : 0]).clamp(0, 63);
        level = (level + (features[i + 1] ?? 0)).clamp(0, 63);
        if (filter.enabled) {
          level =
              (level +
                      ((filter.references[reference] +
                              (reference == 0
                                  ? 0
                                  : filter.modes[moving ? 1 : 0])) <<
                          (level >> 5)))
                  .clamp(0, 63);
        }
        return level;
      });
    });
  }

  int _readDelta(_Family family, List<int> table, int i) {
    var value = _symbol(family, table, i);
    if (value == 3) {
      final bits = 1 + _reader.literal(3);
      value = (1 << bits) + 1 + _reader.literal(bits);
    }
    return value != 0 && _reader.literal(1) != 0 ? -value : value;
  }

  int _angle(Av1IntraMode mode, int size) => size >= 3 && mode.directional
      ? _symbol(_Family.angle, intraAngleCdfs[mode.index - 1], mode.index) - 3
      : 0;

  int _alpha(int sign, int other) {
    if (sign == 0) return 0;
    final ctx = (sign - 1) * 3 + other;
    final magnitude =
        1 + _symbol(_Family.cflAlpha, intraCflAlphaCdfs[ctx], ctx);
    return sign == 1 ? -magnitude : magnitude;
  }

  Av1TxSize _lumaTx(
    int width,
    int height,
    _Block? above,
    _Block? left,
    bool lossless,
  ) {
    if (lossless) return Av1TxSize.tx4x4;
    var size = Av1TxSize.of(math.min(width, 64), math.min(height, 64));
    if (params.transformMode == Av1TransformMode.select &&
        size != Av1TxSize.tx4x4) {
      final depth = size.squareUp - 1;
      final aboveW = above == null
          ? 0
          : above.motion == null
          ? above.txSize.width
          : above.width * 4;
      final leftH = left == null
          ? 0
          : left.motion == null
          ? left.txSize.height
          : left.height * 4;
      final ctx =
          (aboveW >= size.width ? 1 : 0) + (leftH >= size.height ? 1 : 0);
      final split = _symbol(
        _Family.txSize,
        intraTxSizeCdfs[depth][ctx],
        depth,
        ctx,
      );
      for (var i = 0; i < split; i++) {
        size = Av1TxSize.values[_splitTx[size.index]];
      }
    }
    return size;
  }

  Av1TxType _type(
    int plane,
    Av1TxSize size,
    Av1IntraMode mode,
    int? filter,
    bool lossless,
    int segment,
  ) {
    if (lossless || size.squareUp >= 3) return Av1TxType.dctDct;
    if (plane != 0) return _chromaTx[mode.index];
    if ((params.quantization.base +
                (params.segmentation.features[segment][0] ?? 0))
            .clamp(0, 255) ==
        0) {
      return Av1TxType.dctDct;
    }
    final set = params.reducedTransforms || size.square == 2 ? 1 : 0;
    final direction = filter == null
        ? mode.index
        : const [0, 1, 2, 6, 0][filter];
    final symbol = _symbol(
      _Family.txType,
      intraTxTypeCdfs[set][size.square][direction],
      set,
      size.square,
      direction,
    );
    return (set == 0 ? _intraSet1 : _intraSet2)[symbol];
  }

  void _transform(
    int p,
    int x,
    int y,
    Av1TxSize size, {
    required int width,
    required int height,
    required Av1IntraMode mode,
    required int angle,
    required bool above,
    required bool left,
    required bool smooth,
    required int? filter,
    required _Palette? palette,
    required bool skip,
    required bool lossless,
    required int segment,
    required int alpha,
  }) {
    final plane = planes[p];
    final (px, py) = p == 0 ? (0, 0) : (sx, sy);
    final right = (xEnd >> px) << 2, bottom = (yEnd >> py) << 2;
    if (x >= right || y >= bottom) return;
    final x4 = x >> 2, y4 = y >> 2;
    final below = y4 + (size.height >> 2);
    final sbHeight = sb4 >> py;
    final w = size.width, h = size.height;
    if (palette != null) {
      for (var r = 0, i = 0; r < h; r++) {
        for (var c = 0; c < w; c++) {
          _predictor.samples[i++] =
              palette.colors[palette.map[palette.offset + r * width + c]];
        }
      }
    } else {
      _predictor.predict(
        plane.samples,
        plane.stride,
        x,
        y,
        size,
        depth: color.depth,
        mode: mode,
        angleDelta: angle,
        above: above,
        left: left,
        aboveRight:
            plane.isDecoded(x4 + (size.width >> 2), y4 - 1) &&
            x + size.width < right &&
            y > ((y0 >> py) << 2),
        belowLeft:
            plane.isDecoded(x4 - 1, below) &&
            below < (y4 & -sbHeight) + sbHeight &&
            (below << 2) < bottom,
        right: right,
        bottom: bottom,
        edgeFilter: frame.sequence.tools.intraEdgeFilter,
        smoothEdge: smooth,
        recursiveFilter: filter,
      );
    }
    final maximum = (1 << color.depth) - 1;
    if (p == 0) {
      _lumaRight = math.max(_lumaRight, x + w);
      _lumaBottom = math.max(_lumaBottom, y + h);
    } else if (alpha != 0) {
      _applyCfl(x, y, w, h, alpha, maximum);
    }

    if (!skip) {
      final (eob: eob, type: type) = _coefficientDecoder.read(
        _quantized,
        neighbors: _neighbors[p],
        x4: x4 - (x0 >> px),
        y4: y4 - (y0 >> py),
        blockWidth: width,
        blockHeight: height,
        size: size,
        chroma: p != 0,
        readType: () => _type(p, size, mode, filter, lossless, segment),
      );
      if (eob > 0) {
        _quantizer.apply(
          _quantized,
          size,
          type,
          p,
          currentQ: _currentQ,
          segmentDelta: params.segmentation.features[segment][0] ?? 0,
        );
        _inverse.apply(
          _quantized,
          _residual,
          size,
          type,
          color.depth,
          lossless: lossless,
        );
        for (var i = 0; i < w * h; i++) {
          _predictor.samples[i] = (_predictor.samples[i] + _residual[i]).clamp(
            0,
            maximum,
          );
        }
      }
    }
    for (var r = 0; r < h; r++) {
      final at = (y + r) * plane.stride + x;
      plane.samples.setRange(at, at + w, _predictor.samples, r * w);
    }
    plane.markDecoded(x4, y4, size);
  }

  void _applyCfl(int x, int y, int w, int h, int alpha, int maximum) {
    final luma = planes[0];
    final scaled = _residual;
    var sum = 0;
    for (var j = 0, i = 0; j < h; j++) {
      final ly = math.min((y + j) << sy, _lumaBottom - (1 << sy));
      for (var k = 0; k < w; k++) {
        final lx = math.min((x + k) << sx, _lumaRight - (1 << sx));
        var value = 0;
        for (var dy = 0; dy < 1 << sy; dy++) {
          for (var dx = 0; dx < 1 << sx; dx++) {
            value += luma.samples[(ly + dy) * luma.stride + lx + dx];
          }
        }
        value <<= 3 - sx - sy;
        scaled[i++] = value;
        sum += value;
      }
    }
    final average = av1Round(sum, (w * h).bitLength - 1);
    for (var i = 0; i < w * h; i++) {
      final contribution = alpha * (scaled[i] - average);
      final delta = contribution.sign * av1Round(contribution.abs(), 6);
      _predictor.samples[i] = (_predictor.samples[i] + delta).clamp(0, maximum);
    }
  }
}
