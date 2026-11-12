import 'dart:math' as math;
import 'dart:typed_data';

typedef MotionVector = ({int x, int y});
typedef MotionPartition = ({int x, int y, int width, int height});

const zeroMotion = (x: 0, y: 0);

/// Per-4×4 motion data. Reference indexes are slice-local for entropy and
/// prediction. Reference identities remain comparable across slice boundaries.
final class MotionField {
  MotionField(this.width, this.height) {
    final size = width * height;
    _reference = Int8List(size)..fillRange(0, size, -1);
    _identity = Int32List(size)..fillRange(0, size, -1);
    _owners = Int32List(size);
    _decoded = Uint8List(size);
    _vectors = Int16List(size * 2);
    _differences = Int16List(size * 2);
  }

  final int width, height;
  late final Int8List _reference;
  late final Int32List _identity, _owners;
  late final Uint8List _decoded;
  late final Int16List _vectors, _differences;

  int _index(int x, int y) =>
      x < 0 || x >= width || y < 0 || y >= height ? -1 : y * width + x;

  int referenceAt(int x, int y, int owner) {
    final index = _index(x, y);
    return index < 0 || _owners[index] != owner ? -1 : _reference[index];
  }

  MotionVector differenceAt(int x, int y, int owner) {
    final index = _index(x, y);
    if (index < 0 || _owners[index] != owner || _decoded[index] == 0)
      return zeroMotion;
    return (x: _differences[index * 2], y: _differences[index * 2 + 1]);
  }

  MotionVector vectorAt(int x, int y) {
    final index = y * width + x;
    return (x: _vectors[index * 2], y: _vectors[index * 2 + 1]);
  }

  int identityAt(int x, int y) => _identity[y * width + x];

  void setReference(MotionPartition part, int owner, int index, int identity) {
    for (var y = part.y; y < part.y + part.height; y++) {
      final start = y * width + part.x;
      final end = start + part.width;
      _owners.fillRange(start, end, owner);
      _reference.fillRange(start, end, index);
      _identity.fillRange(start, end, identity);
    }
  }

  void setVector(
    MotionPartition part,
    MotionVector vector,
    MotionVector difference,
  ) {
    for (var y = part.y; y < part.y + part.height; y++) {
      for (var x = part.x; x < part.x + part.width; x++) {
        final index = y * width + x;
        _vectors[index * 2] = vector.x;
        _vectors[index * 2 + 1] = vector.y;
        _differences[index * 2] = difference.x;
        _differences[index * 2 + 1] = difference.y;
        _decoded[index] = 1;
      }
    }
  }

  void setIntra(MotionPartition part, int owner) {
    setReference(part, owner, -1, -1);
    setVector(part, zeroMotion, zeroMotion);
  }

  ({int reference, MotionVector vector})? _candidate(int x, int y, int owner) {
    final index = _index(x, y);
    if (index < 0 || _owners[index] != owner || _decoded[index] == 0)
      return null;
    return (reference: _reference[index], vector: vectorAt(x, y));
  }

  MotionVector predictSkip(MotionPartition part, int owner) {
    final left = _candidate(part.x - 1, part.y, owner);
    final top = _candidate(part.x, part.y - 1, owner);
    if (left == null ||
        top == null ||
        (left.reference == 0 && left.vector == zeroMotion) ||
        (top.reference == 0 && top.vector == zeroMotion)) {
      return zeroMotion;
    }
    return predict(part, owner, 0);
  }

  MotionVector predict(MotionPartition part, int owner, int reference) {
    final x = part.x, y = part.y;
    final a = _candidate(x - 1, y, owner);
    final b = _candidate(x, y - 1, owner);
    final c =
        _candidate(x + part.width, y - 1, owner) ??
        _candidate(x - 1, y - 1, owner);
    if (part.width == 4 && part.height == 2) {
      final preferred = y & 2 == 0 ? b : a;
      if (preferred?.reference == reference) return preferred!.vector;
    } else if (part.width == 2 && part.height == 4) {
      final preferred = x & 2 == 0 ? a : c;
      if (preferred?.reference == reference) return preferred!.vector;
    }
    if (b == null && c == null) return a?.vector ?? zeroMotion;
    final matches =
        (a?.reference == reference ? 1 : 0) +
        (b?.reference == reference ? 1 : 0) +
        (c?.reference == reference ? 1 : 0);
    if (matches == 1) {
      if (a?.reference == reference) return a!.vector;
      if (b?.reference == reference) return b!.vector;
      return c!.vector;
    }
    final av = a?.vector ?? zeroMotion;
    final bv = b?.vector ?? zeroMotion;
    final cv = c?.vector ?? zeroMotion;
    return (x: _median(av.x, bv.x, cv.x), y: _median(av.y, bv.y, cv.y));
  }
}

int _median(int a, int b, int c) =>
    math.max(math.min(a, b), math.min(math.max(a, b), c));
