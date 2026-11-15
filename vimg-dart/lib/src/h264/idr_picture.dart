import 'dart:typed_data';

import 'access_unit.dart';
import 'b_motion.dart';
import 'deblock.dart';
import 'intra_prediction.dart';
import 'motion.dart';
import 'motion_compensation.dart';
import 'parameters.dart';
import 'picture.dart';
import 'reference.dart';
import 'slice_data.dart';
import 'slice_header.dart';
import 'transforms.dart';

/// Decoder for independently decodable H.264 pictures. Full-GOP decoding can
/// reuse the same reconstructed planes for reference pictures.
final class H264IdrDecoder {
  H264IdrDecoder(this.configuration);

  final AvcConfiguration configuration;

  H264Picture? decode(Uint8List sample) {
    final slices = <SliceHeader>[];
    for (final nal in configuration.nals(sample)) {
      switch (nal[0] & 31) {
        case 7 || 8:
          configuration.store(nal);
        case 5:
          slices.add(SliceHeader(nal, configuration.pictures));
      }
    }
    return slices.isEmpty ? null : _decodeAccessUnit(slices);
  }
}

/// Sequential decoder. The container supplies one access unit at a time in
/// decode order, including reference pictures that are not selected for output.
final class H264StreamDecoder {
  H264StreamDecoder(this.configuration);

  final AvcConfiguration configuration;
  var _references = [ReferenceState()];

  H264Picture? decode(Uint8List sample) {
    final slices = <SliceHeader>[];
    for (final nal in configuration.nals(sample)) {
      switch (nal[0] & 31) {
        case 7 || 8:
          configuration.store(nal);
        case 1 || 5:
          slices.add(SliceHeader(nal, configuration.pictures));
      }
    }
    if (slices.isEmpty) return null;
    final planeCount = slices.first.pps.sps.separateColorPlane ? 3 : 1;
    if (_references.length != planeCount) {
      _references = List.generate(planeCount, (_) => ReferenceState());
    }
    return _decodeAccessUnit(slices, _references);
  }
}

H264Picture _decodeAccessUnit(
  List<SliceHeader> slices, [
  List<ReferenceState>? references,
]) {
  final first = slices.first;
  if (slices.any((slice) => !first.samePicture(slice))) {
    throw const FormatException('H.264 sample contains more than one picture');
  }
  if (!first.pps.sps.separateColorPlane) {
    final state = references?.first;
    final pending = state?.begin(first);
    final picture = _decodePicture(slices, pending: pending);
    if (pending != null) state!.commit(pending, picture);
    return picture;
  }

  final planes = [<SliceHeader>[], <SliceHeader>[], <SliceHeader>[]];
  for (final slice in slices) {
    planes[slice.colorPlane].add(slice);
  }
  if (planes.any((plane) => plane.isEmpty)) {
    throw const FormatException('Incomplete H.264 picture color planes');
  }
  final pending = references == null
      ? null
      : [
          for (var i = 0; i < planes.length; i++)
            references[i].begin(planes[i].first),
        ];
  final pictures = [
    for (var i = 0; i < planes.length; i++)
      _decodePicture(planes[i], pending: pending?[i]),
  ];
  if (pending != null) {
    for (var i = 0; i < planes.length; i++) {
      references![i].commit(pending[i], pictures[i]);
    }
  }
  return H264Picture.fromPlanes(pictures[0], pictures[1], pictures[2]);
}

H264Picture _decodePicture(
  List<SliceHeader> slices, {
  PendingPicture? pending,
}) {
  final first = slices.first;
  final sps = first.pps.sps;
  if (sps.mbWidth * sps.mbHeight > 139264) {
    throw const FormatException(
      'H.264 picture exceeds the maximum macroblock count',
    );
  }
  final picture = H264Picture(sps);
  if (slices.any((slice) => slice.kind != SliceKind.intra)) {
    picture.motionL0 = MotionField(sps.mbWidth * 4, sps.mbHeight * 4);
  }
  if (slices.any((slice) => slice.kind == SliceKind.b)) {
    picture.motionL1 = MotionField(sps.mbWidth * 4, sps.mbHeight * 4);
  }
  final decoder = _Reconstruction(picture, first.pps, first.colorPlane);
  for (final slice in slices) {
    decoder.decode(slice, pending);
  }
  if (decoder.decoded != decoder.blocks.length) {
    throw const FormatException('Incomplete H.264 picture');
  }
  deblockPicture(decoder.blocks, picture);
  return picture;
}

