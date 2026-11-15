part of 'decoder.dart';

typedef _Vector = ({int row, int column});
const _zeroVector = (row: 0, column: 0);

const _nearest = 10, _near = 11, _zeroMotion = 12, _newMotion = 13;
const _last = 1, _golden = 2, _alt = 3;
const _interModeTree = [-2, 2, 0, 4, -1, -3];
const _interpolationTree = [0, 2, -1, -2];
const _jointTree = [0, 2, -1, 4, -2, -3];
const _classTree = [
  0,
  2,
  -1,
  4,
  6,
  8,
  -2,
  -3,
  10,
  12,
  -4,
  -5,
  -6,
  14,
  16,
  18,
  -7,
  -8,
  -9,
  -10,
];
const _fractionTree = [0, 2, -1, 4, -2, -3];
const _contextByCounter = [
  2,
  3,
  4,
  1,
  3,
  9,
  0,
  9,
  9,
  5,
  5,
  9,
  5,
  9,
  9,
  9,
  9,
  9,
  6,
];
const _subblockByColumn = [(1, 2), (1, 3), (3, 2), (3, 3)];

final class _Motion {
  _Motion(this.first, this.second, this.filter);
  final int first, second, filter;
  final vectors = List<_Vector>.filled(8, _zeroVector);
  int mode = _zeroMotion;

  bool get compound => second > 0;
  int reference(int list) => list == 0 ? first : second;
  bool uses(int ref) => first == ref || second == ref;
  _Vector vector(int list, int subblock) => vectors[4 * list + subblock];
}

typedef _BlockInfo = ({
  int width,
  int height,
  int transform,
  int segment,
  bool skip,
  _Motion? motion,
  bool predictedSegment,
});

final class _BlockMap {
  _BlockMap(this.columns, this.rows)
    : _blocks = List<_BlockInfo?>.filled(columns * rows, null);
  final int columns, rows;
  final List<_BlockInfo?> _blocks;

  _BlockInfo? at(int x, int y) => _blocks[y * columns + x];

  void fill(int x, int y, int right, int bottom, _BlockInfo block) {
    for (var row = y; row < bottom; row++) {
      _blocks.fillRange(row * columns + x, row * columns + right, block);
    }
  }
}

int _flag(bool value) => value ? 1 : 0;
int _blockSizeIndex(int width, int height) {
  final x = width.bitLength - 3, y = height.bitLength - 3;
  return 3 * math.min<int>(x, y) +
      (x < y
          ? 1
          : x > y
          ? 2
          : 0);
}

/// VP9 §9.3.2 probabilities for choosing single and compound references.
final class _ReferenceNeighbors {
  _ReferenceNeighbors(this.above, this.left);
  final _BlockInfo? above, left;

  int get isInter {
    final a = above, l = left;
    if (a == null || l == null) {
      final only = a ?? l;
      return only != null && only.motion == null ? 2 : 0;
    }
    final count = _flag(a.motion == null) + _flag(l.motion == null);
    return count == 2 ? 3 : count;
  }

  int get interpolation {
    final a = above?.motion?.filter ?? 3, l = left?.motion?.filter ?? 3;
    return a == l || l == 3
        ? a
        : a == 3
        ? l
        : 3;
  }

  int compoundMode(int fixed) {
    final a = above, l = left;
    final am = a?.motion, lm = l?.motion;
    final ac = am?.compound ?? false, lc = lm?.compound ?? false;
    if (a == null && l == null) return 1;
    if (a == null || l == null) {
      final m = am ?? lm;
      return m?.compound == true ? 3 : _flag(m?.first == fixed);
    }
    if (!ac && !lc) return _flag((am?.first == fixed) != (lm?.first == fixed));
    if (ac && lc) return 4;
    final single = ac ? lm : am;
    return 2 + _flag(single == null || single.first == fixed);
  }

