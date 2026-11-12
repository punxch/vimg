import 'dart:typed_data';

import 'access_unit.dart';
import 'cabac.dart';
import 'contexts.dart';
import 'ctu_layout.dart';
import 'decoded_pictures.dart';
import 'inter_motion.dart';
import 'inter_prediction.dart';
import 'intra_prediction.dart';
import 'loop_filter.dart';
import 'picture.dart';
import 'picture_order.dart';
import 'residual.dart';
import 'sao.dart';
import 'slice_header.dart';
import 'transform.dart';

/// Reconstruct an intra-coded HEVC picture from a container sample.
final class HevcIntraDecoder {
  HevcIntraDecoder(this.configuration);

  final HevcConfiguration configuration;

  HevcPicture? decode(Uint8List sample) {
    final slices = configuration.slices(sample);
    if (slices.isEmpty) return null;
    if (slices.any((s) => s.parameters.kind != HevcSliceKind.intra))
      return null;
    return _reconstruct(slices);
  }
}

/// Decode samples in bitstream order, with an IRAP picture as the entry point.
final class HevcStreamDecoder {
  HevcStreamDecoder(this.configuration);

  final HevcConfiguration configuration;
  final _order = HevcPictureOrder();
  final _references = HevcDecodedPictures();

  HevcPicture? decode(Uint8List sample) {
    final slices = configuration.slices(sample);
    if (slices.isEmpty) return null;
    final first = slices.first;
    final order = _order.observe(first);
    if (order.discardRasl) return null;
    final picture = _reconstruct(
      slices,
      references: _references,
      poc: order.poc,
    );
    _references.update(first, order.poc, picture);
    return order.output ? picture : null;
  }
}

HevcPicture _reconstruct(
  List<HevcSliceHeader> slices, {
  HevcDecodedPictures? references,
  int poc = 0,
}) {
  final first = slices.first, sps = first.sps;
  final range = first.pps.rangeExtension;
  if (sps.fieldSequence ||
      sps.separateColourPlane ||
      sps.lumaDepth > 12 ||
      sps.chromaDepth > 12 ||
      sps.hasUnsupportedRangeTools ||
      range?.crossComponent == true ||
      range?.chromaOffsetDepth != null) {
    throw UnsupportedError(
      'Unsupported HEVC field, separate plane, bit depth or range extension tools',
    );
  }
  if (sps.codedWidth * sps.codedHeight > 36 * 1024 * 1024) {
    throw const FormatException('Oversized HEVC picture');
  }
  final picture = HevcPicture(
    sps,
    inter: slices.any((s) => s.parameters.kind != HevcSliceKind.intra),
  );
  final decoder = _Reconstruction(picture, first, references, poc);
  decoder.read(slices);
  decoder.filter();
  return picture;
}

final class _Reconstruction {
  _Reconstruction(
    this.picture,
    HevcSliceHeader first,
    this._references,
    this._poc,
  ) : layout = HevcCtuLayout(first.sps, first.pps.tiles),
      _scaling = HevcScalingFactors(
        first.pps.scalingLists ?? first.sps.scalingLists,
        fullChroma: first.sps.chromaArrayType == 3,
      ),
      _cellsWide = first.sps.codedWidth >> 2 {
    final count = layout.order.length;
    final cells = (picture.sps.codedHeight >> 2) * _cellsWide;
    _owners = Int32List(count)..fillRange(0, count, -1);
    _headers = List.filled(count, null);
    _sao = List.filled(count, hevcSaoOff);
    _synchronized = List.filled(count, null);
    _depth = Int8List(cells)..fillRange(0, cells, -1);
    _mode = Uint8List(cells)..fillRange(0, cells, 1);
    if (first.sps.chromaArrayType == 3) _chromaMode = Uint8List(cells);
    _qp = Int8List(cells);
    _filterEdges = Uint8List(cells);
    _filterDisabled = Uint8List(cells);
    _skip = Uint8List(cells);
    _intra = Uint8List(cells);
    _lumaCbf = Uint8List(cells);
  }

