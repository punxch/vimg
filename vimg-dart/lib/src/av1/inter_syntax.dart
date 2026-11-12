import 'dart:math' as math;

import 'entropy_context.dart';
import 'frame_header.dart';
import 'frame_parameters.dart';
import 'inter_cdfs.dart';
import 'inter_prediction.dart';
import 'inter_prediction_tables.dart';
import 'motion_vectors.dart';
import 'range_decoder.dart';
import 'sequence_header.dart';
import 'warp.dart';

enum _Cdf {
  refMode,
  refType,
  uniRef,
  fwdRef,
  bwdRef,
  singleRef,
  compoundMode,
  newMv,
  zeroMv,
  refMv,
  drl,
  joint,
  sign,
  mvClass,
  class0,
  mvBit,
  fraction,
  class0Fraction,
  precision,
  class0Precision,
  ii,
  iiMode,
  iiWedge,
  wedge,
  obmc,
  motion,
  group,
  compoundIdx,
  compoundType,
  filter,
}

const _compoundModes = [
  (Av1MvMode.nearest, Av1MvMode.nearest),
  (Av1MvMode.near, Av1MvMode.near),
  (Av1MvMode.nearest, Av1MvMode.newMv),
  (Av1MvMode.newMv, Av1MvMode.nearest),
  (Av1MvMode.near, Av1MvMode.newMv),
  (Av1MvMode.newMv, Av1MvMode.near),
  (Av1MvMode.global, Av1MvMode.global),
  (Av1MvMode.newMv, Av1MvMode.newMv),
];

/// AV1 §5.11.23/25–32 inter references, motion vectors and compound modes.
final class Av1InterSyntax {
  Av1InterSyntax(this.reader, this.context, this.header, this.tools);

  final RangeDecoder reader;
  final Av1EntropyContext context;
  final Av1FrameHeader header;
  final Av1SequenceTools tools;