final class _Reconstruction {
  _Reconstruction(this.picture, H264Pps pps, this._colorPlane)
    : _scaling = ScalingMatrices(pps),
      width = picture.sps.mbWidth,
      blocks = List<Macroblock?>.filled(
        picture.sps.mbWidth * picture.sps.mbHeight,
        null,
      );

  final H264Picture picture;
  final int width;
  final List<Macroblock?> blocks;
  final ScalingMatrices _scaling;
  final int _colorPlane;
  late final _lumaPrediction = IntraPrediction(picture.sps.lumaDepth);
  late final _chromaPrediction =
      picture.sps.chromaDepth == picture.sps.lumaDepth
      ? _lumaPrediction
      : IntraPrediction(picture.sps.chromaDepth);
  final _transform = IntraTransform();
  var decoded = 0;

  void decode(SliceHeader slice, PendingPicture? pending) {
    final SliceData reader = slice.pps.cabac
        ? CabacSlice(slice)
        : CavlcSlice(slice);
    final motion = picture.motionL0;
    final motion1 = picture.motionL1;
    final references = switch (slice.kind) {
      SliceKind.intra => (
        l0: const <ReferencePicture?>[],
        l1: const <ReferencePicture?>[],
      ),
      SliceKind.p => (
        l0: pending!.pList(slice),
        l1: const <ReferencePicture?>[],
      ),
      SliceKind.b => pending!.bLists(slice),
    };
    final b = slice.kind == SliceKind.b
        ? BDirect(slice, pending!.poc, references, motion!, motion1!)
        : null;
    var address = slice.firstMb;
    while (true) {
      if (address >= blocks.length || blocks[address] != null) {
        throw const FormatException('Overlapping or oversized H.264 slices');
      }
      final x = address % width;
      final row = address ~/ width;
      final left = x == 0 ? null : _neighbor(address - 1, slice);
      final top = row == 0 ? null : _neighbor(address - width, slice);
      final corner = row == 0 || x == 0
          ? null
          : _neighbor(address - width - 1, slice);
      final topRight = row == 0 || x + 1 == width
          ? null
          : _neighbor(address - width + 1, slice);
      final block = switch (slice.kind) {
        SliceKind.intra => reader.readIntra(left, top),
        SliceKind.p => reader.readP(left, top, motion!, x, row, references.l0),
        SliceKind.b => reader.readB(left, top, b!, x, row),
      };
      if (block.intra) {
        if (slice.kind == SliceKind.intra && motion != null) {
          final whole = (x: x * 4, y: row * 4, width: 4, height: 4);
          motion.setUnused(whole, slice.firstMb + 1);
          motion1?.setUnused(whole, slice.firstMb + 1);
        }
        bool usable(Macroblock? other) =>
            other != null && (!slice.pps.constrainedIntra || other.intra);
        final available = (
          left: usable(left),
          top: usable(top),
          corner: usable(corner),
          topRight: usable(topRight),
        );
        _reconstruct(block, reader.coefficients, x, row, available);
      } else {
        _reconstructInter(
          block,
          reader.coefficients,
          x,
          row,
          motion!,
          b?.l1,
          references,
          pending!.poc,
        );
      }
      blocks[address++] = block;
      decoded++;
      if (reader.endOfSlice()) return;
    }
  }

  Macroblock? _neighbor(int index, SliceHeader slice) {
    final block = blocks[index];
    return block?.slice == slice ? block : null;
  }

  void _reconstruct(
    Macroblock block,
    MacroblockCoefficients levels,
    int mbX,
    int mbY,
    Neighbors available,
  ) {
    final sps = picture.sps;
    final lumaQp = block.qp + sps.lumaQpOffset;
    final bypass = sps.transformBypass && lumaQp == 0;
    for (var component = 0; component < levels.levels.length; component++) {
      final (plane, stride, offset) = _target(component, mbX, mbY);
      if (block.pcm) {
        final samples = sps.chromaWidth * sps.chromaHeight;
        _copyBlock(
          levels.pcm,
          component == 0 ? 0 : 256 + (component - 1) * samples,
          plane,
          offset,
          stride,
          component == 0 ? 16 : sps.chromaWidth,
          height: component == 0 ? 16 : sps.chromaHeight,
        );
      } else if (component == 0 || sps.fullChroma) {
        _reconstructFullIntra(
          block,
          levels.levels[component],
          levels.dc[component],
          component,
          plane,
          stride,
          offset,
          component == 0 ? lumaQp : _chromaTransformQp(block, component - 1),
          bypass,
          available,
        );
      } else {
        _chromaPrediction.chroma(
          plane,
          stride,
          offset,
          block.chromaMode,
          available,
          sps.chromaHeight,
        );
        _reconstructChroma(
          plane,
          offset,
          stride,
          block,
          levels,
          component - 1,
          bypass,
        );
      }
    }
  }

