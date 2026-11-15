import 'dart:typed_data';

import 'package:image/image.dart' as image;

import '../yuv_image.dart';
import 'motion.dart';
import 'parameters.dart';

final class H264Picture {
  H264Picture(H264Sps sps, {bool? bottomField})
    : this._(
        sps,
        _samples(
          sps.mbWidth * _mbHeight(sps, bottomField) * 256,
          sps.lumaDepth,
        ),
        _chromaSamples(sps, bottomField),
        _chromaSamples(sps, bottomField),
        bottomField,
      );

  /// Assemble the independently decoded planes without copying samples.
  H264Picture.fromPlanes(H264Picture y, H264Picture cb, H264Picture cr)
    : this._(y.sps, y.y, cb.y, cr.y, y.bottomField);

  H264Picture.fromFields(H264Picture top, H264Picture bottom)
    : this._(
        top.sps,
        _weave(top.y, bottom.y, top.stride, top.sps.lumaDepth),
        _weave(top.cb, bottom.cb, top.chromaStride, top._chromaDepth),
        _weave(top.cr, bottom.cr, top.chromaStride, top._chromaDepth),
        null,
      );

  H264Picture._(this.sps, this.y, this.cb, this.cr, this.bottomField)
    : stride = sps.mbWidth * 16;

  final H264Sps sps;
  final int stride;
  final List<int> y, cb, cr;
  final bool? bottomField;
  H264Picture? _referenceFrame;
  int get mbHeight => _mbHeight(sps, bottomField);
  int get _fieldShift => bottomField == null ? 0 : 1;
  int get _chromaDepth =>
      sps.separateColorPlane ? sps.lumaDepth : sps.chromaDepth;
  int get chromaStride => sps.mbWidth * sps.chromaWidth;
  MotionField? motionL0;
  MotionField? motionL1;

  H264Picture referenceFrameWith(H264Picture bottom) =>
      _referenceFrame ??= H264Picture.fromFields(this, bottom);

  // References to a field of a decoded frame advance by two rows.
  // The bottom field begins one row later in the same sample storage.
  late final _bottomRows = [
    _skipRow(y, stride),
    _skipRow(cb, chromaStride),
    _skipRow(cr, chromaStride),
  ];

  List<int> referenceSamples(int plane, {required bool skipTopRow}) =>
      skipTopRow
      ? _bottomRows[plane]
      : switch (plane) {
          0 => y,
          1 => cb,
          _ => cr,
        };

  image.Image rgb({YuvImageScaler? scaler}) => yuvImage(
    y: y,
    cb: cb,
    cr: cr,
    stride: stride,
    chromaStride: chromaStride,
    subsamplingX: sps.fullChroma ? 0 : 1,
    subsamplingY: sps.chromaFormat == 1 ? 1 : 0,
    width: sps.width,
    height: sps.height >> _fieldShift,
    cropLeft: sps.cropLeft,
    cropTop: sps.cropTop >> _fieldShift,
    matrix: sps.color.matrix,
    fullRange: sps.color.fullRange,
    lumaDepth: sps.lumaDepth,
    chromaDepth: _chromaDepth,
    sampleAspect: sps.sampleAspect,
    scaler: scaler,
  );
}

int _mbHeight(H264Sps sps, bool? bottomField) =>
    sps.mbHeight >> (bottomField == null ? 0 : 1);

List<int> _chromaSamples(H264Sps sps, bool? bottomField) =>
    sps.chromaArrayType == 0
    ? const []
    : _samples(
        sps.mbWidth *
            _mbHeight(sps, bottomField) *
            sps.chromaWidth *
            sps.chromaHeight,
        sps.chromaDepth,
      );

List<int> _weave(List<int> top, List<int> bottom, int stride, int depth) {
  if (top.isEmpty) return const [];
  final result = _samples(top.length + bottom.length, depth);
  for (var row = 0; row < top.length; row += stride) {
    final start = row * 2;
    result.setRange(start, start + stride, top, row);
    result.setRange(start + stride, start + 2 * stride, bottom, row);
  }
  return result;
}

List<int> _samples(int count, int depth) =>
    depth == 8 ? Uint8List(count) : Uint16List(count);

List<int> _skipRow(List<int> data, int stride) => switch (data) {
  Uint8List() => Uint8List.sublistView(data, stride),
  Uint16List() => Uint16List.sublistView(data, stride),
  _ => const [],
};
