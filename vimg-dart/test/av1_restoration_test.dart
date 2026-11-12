import 'package:vimg_dart/src/av1/frame_parameters.dart';
import 'package:vimg_dart/src/av1/picture_decoder.dart';
import 'package:vimg_dart/src/avif_animation.dart';

import 'fixtures.dart';

void main() {
  // Five synthetic 96×64 YUV420 pictures encoded by OxideAV at q=73.
  // The second picture signals a Wiener unit in switchable mode.
  // Checksums are from dav1d with film grain disabled.
  final movie = AvifAnimation.open('test/fixtures/av1-restoration.avif');
  try {
    final decoder = Av1StreamDecoder();
    final types = <Av1RestorationType>{};
    final hashes = List.filled(3, 0);
    var frames = 0;
    for (final entry in movie.codedFrames()) {
      final config = entry.frame.header.parameters.restoration;
      if (config != null) types.addAll(config.types);
      final picture = decoder.decode(entry.frame);
      if (!entry.present) continue;
      frames++;
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
    check(frames == 5, 'AV1 restoration test frame count');
    check(
      types.containsAll(Av1RestorationType.values),
      'AV1 restoration test includes every frame filter mode',
    );
    const expected = [0x5d3e376c, 0xdfac4103, 0xbd3a9900];
    for (final (p, hash) in hashes.indexed) {
      check(hash == expected[p], 'AV1 restored plane $p reference checksum');
    }
  } finally {
    movie.close();
  }
}
