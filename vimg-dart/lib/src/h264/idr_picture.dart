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
    return slices.isEmpty ? null : _decodePicture(slices);
  }
}

/// Sequential decoder. The container supplies one access unit at a time in
/// decode order, including reference pictures that are not selected for output.
final class H264StreamDecoder {
  H264StreamDecoder(this.configuration);

  final AvcConfiguration configuration;
  final _references = ReferenceState();

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
    final pending = _references.begin(slices.first);
    final picture = _decodePicture(slices, pending: pending);
    _references.commit(pending, picture);
    return picture;
  }
}

H264Picture _decodePicture(
  List<SliceHeader> slices, {
  PendingPicture? pending,
}) {
  final first = slices.first;
  final sps = first.pps.sps;
  if (sps.lumaDepth != 8 ||
      sps.chromaDepth != 8 ||
      sps.chromaFormat > 1 ||
      sps.transformBypass) {
    throw UnsupportedError(
      'H.264 decoding supports progressive 8-bit 4:2:0 and monochrome',
    );
  }
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
  final decoder = _Reconstruction(picture, first.pps);
  for (final slice in slices) {
    if (!first.samePicture(slice)) {
      throw const FormatException(
        'H.264 sample contains more than one picture',
      );
    }
    decoder.decode(slice, pending);
  }
  if (decoder.decoded != decoder.blocks.length) {
    throw const FormatException('Incomplete H.264 picture');
  }
  deblockPicture(
    decoder.blocks,
    picture.y,
    picture.cb,
    picture.cr,
    sps.mbWidth,
    picture.motionL0,
    picture.motionL1,
  );
  return picture;
}

final class _Reconstruction {
  _Reconstruction(this.picture, H264Pps pps)
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
  final _predict = IntraPrediction();
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
    final stride = picture.stride;
    final yOffset = (mbY * stride + mbX) * 16;
    final cStride = stride >> 1;
    final cOffset = (mbY * cStride + mbX) * 8;
    if (block.pcm) {
      _copyPcm(levels.pcm, 0, picture.y, yOffset, stride, 16);
      if (picture.cb.isNotEmpty) {
        _copyPcm(levels.pcm, 256, picture.cb, cOffset, cStride, 8);
        _copyPcm(levels.pcm, 320, picture.cr, cOffset, cStride, 8);
      }
      return;
    }

    if (block.intra16) {
      _predict.luma(
        picture.y,
        stride,
        yOffset,
        16,
        (block.type - 1) & 3,
        available,
      );
      final dc = _transform.lumaDc(
        levels.lumaDc,
        block.qp,
        _scaling.four[0][0],
      );
      for (var i = 0; i < 16; i++) {
        final x = blockX(i);
        final row = blockY(i);
        _transform.block4(
          levels.luma,
          i * 16,
          block.qp,
          _scaling.four[0],
          dc: dc[row * 4 + x],
        );
        _add(
          picture.y,
          stride,
          yOffset + 4 * (row * stride + x),
          4,
          16,
          4 * (row * 16 + x),
        );
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
        _predict.luma(
          picture.y,
          stride,
          offset,
          size,
          block.predictionMode(x, row),
          neighbors,
        );
        if (block.transform8x8) {
          _transform.block8(levels.luma, i * 64, block.qp, _scaling.eight);
        } else {
          _transform.block4(levels.luma, i * 16, block.qp, _scaling.four[0]);
        }
        _add(picture.y, stride, offset, size, size, 0);
      }
    }
    if (picture.cb.isEmpty) return;
    _chroma(picture.cb, cOffset, cStride, available, block, levels, 0);
    _chroma(picture.cr, cOffset, cStride, available, block, levels, 1);
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
    final stride = picture.stride;
    final offset = (mbY * stride + mbX) * 16;
    predictInter(
      _predict.pixels,
      0,
      mbX,
      mbY,
      owner,
      motion,
      motion1,
      references,
      slice,
      poc,
    );
    _copyPcm(_predict.pixels, 0, picture.y, offset, stride, 16);
    if (block.codedLuma != 0) {
      final size = block.transform8x8 ? 8 : 4;
      for (var z = 0; z < 16; z += block.transform8x8 ? 4 : 1) {
        if ((block.codedLuma & (1 << z)) == 0) continue;
        if (block.transform8x8) {
          _transform.block8(levels.luma, z * 16, block.qp, _scaling.interEight);
        } else {
          _transform.block4(
            levels.luma,
            z * 16,
            block.qp,
            _scaling.interFour[0],
          );
        }
        _add(
          picture.y,
          stride,
          offset + 4 * (blockY(z) * stride + blockX(z)),
          size,
          16,
          4 * (blockY(z) * 16 + blockX(z)),
        );
      }
    }