  final HevcPicture picture;
  final HevcDecodedPictures? _references;
  final int _poc;
  late final _interPrediction = HevcInterPrediction();
  HevcInterMotion? _motion;
  final HevcCtuLayout layout;
  final HevcScalingFactors _scaling;
  final _predict = HevcIntraPrediction();
  final _coefficients = HevcResidual();
  final _transform = HevcTransform();
  final int _cellsWide;
  late final Int32List _owners;
  late final List<HevcSliceHeader?> _headers;
  late final List<HevcSao> _sao;
  late final List<Uint8List?> _synchronized;
  late final Int8List _depth, _qp;
  late final Uint8List _mode,
      _chromaMode,
      _filterEdges,
      _filterDisabled,
      _skip,
      _intra,
      _lumaCbf;

  late HevcSliceHeader _slice;
  late HevcCabac _cabac;
  var _address = 0, _owner = 0;
  var _groupX = -1, _groupY = -1;
  var _previousQp = 0, _predictedQp = 0, _currentQp = 0;
  var _deltaRead = false;

  int _cell(int x, int y) => (y >> 2) * _cellsWide + (x >> 2);

  void read(List<HevcSliceHeader> slices) {
    var decoded = 0;
    for (var index = 0; index < slices.length; index++) {
      _slice = slices[index];
      final start = layout.index[_slice.address];
      final end = index + 1 == slices.length
          ? layout.order.length
          : layout.index[slices[index + 1].address];
      if (start != decoded || end <= start)
        throw const FormatException('Invalid HEVC slice segment order');
      if (!_slice.dependent) {
        _owner = _slice.address;
        _motion = _slice.parameters.kind == HevcSliceKind.intra
            ? null
            : HevcInterMotion(
                _slice,
                _poc,
                _references!.lists(_slice, _poc),
                picture.motion!,
                _available,
              );
        _resetQp();
      }
      final streams = _slice.substreams().iterator;
      for (var i = start; i < end; i++) {
        final previous = i == 0 ? -1 : layout.order[i - 1];
        _address = layout.order[i];
        final tileStart =
            previous < 0 || layout.tile[previous] != layout.tile[_address];
        final rowStart = _slice.pps.wavefront && layout.rowStart(_address);
        if (i == start || tileStart || rowStart) {
          if (i != start && !_cabac.terminate())
            throw const FormatException(
              'Missing HEVC end of entropy substream',
            );
          if (!streams.moveNext())
            throw const FormatException('Missing HEVC CABAC entry point');
          final independent = i == start && !_slice.dependent;
          final aboveRight = _address - picture.sps.ctbWidth + 1;
          final sync =
              rowStart &&
              aboveRight >= 0 &&
              layout.tileWidth[_address] > 1 &&
              _address >= picture.sps.ctbWidth &&
              _sameCtuRegion(aboveRight);
          final models = tileStart || independent
              ? null
              : rowStart
              ? (sync ? _synchronized[_address] : null)
              : _cabac.copyModels();
          _cabac = HevcCabac(
            streams.current,
            _slice.parameters,
            savedModels: models,
          );
          if (tileStart || rowStart) _resetQp();
        }
        _owners[_address] = _owner;
        _headers[_address] = _slice;
        final width = picture.sps.ctbWidth;
        final x = _address % width, y = _address ~/ width;
        final left = x > 0 && _sameCtuRegion(_address - 1)
            ? _sao[_address - 1]
            : null;
        final above = y > 0 && _sameCtuRegion(_address - width)
            ? _sao[_address - width]
            : null;
        _sao[_address] = readHevcSao(_cabac, _slice, left, above);
        final log2 = picture.sps.ctbLog2;
        _codingTree(x << log2, y << log2, log2, 0);
        if (_slice.pps.wavefront &&
            x == layout.tileLeft[_address] + 1 &&
            y + 1 < picture.sps.ctbHeight) {
          final next = _address + width - 1;
          if (layout.tile[next] == layout.tile[_address])
            _synchronized[next] = _cabac.copyModels();
        }
        final done = _cabac.terminate();
        if (done != (i + 1 == end))
          throw FormatException(
            'Unexpected HEVC end-of-slice flag at CTU $_address',
          );
      }
      if (streams.moveNext())
        throw const FormatException('Unused HEVC entropy substream');
      decoded = end;
    }
  }

  bool _sameCtuRegion(int address) =>
      _owners[address] == _owner &&
      layout.tile[address] == layout.tile[_address];

  bool _available(int x, int y) =>
      picture.luma.contains(x, y) && _sameCtuRegion(layout.atSample(x, y));

