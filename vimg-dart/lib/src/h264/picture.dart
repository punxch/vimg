import 'dart:typed_data';

import 'package:image/image.dart' as image;

import '../yuv_image.dart';
import 'motion.dart';
import 'parameters.dart';

final class H264Picture {
  H264Picture(this.sps)
    : stride = sps.mbWidth * 16,
      y = Uint8List(sps.mbWidth * sps.mbHeight * 256),
      cb = Uint8List(
        sps.chromaFormat == 0 ? 0 : sps.mbWidth * sps.mbHeight * 64,
      ),
      cr = Uint8List(
        sps.chromaFormat == 0 ? 0 : sps.mbWidth * sps.mbHeight * 64,
      );

  final H264Sps sps;
  final int stride;
  final Uint8List y, cb, cr;
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
    sampleAspect: sps.sampleAspect,
    scaler: scaler,
  );
}