  int compoundReference(
    int fixed,
    int variable0,
    int variable1,
    int variableIndex,
  ) {
    final a = above?.motion, l = left?.motion;
    int ref(_Motion m) => m.compound ? m.reference(variableIndex) : m.first;
    if (a == null && l == null) return 2;
    if (a == null || l == null) {
      final neighbor = (a ?? l)!;
      final different = _flag(ref(neighbor) != variable1);
      return (above == null || left == null)
          ? (neighbor.compound ? 4 : 3) * different
          : 1 + 2 * different;
    }
    final ar = ref(a), lr = ref(l);
    if (ar == variable1 && lr == variable1) return 0;
    if (!a.compound && !l.compound) {
      if ((ar == fixed && lr == variable0) || (lr == fixed && ar == variable0))
        return 4;
      return ar == lr ? 3 : 1;
    }
    if (a.compound && l.compound) return ar == lr ? 4 : 2;
    final compound = a.compound ? ar : lr, single = a.compound ? lr : ar;
    if (compound == variable1) return 1;
    return single == variable1 ? 2 : 4;
  }

  int get singleLast {
    final a = above?.motion, l = left?.motion;
    if (a == null && l == null) return 2;
    if (a == null || l == null) {
      final m = (a ?? l)!;
      return m.compound
          ? 1 + _flag(m.uses(_last))
          : 4 * _flag(m.first == _last);
    }
    if (a.compound && l.compound)
      return 1 + _flag(a.uses(_last) || l.uses(_last));
    if (!a.compound && !l.compound)
      return 2 * (_flag(a.first == _last) + _flag(l.first == _last));
    final single = a.compound ? l : a, compound = a.compound ? a : l;
    return (single.first == _last ? 3 : 0) + _flag(compound.uses(_last));
  }

  int get singleGolden {
    final a = above?.motion, l = left?.motion;
    if (a == null && l == null) return 2;
    if (a == null || l == null) {
      final m = (a ?? l)!;
      if (above == null || left == null) {
        if (!m.compound && m.first == _last) return 2;
        return (m.compound ? 3 : 4) * _flag(m.uses(_golden));
      }
      if (m.compound) return 1 + 2 * _flag(m.uses(_golden));
      return m.first == _last ? 3 : 4 * _flag(m.first == _golden);
    }
    if (a.compound && l.compound) {
      return a.first == l.first && a.second == l.second
          ? 3 * _flag(a.uses(_golden))
          : 2;
    }
    if (!a.compound && !l.compound) {
      if (a.first == _last && l.first == _last) return 3;
      if (a.first == _last || l.first == _last)
        return 4 * _flag(a.first == _golden || l.first == _golden);
      return 2 * (_flag(a.first == _golden) + _flag(l.first == _golden));
    }
    final single = a.compound ? l : a, compound = a.compound ? a : l;
    final hasGolden = _flag(compound.uses(_golden));
    return switch (single.first) {
      _golden => 3 + hasGolden,
      _alt => hasGolden,
      _ => 1 + 2 * hasGolden,
    };
  }
}