  Av1InterMotion read({
    required int x,
    required int y,
    required int width4,
    required int height4,
    required int columns,
    required int rows,
    required int blockSize,
    required bool skipMode,
    required List<int?> segmentFeatures,
    required Av1InterNeighbor? Function(int x, int y) neighbor,
    required bool Function(int x, int y) inTile,
    required int Function(int ref) distance,
    required bool Function(int ref) scaled,
    required Av1MvPair? Function(int x, int y, int ref0, int ref1)? temporal,
  }) {
    final above = neighbor(x, y - 1), left = neighbor(x - 1, y);
    final u = above?.motion, l = left?.motion;
    final large = width4 >= 2 && height4 >= 2;
    final (ref0, chosenRef) = _readReferences(
      above,
      left,
      segmentFeatures,
      large,
      skipMode,
    );
    final compound = chosenRef > 0;
    final gm = header.parameters.globalMotion;
    final stack = av1FindMvStack(
      x: x,
      y: y,
      width4: width4,
      height4: height4,
      columns: columns,
      rows: rows,
      ref0: ref0,
      ref1: chosenRef,
      highPrecision: header.motion.highPrecision,
      integer: header.motion.integer,
      globals: gm,
      distance: distance,
      neighbor: neighbor,
      inTile: inTile,
      temporal: temporal == null
          ? null
          : (x, y) => temporal(x, y, ref0, chosenRef),
    );
    final (mode0, mode1) = _readModes(
      stack,
      compound,
      skipMode,
      segmentFeatures,
    );
    var index = 0;
    if (mode0 == Av1MvMode.newMv && (!compound || mode1 == Av1MvMode.newMv)) {
      while (index < 2 && stack.count > index + 1 && _readDrl(stack, index)) {
        index++;
      }
    } else if (mode0 == Av1MvMode.near || mode1 == Av1MvMode.near) {
      index = 1;
      while (index < 3 && stack.count > index + 1 && _readDrl(stack, index)) {
        index++;
      }
    }
    Av1Mv assign(Av1MvMode mode, int list) {
      if (mode == Av1MvMode.global)
        return list == 0 ? stack.global.$1 : stack.global.$2;
      final position =
          mode == Av1MvMode.nearest ||
              (mode == Av1MvMode.newMv && stack.count <= 1)
          ? 0
          : index;
      final pair = stack.entries[position].mv;
      final mv = list == 0 ? pair.$1 : pair.$2;
      return mode == Av1MvMode.newMv ? _readMv(mv) : mv;
    }

    final mv0 = assign(mode0, 0), mv1 = compound ? assign(mode1, 1) : av1ZeroMv;
    var ref1 = chosenRef;
    int? iiMode;
    var wedge = -1, invert = false;
    if (!skipMode &&
        tools.interIntra &&
        !compound &&
        blockSize >= 3 &&
        blockSize <= 9) {
      final group = (math.min(width4, height4).bitLength - 2).clamp(0, 2);
      if (_symbol(_Cdf.ii, interInterIntraCdf[group], group) != 0) {
        iiMode = _symbol(_Cdf.iiMode, interInterIntraModeCdf[group], group);
        ref1 = 0;
        if (_symbol(
              _Cdf.iiWedge,
              interWedgeInterIntraCdf[blockSize],
              blockSize,
            ) !=
            0) {
          wedge = _symbol(_Cdf.wedge, interWedgeIndexCdf[blockSize], blockSize);
        }
      }
    }

    var obmc = false, localWarp = false;
    List<int>? warp;
    final globalWarp =
        mode0 == Av1MvMode.global &&
        gm[ref0 - 1].type.index > Av1GlobalMotionType.translation.index;
    if (!skipMode &&
        header.motion.switchableMode &&
        large &&
        !compound &&
        iiMode == null &&
        (header.motion.integer || !globalWarp)) {
      final overlap = <Av1InterMotion>[];
      for (var i = 1; i < width4; i += 2) {
        final m = neighbor(x + i, y - 1)?.motion;
        if (m != null) overlap.add(m);
      }
      for (var i = 1; i < height4; i += 2) {
        final m = neighbor(x - 1, y + i)?.motion;
        if (m != null) overlap.add(m);
      }
      if (overlap.isNotEmpty) {
        final samples =
            header.motion.warped && !header.motion.integer && !scaled(ref0)
            ? av1WarpSamples(x, y, width4, height4, ref0, mv0, neighbor)
            : const <Av1WarpSample>[];
        final canWarp = samples.isNotEmpty;
        final mode = canWarp
            ? _symbol(_Cdf.motion, interMotionModeCdf[blockSize], blockSize)
            : _symbol(_Cdf.obmc, interUseObmcCdf[blockSize], blockSize);
        localWarp = mode == 2;
        if (localWarp)
          warp = av1EstimateWarp(samples, x, y, width4, height4, mv0);
        obmc = mode == 1;
      }
    }

    Av1Compound? blend;
    if (compound) {
      blend = Av1Compound.average;
      if (!skipMode) {
        int masked(Av1InterMotion? m) => m == null
            ? 0
            : m.ref1 > 0
            ? (m.compound == Av1Compound.wedge ||
                      m.compound == Av1Compound.difference
                  ? 1
                  : 0)
            : (m.ref0 == 7 ? 3 : 0);
        final group = math.min(5, masked(u) + masked(l));
        if (tools.maskedCompound &&
            _symbol(_Cdf.group, interCompGroupIdxCdf[group], group) != 0) {
          final useWedge =
              av1WedgeBits[blockSize] != 0 &&
              _symbol(
                    _Cdf.compoundType,
                    interCompoundTypeCdf[blockSize],
                    blockSize,
                  ) ==
                  0;
          if (useWedge) {
            wedge = _symbol(
              _Cdf.wedge,
              interWedgeIndexCdf[blockSize],
              blockSize,
            );
          }
          invert = reader.literal(1) != 0;
          blend = useWedge ? Av1Compound.wedge : Av1Compound.difference;
        } else if (tools.jointCompound) {
          int averaged(Av1InterMotion? m) => m == null
              ? 0
              : m.ref1 > 0
              ? (m.compound == Av1Compound.average ? 1 : 0)
              : (m.ref0 == 7 ? 1 : 0);
          final equal = distance(ref0).abs() == distance(ref1).abs();
          final idx = (equal ? 3 : 0) + averaged(u) + averaged(l);
          if (_symbol(_Cdf.compoundIdx, interCompoundIdxCdf[idx], idx) == 0) {
            blend = Av1Compound.distance;
          }
        }
      }
    }

    var filterX = header.motion.interpolation.index, filterY = filterX;
    if (header.motion.interpolation == Av1Interpolation.switchable) {
      final global =
          mode0 == Av1MvMode.global && (!compound || mode1 == Av1MvMode.global);
      final needsFilter =
          !skipMode &&
          !localWarp &&
          (!large ||
              !global ||
              gm[ref0 - 1].type == Av1GlobalMotionType.translation ||
              (compound &&
                  gm[ref1 - 1].type == Av1GlobalMotionType.translation));
      int filter(int dir) {
        int get(Av1InterMotion? m) =>
            m != null && (m.ref0 == ref0 || m.ref1 == ref0)
            ? (dir == 0 ? m.filterX : m.filterY)
            : 3;
        final a = get(u), b = get(l);
        final type = a == b || b == 3
            ? a
            : a == 3
            ? b
            : 3;
        final ctx = dir * 8 + (compound ? 4 : 0) + type;
        return _symbol(_Cdf.filter, interInterpFilterCdf[ctx], ctx);
      }

      filterX = needsFilter ? filter(0) : 0;
      filterY = tools.dualFilter && needsFilter ? filter(1) : filterX;
    }
    return (
      ref0: ref0,
      ref1: ref1,
      mv0: mv0,
      mv1: mv1,
      mode0: mode0,
      mode1: mode1,
      filterX: filterX,
      filterY: filterY,
      compound: blend,
      invertMask: invert,
      wedgeIndex: wedge,
      interIntraMode: iiMode,
      obmc: obmc,
      warp: warp,
    );
  }

