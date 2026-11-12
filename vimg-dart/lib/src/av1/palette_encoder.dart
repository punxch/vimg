import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as image;

import 'bitstream.dart';
import 'palette_cdf.dart';
import 'range_encoder.dart';

/// An 8-bit, 4:4:4 AV1 encoder. All frames are keyframes. An 8×8 block
/// represents its green samples and its blue/red pairs with separate palettes.
final class Av1PaletteEncoder {
  Av1PaletteEncoder(this.width, this.height, {required this.still}) {
    if (width < 1 ||
        height < 1 ||
        width > 4096 ||
        height > 2304 ||
        ((width + 63) ~/ 64) * ((height + 63) ~/ 64) > 2304 ||
        width * height > 8912896) {
      throw const FormatException(
        'AV1 palette encoder dimensions exceed a Level 5.1 tile',
      );
    }
  }

  static const profile = 1;
  static const level = 13;

  final int width;
  final int height;
  final bool still;

  late final Uint8List sequence = _sequence();

  Uint8List _sequence() {
    final bits = BitWriter();
    bits
      ..write(profile, 3)
      ..write(still ? 3 : 0, 2); // still_picture, reduced_still_picture_header
    if (!still) {
      bits.write(
        0,
        19,
      ); // no timing, no initial delay, one operating point (idc=0)
    }
    bits.write(level, 5);
    if (!still) bits.write(0, 1); // main tier
    final widthBits = math.max(1, (width - 1).bitLength);
    final heightBits = math.max(1, (height - 1).bitLength);
    bits
      ..write(widthBits - 1, 4)
      ..write(heightBits - 1, 4)
      ..write(width - 1, widthBits)
      ..write(height - 1, heightBits);
    if (!still) bits.write(0, 1); // no frame IDs
    bits.write(0, 3); // 64×64 superblocks, no filter-intra or intra-edge filter
    if (!still) {
      bits
        ..write(
          0,
          5,
        ) // no inter-intra, masked compound, warp, dual filter or order hint
        ..write(
          1,
          2,
        ) // seq_choose_screen_content_tools=0, seq_force_screen_content_tools=1
        ..write(1, 2); // seq_choose_integer_mv=0, seq_force_integer_mv=1
    }
    bits
      ..write(0, 3) // no superres, CDEF, or loop restoration
      ..write(0, 1) // 8-bit
      ..write(1, 1) // color description present
      ..write(1, 8) // BT.709/sRGB primaries
      ..write(13, 8) // sRGB transfer
      ..write(0, 8) // identity matrix, full range (GBR)
      ..write(0, 1) // shared UV delta quantizer
      ..write(0, 1); // no film grain
    return obu(1, bits.finish(trailingBit: true));
  }

  Uint8List frame(image.Image pixels) {
    if (pixels.width != width || pixels.height != height) {
      throw const FormatException('AV1 frame dimensions changed');
    }
    final bits = BitWriter();
    if (!still) bits.write(1, 4); // no show-existing, KEY_FRAME, show_frame
    bits.write(1, 1); // disable_cdf_update
    if (still) {
      bits.write(
        2,
        2,
      ); // allow_screen_content_tools=1, force_integer_mv=0 (implied on intra)
    } else {
      bits.write(0, 1); // use the sequence dimensions
    }
    bits
      ..write(0, 1) // render and frame dimensions match
      ..write(0, 1) // no intra block copy
      ..write(1, 1); // uniform tiles
    if (width > 64) bits.write(0, 1); // one tile column
    if (height > 64) bits.write(0, 1); // one tile row
    bits.write(
      0,
      14,
    ); // lossless qindex, no deltas, matrix, segmentation or reduced tx set
    final payload = BytesBuilder(copy: false)
      ..add(bits.finish())
      ..add(_PaletteTile(pixels).encode());
    return obu(6, payload.takeBytes());
  }
}

typedef _Neighbors = ({List<int> green, List<int> blue});

final class _PaletteTile {
  _PaletteTile(image.Image frame)
    : _rgb = frame.getBytes(order: image.ChannelOrder.rgb),
      _width = frame.width,
      _height = frame.height,
      _blocksWide = (frame.width + 7) ~/ 8,
      _blocksHigh = (frame.height + 7) ~/ 8;

