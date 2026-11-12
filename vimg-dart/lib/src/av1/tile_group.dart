import 'dart:math' as math;
import 'dart:typed_data';

import 'bitstream.dart';

/// Tile boundaries in 4×4 mode-info units, including the last boundary.
final class Av1TileLayout {
  const Av1TileLayout._(
    this.columns,
    this.rows,
    this.indexBits,
    this.sizeBytes,
    this.contextTile,
  );

  factory Av1TileLayout.read(Av1Bits bits, int width, int height, int sbLog2) {
    final sb = 1 << sbLog2;
    final miShift = sbLog2 - 2;
    final miColumns = 2 * ((width + 7) >> 3), miRows = 2 * ((height + 7) >> 3);
    final sbColumns = (width + sb - 1) >> sbLog2;
    final sbRows = (height + sb - 1) >> sbLog2;
    final maxWidth = 4096 >> sbLog2;
    final maxArea = (4096 * 2304) >> (2 * sbLog2);
    int log2(int block, int target) => ((target - 1) ~/ block).bitLength;
    final minColumnBits = log2(maxWidth, sbColumns);
    final minTilesBits = math.max(
      minColumnBits,
      log2(maxArea, sbRows * sbColumns),
    );
    final columns = <int>[], rows = <int>[];
    int columnBits, rowBits;
    if (bits.flag()) {
      int uniformLog2(int minimum, int size) {
        final maximum = log2(1, math.min(size, 64));
        if (minimum > maximum)
          throw const FormatException('AV1 frame exceeds tile layout limits');
        while (minimum < maximum && bits.flag()) {
          minimum++;
        }
        return minimum;
      }

      columnBits = uniformLog2(minColumnBits, sbColumns);
      final stepX = 1 + ((sbColumns - 1) >> columnBits);
      for (var start = 0; start < sbColumns; start += stepX) {
        columns.add(start << miShift);
      }
      rowBits = uniformLog2(math.max(minTilesBits - columnBits, 0), sbRows);
      final stepY = 1 + ((sbRows - 1) >> rowBits);
      for (var start = 0; start < sbRows; start += stepY) {
        rows.add(start << miShift);
      }
    } else {
      var widest = 0;
      for (var start = 0; start < sbColumns;) {
        if (columns.length == 64)
          throw const FormatException('Too many AV1 tile columns');
        final size = bits.uniform(math.min(sbColumns - start, maxWidth)) + 1;
        columns.add(start << miShift);
        widest = math.max(widest, size);
        start += size;
      }
      final area =
          (sbRows * sbColumns) >> (minTilesBits == 0 ? 0 : minTilesBits + 1);
      final maxHeight = math.max(1, area ~/ widest);
      for (var start = 0; start < sbRows;) {
        if (rows.length == 64)
          throw const FormatException('Too many AV1 tile rows');
        final size = bits.uniform(math.min(sbRows - start, maxHeight)) + 1;
        rows.add(start << miShift);
        start += size;
      }
      columnBits = log2(1, columns.length);
      rowBits = log2(1, rows.length);
    }
    final indexBits = columnBits + rowBits;
    final context = bits.read(indexBits);
    if (context >= rows.length * columns.length)
      throw const FormatException('Invalid AV1 context update tile');
    final sizeBytes = indexBits == 0 ? 0 : bits.read(2) + 1;
    return Av1TileLayout._(
      List.unmodifiable([...columns, miColumns]),
      List.unmodifiable([...rows, miRows]),
      indexBits,
      sizeBytes,
      context,
    );
  }

  final List<int> columns, rows;
  final int indexBits, sizeBytes, contextTile;

  int get count => (columns.length - 1) * (rows.length - 1);
}

typedef Av1Tile = ({int index, Uint8List payload});

/// AV1 §5.11.1. Tile lengths are little-endian, except the last tile, which
/// consumes the remaining bytes of its group.
List<Av1Tile> readAv1TileGroup(
  Av1Bits bits,
  Av1TileLayout layout, {
  required bool combined,
}) {
  final explicit = layout.count > 1 && bits.flag();
  if (explicit && combined)
    throw const FormatException(
      'AV1 frame OBU must contain its entire tile group',
    );
  final start = explicit ? bits.read(layout.indexBits) : 0;
  final end = explicit ? bits.read(layout.indexBits) : layout.count - 1;
  if (start > end || end >= layout.count)
    throw const FormatException('Invalid AV1 tile group range');
  bits.align();

  final tiles = <Av1Tile>[];
  for (var index = start; index <= end; index++) {
    var size = bits.remaining >> 3;
    if (index != end) {
      size = 0;
      for (var i = 0; i < layout.sizeBytes; i++) {
        size |= bits.read(8) << (8 * i);
      }
      size++;
    }
    if (size <= 0 || size > bits.remaining >> 3)
      throw const FormatException('Invalid AV1 tile payload size');
    final offset = bits.position >> 3;
    tiles.add((
      index: index,
      payload: Uint8List.sublistView(bits.data, offset, offset + size),
    ));
    bits.position += 8 * size;
  }
  return tiles;
}
