part of 'decoder.dart';

/// Deblocks the reconstructed picture before it can be used as a reference.
final class _LoopFilter {
  _LoopFilter(
    this.picture,
    this.blocks,
    this.features,
    this.referenceDeltas,
    this.modeDeltas,
  ) : _depthShift = picture.header.color.depth - 8;

  final Vp9Picture picture;
  final _BlockMap blocks;
  final _SegmentationFeatures? features;
  final List<int> referenceDeltas, modeDeltas;
  final int _depthShift;
  final _wideResult = Int32List(16);

  void apply() {
    final header = picture.header;
    if (header.filter.level == 0) return;
    final sharpness = header.filter.sharpness, baseLevel = header.filter.level;
    final thresholdShift = sharpness > 4
        ? 2
        : sharpness > 0
        ? 1
        : 0;
    final deltaScale = 1 << (baseLevel >> 5);
    final levels = List.generate(8 * 8, (i) {
      final segment = i >> 3, ref = (i >> 1) & 3, mode = i & 1;
      var level = baseLevel;
      if (features?.data[segment][1] case final delta?) {
        level = (features!.absolute ? delta : level + delta).clamp(0, 63);
      }
      if (header.filter.deltaEnabled) {
        final refDelta = referenceDeltas[ref];
        final modeDelta = ref == 0 ? 0 : modeDeltas[mode];
        level = (level + (refDelta + modeDelta) * deltaScale).clamp(0, 63);
      }
      final limit = sharpness == 0
          ? math.max(1, level)
          : (level >> thresholdShift).clamp(1, 9 - sharpness);
      return (
        level: level,
        limit: limit << _depthShift,
        blimit: (2 * (level + 2) + limit) << _depthShift,
        threshold: (level >> 4) << _depthShift,
      );
    });

    final planes = [picture.y, picture.u, picture.v];
    final miColumns = header.miColumns, miRows = header.miRows;
    for (var row = 0; row < miRows; row += 8) {
      for (var column = 0; column < miColumns; column += 8) {
        for (final (index, plane) in planes.indexed) {
          final sx = index == 0 ? 0 : header.color.subX;
          final sy = index == 0 ? 0 : header.color.subY;
          for (var pass = 0; pass < 2; pass++) {
            final vertical = pass == 0;
            final sub = vertical ? sx : sy;
            final edgeCount = 16 >> sub;
            final edgeLength = 64 >> (vertical ? sy : sx);
            for (var edge = 0; edge < edgeCount; edge++) {
              for (var i = 0; i < edgeLength; i++) {
                final x = column * 8 + (vertical ? edge * (4 << sx) : i << sx);
                final y = row * 8 + (vertical ? i << sy : edge * (4 << sy));
                if (x >= miColumns * 8 ||
                    y >= miRows * 8 ||
                    (vertical ? x : y) == 0) {
                  continue;
                }
                final mx = ((x >> 3) >> sx) << sx, my = ((y >> 3) >> sy) << sy;
                final block = blocks.at(mx, my)!;
                final tx = index == 0 || block.width < 8 || block.height < 8
                    ? block.transform
                    : math.min(
                        block.transform,
                        math
                                .min(block.width >> sx, block.height >> sy)
                                .bitLength -
                            3,
                      );
                final blockExtent = math.max(
                  sub == 0 ? 8 : 16,
                  vertical ? block.width : block.height,
                );
                final across = vertical ? x : y;
                final isBlockEdge = across % blockExtent == 0;
                final crossesChromaRight =
                    !vertical &&
                    sx == 1 &&
                    miColumns.isOdd &&
                    edge.isOdd &&
                    x + 8 >= miColumns * 8;
                final isTxEdge = !crossesChromaRight && edge % (1 << tx) == 0;
                if (!isBlockEdge &&
                    (!isTxEdge || (block.motion != null && block.skip)))
                  continue;
                final motion = block.motion;
                final ref = motion?.first ?? 0;
                final type = motion == null || motion.mode == _zeroMotion
                    ? 0
                    : 1;
                final strength = levels[block.segment * 8 + ref * 2 + type];
                if (strength.level == 0) continue;
                var filterSize = tx == 0 && edge % 8 == 0 ? 1 : math.min(2, tx);
                if (sub == 1 &&
                    filterSize == 2 &&
                    across >> 3 == (vertical ? miColumns : miRows) - 1) {
                  filterSize = 1;
                }
                _filter(
                  plane.samples,
                  (y >> sy) * plane.stride + (x >> sx),
                  vertical ? 1 : plane.stride,
                  filterSize,
                  strength.limit,
                  strength.blimit,
                  strength.threshold,
                );
              }
            }
          }
        }
      }
    }
  }

  void _filter(
    Uint16List pixels,
    int edge,
    int step,
    int size,
    int limit,
    int blimit,
    int threshold,
  ) {
    int sample(int i) => pixels[edge + i * step];
    final p0 = sample(-1), q0 = sample(0);
    final p1 = sample(-2), q1 = sample(1);
    if ((p0 - q0).abs() * 2 + ((p1 - q1).abs() >> 1) > blimit) return;
    final left = (p1 - p0).abs(), right = (q1 - q0).abs();
    if (left > limit ||
        right > limit ||
        (sample(-4) - sample(-3)).abs() > limit ||
        (sample(-3) - p1).abs() > limit ||
        (sample(2) - q1).abs() > limit ||
        (sample(3) - sample(2)).abs() > limit) {
      return;
    }
    var flat = 0;
    final flatThreshold = 1 << _depthShift;
    final radius = size == 2
        ? 8
        : size == 1
        ? 4
        : 0;
    for (var i = 1; i < radius; i++) {
      if ((sample(-1 - i) - p0).abs() > flatThreshold ||
          (sample(i) - q0).abs() > flatThreshold) {
        break;
      }
      flat = i;
    }
    if (flat >= 3) {
      final log = flat == 7 ? 4 : 3;
      final n = (1 << (log - 1)) - 1;
      for (var i = -n; i < n; i++) {
        var total = sample(i);
        for (var j = -n; j <= n; j++) {
          total += sample((i + j).clamp(-n - 1, n));
        }
        _wideResult[i + n] = (total + (1 << (log - 1))) >> log;
      }
      for (var i = -n; i < n; i++) {
        pixels[edge + i * step] = _wideResult[i + n];
      }
      return;
    }
    final midpoint = 128 << _depthShift, max = midpoint * 2 - 1;
    final hev = left > threshold || right > threshold;
    int clamp(int value) => value.clamp(-midpoint, midpoint - 1);
    final inner = clamp((hev ? clamp(p1 - q1) : 0) + 3 * (q0 - p0));
    final qDelta = clamp(inner + 4) >> 3, pDelta = clamp(inner + 3) >> 3;
    pixels[edge] = (q0 - qDelta).clamp(0, max);
    pixels[edge - step] = (p0 + pDelta).clamp(0, max);
    if (!hev) {
      final outer = (qDelta + 1) >> 1;
      pixels[edge + step] = (q1 - outer).clamp(0, max);
      pixels[edge - 2 * step] = (p1 + outer).clamp(0, max);
    }
  }
}