  final Uint8List _rgb;
  final int _width;
  final int _height;
  final int _blocksWide;
  final int _blocksHigh;
  final _range = RangeEncoder();
  late final _neighbors = List<_Neighbors?>.filled(
    _blocksWide * _blocksHigh,
    null,
  );
  final _green = List<int>.filled(64, 0);
  final _blueRed = List<int>.filled(64, 0);
  final _scores = Uint8List(8);
  final _indices = Uint8List(64);

  Uint8List encode() {
    for (var row = 0; row < _blocksHigh; row += 8) {
      for (var col = 0; col < _blocksWide; col += 8) {
        _partition(row, col, 3);
      }
    }
    return _range.finish();
  }

  void _partition(int row, int col, int logSize) {
    if (row >= _blocksHigh || col >= _blocksWide) return;
    if (logSize == 0) {
      _range.symbol(partitionCdf[0][0], 0); // PARTITION_NONE
      _block(row, col);
      return;
    }
    final half = 1 << (logSize - 1);
    final bottom = row + half < _blocksHigh;
    final right = col + half < _blocksWide;
    final context = (row == 0 ? 0 : 1) + (col == 0 ? 0 : 2);
    final cdf = partitionCdf[logSize][context];
    if (bottom && right) {
      _range.symbol(cdf, 3); // PARTITION_SPLIT
    } else if (bottom || right) {
      _range.symbol(partitionEdgeCdf(cdf, rightEdge: bottom), 1);
    }
    _partition(row, col, logSize - 1);
    _partition(row, col + half, logSize - 1);
    _partition(row + half, col, logSize - 1);
    _partition(row + half, col + half, logSize - 1);
  }

  void _block(int row, int col) {
    final offset = row * _blocksWide + col;
    final context = (row == 0 ? 0 : 1) + (col == 0 ? 0 : 1);
    _range
      ..symbol(skipCdf[context], 1) // no residual
      ..symbol(keyframeDcCdf, 0)
      ..symbol(chromaDcCdf, 0);

    for (var y = 0; y < 8; y++) {
      final sourceY = math.min(row * 8 + y, _height - 1);
      for (var x = 0; x < 8; x++) {
        final sourceX = math.min(col * 8 + x, _width - 1);
        final source = (sourceY * _width + sourceX) * 3;
        final index = y * 8 + x;
        _green[index] = _rgb[source + 1];
        _blueRed[index] = (_rgb[source + 2] << 8) | _rgb[source];
      }
    }
    final green = _palette(_green, paired: false);
    final blueRed = _palette(_blueRed, paired: true);
    final blue = [for (final color in blueRed) color >> 8];

    final above = row % 8 == 0 ? null : _neighbors[offset - _blocksWide];
    final left = col == 0 ? null : _neighbors[offset - 1];
    _range
      ..symbol(paletteLumaModeCdf[context], 1)
      ..symbol(paletteLumaSizeCdf, green.length - 2);
    _colors(green, above?.green, left?.green, chroma: false);
    _range
      ..symbol(paletteChromaModeCdf, 1)
      ..symbol(paletteChromaSizeCdf, blue.length - 2);
    _colors(blue, above?.blue, left?.blue, chroma: true);
    _range.literal(0, 1); // raw V palette (no signed delta coding)
    for (final color in blueRed) {
      _range.literal(color & 255, 8);
    }
    _map(_green, green, paired: false);
    _map(_blueRed, blueRed, paired: true);
    _neighbors[offset] = (green: green, blue: blue);
  }

  void _colors(
    List<int> colors,
    List<int>? above,
    List<int>? left, {
    required bool chroma,
  }) {
    // The decoder merges distinct cached colors from the top and left edges.
    // Write all palette entries explicitly, preserving the UV pair order.
    if (above != null || left != null) {
      final cached = <int>{...?above, ...?left};
      _range.literal(0, cached.length);
    }
    _range
      ..literal(colors.first, 8)
      ..literal(3, 2); // 8 bits for the first delta
    final minimumDelta = chroma ? 0 : 1;
    var bits = 8;
    for (var i = 1; i < colors.length; i++) {
      _range.literal(colors[i] - colors[i - 1] - minimumDelta, bits);
      bits = math.min(bits, (255 - colors[i] - minimumDelta).bitLength);
    }
  }