extension _ReadMotion on _FrameDecoder {
  _Motion _motion(
    int x,
    int y,
    int width,
    int height,
    _ReferenceNeighbors neighbors,
    int? forcedReference,
    bool skipSegment,
  ) {
    final (first, second) = forcedReference == null
        ? _readReferences(neighbors)
        : (forcedReference, 0);
    final subblock = width < 8 || height < 8;
    if (subblock && skipSegment) {
      throw const FormatException('VP9 skip segment uses a sub-8x8 block');
    }
    final positions = vp9MotionNeighbors[_blockSizeIndex(width, height)];
    _Motion? candidate((int, int) position) {
      final (dy, dx) = position;
      final cx = x + dx, cy = y + dy;
      return cx >= _tileLeft &&
              cx < _tileRight &&
              cy >= 0 &&
              cy < _header.miRows
          ? blocks.at(cx, cy)?.motion
          : null;
    }

    var counter = 0;
    for (var i = 0; i < 2; i++) {
      final (dy, dx) = positions[i];
      final cx = x + dx, cy = y + dy;
      if (cx >= _tileLeft &&
          cx < _tileRight &&
          cy >= 0 &&
          cy < _header.miRows) {
        final neighbor = blocks.at(cx, cy);
        if (neighbor != null) {
          counter += switch (neighbor.motion?.mode) {
            _zeroMotion => 3,
            _newMotion => 1,
            _nearest || _near => 0,
            _ => 9,
          };
        }
      }
    }
    final modeContext = _contextByCounter[counter] * 3;
    int readMode() =>
        10 +
        entropy.tree(
          _bits,
          _interModeTree,
          Vp9Probability.interMode,
          modeContext,
        );
    final mode = skipSegment
        ? _zeroMotion
        : subblock
        ? _nearest
        : readMode();
    final raw = _header.interpolation;
    final filter = raw == null
        ? entropy.tree(
            _bits,
            _interpolationTree,
            Vp9Probability.interpolation,
            2 * neighbors.interpolation,
          )
        : const [1, 0, 2, 3][raw];
    final motion = _Motion(first, second, filter);

    List<_Vector> candidates(int reference, int sub) {
      final values = <_Vector>[];
      void add(_Vector value) {
        if (values.length < 2 && !values.contains(value)) values.add(value);
      }

      final previous = previousMotion?.at(x, y)?.motion;
      for (final (i, position) in positions.indexed) {
        final neighbor = candidate(position);
        if (neighbor == null || !neighbor.uses(reference)) continue;
        final index = sub >= 0 && i < 2
            ? (position.$2 == 0
                  ? _subblockByColumn[sub].$2
                  : _subblockByColumn[sub].$1)
            : 3;
        add(neighbor.vector(neighbor.first == reference ? 0 : 1, index));
      }
      if (previous != null && previous.uses(reference)) {
        add(previous.vector(previous.first == reference ? 0 : 1, 3));
      }
      void different(_Motion? m) {
        if (m == null || values.length == 2) return;
        for (var list = 0; list <= _flag(m.compound); list++) {
          final ref = m.reference(list), vector = m.vector(list, 3);
          if (ref == reference || (list == 1 && vector == m.vector(0, 3)))
            continue;
          final negate =
              _header.referenceBiases[ref - 1] !=
              _header.referenceBiases[reference - 1];
          add(negate ? (row: -vector.row, column: -vector.column) : vector);
        }
      }

      for (final position in positions) {
        different(candidate(position));
      }
      different(previous);
      while (values.length < 2) {
        values.add(_zeroVector);
      }
      final bw = math.max(1, width >> 3), bh = math.max(1, height >> 3);
      return [
        for (final value in values)
          (
            row: value.row.clamp(
              -y * 64 - 128,
              (_header.miRows - y - bh) * 64 + 128,
            ),
            column: value.column.clamp(
              -x * 64 - 128,
              (_header.miColumns - x - bw) * 64 + 128,
            ),
          ),
      ];
    }

    _Vector readVector(int list, int mode, int sub) {
      if (mode == _zeroMotion) return _zeroVector;
      final reference = motion.reference(list);
      if (sub < 0 || mode == _newMotion) {
        final vectors = candidates(reference, -1);
        final chosen = vectors[mode == _near ? 1 : 0];
        final base = _header.highPrecisionMotion && _usesHighPrecision(chosen)
            ? chosen
            : (row: chosen.row ~/ 2 * 2, column: chosen.column ~/ 2 * 2);
        return mode == _newMotion ? _readMotionDelta(base) : base;
      }
      final nearCandidates = candidates(reference, sub);
      if (sub == 0) return nearCandidates[mode == _near ? 1 : 0];
      final nearest = motion.vector(list, sub == 3 ? 2 : 0);
      if (mode == _nearest) return nearest;
      if (sub == 3) {
        final prior1 = motion.vector(list, 1), prior0 = motion.vector(list, 0);
        if (prior1 != nearest) return prior1;
        if (prior0 != nearest) return prior0;
      }
      return nearCandidates.firstWhere(
        (value) => value != nearest,
        orElse: () => _zeroVector,
      );
    }

    final stepX = subblock && width == 4 ? 1 : 2,
        stepY = subblock && height == 4 ? 1 : 2;
    for (var j = 0; j < 2; j += stepY) {
      for (var i = 0; i < 2; i += stepX) {
        final blockMode = subblock ? readMode() : mode;
        motion.mode = blockMode;
        for (var list = 0; list <= _flag(motion.compound); list++) {
          final vector = readVector(list, blockMode, subblock ? j * 2 + i : -1);
          for (var row = j; row < j + stepY; row++) {
            motion.vectors.fillRange(
              4 * list + row * 2 + i,
              4 * list + row * 2 + i + stepX,
              vector,
            );
          }
        }
      }
    }
    return motion;
  }

