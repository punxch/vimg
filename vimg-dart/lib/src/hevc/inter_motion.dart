import 'cabac.dart';
import 'contexts.dart';
import 'decoded_pictures.dart';
import 'motion_field.dart';
import 'slice_header.dart';

enum HevcPartition {
  whole,
  horizontal,
  vertical,
  top,
  bottom,
  left,
  right,
  quarters;

  bool get splitVertical => this == vertical || this == left || this == right;
  bool get splitHorizontal =>
      this == horizontal || this == top || this == bottom;

  Iterable<HevcBlock> blocks(int x, int y, int size) sync* {
    final half = size >> 1;
    final quarter = size >> 2;
    if (splitHorizontal) {
      final first = this == horizontal
          ? half
          : this == top
          ? quarter
          : size - quarter;
      yield (x: x, y: y, width: size, height: first);
      yield (x: x, y: y + first, width: size, height: size - first);
    } else if (splitVertical) {
      final first = this == vertical
          ? half
          : this == left
          ? quarter
          : size - quarter;
      yield (x: x, y: y, width: first, height: size);
      yield (x: x + first, y: y, width: size - first, height: size);
    } else if (this == quarters) {
      for (var i = 0; i < 4; i++) {
        yield (
          x: x + (i & 1) * half,
          y: y + (i >> 1) * half,
          width: half,
          height: half,
        );
      }
    } else {
      yield (x: x, y: y, width: size, height: size);
    }
  }
}

HevcPartition readHevcPartition(
  HevcCabac cabac,
  int log2,
  int minLog2,
  bool amp,
) {
  if (cabac.decode(HevcContext.partMode) != 0) return HevcPartition.whole;
  final horizontal = cabac.decode(HevcContext.partMode, 1) != 0;
  if (log2 == minLog2) {
    if (horizontal) return HevcPartition.horizontal;
    return log2 == 3 || cabac.decode(HevcContext.partMode, 2) != 0
        ? HevcPartition.vertical
        : HevcPartition.quarters;
  }
  if (!amp || cabac.decode(HevcContext.partMode, 3) != 0)
    return horizontal ? HevcPartition.horizontal : HevcPartition.vertical;
  final second = cabac.bypass() != 0;
  return horizontal
      ? (second ? HevcPartition.bottom : HevcPartition.top)
      : (second ? HevcPartition.right : HevcPartition.left);
}

/// Decode PU motion syntax and derive its predictors (H.265 §8.5.3.2).
final class HevcInterMotion {
  HevcInterMotion(
    this.slice,
    this.poc,
    this.references,
    this.field,
    this.available,
  ) {
    if (slice.parameters.temporalMvp) {
      _colocated = _list(
        slice.parameters.colocatedL0 ? 0 : 1,
      )[slice.parameters.colocatedIndex];
    }
    _noBackward =
        references.l0.every((r) => r.poc <= poc) &&
        references.l1.every((r) => r.poc <= poc);
  }

  final HevcSliceHeader slice;
  final int poc;
  final HevcReferenceLists references;
  final HevcMotionField field;
  final bool Function(int, int) available;
  HevcReferencePicture? _colocated;
  late final bool _noBackward;

  List<HevcReferencePicture> _list(int list) =>
      list == 0 ? references.l0 : references.l1;
  bool get _b => slice.parameters.kind == HevcSliceKind.b;

  HevcMotion _motion(int list, int index, HevcVector vector) {
    final reference = _list(list)[index];
    return (
      index: index,
      poc: reference.poc,
      longTerm: reference.longTerm,
      vector: vector,
    );
  }