  void _map(List<int> samples, List<int> colors, {required bool paired}) {
    final count = colors.length;
    final exact = {for (var i = 0; i < count; i++) colors[i]: i};
    for (var i = 0; i < samples.length; i++) {
      _indices[i] = exact[samples[i]] ?? _nearest(samples[i], colors, paired);
    }
    _range.uniform(_indices[0], count);
    final contexts = (paired
        ? paletteChromaMapCdf
        : paletteLumaMapCdf)[count - 2];
    for (var diagonal = 1; diagonal < 15; diagonal++) {
      for (
        var col = math.min(diagonal, 7);
        col >= math.max(0, diagonal - 7);
        col--
      ) {
        final row = diagonal - col;
        final index = row * 8 + col;
        _scores.fillRange(0, count, 0);
        if (col > 0) _scores[_indices[index - 1]] += 2;
        if (row > 0) _scores[_indices[index - 8]] += 2;
        if (row > 0 && col > 0) _scores[_indices[index - 9]]++;
        final color = _indices[index];
        final score = _scores[color];
        var rank = 0;
        var maximum = 0;
        var sum = 0;
        for (var i = 0; i < count; i++) {
          final other = _scores[i];
          if (other > score || (other == score && i < color)) rank++;
          maximum = math.max(maximum, other);
          sum += other;
        }
        // The sum consists of at most three non-zero neighbor scores.
        final hash = 2 * sum - maximum;
        _range.symbol(contexts[paletteColorContexts[hash]], rank);
      }
    }
  }
}

int _nearest(int sample, List<int> colors, bool paired) {
  var best = 0;
  var bestDistance = 131073;
  for (var i = 0; i < colors.length; i++) {
    final color = colors[i];
    final a = (sample & 255) - (color & 255);
    final b = paired ? (sample >> 8) - (color >> 8) : 0;
    final distance = a * a + b * b;
    if (distance < bestDistance) {
      best = i;
      bestDistance = distance;
    }
  }
  return best;
}

/// A deterministic median cut on 64 samples. The UV palette uses the longer
/// color axis for each split and averages the components independently.
List<int> _palette(List<int> samples, {required bool paired}) {
  final unique = samples.toSet();
  if (unique.length == 1) unique.add(unique.first ^ 1);
  if (unique.length <= 8) return unique.toList()..sort();
  final groups = [List<int>.of(samples)];
  while (groups.length < 8) {
    var chosen = 0;
    var score = 0;
    var useHigh = false;
    for (var i = 0; i < groups.length; i++) {
      final group = groups[i];
      var lowMin = 255, lowMax = 0, highMin = 255, highMax = 0;
      for (final sample in group) {
        lowMin = math.min(lowMin, sample & 255);
        lowMax = math.max(lowMax, sample & 255);
        highMin = math.min(highMin, sample >> 8);
        highMax = math.max(highMax, sample >> 8);
      }
      final low = lowMax - lowMin;
      final high = paired ? highMax - highMin : 0;
      final weight = math.max(low, high) * group.length;
      if (weight > score) {
        chosen = i;
        score = weight;
        useHigh = high > low;
      }
    }
    if (score == 0) break;
    final group = groups[chosen]..sort(useHigh ? null : _compareLow);
    final half = group.length ~/ 2;
    groups[chosen] = group.sublist(0, half);
    groups.add(group.sublist(half));
  }
  final colors = <int>{};
  for (final group in groups) {
    var low = 0, high = 0;
    for (final sample in group) {
      low += sample & 255;
      high += sample >> 8;
    }
    final count = group.length;
    colors.add(
      (((high + count ~/ 2) ~/ count) << 8) | ((low + count ~/ 2) ~/ count),
    );
  }
  if (colors.length == 1) colors.add(colors.first ^ 1);
  return colors.toList()..sort();
}

int _compareLow(int a, int b) {
  final order = (a & 255).compareTo(b & 255);
  return order == 0 ? a.compareTo(b) : order;
}