  (List<int>, int, int) _target(int component, int mbX, int mbY) {
    final sps = picture.sps;
    if (component == 0) {
      final stride = picture.stride;
      return (picture.y, stride, (mbY * stride + mbX) * 16);
    }
    final stride = picture.chromaStride;
    return (
      component == 1 ? picture.cb : picture.cr,
      stride,
      mbY * stride * sps.chromaHeight + mbX * sps.chromaWidth,
    );
  }

  IntraPrediction _predictionFor(int component) =>
      component == 0 ? _lumaPrediction : _chromaPrediction;

  void _reconstructFullIntra(
    Macroblock block,
    Int32List levels,
    Int32List dcLevels,
    int component,
    List<int> plane,
    int stride,
    int yOffset,
    int qp,
    bool bypass,
    Neighbors available,
  ) {
    final prediction = _predictionFor(component);
    final four = _scaling.four[component + _colorPlane];
    if (block.intra16) {
      final mode = (block.type - 1) & 3;
      prediction.luma(plane, stride, yOffset, 16, mode, available);
      final dc = _transform.lumaDc(dcLevels, qp, four[0], bypass: bypass);
      if (bypass) {
        _transform.bypassMacroblock(levels, 0, dc, 16, 16, mode);
        _add(prediction, plane, stride, yOffset, 16, 16, 0);
      } else {
        for (var i = 0; i < 16; i++) {
          final x = blockX(i);
          final row = blockY(i);
          _transform.block4(levels, i * 16, qp, four, dc: dc[row * 4 + x]);
          _add(
            prediction,
            plane,
            stride,
            yOffset + 4 * (row * stride + x),
            4,
            16,
            4 * (row * 16 + x),
          );
        }
      }
    } else {
      final size = block.transform8x8 ? 8 : 4;
      final count = block.transform8x8 ? 4 : 16;
      for (var i = 0; i < count; i++) {
        final z = block.transform8x8 ? i * 4 : i;
        final x = blockX(z);
        final row = blockY(z);
        final offset = yOffset + 4 * (row * stride + x);
        final neighbors = _withinMb(x * 4, row * 4, size, available, i);
        final mode = block.predictionMode(x, row);
        prediction.luma(plane, stride, offset, size, mode, neighbors);
        if (bypass) {
          _transform.bypassBlock(levels, z * 16, size, mode: mode);
        } else if (block.transform8x8) {
          _transform.block8(
            levels,
            i * 64,
            qp,
            _scaling.eight[component + _colorPlane],
          );
        } else {
          _transform.block4(levels, i * 16, qp, four);
        }
        _add(prediction, plane, stride, offset, size, size, 0);
      }
    }
  }

  void _reconstructInter(
    Macroblock block,
    MacroblockCoefficients levels,
    int mbX,
    int mbY,
    MotionField motion,
    MotionField? motion1,
    ReferenceLists references,
    int poc,
  ) {
    final slice = block.slice;
    final owner = slice.firstMb + 1;
    final sps = picture.sps;
    final lumaQp = block.qp + sps.lumaQpOffset;
    final bypass = sps.transformBypass && lumaQp == 0;
    for (var component = 0; component < levels.levels.length; component++) {
      final (plane, stride, offset) = _target(component, mbX, mbY);
      final prediction = _predictionFor(component);
      predictInter(
        prediction.pixels,
        component,
        mbX,
        mbY,
        owner,
        motion,
        motion1,
        references,
        slice,
        poc,
      );
      if (component == 0 || sps.fullChroma) {
        _copyBlock(prediction.pixels, 0, plane, offset, stride, 16);
        final coded = block.codedPlane(component);
        if (coded == 0) continue;
        _addFullInterResiduals(
          block,
          levels.levels[component],
          component,
          plane,
          stride,
          offset,
          coded,
          component == 0 ? lumaQp : _chromaTransformQp(block, component - 1),
          bypass,
        );
      } else {
        _reconstructChroma(
          plane,
          offset,
          stride,
          block,
          levels,
          component - 1,
          bypass,
        );
      }
    }
  }

