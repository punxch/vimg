import 'dart:typed_data';

import 'access_unit.dart';
import 'cabac.dart';
import 'contexts.dart';
import 'ctu_layout.dart';
import 'intra_prediction.dart';
import 'loop_filter.dart';
import 'picture.dart';
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
    final first = slices.first;
    final sps = first.sps;
    if (sps.fieldSequence ||
        sps.chromaArrayType > 1 ||
        sps.separateColourPlane ||
        sps.lumaDepth > 12 ||
        sps.chromaDepth > 12 ||
        sps.rangeExtension != 0 ||
        first.pps.rangeExtension != null) {
      throw UnsupportedError(
        'HEVC intra decoding requires progressive monochrome or 4:2:0 samples up to 12 bits without range extension tools',
      );
    }
    if (sps.codedWidth * sps.codedHeight > 36 * 1024 * 1024) {
      throw const FormatException('Oversized HEVC picture');
    }
    if (slices.any((s) => s.parameters.kind != HevcSliceKind.intra)) {
      throw UnsupportedError('HEVC inter-picture decoding is unavailable');
    }
    final picture = HevcPicture(sps);
    final decode = _IntraReconstruction(picture, first);
    decode.read(slices);
    decode.filter();
    return picture;
  }
}

final class _IntraReconstruction {
  _IntraReconstruction(this.picture, HevcSliceHeader first)
    : layout = HevcCtuLayout(first.sps, first.pps.tiles),
      _scaling = HevcScalingFactors(
        first.pps.scalingLists ?? first.sps.scalingLists,
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
    _qp = Int8List(cells);
    _filterEdges = Uint8List(cells);
    _filterDisabled = Uint8List(cells);
  }

  final HevcPicture picture;
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
  late final Uint8List _mode, _filterEdges, _filterDisabled;

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
    final split =
        log2 == sps.minCbLog2 && _cabac.decode(HevcContext.partMode) == 0;
    _beginQuantGroup(x, y);
    final pcm = sps.pcm;
    if (!split &&
        pcm != null &&
        log2 >= pcm.minLog2 &&
        log2 <= pcm.maxLog2 &&
        _cabac.terminate()) {
      _readPcm(x, y, size, pcm.lumaDepth, pcm.chromaDepth);
      _edges(x, y, size);
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
    final luma = _mode[_cell(x, y)];
    var chroma = luma;
    if (picture.cb != null &&
        _cabac.decode(HevcContext.intraChromaPredMode) != 0) {
      chroma = const [0, 26, 10, 1][_cabac.bypassBits(2)];
      if (chroma == luma) chroma = 34;
    }
    _transformTree(x, y, log2, 0, 0, 0, split, chroma, bypass);
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
    bool intraSplit,
    int chromaMode,
    bool bypass,
  ) {
    final sps = picture.sps;
    final forced = log2 > sps.maxTbLog2 || (intraSplit && depth == 0);
    final split =
        forced ||
        (log2 > sps.minTbLog2 &&
            depth < sps.transformDepthIntra + (intraSplit ? 1 : 0) &&
            _cabac.decode(HevcContext.splitTransformFlag, 5 - log2) != 0);
    var chroma = inherited;
    if (log2 > 2 && picture.cb != null) {
      chroma = 0;
      for (var i = 0; i < 2; i++) {
        if ((depth == 0 || inherited & (1 << i) != 0) &&
            _cabac.decode(HevcContext.cbfChroma, depth) != 0) {
          chroma |= 1 << i;
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
          intraSplit,
          chromaMode,
          bypass,
        );
      }
      return;
    }
    final lumaCoded =
        _cabac.decode(HevcContext.cbfLuma, depth == 0 ? 1 : 0) != 0;
    // The last 4×4 luma child carries its parent's shared chroma block.
    final writeChroma = picture.cb != null && (log2 > 2 || child == 3);
    if ((lumaCoded || chroma != 0) &&
        !_deltaRead &&
        _slice.pps.qpDeltaDepth != null)
      _readDelta();
    _edges(x, y, 1 << log2);
    _block(picture.luma, x, y, log2, _mode[_cell(x, y)], 0, lumaCoded, bypass);
    if (writeChroma) {
      final cx = (log2 == 2 ? x & ~7 : x) >> 1,
          cy = (log2 == 2 ? y & ~7 : y) >> 1;
      final size = log2 == 2 ? 2 : log2 - 1;
      _block(picture.cb!, cx, cy, size, chromaMode, 1, chroma & 1 != 0, bypass);
      _block(picture.cr!, cx, cy, size, chromaMode, 2, chroma & 2 != 0, bypass);
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
    final chroma = component != 0;
    Int32List? residual;
    if (coded) {
      final skip =
          !bypass &&
          _slice.pps.transformSkip &&
          log2 == 2 &&
          _cabac.decode(HevcContext.transformSkipFlag, chroma ? 1 : 0) != 0;
      final levels = _coefficients.read(
        _cabac,
        log2,
        mode,
        chroma: chroma,
        hideSign: !bypass && _slice.pps.signHiding,
      );
      final offset = 6 * (plane.depth - 8);
      var qp = _currentQp;
      if (chroma) {
        final offsets = _slice.parameters.chromaOffsets;
        qp = hevcChromaQp420(
          (qp + (component == 1 ? offsets.cb : offsets.cr)).clamp(-offset, 57),
        );
      }
      residual = _transform.apply(
        levels,
        log2,
        plane.depth,
        qp + offset,
        lumaIntra: !chroma,
        skip: skip,
        bypass: bypass,
        weights: _scaling.weights(log2, component),
      );
    }
    _predict.reconstruct(
      plane,
      x,
      y,
      log2,
      mode,
      luma: !chroma,
      strongSmoothing: picture.sps.strongIntraSmoothing,
      available: chroma ? (x, y) => _available(2 * x, 2 * y) : _available,
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

  void _edges(int x, int y, int size) {
    if (x > 0 && x & 7 == 0) {
      for (var row = y; row < y + size; row += 4)
        _filterEdges[_cell(x, row)] |= 1;
    }
    if (y > 0 && y & 7 == 0) {
      for (var col = x; col < x + size; col += 4)
        _filterEdges[_cell(col, y)] |= 2;
    }
  }

  void _readPcm(int x, int y, int size, int lumaDepth, int chromaDepth) {
    _cabac.bits.align(0);
    void copy(HevcPlane plane, int x, int y, int n, int depth) {
      if (depth > plane.depth)
        throw const FormatException('Invalid HEVC PCM depth');
      final shift = plane.depth - depth;
      for (var row = 0; row < n; row++) {
        final start = (y + row) * plane.width + x;
        for (var col = 0; col < n; col++)
          plane.samples[start + col] = _cabac.bits.read(depth) << shift;
      }
      plane.mark(x, y, n);
    }

    copy(picture.luma, x, y, size, lumaDepth);
    if (picture.cb != null) {
      copy(picture.cb!, x >> 1, y >> 1, size >> 1, chromaDepth);
      copy(picture.cr!, x >> 1, y >> 1, size >> 1, chromaDepth);
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
    _sao,
  ).apply();
}
