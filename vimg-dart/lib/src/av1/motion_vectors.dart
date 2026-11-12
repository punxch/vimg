import 'dart:math' as math;

import 'frame_parameters.dart';
import 'inter_prediction.dart';
import 'transform.dart';

enum Av1MvMode { nearest, near, global, newMv }

typedef Av1InterMotion = ({
  int ref0,
  int ref1,
  Av1Mv mv0,
  Av1Mv mv1,
  Av1MvMode mode0,
  Av1MvMode mode1,
  int filterX,
  int filterY,
  Av1Compound? compound,
  bool invertMask,
  int wedgeIndex,
  int? interIntraMode,
  bool obmc,
  List<int>? warp,
});

typedef Av1InterNeighbor = ({int width4, int height4, Av1InterMotion? motion});

typedef Av1MvPair = (Av1Mv, Av1Mv);

final class Av1MvStack {
  Av1MvStack(
    this.entries,
    this.count,
    this.newContext,
    this.refContext,
    this.zeroContext,
    this.global,
  );

  final List<({Av1MvPair mv, int weight})> entries;
  final int count, newContext, refContext, zeroContext;
  final Av1MvPair global;

  int drlContext(int index) => entries[index].weight < 640
      ? 2
      : entries[index + 1].weight < 640
      ? 1
      : 0;
}

