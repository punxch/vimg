import 'slice_data.dart';

/// Maps between macroblock-pair scan order and sample rows in a frame (§6.4).
final class MbaffLayout {
  MbaffLayout(this.blocks, this.mbWidth);

  final List<Macroblock?> blocks;
  final int mbWidth;

  int column(int address) => (address >> 1) % mbWidth;
  int row(int address) => 2 * ((address >> 1) ~/ mbWidth) + (address & 1);

  static int firstRow(int row, int height, bool field) =>
      field ? (row & ~1) * height + (row & 1) : row * height;

  SampleNeighbor neighbor(
    int address,
    bool field,
    int x,
    int y,
    int width,
    int height,
  ) {
    const unavailable = (block: null, x: 0, y: 0);
    if (y >= height || (x >= width && y >= 0)) return unavailable;
    final sampleX = column(address) * width + x;
    final sampleY = firstRow(row(address), height, field) + y * (field ? 2 : 1);
    if (sampleX < 0 || sampleX >= mbWidth * width || sampleY < 0) {
      return unavailable;
    }
    final pairHeight = 2 * height;
    final top = 2 * ((sampleY ~/ pairHeight) * mbWidth + sampleX ~/ width);
    if (top >= blocks.length) return unavailable;
    final target = blocks[top];
    if (target == null) return unavailable;
    final line = sampleY % pairHeight;
    final targetField = target.mbaffField;
    final member = targetField ? line & 1 : line ~/ height;
    return (
      block: blocks[top + member],
      x: sampleX % width,
      y: targetField ? line >> 1 : line % height,
    );
  }
}
