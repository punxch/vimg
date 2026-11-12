import 'dart:typed_data';

import 'package:image/image.dart' as image;

import 'access_unit.dart';
import 'deblock.dart';
import 'intra_blocks.dart';
import 'intra_prediction.dart';
import 'parameters.dart';
import 'transforms.dart';

/// Decoder for independently decodable H.264 pictures. Full-GOP decoding can
/// reuse the same reconstructed planes for reference pictures.
final class H264IdrDecoder {
  H264IdrDecoder(this.configuration);

  final AvcConfiguration configuration;

  H264Picture? decode(Uint8List sample) {
    final slices = <IdrSlice>[];
    for (final nal in configuration.nals(sample)) {
      switch (nal[0] & 31) {
        case 7 || 8:
          configuration.store(nal);
        case 5:
          slices.add(IdrSlice(nal, configuration.pictures));
      }
    }
    return slices.isEmpty ? null : H264Picture.decode(slices);
  }
}

final class H264Picture {
  H264Picture._(this.sps)
    : stride = sps.mbWidth * 16,
      y = Uint8List(sps.mbWidth * sps.mbHeight * 256),
      cb = Uint8List(
        sps.chromaFormat == 0 ? 0 : sps.mbWidth * sps.mbHeight * 64,
      ),
      cr = Uint8List(
        sps.chromaFormat == 0 ? 0 : sps.mbWidth * sps.mbHeight * 64,
      );

  factory H264Picture.decode(List<IdrSlice> slices) {
    final first = slices.first;
    final sps = first.pps.sps;
    if (sps.lumaDepth != 8 ||
        sps.chromaDepth != 8 ||
        sps.chromaFormat > 1 ||
        sps.transformBypass) {
      throw UnsupportedError(
        'H.264 IDR decoding supports progressive 8-bit 4:2:0 and monochrome',
      );
    }
    if (sps.mbWidth * sps.mbHeight > 139264) {
      throw const FormatException(
        'H.264 picture exceeds the maximum macroblock count',
      );
    }
    final picture = H264Picture._(sps);
    final decoder = _Reconstruction(picture, first.pps);
    for (final slice in slices) {
      if (slice.pps != first.pps ||
          slice.frameNum != first.frameNum ||
          slice.idrId != first.idrId ||
          slice.pocLsb != first.pocLsb) {
        throw const FormatException(
          'H.264 sample contains more than one IDR picture',
        );
      }
      if (!slice.pps.cabac)
        throw UnsupportedError('H.264 CAVLC slices are unavailable');
      decoder.decode(slice);
    }
    if (decoder.decoded != decoder.blocks.length) {
      throw const FormatException('Incomplete H.264 IDR picture');
    }
    deblockIntra(
      decoder.blocks,
      picture.y,
      picture.cb,
      picture.cr,
      sps.mbWidth,
    );
    return picture;
  }

  final H264Sps sps;
  final int stride;
  final Uint8List y, cb, cr;

  image.Image rgb() {
    final pixels = image.Image(width: sps.width, height: sps.height);
    final (rv, gu, gv, bu) = switch (sps.color.matrix) {
      1 => (1.5748, 0.187324, 0.468124, 1.8556), // BT.709
      9 || 10 => (1.4746, 0.164553, 0.571353, 1.8814), // BT.2020
      _ => (1.402, 0.344136, 0.714136, 1.772), // BT.601 / unspecified
    };
    final fullRange = sps.color.fullRange;
    final scale = fullRange ? 1.0 : 255 / 224;
    const precision = 1 << 14;
    final red = (rv * scale * precision).round();
    final greenU = (gu * scale * precision).round();
    final greenV = (gv * scale * precision).round();
    final blue = (bu * scale * precision).round();
    final yScale = (precision * (fullRange ? 1.0 : 255 / 219)).round();
    final bias = fullRange ? 0 : 16;
    for (final pixel in pixels) {
      final x = sps.cropLeft + pixel.x;
      final row = sps.cropTop + pixel.y;
      final luma = (y[row * stride + x] - bias) * yScale + (precision >> 1);
      final offset = (row >> 1) * (stride >> 1) + (x >> 1);
      final u = cb.isEmpty ? 0 : cb[offset] - 128;
      final v = cr.isEmpty ? 0 : cr[offset] - 128;
      pixel.setRgb(
        ((luma + red * v) >> 14).clamp(0, 255),
        ((luma - greenU * u - greenV * v) >> 14).clamp(0, 255),
        ((luma + blue * u) >> 14).clamp(0, 255),
      );
    }
    return pixels;
  }
}

final class _Reconstruction {
  _Reconstruction(this.picture, H264Pps pps)
    : _scaling = IntraScaling(pps),
      width = picture.sps.mbWidth,
      blocks = List<IntraBlock?>.filled(
        picture.sps.mbWidth * picture.sps.mbHeight,
        null,
      );

  final H264Picture picture;
  final int width;
  final List<IntraBlock?> blocks;
  final IntraScaling _scaling;
  final _predict = IntraPrediction();
  final _transform = IntraTransform();
  var decoded = 0;

  void decode(IdrSlice slice) {
    final reader = CabacIntraSlice(slice);
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
      final block = reader.read(left, top);
      final available = (
        left: left != null,
        top: top != null,
        corner: corner != null,
        topRight: topRight != null,
      );
      _reconstruct(block, reader.coefficients, x, row, available);
      blocks[address++] = block;
      decoded++;
      if (reader.endOfSlice()) return;
    }
  }

  IntraBlock? _neighbor(int index, IdrSlice slice) {
    final block = blocks[index];
    return block?.slice == slice ? block : null;
  }

  void _reconstruct(
    IntraBlock block,
    IntraCoefficients levels,
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

  void _chroma(
    Uint8List plane,
    int offset,
    int stride,
    Neighbors available,
    IntraBlock block,
    IntraCoefficients levels,
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