  int _neighborDepth(int x, int y) =>
      _available(x, y) ? _depth[_cell(x, y)] : -1;

  void _codingTree(int x, int y, int log2, int depth) {
    final size = 1 << log2;
    final sps = picture.sps;
    if (log2 > sps.minCbLog2) {
      final fits = x + size <= sps.codedWidth && y + size <= sps.codedHeight;
      final context =
          (_neighborDepth(x - 1, y) > depth ? 1 : 0) +
          (_neighborDepth(x, y - 1) > depth ? 1 : 0);
      if (!fits || _cabac.decode(HevcContext.splitCuFlag, context) != 0) {
        final half = size >> 1;
        for (var i = 0; i < 4; i++) {
          final cx = x + (i & 1) * half, cy = y + (i >> 1) * half;
          if (cx < sps.codedWidth && cy < sps.codedHeight)
            _codingTree(cx, cy, log2 - 1, depth + 1);
        }
        return;
      }
    }
    _codingUnit(x, y, log2, depth);
  }

  void _codingUnit(int x, int y, int log2, int depth) {
    final size = 1 << log2;
    final sps = picture.sps;
    final bypass =
        _slice.pps.transquantBypass &&
        _cabac.decode(HevcContext.cuTransquantBypassFlag) != 0;
    _beginQuantGroup(x, y);
    final interSlice = _motion != null;
    int skipped(int sx, int sy) =>
        _available(sx, sy) ? _skip[_cell(sx, sy)] : 0;
    final skip =
        interSlice &&
        _cabac.decode(
              HevcContext.cuSkipFlag,
              skipped(x - 1, y) + skipped(x, y - 1),
            ) !=
            0;
    final intra =
        !skip && (!interSlice || _cabac.decode(HevcContext.predModeFlag) != 0);
    if (!intra) {
      _interCu(x, y, log2, depth, bypass, skip);
      return;
    }
    _fill(_intra, x, y, size, 1);
    final split =
        log2 == sps.minCbLog2 && _cabac.decode(HevcContext.partMode) == 0;
    final pcm = sps.pcm;
    if (!split &&
        pcm != null &&
        log2 >= pcm.minLog2 &&
        log2 <= pcm.maxLog2 &&
        _cabac.terminate()) {
      _readPcm(x, y, size, pcm.lumaDepth, pcm.chromaDepth);
      _edges(x, y, size, size, transform: true);
      _storeCu(x, y, size, depth, bypass || pcm.filterDisabled);
      return;
    }

    final count = split ? 4 : 1;
    final flags = List.generate(
      count,
      (_) => _cabac.decode(HevcContext.prevIntraLumaPredFlag) != 0,
    );
    final part = split ? size >> 1 : size;
    for (var i = 0; i < count; i++) {
      final px = x + (i & 1) * part, py = y + (i >> 1) * part;
      final mode = _readIntraMode(px, py, flags[i]);
      _fill(_mode, px, py, part, mode);
    }
    var chroma = -1;
    if (sps.chromaArrayType == 3) {
      for (var i = 0; i < count; i++) {
        final px = x + (i & 1) * part, py = y + (i >> 1) * part;
        _fill(_chromaMode, px, py, part, _readChromaMode(_mode[_cell(px, py)]));
      }
    } else if (picture.cb != null) {
      chroma = _readChromaMode(_mode[_cell(x, y)]);
      if (sps.chromaArrayType == 2) chroma = _chroma422Modes[chroma];
    }
    _transformTree(x, y, log2, 0, 0, 0, split, chroma, bypass, intra: true);
    _storeCu(x, y, size, depth, bypass);
  }

  int _readChromaMode(int luma) {
    if (_cabac.decode(HevcContext.intraChromaPredMode) == 0) return luma;
    final mode = const [0, 26, 10, 1][_cabac.bypassBits(2)];
    return mode == luma ? 34 : mode;
  }