/// AV1 §7.10.2 reference MV search. Coordinates use 4×4 luma cells.
Av1MvStack av1FindMvStack({
  required int x,
  required int y,
  required int width4,
  required int height4,
  required int columns,
  required int rows,
  required int ref0,
  required int ref1,
  required bool highPrecision,
  required bool integer,
  required List<Av1GlobalMotion> globals,
  required int Function(int reference) distance,
  required Av1InterNeighbor? Function(int x, int y) neighbor,
  required Av1MvPair? Function(int x, int y)? temporal,
  required bool Function(int x, int y) inTile,
}) {
  final compound = ref1 > 0;
  final global = (
    av1GlobalMv(
      globals[ref0 - 1],
      x,
      y,
      width4,
      height4,
      highPrecision,
      integer,
    ),
    compound
        ? av1GlobalMv(
            globals[ref1 - 1],
            x,
            y,
            width4,
            height4,
            highPrecision,
            integer,
          )
        : av1ZeroMv,
  );
  final candidates = <({Av1MvPair mv, int weight})>[];
  var newCount = 0;

  void add(Av1MvPair motion, int weight) {
    final i = candidates.indexWhere((e) => e.mv == motion);
    if (i >= 0) {
      candidates[i] = (mv: motion, weight: candidates[i].weight + weight);
    } else if (candidates.length < 8) {
      candidates.add((mv: motion, weight: weight));
    }
  }

  Av1Mv precision(Av1Mv mv) => av1LowerMvPrecision(mv, highPrecision, integer);
  bool candidate(Av1InterNeighbor block, int weight) {
    final motion = block.motion;
    if (motion == null) return false;
    final (a, b) = (motion.ref0, motion.ref1);
    final hasNew =
        motion.mode0 == Av1MvMode.newMv ||
        (b > 0 && motion.mode1 == Av1MvMode.newMv);
    if (compound) {
      if (a != ref0 || b != ref1) return false;
      final isGlobal =
          motion.mode0 == Av1MvMode.global && motion.mode1 == Av1MvMode.global;
      final first = isGlobal && globals[a - 1].type.index > 1
          ? global.$1
          : motion.mv0;
      final second = isGlobal && globals[b - 1].type.index > 1
          ? global.$2
          : motion.mv1;
      add((precision(first), precision(second)), weight);
      if (hasNew) newCount++;
      return true;
    }

    var found = false;
    final large = block.width4 >= 2 && block.height4 >= 2;
    for (final (ref, mv, mode) in [
      (a, motion.mv0, motion.mode0),
      (b, motion.mv1, motion.mode1),
    ]) {
      if (ref != ref0) continue;
      final v =
          large && mode == Av1MvMode.global && globals[ref - 1].type.index > 1
          ? global.$1
          : mv;
      add((precision(v), av1ZeroMv), weight);
      if (hasNew) newCount++;
      found = true;
    }
    return found;
  }

  final limitX = math.min(width4, math.min(columns - x, 16));
  final limitY = math.min(height4, math.min(rows - y, 16));
  bool scan(int offset, {required bool row}) {
    var matched = false;
    final side = row ? width4 : height4;
    final delta = offset == -1 ? -1 : offset + ((row ? y : x) & 1);
    final shift = offset == -1 ? 0 : 1 - ((row ? x : y) & 1);
    final minStep = side >= 16
        ? 4
        : delta.abs() > 1
        ? 2
        : 1;
    final end = row ? limitX : limitY;
    for (var i = 0; i < end;) {
      final xx = row ? x + i + shift : x + delta;
      final yy = row ? y + delta : y + i + shift;
      if (!inTile(xx, yy)) break;
      final block = neighbor(xx, yy);
      final step = math.max(
        minStep,
        math.min(side, (row ? block?.width4 : block?.height4) ?? 1),
      );
      if (block != null && candidate(block, step * 2)) matched = true;
      i += step;
    }
    return matched;
  }

  bool point(int dx, int dy) {
    final block = neighbor(x + dx, y + dy);
    return block != null && candidate(block, 4);
  }

  var above = scan(-1, row: true), left = scan(-1, row: false);
  if (math.max(width4, height4) <= 16 && point(width4, -1)) above = true;
  final close = (above ? 1 : 0) + (left ? 1 : 0);
  final nearest = candidates.length, closeNew = newCount != 0;
  for (var i = 0; i < nearest; i++) {
    final entry = candidates[i];
    candidates[i] = (mv: entry.mv, weight: entry.weight + 640);
  }

  var zero = 0;
  if (temporal != null) {
    void sample(int dx, int dy) {
      final xx = (x + dx) | 1, yy = (y + dy) | 1;
      if (!inTile(xx, yy)) return;
      final pair = temporal(xx, yy);
      final isCenter = dx == 0 && dy == 0;
      if (pair == null) {
        if (isCenter) zero = 1;
        return;
      }
      final mv = (
        precision(pair.$1),
        compound ? precision(pair.$2) : av1ZeroMv,
      );
      if (isCenter) {
        bool distant(Av1Mv a, Av1Mv b) =>
            (a.x - b.x).abs() >= 16 || (a.y - b.y).abs() >= 16;
        zero =
            distant(mv.$1, global.$1) || (compound && distant(mv.$2, global.$2))
            ? 1
            : 0;
      }
      add(mv, 2);
    }

    for (var dy = 0; dy < math.min(height4, 16); dy += height4 >= 16 ? 4 : 2) {
      for (var dx = 0; dx < math.min(width4, 16); dx += width4 >= 16 ? 4 : 2) {
        sample(dx, dy);
      }
    }
    if (width4 >= 2 && height4 >= 2 && width4 < 16 && height4 < 16) {
      for (final (dx, dy) in [
        (-2, height4),
        (width4, height4),
        (width4, height4 - 2),
      ]) {
        final xx = (x & 15) + dx, yy = (y & 15) + dy;
        if (xx >= 0 && xx < 16 && yy >= 0 && yy < 16) sample(dx, dy);
      }
    }
  }
  if (point(-1, -1)) above = true;
  if (scan(-3, row: true)) above = true;
  if (scan(-3, row: false)) left = true;
  if (height4 > 1 && scan(-5, row: true)) above = true;
  if (width4 > 1 && scan(-5, row: false)) left = true;
  final matches = (above ? 1 : 0) + (left ? 1 : 0);

  // Stable descending sort within the nearest and remaining groups.
  for (final (start, end) in [(0, nearest), (nearest, candidates.length)]) {
    for (var i = start + 1; i < end; i++) {
      final value = candidates[i];
      var j = i;
      while (j > start && candidates[j - 1].weight < value.weight) {
        candidates[j] = candidates[j - 1];
        j--;
      }
      candidates[j] = value;
    }
  }

  if (candidates.length < 2) {
    final same = [<Av1Mv>[], <Av1Mv>[]], different = [<Av1Mv>[], <Av1Mv>[]];
    final limit = math.min(limitX, limitY);
    for (final row in [true, false]) {
      for (var i = 0; i < limit && candidates.length < 2;) {
        final xx = row ? x + i : x - 1, yy = row ? y - 1 : y + i;
        if (!inTile(xx, yy)) break;
        final block = neighbor(xx, yy);
        final m = block?.motion;
        if (m != null) {
          for (final (ref, mv) in [(m.ref0, m.mv0), (m.ref1, m.mv1)]) {
            if (ref <= 0) continue;
            for (final (j, target) in [(0, ref0), if (compound) (1, ref1)]) {
              final v = (distance(ref) > 0) == (distance(target) > 0)
                  ? mv
                  : (x: -mv.x, y: -mv.y);
              if (compound) {
                final list = ref == target && same[j].length < 2
                    ? same[j]
                    : different[j];
                if (list.length < 2) list.add(v);
              } else if (!candidates.any((c) => c.mv.$1 == v)) {
                add((v, av1ZeroMv), 2);
              }
            }
          }
        }
        i += (row ? block?.width4 : block?.height4) ?? 1;
      }
    }
    if (compound) {
      final list0 = [...same[0], ...different[0], global.$1, global.$1];
      final list1 = [...same[1], ...different[1], global.$2, global.$2];
      final a = (list0[0], list1[0]), b = (list0[1], list1[1]);
      if (candidates.isEmpty) {
        candidates.add((mv: a, weight: 2));
        candidates.add((mv: b, weight: 2));
      } else {
        candidates.add((mv: candidates.first.mv == a ? b : a, weight: 2));
      }
    }
  }

  final count = candidates.length;
  Av1Mv clamp(Av1Mv mv) => (
    x: mv.x.clamp(-32 * (x + width4) - 128, 32 * (columns - x) + 128),
    y: mv.y.clamp(-32 * (y + height4) - 128, 32 * (rows - y) + 128),
  );
  for (var i = 0; i < count; i++) {
    final entry = candidates[i];
    candidates[i] = (
      mv: (clamp(entry.mv.$1), clamp(entry.mv.$2)),
      weight: entry.weight,
    );
  }
  while (candidates.length < 2) {
    candidates.add((mv: global, weight: 0));
  }
  final (newCtx, refCtx) = switch (close) {
    0 => (math.min(matches, 1), matches),
    1 => (closeNew ? 2 : 3, 2 + matches),
    _ => (closeNew ? 4 : 5, 5),
  };
  return Av1MvStack(candidates, count, newCtx, refCtx, zero, global);
}