  (int, int) _readReferences(
    Av1InterNeighbor? above,
    Av1InterNeighbor? left,
    List<int?> features,
    bool large,
    bool skip,
  ) {
    if (skip) {
      final (a, b) = header.motion.skipMode!;
      return (a + 1, b + 1);
    }
    if (features[5] case final ref?) return (ref, -1);
    if (features[6] != null || features[7] != null) return (1, -1);
    final u = above?.motion, l = left?.motion;
    final a = u?.ref0 ?? 0, b = l?.ref0 ?? 0;
    final ac = (u?.ref1 ?? -1) > 0, bc = (l?.ref1 ?? -1) > 0;
    final refs = [a, b, u?.ref1 ?? -1, l?.ref1 ?? -1];
    int count(int from, int to) =>
        refs.where((r) => r >= from && r <= to).length;
    final forward = count(1, 4), backward = count(5, 7);
    final early = count(1, 2), late = count(3, 4);
    final near = count(5, 6), alt = count(7, 7);
    final fl = count(1, 1),
        f2 = count(2, 2),
        f3 = count(3, 3),
        f4 = count(4, 4);
    final b5 = count(5, 5), b6 = count(6, 6);
    int compare(int x, int y) => x == y
        ? 1
        : x < y
        ? 0
        : 2;
    var compound = false;
    if (large && header.motion.compound) {
      final int ctx;
      if (above != null && left != null) {
        ctx = ac && bc
            ? 4
            : !ac && !bc
            ? ((a >= 5) != (b >= 5) ? 1 : 0)
            : 2 + ((ac ? b : a) >= 5 || (ac ? b : a) == 0 ? 1 : 0);
      } else if (above != null || left != null) {
        ctx = ac || bc
            ? 3
            : a >= 5 || b >= 5
            ? 1
            : 0;
      } else {
        ctx = 1;
      }
      compound = _symbol(_Cdf.refMode, interCompModeCdf[ctx], ctx) != 0;
    }

    bool choose(
      _Cdf family,
      List<List<List<int>>> table,
      int idx,
      int x,
      int y,
    ) {
      final ctx = compare(x, y);
      return _symbol(family, table[ctx][idx], ctx, idx) != 0;
    }

    if (!compound) {
      bool bit(int i, int x, int y) =>
          choose(_Cdf.singleRef, interSingleRefCdf, i, x, y);
      if (bit(0, forward, backward)) {
        return (
          bit(1, near, alt)
              ? 7
              : bit(5, b5, b6)
              ? 6
              : 5,
          -1,
        );
      }
      return (
        bit(2, early, late)
            ? (bit(4, f3, f4) ? 4 : 3)
            : (bit(3, fl, f2) ? 2 : 1),
        -1,
      );
    }
    final au = ac && (a >= 5) == (u!.ref1 >= 5);
    final bu = bc && (b >= 5) == (l!.ref1 >= 5);
    final direction = (a >= 5) == (b >= 5) ? 1 : 0;
    final int ctx;
    if (a > 0 && b > 0) {
      if (!ac && !bc) {
        ctx = 1 + 2 * direction;
      } else if (!ac || !bc) {
        ctx = au || bu ? 3 + direction : 1;
      } else {
        ctx = !au && !bu
            ? 0
            : !au || !bu
            ? 2
            : 3 + ((a == 5) == (b == 5) ? 1 : 0);
      }
    } else if (above != null && left != null) {
      ctx = ac || bc ? 1 + (au || bu ? 2 : 0) : 2;
    } else {
      ctx = ac || bc ? (au || bu ? 4 : 0) : 2;
    }
    final bidirectional =
        _symbol(_Cdf.refType, interCompRefTypeCdf[ctx], ctx) != 0;
    if (!bidirectional) {
      bool bit(int i, int x, int y) =>
          choose(_Cdf.uniRef, interUniCompRefCdf, i, x, y);
      if (bit(0, forward, backward)) return (5, 7);
      return (1, bit(1, f2, f3 + f4) ? (bit(2, f3, f4) ? 4 : 3) : 2);
    }
    bool fwd(int i, int x, int y) =>
        choose(_Cdf.fwdRef, interCompRefCdf, i, x, y);
    bool bwd(int i, int x, int y) =>
        choose(_Cdf.bwdRef, interCompBwdRefCdf, i, x, y);
    return (
      fwd(0, early, late) ? (fwd(2, f3, f4) ? 4 : 3) : (fwd(1, fl, f2) ? 2 : 1),
      bwd(0, near, alt)
          ? 7
          : bwd(1, b5, b6)
          ? 6
          : 5,
    );
  }

