import 'dart:typed_data';

import 'package:image/image.dart' as image;

import '../yuv_image.dart';
import 'motion.dart';
import 'parameters.dart';

final class H264Picture {
  H264Picture(this.sps)
    : stride = sps.mbWidth * 16,
      y = _samples(sps.mbWidth * sps.mbHeight * 256, sps.lumaDepth),
      cb = _samples(
        sps.chromaFormat == 0 ? 0 : sps.mbWidth * sps.mbHeight * 64,
        sps.chromaDepth,
      ),
      cr = _samples(
        sps.chromaFormat == 0 ? 0 : sps.mbWidth * sps.mbHeight * 64,
        sps.chromaDepth,
      );

  final H264Sps sps;
  final int stride;
  final List<int> y, cb, cr;
  MotionField? motionL0;
  MotionField? motionL1;

  image.Image rgb({YuvImageScaler? scaler}) => yuvImage(
    y: y,
    cb: cb,
    cr: cr,
    stride: stride,
    chromaStride: stride >> 1,
    width: sps.width,
    height: sps.height,
    cropLeft: sps.cropLeft,
    cropTop: sps.cropTop,
    matrix: sps.color.matrix,
    fullRange: sps.color.fullRange,
    lumaDepth: sps.lumaDepth,
    chromaDepth: sps.chromaDepth,
    sampleAspect: sps.sampleAspect,
    scaler: scaler,
  );
}

List<int> _samples(int count, int depth) =>
    depth == 8 ? Uint8List(count) : Uint16List(count);
