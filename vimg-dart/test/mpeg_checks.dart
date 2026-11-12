import 'package:vimg_dart/src/mpeg12/decode.dart';

/// FNV-1a over the visible Y, Cb and Cr rows, excluding coded padding.
int mpegYuvHash(MpegPicture picture) {
  var hash = 2166136261;
  for (final (component, plane) in picture.planes.indexed) {
    final sx = component == 0 ? 0 : picture.subsamplingX;
    final sy = component == 0 ? 0 : picture.subsamplingY;
    final stride = picture.stride >> sx;
    final width = (picture.width + sx) >> sx;
    final height = (picture.height + sy) >> sy;
    for (var y = 0; y < height; y++) {
      final row = y * stride;
      for (var x = 0; x < width; x++) {
        hash = ((hash ^ plane[row + x]) * 16777619) & 0xffffffff;
      }
    }
  }
  return hash;
}