  ({HevcMotionPair motion, bool merge}) read(
    HevcCabac cabac,
    HevcBlock block,
    HevcBlock cu,
    HevcPartition partition,
    int index,
    int depth,
    bool skip,
  ) {
    final merge = skip || cabac.decode(HevcContext.mergeFlag) != 0;
    if (merge) {
      final max = slice.parameters.mergeCandidates - 1;
      var candidate = 0;
      if (max > 0 && cabac.decode(HevcContext.mergeIdx) != 0) {
        candidate++;
        while (candidate < max && cabac.bypass() != 0) candidate++;
      }
      final shared = slice.pps.parallelMergeLog2 > 2 && cu.width == 8;
      var motion = _merge(
        shared ? cu : block,
        shared ? HevcPartition.whole : partition,
        index,
        candidate,
      );
      if (block.width + block.height == 12 && motion.l0 != null)
        motion = (l0: motion.l0, l1: null);
      return (motion: motion, merge: true);
    }

    var direction = 0;
    if (_b) {
      if (block.width + block.height != 12 &&
          cabac.decode(HevcContext.interPredIdc, depth.clamp(0, 3)) != 0) {
        direction = 2;
      } else {
        direction = cabac.decode(HevcContext.interPredIdc, 4);
      }
    }
    final neighbours = _neighbours(block);
    HevcMotion readList(int list) {
      final count = _list(list).length;
      var reference = 0;
      if (count > 1 && cabac.decode(HevcContext.refIdx) != 0) {
        reference++;
        if (count > 2 && cabac.decode(HevcContext.refIdx, 1) != 0) {
          reference++;
          while (reference < count - 1 && cabac.bypass() != 0) reference++;
        }
      }
      final delta = list == 1 && direction == 2 && slice.parameters.mvdL1Zero
          ? hevcZeroVector
          : _difference(cabac);
      final predictor = _amvp(
        block,
        neighbours,
        list,
        _list(list)[reference],
        cabac.decode(HevcContext.mvpFlag),
      );
      int wrap(int value) => ((value + 32768) & 65535) - 32768;
      return _motion(list, reference, (
        x: wrap(predictor.x + delta.x),
        y: wrap(predictor.y + delta.y),
      ));
    }

    return (
      motion: (
        l0: direction == 1 ? null : readList(0),
        l1: direction == 0 ? null : readList(1),
      ),
      merge: false,
    );
  }

  static HevcVector _difference(HevcCabac cabac) {
    final x = cabac.decode(HevcContext.absMvdGreaterFlag);
    final y = cabac.decode(HevcContext.absMvdGreaterFlag);
    final xLarge =
        x != 0 && cabac.decode(HevcContext.absMvdGreaterFlag, 1) != 0;
    final yLarge =
        y != 0 && cabac.decode(HevcContext.absMvdGreaterFlag, 1) != 0;
    int component(int nonzero, bool large) {
      if (nonzero == 0) return 0;
      final magnitude = large ? 2 + cabac.bypassGolomb(1) : 1;
      return cabac.bypass() == 0 ? magnitude : -magnitude;
    }

    return (x: component(x, xLarge), y: component(y, yLarge));
  }

  List<HevcVector> _positions(HevcBlock b) => [
    (x: b.x - 1, y: b.y + b.height - 1), // A1
    (x: b.x + b.width - 1, y: b.y - 1), // B1
    (x: b.x + b.width, y: b.y - 1), // B0
    (x: b.x - 1, y: b.y + b.height), // A0
    (x: b.x - 1, y: b.y - 1), // B2
  ];

  HevcMotionPair? _neighbor(HevcVector p) =>
      available(p.x, p.y) ? field.at(p.x, p.y) : null;

  List<HevcMotionPair?> _neighbours(HevcBlock b) =>
      _positions(b).map(_neighbor).toList(growable: false);

  HevcMotionPair _merge(
    HevcBlock b,
    HevcPartition partition,
    int part,
    int index,
  ) {
    final level = slice.pps.parallelMergeLog2;
    final positions = _positions(b);
    HevcMotionPair? spatial(int i) {
      final p = positions[i];
      if (b.x >> level == p.x >> level && b.y >> level == p.y >> level)
        return null;
      return _neighbor(p);
    }

    final a1 = part == 1 && partition.splitVertical ? null : spatial(0);
    final b1 = part == 1 && partition.splitHorizontal ? null : spatial(1);
    final b0 = spatial(2), a0 = spatial(3), b2 = spatial(4);
    final candidates = <HevcMotionPair>[
      if (a1 != null) a1,
      if (b1 != null && b1 != a1) b1,
      if (b0 != null && b0 != b1) b0,
      if (a0 != null && a0 != a1) a0,
    ];
    if (candidates.length < 4 && b2 != null && b2 != a1 && b2 != b1)
      candidates.add(b2);
    if (index < candidates.length) return candidates[index];

    final t0 = _temporal(b, 0, references.l0.first);
    final t1 = _b ? _temporal(b, 1, references.l1.first) : null;
    if (t0 != null || t1 != null) {
      candidates.add((
        l0: t0 == null ? null : _motion(0, 0, t0),
        l1: t1 == null ? null : _motion(1, 0, t1),
      ));
      if (index < candidates.length) return candidates[index];
    }

    if (_b) {
      final original = candidates.length;
      for (var i = 1; i < original; i++) {
        for (var j = 0; j < i; j++) {
          for (final (left, right) in [(j, i), (i, j)]) {
            final l0 = candidates[left].l0, l1 = candidates[right].l1;
            if (l0 == null ||
                l1 == null ||
                (l0.poc == l1.poc && l0.vector == l1.vector))
              continue;
            candidates.add((l0: l0, l1: l1));
            if (index < candidates.length) return candidates[index];
          }
        }
      }
    }
    final zero = index - candidates.length;
    final reference =
        zero < references.l0.length && (!_b || zero < references.l1.length)
        ? zero
        : 0;
    return (
      l0: _motion(0, reference, hevcZeroVector),
      l1: _b ? _motion(1, reference, hevcZeroVector) : null,
    );
  }

