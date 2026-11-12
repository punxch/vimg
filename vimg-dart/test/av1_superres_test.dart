import 'package:vimg_dart/src/av1/picture_decoder.dart';
import 'package:vimg_dart/src/avif_animation.dart';

import 'fixtures.dart';

void main() {
  // Remuxed aom_superres_random.ivf from OxideAV/oxideav-av1 at f0b4af4.
  // AOM encoded synthetic testsrc at 96×64 with random scale denominators.
  _checkAnimation(
    'test/fixtures/av1-superres-aom.avif',
    frames: 16,
    depth: 8,
    denominators: {8, 9, 10, 11, 13, 14, 15, 16},
    expected: [0xcdf27e9d, 0x81e482f4, 0x5455c42c],
  );

  // SVT-AV1 preset 7, CRF 25, 128×96 testsrc2 at 20 fps in 10-bit 4:2:0.
  // Fixed denominator 12, restoration enabled, with hidden references.
  _checkAnimation(
    'test/fixtures/av1-superres-svt.avif',
    frames: 9,
    depth: 10,
    denominators: {8, 12},
    expected: [0x5f3d7da0, 0x89e7fd61, 0x3e7573b2],
  );
}

void _checkAnimation(
  String path, {
  required int frames,
  required int depth,
  required Set<int> denominators,
  required List<int> expected,
}) {
  final movie = AvifAnimation.open(path);
  try {
    final decoder = Av1StreamDecoder();
    final actualDenominators = <int>{};
    final hashes = List.filled(3, 0);
    var displayed = 0;
    var scaledRestoration = false;
    for (final entry in movie.codedFrames()) {
      final frame = entry.frame;
      final picture = decoder.decode(frame);
      final size = frame.header.size;
      actualDenominators.add(size.superresDenominator);
      scaledRestoration |=
          size.width != size.upscaledWidth &&
          frame.header.parameters.restoration != null;
      check(picture.color.depth == depth, 'AV1 sample depth in $path');
      if (!entry.present) continue;
      displayed++;
      for (final (p, plane) in picture.planes.indexed) {
        final sub = p == 0 ? 0 : 1;
        check(
          plane.width == (movie.width + sub) >> sub &&
              plane.height == (movie.height + sub) >> sub,
          'AV1 upscaled plane dimensions in $path',
        );
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
    check(displayed == frames, 'AV1 displayed frame count in $path');
    check(
      actualDenominators.length == denominators.length &&
          actualDenominators.containsAll(denominators),
      'AV1 super-resolution denominators in $path',
    );
    check(scaledRestoration, 'AV1 restoration on a scaled frame in $path');
    // Reference checksums are from dav1d with grain disabled.
    for (final (p, hash) in hashes.indexed) {
      check(hash == expected[p], 'AV1 upscaled plane $p checksum in $path');
    }

    final key = decodeAv1IntraImage(movie.codedFrames().first.frame);
    check(
      key.width == movie.width && key.height == movie.height,
      'AV1 keyframe preview dimensions in $path',
    );
    check(
      movie.decodeFrames().length == frames,
      'AVIF animation RGB output in $path',
    );
  } finally {
    movie.close();
  }
}