  void _interCu(int x, int y, int log2, int depth, bool bypass, bool skip) {
    final size = 1 << log2;
    final sps = picture.sps;
    final partition = skip
        ? HevcPartition.whole
        : readHevcPartition(_cabac, log2, sps.minCbLog2, sps.amp);
    final cu = (x: x, y: y, width: size, height: size);
    final motion = _motion!;
    var merge = false;
    var index = 0;
    for (final block in partition.blocks(x, y, size)) {
      final prediction = motion.read(
        _cabac,
        block,
        cu,
        partition,
        index++,
        depth,
        skip,
      );
      merge = prediction.merge;
      motion.field.store(block, prediction.motion);
      _interPrediction.reconstruct(
        picture,
        block,
        prediction.motion,
        motion.references,
        _slice.parameters.weights,
      );
      _edges(block.x, block.y, block.width, block.height, transform: false);
    }
    // The CU boundary is also a transform boundary for zero-residual CUs.
    _edges(x, y, size, size, transform: true);
    picture.luma.mark(x, y, size);
    final sx = sps.chromaShiftX, sy = sps.chromaShiftY;
    picture.cb?.mark(x >> sx, y >> sy, size >> sx, size >> sy);
    picture.cr?.mark(x >> sx, y >> sy, size >> sx, size >> sy);
    if (skip) {
      _fill(_skip, x, y, size, 1);
    } else if ((partition == HevcPartition.whole && merge) ||
        _cabac.decode(HevcContext.rqtRootCbf) != 0) {
      final split =
          partition != HevcPartition.whole && sps.transformDepthInter == 0;
      _transformTree(x, y, log2, 0, 0, 0, split, -1, bypass, intra: false);
    }
    _storeCu(x, y, size, depth, bypass);
  }

  int _readIntraMode(int x, int y, bool previous) {
    final a = _available(x - 1, y) ? _mode[_cell(x - 1, y)] : 1;
    final b = y % (1 << picture.sps.ctbLog2) != 0 && _available(x, y - 1)
        ? _mode[_cell(x, y - 1)]
        : 1;
    final candidates = a == b
        ? (a < 2 ? [0, 1, 26] : [a, 2 + (a + 29) % 32, 2 + (a - 1) % 32])
        : [
            a,
            b,
            a != 0 && b != 0
                ? 0
                : a != 1 && b != 1
                ? 1
                : 26,
          ];
    if (previous) {
      final index = _cabac.bypass() == 0 ? 0 : 1 + _cabac.bypass();
      return candidates[index];
    }
    var mode = _cabac.bypassBits(5);
    for (final excluded in candidates..sort()) {
      if (mode >= excluded) mode++;
    }
    return mode;
  }

  void _transformTree(
    int x,
    int y,
    int log2,
    int depth,
    int child,
    int inherited,
    bool rootSplit,
    int chromaMode,
    bool bypass, {
    required bool intra,
  }) {
    final sps = picture.sps;
    final forced = log2 > sps.maxTbLog2 || (rootSplit && depth == 0);
    final maxDepth = intra
        ? sps.transformDepthIntra + (rootSplit ? 1 : 0)
        : sps.transformDepthInter;
    final split =
        forced ||
        (log2 > sps.minTbLog2 &&
            depth < maxDepth &&
            _cabac.decode(HevcContext.splitTransformFlag, 5 - log2) != 0);
    final format = sps.chromaArrayType;
    var chroma = inherited;
    if (format != 0 && (log2 > 2 || format == 3)) {
      // For 4:2:2 each component can have a second square below the first.
      for (final flag in const [1, 4]) {
        if (depth != 0 && inherited & flag == 0) continue;
        chroma &= ~flag;
        if (_cabac.decode(HevcContext.cbfChroma, depth) != 0) chroma |= flag;
        if (format == 2 && (!split || log2 == 3)) {
          final lower = flag << 1;
          chroma &= ~lower;
          if (_cabac.decode(HevcContext.cbfChroma, depth) != 0) chroma |= lower;
        }
      }
    }
    if (split) {
      final half = 1 << (log2 - 1);
      for (var i = 0; i < 4; i++) {
        _transformTree(
          x + (i & 1) * half,
          y + (i >> 1) * half,
          log2 - 1,
          depth + 1,
          i,
          chroma,
          rootSplit,
          chromaMode,
          bypass,
          intra: intra,
        );
      }
      return;
    }
    final lumaCoded =
        (!intra && depth == 0 && chroma == 0) ||
        _cabac.decode(HevcContext.cbfLuma, depth == 0 ? 1 : 0) != 0;
    // The last 4×4 luma child carries its parent's shared chroma block.
    final shared = log2 == 2 && format != 3;
    final writeChroma = format != 0 && (!shared || child == 3);
    if ((lumaCoded || chroma != 0) &&
        !_deltaRead &&
        _slice.pps.qpDeltaDepth != null)
      _readDelta();
    final size = 1 << log2;
    _edges(x, y, size, size, transform: true);
    if (lumaCoded) _fill(_lumaCbf, x, y, size, 1);
    final mode = intra ? _mode[_cell(x, y)] : -1;
    _block(picture.luma, x, y, log2, mode, 0, lumaCoded, bypass);
    if (writeChroma) {
      final cx = (shared ? x & ~7 : x) >> sps.chromaShiftX;
      final cy = (shared ? y & ~7 : y) >> sps.chromaShiftY;
      final log2Chroma = shared ? 2 : log2 - sps.chromaShiftX;
      final prediction = intra && format == 3
          ? _chromaMode[_cell(x, y)]
          : chromaMode;
      final blocks = format == 2 ? 2 : 1;
      for (var component = 1; component <= 2; component++) {
        final plane = component == 1 ? picture.cb! : picture.cr!;
        for (var i = 0; i < blocks; i++) {
          final flag = 1 << ((component - 1) * 2 + i);
          _block(
            plane,
            cx,
            cy + (i << log2Chroma),
            log2Chroma,
            prediction,
            component,
            chroma & flag != 0,
            bypass,
          );
        }
      }
    }
  }