  HevcVector _amvp(
    HevcBlock b,
    List<HevcMotionPair?> neighbours,
    int list,
    HevcReferencePicture reference,
    int index,
  ) {
    HevcVector? find(List<int> locations, {required bool scale}) {
      for (final location in locations) {
        final pair = neighbours[location];
        if (pair == null) continue;
        final first = list == 0 ? pair.l0 : pair.l1;
        final second = list == 0 ? pair.l1 : pair.l0;
        for (final source in [first, second]) {
          if (source == null) continue;
          if (!scale) {
            if (source.poc == reference.poc) return source.vector;
          } else if (source.longTerm == reference.longTerm) {
            return reference.longTerm || source.poc == reference.poc
                ? source.vector
                : _scale(source.vector, poc - source.poc, poc - reference.poc);
          }
        }
      }
      return null;
    }

    const left = [3, 0], above = [2, 1, 4];
    final scaledLeft = neighbours[3] != null || neighbours[0] != null;
    var a = find(left, scale: false) ?? find(left, scale: true);
    var top = find(above, scale: false);
    if (!scaledLeft) {
      a = top;
      top = find(above, scale: true);
    }
    if (a == top) top = null;
    if (a == null) {
      a = top;
      top = null;
    }
    if (index == 0 && a != null) return a;
    if (index == 1 && top != null) return top;
    if ((a == null && index == 0) || (a != null && index == 1))
      return _temporal(b, list, reference) ?? hevcZeroVector;
    return hevcZeroVector;
  }

  HevcVector? _temporal(HevcBlock b, int list, HevcReferencePicture reference) {
    final col = _colocated;
    final motion = col?.picture.motion;
    if (col == null || motion == null) return null;

    HevcVector? from(int x, int y) {
      if (!col.picture.luma.contains(x, y)) return null;
      final pair = motion.at(x & ~15, y & ~15);
      if (pair == null) return null;
      final useL0 = _noBackward ? list == 0 : !slice.parameters.colocatedL0;
      final source = (useL0 ? pair.l0 ?? pair.l1 : pair.l1 ?? pair.l0)!;
      if (source.longTerm != reference.longTerm) return null;
      final td = col.poc - source.poc, tb = poc - reference.poc;
      return reference.longTerm || td == tb
          ? source.vector
          : _scale(source.vector, td, tb);
    }

    final right = b.x + b.width, bottom = b.y + b.height;
    final ctb = slice.sps.ctbLog2;
    final br = b.y >> ctb == bottom >> ctb ? from(right, bottom) : null;
    return br ?? from(b.x + (b.width >> 1), b.y + (b.height >> 1));
  }

  static HevcVector _scale(HevcVector mv, int from, int to) {
    final td = from.clamp(-128, 127);
    if (td == 0) return mv;
    final tb = to.clamp(-128, 127);
    final tx = (16384 + (td.abs() >> 1)) ~/ td;
    final scale = ((tb * tx + 32) >> 6).clamp(-4096, 4095);
    int component(int value) {
      final product = scale * value;
      return (product.sign * ((product.abs() + 127) >> 8)).clamp(-32768, 32767);
    }

    return (x: component(mv.x), y: component(mv.y));
  }
}