Av1Mv av1GlobalMv(
  Av1GlobalMotion gm,
  int x4,
  int y4,
  int w4,
  int h4,
  bool highPrecision,
  bool integer,
) {
  final m = gm.matrix;
  final Av1Mv value;
  switch (gm.type) {
    case Av1GlobalMotionType.identity:
      return av1ZeroMv;
    case Av1GlobalMotionType.translation:
      value = (x: m[1] >> 13, y: m[0] >> 13);
    case Av1GlobalMotionType.rotZoom || Av1GlobalMotionType.affine:
      final x = x4 * 4 + 2 * w4 - 1, y = y4 * 4 + 2 * h4 - 1;
      final dx = (m[2] - 65536) * x + m[3] * y + m[0];
      final dy = m[4] * x + (m[5] - 65536) * y + m[1];
      final shift = highPrecision ? 13 : 14;
      final step = highPrecision ? 1 : 2;
      value = (
        x: dx.sign * av1Round(dx.abs(), shift) * step,
        y: dy.sign * av1Round(dy.abs(), shift) * step,
      );
  }
  return av1LowerMvPrecision(value, highPrecision, integer);
}

Av1Mv av1LowerMvPrecision(Av1Mv mv, bool highPrecision, bool integer) {
  if (highPrecision) return mv;
  int lower(int v) =>
      integer ? v.sign * (((v.abs() + 3) >> 3) << 3) : v.sign * (v.abs() & -2);
  return (x: lower(mv.x), y: lower(mv.y));
}
