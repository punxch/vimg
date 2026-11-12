typedef HevcBlock = ({int x, int y, int width, int height});
typedef HevcVector = ({int x, int y});
typedef HevcMotion = ({int index, int poc, bool longTerm, HevcVector vector});
typedef HevcMotionPair = ({HevcMotion? l0, HevcMotion? l1});

const hevcZeroVector = (x: 0, y: 0);

/// The 4×4 motion grid stores picture identities and vectors. Each cell
/// shares its prediction block's entry.
final class HevcMotionField {
  HevcMotionField(int width, int height)
    : _stride = width >> 2,
      _cells = List.filled((width >> 2) * (height >> 2), null);

  final int _stride;
  final List<HevcMotionPair?> _cells;

  HevcMotionPair? at(int x, int y) => _cells[(y >> 2) * _stride + (x >> 2)];

  void store(HevcBlock block, HevcMotionPair motion) {
    final cells = block.width >> 2;
    for (var y = block.y; y < block.y + block.height; y += 4) {
      final start = (y >> 2) * _stride + (block.x >> 2);
      _cells.fillRange(start, start + cells, motion);
    }
  }
}

bool hevcMotionBoundary(HevcMotionPair p, HevcMotionPair q) {
  bool matches(HevcMotion? a, HevcMotion? b) {
    if (a == null || b == null) return a == b;
    return a.poc == b.poc &&
        (a.vector.x - b.vector.x).abs() < 4 &&
        (a.vector.y - b.vector.y).abs() < 4;
  }

  return !(matches(p.l0, q.l0) && matches(p.l1, q.l1)) &&
      !(matches(p.l0, q.l1) && matches(p.l1, q.l0));
}
