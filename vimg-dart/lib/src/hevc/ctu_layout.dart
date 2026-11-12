import 'dart:typed_data';

import 'parameters.dart';

/// Translates raster slice addresses to the order in which CTUs are coded.
final class HevcCtuLayout {
  HevcCtuLayout(this.sps, HevcTiles? tiles) {
    final columns = tiles?.columns ?? [sps.ctbWidth];
    final rows = tiles?.rows ?? [sps.ctbHeight];
    if (columns.fold(0, (sum, n) => sum + n) != sps.ctbWidth ||
        rows.fold(0, (sum, n) => sum + n) != sps.ctbHeight) {
      throw const FormatException('HEVC tiles do not cover the picture');
    }
    final count = sps.ctbWidth * sps.ctbHeight;
    order = Int32List(count);
    index = Int32List(count);
    tile = Int32List(count);
    tileLeft = Int32List(count);
    tileWidth = Int32List(count);
    var top = 0, position = 0, tileId = 0;
    for (final height in rows) {
      var left = 0;
      for (final width in columns) {
        for (var y = top; y < top + height; y++) {
          for (var x = left; x < left + width; x++) {
            final raster = y * sps.ctbWidth + x;
            order[position] = raster;
            index[raster] = position++;
            tile[raster] = tileId;
            tileLeft[raster] = left;
            tileWidth[raster] = width;
          }
        }
        left += width;
        tileId++;
      }
      top += height;
    }
  }

  final HevcSps sps;
  late final Int32List order, index, tile, tileLeft, tileWidth;

  int atSample(int x, int y) =>
      (y >> sps.ctbLog2) * sps.ctbWidth + (x >> sps.ctbLog2);

  bool rowStart(int raster) => raster % sps.ctbWidth == tileLeft[raster];
}