  (Av1MvMode, Av1MvMode) _readModes(
    Av1MvStack stack,
    bool compound,
    bool skip,
    List<int?> features,
  ) {
    if (skip) return _compoundModes[0];
    if (features[6] != null || features[7] != null) {
      return (Av1MvMode.global, Av1MvMode.global);
    }
    if (compound) {
      const contexts = [
        [0, 1, 1, 1, 1],
        [1, 2, 3, 4, 4],
        [4, 4, 5, 6, 7],
      ];
      final ctx =
          contexts[stack.refContext >> 1][math.min(4, stack.newContext)];
      return _compoundModes[_symbol(
        _Cdf.compoundMode,
        interCompoundModeCdf[ctx],
        ctx,
      )];
    }
    final n = stack.newContext, z = stack.zeroContext, r = stack.refContext;
    final mode = _symbol(_Cdf.newMv, interNewMvCdf[n], n) == 0
        ? Av1MvMode.newMv
        : _symbol(_Cdf.zeroMv, interZeroMvCdf[z], z) == 0
        ? Av1MvMode.global
        : _symbol(_Cdf.refMv, interRefMvCdf[r], r) == 0
        ? Av1MvMode.nearest
        : Av1MvMode.near;
    return (mode, Av1MvMode.nearest);
  }

  bool _readDrl(Av1MvStack stack, int index) {
    final ctx = stack.drlContext(index);
    return _symbol(_Cdf.drl, interDrlModeCdf[ctx], ctx) != 0;
  }

  Av1Mv _readMv(Av1Mv mv) {
    final joint = _symbol(_Cdf.joint, interMvJointCdf);
    final y = mv.y + ((joint & 2) == 0 ? 0 : _component(0));
    final x = mv.x + ((joint & 1) == 0 ? 0 : _component(1));
    return (x: x, y: y);
  }

  int _component(int plane) {
    final sign = _symbol(_Cdf.sign, interMvSignCdf, plane);
    final kind = _symbol(_Cdf.mvClass, interMvClassCdf[plane], plane);
    var bits = kind == 0
        ? _symbol(_Cdf.class0, interMvClass0BitCdf, plane)
        : 1 << kind;
    for (var i = 0; i < kind; i++) {
      bits |= _symbol(_Cdf.mvBit, interMvBitCdf[i], plane, i) << i;
    }
    var fraction = 3, high = 1;
    if (!header.motion.integer) {
      fraction = kind == 0
          ? _symbol(
              _Cdf.class0Fraction,
              interMvClass0FrCdf[plane][bits],
              plane,
              bits,
            )
          : _symbol(_Cdf.fraction, interMvFrCdf[plane], plane);
      if (header.motion.highPrecision) {
        high = kind == 0
            ? _symbol(_Cdf.class0Precision, interMvClass0HpCdf, plane)
            : _symbol(_Cdf.precision, interMvHpCdf, plane);
      }
    }
    final magnitude = ((bits << 3) | (fraction << 1) | high) + 1;
    return sign == 0 ? magnitude : -magnitude;
  }

  int _symbol(_Cdf family, List<int> defaults, [int a = 0, int b = 0]) =>
      reader.adaptive(context.cdf((family, a, b), defaults));
}
