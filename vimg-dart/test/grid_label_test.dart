import 'package:image/image.dart' as image;
import 'package:vimg_dart/src/grid.dart';

import 'fixtures.dart';

int _rgbHash(image.Image pixels) {
  var hash = 0x811c9dc5;
  for (final channel in pixels.getBytes(order: image.ChannelOrder.rgb)) {
    hash = ((hash ^ channel) * 0x01000193) & 0xffffffff;
  }
  return hash;
}

void main() {
  const width = 120, height = 80;
  final composer = GridComposer(width, height, 3, 2, const [
    '03:03',
    'A\u0301V\u0301 ffi',
    '2:04:56\nthis line is ignored',
  ]);
  // RGB output from the Rust RgbLabel renderer for these generated tiles.
  for (final (seed, reference) in [(0, 0x53a93d75), (31, 0xb4f4e7f0)]) {
    final tiles = List.generate(3, (i) {
      final tile = image.Image(width: width, height: height);
      for (final pixel in tile) {
        pixel.setRgb(
          (pixel.x * 7 + pixel.y * 11 + seed) & 255,
          (pixel.y * 3 + i * 83 + seed) & 255,
          255 - seed,
        );
      }
      return tile;
    });
    final grid = composer.compose(tiles);
    final hash = _rgbHash(grid);
    check(hash == reference, 'Rust contact grid RGB differs for seed $seed');
  }

  final rgba = image.Image(width: width, height: height, numChannels: 4);
  for (final pixel in rgba) {
    pixel.setRgba(
      (pixel.x * 7 + pixel.y * 11) & 255,
      pixel.y * 3 & 255,
      173,
      (pixel.x * 5 + pixel.y * 7) & 255,
    );
  }
  final joined = GridComposer(width, height, 1, 1, const [
    'é à Í Ç ß 🦊',
  ]).compose([rgba], sourceAlpha: true);
  // Rust `vimg join` on the RGBA fixture, including composite glyphs and the
  // missing-glyph outline for a character outside the bundled font.
  check(_rgbHash(joined) == 0x22ad2cad, 'Rust transparent join RGB differs');

  final narrow = image.Image(width: 64, height: 48);
  for (final pixel in narrow) {
    pixel.setRgb((pixel.x * 7 + pixel.y * 11) & 255, pixel.y * 3, 173);
  }
  final wrapped = GridComposer(64, 48, 1, 1, const [
    'Latin é 中 Label 12:34, left to right. Long words wrap at the tile boundary.',
  ]).compose([narrow], sourceAlpha: true);
  check(_rgbHash(wrapped) == 0x0592e541, 'Rust single-line wrapping differs');
}