  void _block(
    HevcPlane plane,
    int x,
    int y,
    int log2,
    int mode,
    int component,
    bool coded,
    bool bypass,
  ) {
    final chroma = component != 0, intra = mode >= 0;
    Int32List? residual;
    if (coded) {
      final skip =
          !bypass &&
          _slice.pps.transformSkip &&
          log2 <= (_slice.pps.rangeExtension?.maxTransformSkipLog2 ?? 2) &&
          _cabac.decode(HevcContext.transformSkipFlag, chroma ? 1 : 0) != 0;
      final levels = _coefficients.read(
        _cabac,
        log2,
        mode,
        chroma: chroma,
        directionalScan:
            log2 == 2 ||
            (log2 == 3 && (!chroma || picture.sps.chromaArrayType == 3)),
        hideSign: !bypass && _slice.pps.signHiding,
      );
      final offset = 6 * (plane.depth - 8);
      var qp = _currentQp;
      if (chroma) {
        final offsets = _slice.parameters.chromaOffsets;
        final qpi = qp + (component == 1 ? offsets.cb : offsets.cr);
        qp = picture.sps.chromaArrayType == 1
            ? hevcChromaQp420(qpi.clamp(-offset, 57))
            : qpi.clamp(-offset, 51);
      }
      residual = _transform.apply(
        levels,
        log2,
        plane.depth,
        qp + offset,
        lumaIntra: intra && !chroma,
        skip: skip,
        bypass: bypass,
        weights: skip && log2 > 2
            ? null
            : _scaling.weights(log2, component + (intra ? 0 : 3)),
      );
    }
    if (!intra) {
      if (residual != null) {
        final size = 1 << log2;
        for (var row = 0; row < size; row++) {
          final dst = (y + row) * plane.width + x, src = row * size;
          for (var col = 0; col < size; col++) {
            final index = dst + col;
            plane.samples[index] = (plane.samples[index] + residual[src + col])
                .clamp(0, plane.maximum);
          }
        }
      }
      return;
    }
    bool available(int sx, int sy) =>
        _available(sx, sy) &&
        (!_slice.pps.constrainedIntra || _intra[_cell(sx, sy)] != 0);
    _predict.reconstruct(
      plane,
      x,
      y,
      log2,
      mode,
      luma: !chroma,
      filterReferences:
          !picture.sps.intraSmoothingDisabled &&
          (!chroma || picture.sps.chromaArrayType == 3),
      strongSmoothing: picture.sps.strongIntraSmoothing,
      available: chroma
          ? (x, y) => available(
              x << picture.sps.chromaShiftX,
              y << picture.sps.chromaShiftY,
            )
          : available,
      residual: residual,
    );
  }

  void _resetQp() {
    _groupX = _groupY = -1;
    _previousQp = _slice.parameters.qp;
  }

