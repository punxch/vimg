import 'package:vimg_dart/src/av1/frame_parameters.dart';
import 'package:vimg_dart/src/av1/picture_decoder.dart';
import 'package:vimg_dart/src/avif_animation.dart';

import 'fixtures.dart';

void main() {
  // SVT-AV1 preset 7, CRF 22, 17 testsrc2 pictures at 128×96, 20 fps,
  // 10-bit 4:2:0, hierarchical level 3, temporal MVs, restoration disabled.
  _checkAnimation('test/fixtures/av1-inter-select.avif', [
    0xfc308341,
    0x5a1df8f9,
    0x5c79e74a,
  ], variableTransforms: true);

  // Four tiles and multiple reference refreshes, with dav1d grain off
  // so the reference pictures can be checked directly.
  _checkAnimation('test/fixtures/av1-svt-tiled.avif', [
    0x85d9d915,
    0x19261105,
    0x68456508,
  ], variableTransforms: false);
}

void _checkAnimation(
  String path,
  List<int> expected, {
  required bool variableTransforms,
}) {
  final movie = AvifAnimation.open(path);
  try {
    final decoder = Av1StreamDecoder();
    final displayed = <int>[];
    final slots = <int, Av1Picture>{};
    final checksums = List.filled(3, 0);
    var hidden = 0, reused = 0, selectInter = 0, temporal = 0;
    for (final entry in movie.codedFrames()) {
      final frame = entry.frame;
      final picture = decoder.decode(frame);
      if (!entry.present) hidden++;
      if (frame.header.motion.referenceMvs) temporal++;
      if (frame.syntax.existingSlot case final index?) {
        check(identical(slots[index], picture), 'AV1 existing frame');
        reused++;
      } else if (!frame.header.type.intra &&
          frame.header.parameters.transformMode == Av1TransformMode.select) {
        selectInter++;
      }
      for (var i = 0; i < 8; i++) {
        if (frame.refreshFlags & (1 << i) != 0) slots[i] = picture;
      }
      if (!entry.present) continue;
      displayed.add(frame.header.orderHint);
      for (final (p, plane) in picture.planes.indexed) {
        var checksum = checksums[p];
        for (var y = 0; y < plane.height; y++) {
          for (var x = 0; x < plane.width; x++) {
            checksum =
                ((checksum * 16777619) ^ plane.samples[y * plane.stride + x]) &
                0xffffffff;
          }
        }
        checksums[p] = checksum;
      }
    }
    check(hidden == 8 && reused == 8 && temporal > 0, 'AV1 reference sequence');
    check((selectInter > 0) == variableTransforms, 'AV1 inter transform mode');
    check(
      displayed.length == 17 &&
          displayed.indexed.every((entry) => entry.$1 == entry.$2),
      'AV1 display order',
    );
    for (var p = 0; p < 3; p++) {
      check(
        checksums[p] == expected[p],
        'AV1 plane $p reference checksum in $path',
      );
    }

    if (variableTransforms) {
      final pictures = movie.decodeFrames().toList();
      check(
        pictures.length == 17 &&
            pictures.every((p) => p.width == 128 && p.height == 96),
        'AVIF animation RGB frames',
      );
    }
  } finally {
    movie.close();
  }
}