    if (picture.cb.isEmpty) return;
    final chromaStride = stride >> 1;
    final chromaOffset = (mbY * chromaStride + mbX) * 8;
    for (var component = 0; component < 2; component++) {
      final plane = component == 0 ? picture.cb : picture.cr;
      predictInter(
        _predict.pixels,
        component + 1,
        mbX,
        mbY,
        owner,
        motion,
        motion1,
        references,
        slice,
        poc,
      );
      _copyPcm(_predict.pixels, 0, plane, chromaOffset, chromaStride, 8);
      if (block.chromaPattern == 0) continue;
      final pps = slice.pps;
      final qp = chromaQp(
        block.qp,
        component == 0 ? pps.chromaOffset : pps.secondChromaOffset,
      );
      final weights = _scaling.interFour[component + 1];
      final dc = IntraTransform.chromaDc(
        levels.chromaDc,
        component * 4,
        qp,
        weights[0],
      );
      for (var i = 0; i < 4; i++) {
        final x = (i & 1) * 4;
        final row = (i >> 1) * 4;
        _transform.block4(
          levels.chroma,
          (component * 4 + i) * 16,
          qp,
          weights,
          dc: dc[i],
        );
        _add(
          plane,
          chromaStride,
          chromaOffset + row * chromaStride + x,
          4,
          8,
          row * 8 + x,
        );
      }
    }
  }

  void _chroma(
    Uint8List plane,
    int offset,
    int stride,
    Neighbors available,
    Macroblock block,
    MacroblockCoefficients levels,
    int component,
  ) {
    final pps = block.slice.pps;
    final qp = chromaQp(
      block.qp,
      component == 0 ? pps.chromaOffset : pps.secondChromaOffset,
    );
    final weights = _scaling.four[component + 1];
    _predict.chroma(plane, stride, offset, block.chromaMode, available);
    final dc = IntraTransform.chromaDc(
      levels.chromaDc,
      component * 4,
      qp,
      weights[0],
    );
    for (var i = 0; i < 4; i++) {
      final x = (i & 1) * 4;
      final row = (i >> 1) * 4;
      _transform.block4(
        levels.chroma,
        (component * 4 + i) * 16,
        qp,
        weights,
        dc: dc[i],
      );
      _add(plane, stride, offset + row * stride + x, 4, 8, row * 8 + x);
    }
  }

  void _add(
    Uint8List plane,
    int stride,
    int start,
    int size,
    int predStride,
    int predStart,
  ) {
    for (var row = 0; row < size; row++) {
      for (var x = 0; x < size; x++) {
        plane[start + row * stride + x] =
            (_predict.pixels[predStart + row * predStride + x] +
                    _transform.residual[row * size + x])
                .clamp(0, 255);
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

void _copyPcm(
  Uint8List source,
  int sourceStart,
  Uint8List target,
  int targetStart,
  int stride,
  int size,
) {
  for (var row = 0; row < size; row++) {
    final start = targetStart + row * stride;
    target.setRange(start, start + size, source, sourceStart + row * size);
  }
}