  void _addFullInterResiduals(
    Macroblock block,
    Int32List levels,
    int component,
    List<int> plane,
    int stride,
    int offset,
    int coded,
    int qp,
    bool bypass,
  ) {
    final prediction = _predictionFor(component);
    final matrix = component + _colorPlane;
    final size = block.transform8x8 ? 8 : 4;
    for (var z = 0; z < 16; z += block.transform8x8 ? 4 : 1) {
      if ((coded & (1 << z)) == 0) continue;
      if (bypass) {
        _transform.bypassBlock(levels, z * 16, size);
      } else if (block.transform8x8) {
        _transform.block8(levels, z * 16, qp, _scaling.interEight[matrix]);
      } else {
        _transform.block4(levels, z * 16, qp, _scaling.interFour[matrix]);
      }
      _add(
        prediction,
        plane,
        stride,
        offset + 4 * (blockY(z) * stride + blockX(z)),
        size,
        16,
        4 * (blockY(z) * 16 + blockX(z)),
      );
    }
  }

  void _reconstructChroma(
    List<int> plane,
    int offset,
    int stride,
    Macroblock block,
    MacroblockCoefficients levels,
    int component,
    bool bypass,
  ) {
    final height = picture.sps.chromaHeight;
    if (block.chromaPattern == 0) {
      _copyBlock(
        _chromaPrediction.pixels,
        0,
        plane,
        offset,
        stride,
        8,
        height: height,
      );
      return;
    }
    final count = picture.sps.chromaBlockCount;
    final qp = _chromaTransformQp(block, component);
    final weights = (block.intra
        ? _scaling.four
        : _scaling.interFour)[component + 1];
    final dc = _transform.chromaDc(
      levels.dc[component + 1],
      0,
      count,
      qp,
      weights[0],
      bypass: bypass,
    );
    if (bypass) {
      final mode =
          block.intra && (block.chromaMode == 1 || block.chromaMode == 2)
          ? 2 - block.chromaMode
          : 2;
      _transform.bypassMacroblock(
        levels.levels[component + 1],
        0,
        dc,
        8,
        height,
        mode,
      );
      _add(_chromaPrediction, plane, stride, offset, 8, 8, 0, height: height);
      return;
    }
    for (var i = 0; i < count; i++) {
      final x = (i & 1) * 4;
      final row = (i >> 1) * 4;
      _transform.block4(
        levels.levels[component + 1],
        i * 16,
        qp,
        weights,
        dc: dc[i],
      );
      _add(
        _chromaPrediction,
        plane,
        stride,
        offset + row * stride + x,
        4,
        8,
        row * 8 + x,
      );
    }
  }

  int _chromaTransformQp(Macroblock block, int component) {
    final pps = block.slice.pps;
    final depthOffset = pps.sps.chromaQpOffset;
    final offset = component == 0 ? pps.chromaOffset : pps.secondChromaOffset;
    return chromaQp(block.qp, offset, depthOffset) + depthOffset;
  }

  void _add(
    IntraPrediction prediction,
    List<int> plane,
    int stride,
    int start,
    int size,
    int predStride,
    int predStart, {
    int? height,
  }) {
    final maximum = prediction.maximum;
    for (var row = 0; row < (height ?? size); row++) {
      for (var x = 0; x < size; x++) {
        plane[start + row * stride + x] =
            (prediction.pixels[predStart + row * predStride + x] +
                    _transform.residual[row * size + x])
                .clamp(0, maximum);
      }
    }
  }
}

Neighbors _withinMb(int x, int y, int size, Neighbors mb, int block) {
  final corner =
      x != 0 && y != 0 ||
      (x != 0 && mb.top) ||
      (y != 0 && mb.left) ||
      (x == 0 && y == 0 && mb.corner);
  final right = x + size < 16;
  return (
    left: x != 0 || mb.left,
    top: y != 0 || mb.top,
    corner: corner,
    topRight: y == 0
        ? (right ? mb.top : mb.topRight)
        : right && !(size == 4 && (block == 3 || block == 11)),
  );
}

void _copyBlock(
  List<int> source,
  int sourceStart,
  List<int> target,
  int targetStart,
  int stride,
  int size, {
  int? height,
}) {
  for (var row = 0; row < (height ?? size); row++) {
    final start = targetStart + row * stride;
    target.setRange(start, start + size, source, sourceStart + row * size);
  }
}
