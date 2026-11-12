import 'package:vimg_dart/src/av1/picture_decoder.dart';
import 'package:vimg_dart/src/avif_animation.dart';

import 'fixtures.dart';

void main() {
  // SVT-AV1 preset 4, CRF 24, 640×192, 8-bit 4:2:0. The source repeats
  // a 64×64 screen pattern. The keyframe copies from earlier rows and columns.
  _checkAnimation(
    'test/fixtures/av1-intrabc-screen.avif',
    depth: 8,
    tiles: 1,
    lossless: false,
    expected: [0xe6720e40, 0xbab6ba00, 0x2cc7e740],
  );

  // SVT-AV1 preset 4, lossless, 1024×192, 10-bit 4:2:0, two tiles.
  // The last 128 columns of each tile use a one-pixel luma shift. The keyframe
  // signals odd displacement vectors, including a 321-pixel horizontal copy.
  _checkAnimation(
    'test/fixtures/av1-intrabc-lossless.avif',
    depth: 10,
    tiles: 2,
    lossless: true,
    expected: [0x16057300, 0x634d5880, 0xbd1b7980],
  );
}

void _checkAnimation(
  String path, {
  required int depth,
  required int tiles,
  required bool lossless,
  required List<int> expected,
}) {
  final movie = AvifAnimation.open(path);
  try {
    final decoder = Av1StreamDecoder();
    final hashes = List.filled(3, 0);
    var shown = 0;
    for (final entry in movie.codedFrames()) {
      final frame = entry.frame;
      if (shown == 0) {
        check(
          frame.header.intrabc &&
              frame.header.type.intra &&
              frame.tiles.length == tiles &&
              frame.header.parameters.losslessSegments.first == lossless,
          'AV1 intra block copy keyframe in $path',
        );
        final preview = decodeAv1IntraImage(frame);
        check(
          preview.width == movie.width && preview.height == movie.height,
          'AV1 intra block copy keyframe preview in $path',
        );
      } else {
        check(!frame.header.type.intra, 'AV1 inter reference frame in $path');
      }
      final picture = decoder.decode(frame);
      check(picture.color.depth == depth, 'AV1 sample depth in $path');
      if (!entry.present) continue;
      shown++;
      for (final (p, plane) in picture.planes.indexed) {
        var hash = hashes[p];
        for (var y = 0; y < plane.height; y++) {
          for (var x = 0; x < plane.width; x++) {
            hash =
                ((hash * 16777619) ^ plane.samples[y * plane.stride + x]) &
                0xffffffff;
          }
        }
        hashes[p] = hash;
      }
    }
    check(shown == 2, 'AV1 intra block copy animation length in $path');
    // Checksums include the decoded keyframe and the following inter frame.
    // dav1d produced the reference planes for both fixtures.
    for (final (p, hash) in hashes.indexed) {
      check(hash == expected[p], 'AV1 intra block copy plane $p in $path');
    }
    check(movie.decodeFrames().length == shown, 'AVIF RGB output in $path');
  } finally {
    movie.close();
  }
}
