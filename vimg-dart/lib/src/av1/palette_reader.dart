import 'dart:math' as math;
import 'dart:typed_data';

import 'palette_cdf.dart';
import 'range_decoder.dart';

/// The palette cache, delta-coded colors and token maps in §5.11.46/49.
final class Av1PaletteReader {
  Av1PaletteReader(this.range, this.depth);

  final RangeDecoder range;
  final int depth;
  final _scores = Uint8List(8);
  final _mapCdfs = <(bool, int, int), Av1Cdf>{};

  List<int> colors(
    int count,
    List<int>? above,
    List<int>? left, {
    required bool chroma,
  }) {
    final values = <int>[];
    final cache = <int>{...?above, ...?left}.toList()..sort();
    for (final value in cache) {
      if (range.literal(1) != 0) {
        values.add(value);
        if (values.length == count) return values;
      }
    }

    final maximum = (1 << depth) - 1;
    final increment = chroma ? 0 : 1;
    var last = range.literal(depth);
    values.add(last);
    if (values.length < count) {
      var bits = depth - 3 + range.literal(2);
      while (values.length < count) {
        last = math.min<int>(maximum, last + increment + range.literal(bits));
        values.add(last);
        bits = math.min(bits, (maximum - last - increment).bitLength);
      }
    }
    return values..sort();
  }

  List<int> vColors(int count) {
    if (range.literal(1) == 0) {
      return List.generate(count, (_) => range.literal(depth));
    }
    final bits = depth - 4 + range.literal(2);
    final mask = (1 << depth) - 1;
    final values = [range.literal(depth)];
    for (var i = 1; i < count; i++) {
      final delta = range.literal(bits);
      final signed = delta != 0 && range.literal(1) != 0 ? -delta : delta;
      values.add((values.last + signed) & mask);
    }
    return values;
  }

  void readMap(
    Uint8List map,
    int count,
    int width,
    int height, {
    required int visibleWidth,
    required int visibleHeight,
    required bool chroma,
  }) {
    final tables = chroma ? paletteChromaMapCdf : paletteLumaMapCdf;
    map[0] = range.uniform(count);
    for (var d = 1; d < visibleWidth + visibleHeight - 1; d++) {
      final start = math.min(d, visibleWidth - 1);
      final end = math.max(0, d - visibleHeight + 1);
      for (var x = start; x >= end; x--) {
        final y = d - x, at = y * width + x;
        _scores.fillRange(0, count, 0);
        if (x > 0) _scores[map[at - 1]] += 2;
        if (y > 0) _scores[map[at - width]] += 2;
        if (x > 0 && y > 0) _scores[map[at - width - 1]]++;
        var maximum = 0, sum = 0;
        for (var i = 0; i < count; i++) {
          maximum = math.max(maximum, _scores[i]);
          sum += _scores[i];
        }
        final ctx = paletteColorContexts[2 * sum - maximum];
        final cdf = _mapCdfs.putIfAbsent((
          chroma,
          count,
          ctx,
        ), () => Av1Cdf(tables[count - 2][ctx]));
        var rank = range.adaptive(cdf);
        for (var score = maximum; score >= 0 && rank >= 0; score--) {
          for (var i = 0; i < count; i++) {
            if (_scores[i] == score && rank-- == 0) {
              map[at] = i;
              break;
            }
          }
        }
      }
    }
    for (var y = 0; y < visibleHeight; y++) {
      final row = y * width;
      map.fillRange(
        row + visibleWidth,
        row + width,
        map[row + visibleWidth - 1],
      );
    }
    for (var y = visibleHeight; y < height; y++) {
      map.setRange(
        y * width,
        (y + 1) * width,
        map,
        (visibleHeight - 1) * width,
      );
    }
  }
}