  void _beginQuantGroup(int x, int y) {
    final log2 = picture.sps.ctbLog2 - (_slice.pps.qpDeltaDepth ?? 0);
    final mask = (1 << log2) - 1;
    final gx = x & ~mask, gy = y & ~mask;
    if (gx == _groupX && gy == _groupY) return;
    _groupX = gx;
    _groupY = gy;
    final ctuMask = (1 << picture.sps.ctbLog2) - 1;
    final a = (gx & ctuMask) != 0 && _neighborDepth(gx - 1, gy) >= 0
        ? _qp[_cell(gx - 1, gy)]
        : _previousQp;
    final b = (gy & ctuMask) != 0 && _neighborDepth(gx, gy - 1) >= 0
        ? _qp[_cell(gx, gy - 1)]
        : _previousQp;
    _predictedQp = _currentQp = (a + b + 1) >> 1;
    _deltaRead = false;
  }

  void _readDelta() {
    var magnitude = 0;
    while (magnitude < 5 &&
        _cabac.decode(HevcContext.cuQpDeltaAbs, magnitude == 0 ? 0 : 1) != 0)
      magnitude++;
    if (magnitude == 5) magnitude += _cabac.bypassGolomb(0);
    final offset = 6 * (picture.sps.lumaDepth - 8);
    final delta = magnitude == 0 || _cabac.bypass() == 0
        ? magnitude
        : -magnitude;
    if (delta < -(26 + offset ~/ 2) || delta > 25 + offset ~/ 2)
      throw const FormatException('Invalid HEVC coding unit QP delta');
    _currentQp = (_predictedQp + delta + offset) % (52 + offset) - offset;
    _deltaRead = true;
  }

  void _storeCu(int x, int y, int size, int depth, bool disableFilter) {
    _fill(_depth, x, y, size, depth);
    _fill(_qp, x, y, size, _currentQp);
    if (disableFilter) _fill(_filterDisabled, x, y, size, 1);
    _previousQp = _currentQp;
  }

  void _fill(List<int> map, int x, int y, int size, int value) {
    for (var row = y; row < y + size; row += 4) {
      final start = _cell(x, row);
      map.fillRange(start, start + (size >> 2), value);
    }
  }

  void _edges(int x, int y, int width, int height, {required bool transform}) {
    // Bits 0 and 1 mark all edges. Bits 2 and 3 mark transform edges.
    final vertical = transform ? 5 : 1;
    final horizontal = transform ? 10 : 2;
    if (x > 0 && x & 7 == 0) {
      for (var row = y; row < y + height; row += 4)
        _filterEdges[_cell(x, row)] |= vertical;
    }
    if (y > 0 && y & 7 == 0) {
      for (var col = x; col < x + width; col += 4)
        _filterEdges[_cell(col, y)] |= horizontal;
    }
  }

  void _readPcm(int x, int y, int size, int lumaDepth, int chromaDepth) {
    _cabac.bits.align(0);
    void copy(HevcPlane plane, int x, int y, int w, int h, int depth) {
      if (depth > plane.depth)
        throw const FormatException('Invalid HEVC PCM depth');
      final shift = plane.depth - depth;
      for (var row = 0; row < h; row++) {
        final start = (y + row) * plane.width + x;
        for (var col = 0; col < w; col++)
          plane.samples[start + col] = _cabac.bits.read(depth) << shift;
      }
      plane.mark(x, y, w, h);
    }

    copy(picture.luma, x, y, size, size, lumaDepth);
    if (picture.cb != null) {
      final sx = picture.sps.chromaShiftX, sy = picture.sps.chromaShiftY;
      copy(picture.cb!, x >> sx, y >> sy, size >> sx, size >> sy, chromaDepth);
      copy(picture.cr!, x >> sx, y >> sy, size >> sx, size >> sy, chromaDepth);
    }
    _cabac.restart();
  }

  void filter() => HevcLoopFilter(
    picture,
    layout,
    _owners,
    _headers,
    _qp,
    _filterEdges,
    _filterDisabled,
    _intra,
    _lumaCbf,
    _sao,
  ).apply();
}

// H.265 Table 8-3 maps prediction angles to the 4:2:2 sample grid.
const _chroma422Modes = [
  0,
  1,
  2,
  2,
  2,
  2,
  3,
  5,
  7,
  8,
  10,
  12,
  13,
  15,
  17,
  18,
  19,
  20,
  21,
  22,
  23,
  23,
  24,
  24,
  25,
  25,
  26,
  27,
  27,
  28,
  28,
  29,
  29,
  30,
  31,
];
