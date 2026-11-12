import 'dart:io';

import 'package:vimg_dart/src/av1/picture_decoder.dart';
import 'package:vimg_dart/src/avif_animation.dart';
import 'package:vimg_dart/src/video_commands.dart';

import 'fixtures.dart';

void main() {
  // The existing SVT-AV1 fixture has 2×2 tiles and signals film grain.
  // These dav1d checksums are for the keyframe with grain disabled.
  final tiled = AvifAnimation.open('test/fixtures/av1-svt-tiled.avif');
  try {
    final coded = tiled.codedFrames().first.frame;
    _checkPlanes(decodeAv1Intra(coded, deblock: false, cdef: false), [
      0x4f893045,
      0xd28c9ed3,
      0x8e36fe95,
    ]);
    _checkPlanes(decodeAv1Intra(coded), [0x6bedbda6, 0x6d3cb3dc, 0xf0c8be97]);
  } finally {
    tiled.close();
  }

  // Two 318×230 testsrc2 pictures at 10 fps, encoded by SVT-AV1 with
  // --lossless 1 --scm 0 --keyint 1 --preset 9. The dimensions exercise
  // partial blocks at both edges and the frames use lossless residuals.
  final lossless = AvifAnimation.open('test/fixtures/av1-intra-lossless.avif');
  try {
    const checksums = [
      [0x27161fee, 0xf6344dcb, 0xfcb5c39b],
      [0xe92c65e6, 0x551fba40, 0xfa10c202],
    ];
    var index = 0;
    for (final sample in lossless.codedFrames()) {
      check(
        sample.present && sample.frame.header.parameters.codedLossless,
        'Expected a displayed lossless AV1 keyframe',
      );
      _checkPlanes(decodeAv1Intra(sample.frame), checksums[index++]);
    }
    check(index == checksums.length, 'Lossless AVIF frame count');
    final images = lossless.decodeFrames().toList();
    check(images.length == index, 'Lossless AVIF RGB frame count');
    check(
      images.every((image) => image.width == 318 && image.height == 230),
      'Lossless AVIF RGB dimensions',
    );
  } finally {
    lossless.close();
  }

  // SVT-AV1 at CRF 27, 10-bit 4:2:0, preset 10, keyint 1, with loop
  // filters disabled. Two 256×144 testsrc2 pictures remuxed to MP4.
  final directory = Directory.systemTemp.createTempSync('vimg-av1-preview-');
  try {
    final output = '${directory.path}/preview.jpg';
    final result = writePreview(
      'test/fixtures/av1-intra.mp4',
      output,
      skip: 0,
      width: 256,
      height: 144,
      quality: 85,
    );
    check(
      result['preview_written'] == true && File(output).lengthSync() > 0,
      'AV1 MP4 preview: $result',
    );
  } finally {
    directory.deleteSync(recursive: true);
  }
}

void _checkPlanes(Av1Picture picture, List<int> expected) {
  check(picture.planes.length == expected.length, 'AV1 plane count');
  for (final (p, plane) in picture.planes.indexed) {
    var checksum = 0;
    for (var y = 0; y < plane.height; y++) {
      for (var x = 0; x < plane.width; x++) {
        checksum =
            ((checksum * 16777619) ^ plane.samples[y * plane.stride + x]) &
            0xffffffff;
      }
    }
    check(
      checksum == expected[p],
      'AV1 plane $p checksum ${checksum.toRadixString(16)}',
    );
  }
}
