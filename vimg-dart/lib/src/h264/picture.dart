import 'dart:typed_data';

import 'package:image/image.dart' as image;

import '../yuv_image.dart';
import 'motion.dart';
import 'parameters.dart';

final class H264Picture {
  H264Picture(H264Sps sps)
    : this._(
        sps,
        _samples(sps.mbWidth * sps.mbHeight * 256, sps.lumaDepth),
        _chromaSamples(sps),
        _chromaSamples(sps),
      );

  /// Assemble the independently decoded planes without copying samples.
  H264Picture.fromPlanes(H264Picture y, H264Picture cb, H264Picture cr)
    : this._(y.sps, y.y, cb.y, cr.y);

  H264Picture._(this.sps, this.y, this.cb, this.cr) : stride = sps.mbWidth * 16;

  final H264Sps sps;
  final int stride;
  final List<int> y, cb, cr;
  int get chromaStride => sps.mbWidth * sps.chromaWidth;
  MotionField? motionL0;
  MotionField? motionL1;

  image.Image rgb({YuvImageScaler? scaler}) => yuvImage(
    y: y,
    cb: cb,
    cr: cr,
    stride: stride,
    chromaStride: chromaStride,
    subsamplingX: sps.fullChroma ? 0 : 1,
    subsamplingY: sps.chromaFormat == 1 ? 1 : 0,
    width: sps.width,
    height: sps.height,
    cropLeft: sps.cropLeft,
    cropTop: sps.cropTop,
    matrix: sps.color.matrix,
    fullRange: sps.color.fullRange,
    lumaDepth: sps.lumaDepth,
    chromaDepth: sps.separateColorPlane ? sps.lumaDepth : sps.chromaDepth,
    sampleAspect: sps.sampleAspect,
    scaler: scaler,
  );
}

List<int> _chromaSamples(H264Sps sps) => sps.chromaArrayType == 0
    ? const []
    : _samples(
        sps.mbWidth * sps.mbHeight * sps.chromaWidth * sps.chromaHeight,
        sps.chromaDepth,
      );

List<int> _samples(int count, int depth) =>
    depth == 8 ? Uint8List(count) : Uint16List(count);