  (int, int) _readReferences(_ReferenceNeighbors neighbors) {
    final fixed = entropy.fixedReference;
    final compound =
        entropy.referenceMode == 1 ||
        (entropy.referenceMode == 2 &&
            entropy.bit(
                  _bits,
                  Vp9Probability.compoundMode,
                  neighbors.compoundMode(fixed),
                ) !=
                0);
    if (compound) {
      final index = _flag(_header.referenceBiases[fixed - 1]);
      final variable0 = entropy.variableRef0, variable1 = entropy.variableRef1;
      final context = neighbors.compoundReference(
        fixed,
        variable0,
        variable1,
        1 - index,
      );
      final variable =
          entropy.bit(_bits, Vp9Probability.compoundRef, context) == 0
          ? variable0
          : variable1;
      return index == 0 ? (fixed, variable) : (variable, fixed);
    }
    final other = entropy.bit(
      _bits,
      Vp9Probability.singleRef,
      neighbors.singleLast * 2,
    );
    if (other == 0) return (_last, 0);
    return (
      entropy.bit(
                _bits,
                Vp9Probability.singleRef,
                neighbors.singleGolden * 2 + 1,
              ) ==
              0
          ? _golden
          : _alt,
      0,
    );
  }

  bool _usesHighPrecision(_Vector vector) =>
      vector.row.abs() < 64 && vector.column.abs() < 64;

  _Vector _readMotionDelta(_Vector base) {
    final joint = entropy.tree(_bits, _jointTree, Vp9Probability.mvJoint, 0);
    final precise = _header.highPrecisionMotion && _usesHighPrecision(base);
    int component(int axis) {
      final negative = entropy.bit(_bits, Vp9Probability.mvSign, axis) != 0;
      final kind = entropy.tree(
        _bits,
        _classTree,
        Vp9Probability.mvClass,
        axis * 10,
      );
      final int integer, fraction, minimum;
      if (kind == 0) {
        integer = entropy.bit(_bits, Vp9Probability.mvClassZero, axis);
        fraction = entropy.tree(
          _bits,
          _fractionTree,
          Vp9Probability.mvClassZeroFraction,
          axis * 6 + integer * 3,
        );
        minimum = 0;
      } else {
        var value = 0;
        for (var k = 0; k < kind; k++) {
          value |=
              entropy.bit(_bits, Vp9Probability.mvBits, axis * 10 + k) << k;
        }
        integer = value;
        fraction = entropy.tree(
          _bits,
          _fractionTree,
          Vp9Probability.mvFraction,
          3 * axis,
        );
        minimum = 2 << (kind + 2);
      }
      final table = kind == 0
          ? Vp9Probability.mvClassZeroHigh
          : Vp9Probability.mvHigh;
      final high = precise ? entropy.bit(_bits, table, axis) : 1;
      if (!precise && _header.highPrecisionMotion)
        entropy.count(table, axis, 1);
      final value = minimum + (integer << 3) + (fraction << 1) + high + 1;
      return negative ? -value : value;
    }

    final row = base.row + (joint & 2 != 0 ? component(0) : 0);
    final column = base.column + (joint & 1 != 0 ? component(1) : 0);
    if (row <= -16384 || row >= 16384 || column <= -16384 || column >= 16384) {
      throw const FormatException('Invalid VP9 motion vector');
    }
    return (row: row, column: column);
  }
}
