import 'dart:typed_data';

import 'package:image/image.dart' as image;

import '../yuv_image.dart';
import 'parameters.dart';

final class HevcPicture {
  HevcPicture(this.sps)
    : luma = HevcPlane(sps.codedWidth, sps.codedHeight, sps.lumaDepth),
      cb = sps.chromaArrayType == 0
          ? null
          : HevcPlane(
              sps.codedWidth >> 1,
              sps.codedHeight >> 1,
              sps.chromaDepth,
            ),
      cr = sps.chromaArrayType == 0
          ? null
          : HevcPlane(
              sps.codedWidth >> 1,
              sps.codedHeight >> 1,
              sps.chromaDepth,
            );

  final HevcSps sps;
  final HevcPlane luma;
  final HevcPlane? cb, cr;

  image.Image rgb() => yuv420Image(
    y: luma.samples,
    cb: cb?.samples ?? const [],
    cr: cr?.samples ?? const [],
    stride: luma.width,
    chromaStride: cb?.width ?? 0,
    width: sps.width,
    height: sps.height,
    cropLeft: sps.crop.left,
    cropTop: sps.crop.top,
    matrix: sps.colour.matrix,
    fullRange: sps.colour.fullRange,
    lumaDepth: sps.lumaDepth,
    chromaDepth: sps.chromaDepth,
  );
}

final class HevcPlane {
  HevcPlane(this.width, this.height, this.depth)
    : samples = Uint16List(width * height),
      _reconstructed = Uint8List((width >> 2) * (height >> 2)),
      maximum = (1 << depth) - 1;

  final int width, height, depth, maximum;
  final Uint16List samples;
  final Uint8List _reconstructed;

  bool contains(int x, int y) => x >= 0 && y >= 0 && x < width && y < height;

  int _cell(int x, int y) => (y >> 2) * (width >> 2) + (x >> 2);

  bool reconstructed(int x, int y) =>
      contains(x, y) && _reconstructed[_cell(x, y)] != 0;

  void mark(int x, int y, int size) {
    for (var row = y; row < y + size; row += 4) {
      final start = _cell(x, row);
      _reconstructed.fillRange(start, start + (size >> 2), 1);
    }
  }
}
