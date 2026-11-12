import 'dart:math' as math;
import 'dart:typed_data';

typedef MotionVector = ({int x, int y});
typedef MotionPartition = ({int x, int y, int width, int height});
typedef _Candidate = ({int reference, MotionVector vector});

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
  Uint8List? _direct;

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

  int storedReferenceAt(int x, int y) => _reference[y * width + x];

  bool directAt(int x, int y, int owner) {
    final index = _index(x, y);
    return index >= 0 && _owners[index] == owner && _direct?[index] == 1;
  }

  void markDirect(MotionPartition part) {
    final direct = _direct ??= Uint8List(width * height);
    for (var y = part.y; y < part.y + part.height; y++) {
      final start = y * width + part.x;
      direct.fillRange(start, start + part.width, 1);
    }
  }

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

  void setUnused(MotionPartition part, int owner) {
    setReference(part, owner, -1, -1);
    setVector(part, zeroMotion, zeroMotion);
  }

  _Candidate? _candidate(int x, int y, int owner) {
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
    final (a, b, c) = _neighbors(part, owner);
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

  int spatialReference(MotionPartition part, int owner) {
    final (a, b, c) = _neighbors(part, owner);
    var result = -1;
    for (final candidate in [a, b, c]) {
      final ref = candidate?.reference ?? -1;
      if (ref >= 0 && (result < 0 || ref < result)) result = ref;
    }
    return result;
  }

  (_Candidate?, _Candidate?, _Candidate?) _neighbors(
    MotionPartition part,
    int owner,
  ) {
    final x = part.x, y = part.y;
    final cx = x + part.width, cy = y - 1;
    // A prefilled direct or unused-list block can belong to a later 8×8.
    final later =
        cx ~/ 4 == x ~/ 4 &&
        cy >= 0 &&
        cy ~/ 4 == y ~/ 4 &&
        _scanIndex(cx, cy) >= _scanIndex(x, y);
    final corner =
        (later ? null : _candidate(cx, cy, owner)) ??
        _candidate(x - 1, cy, owner);
    return (_candidate(x - 1, y, owner), _candidate(x, cy, owner), corner);
  }
}

int _scanIndex(int x, int y) =>
    ((y & 2) << 2) | ((x & 2) << 1) | ((y & 1) << 1) | (x & 1);

int signedMotion(int value) => ((value + 32768) & 65535) - 32768;

int _median(int a, int b, int c) =>
    math.max(math.min(a, b), math.min(math.max(a, b), c));
