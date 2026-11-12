import 'dart:io';
import 'dart:typed_data';

import 'package:image/image.dart' as image;
import 'package:vimg_dart/src/av1/access_units.dart';
import 'package:vimg_dart/src/av1/picture_decoder.dart';
import 'package:vimg_dart/src/av1/palette_decoder.dart';
import 'package:vimg_dart/src/avif_animation.dart';
import 'package:vimg_dart/src/avif_encoder.dart';
import 'package:vimg_dart/src/binary_file.dart';
import 'package:vimg_dart/src/iso_media.dart';
import 'package:vimg_dart/src/ssim.dart';

import 'fixtures.dart';

Future<void> main(List<String> arguments) async {
  final temp = Directory.systemTemp.createTempSync('vimg-dart-avif-test-');
  try {
    for (final (width, height, frames) in [
      (1, 1, 1),
      (17, 39, 1),
      (127, 77, 1),
      (639, 480, 3),
    ]) {
      await _checkAvif(temp, width, height, frames, arguments.firstOrNull);
    }
    await _checkTransformAnimation(temp, arguments.firstOrNull);
    _checkMotionSavings(temp);
  } finally {
    temp.deleteSync(recursive: true);
  }
}

void _checkMotionSavings(Directory temp) {
  const width = 151, height = 99;
  final source = <image.Image>[];
  final encoder = AvifEncoder(width, height, fps: 20, qIndex: 24);
  for (final (dx, dy) in [(0, 0), (3, -2), (6, -4)]) {
    final frame = image.Image(width: width, height: height);
    for (final pixel in frame) {
      final x = (pixel.x + dx).clamp(0, width - 1);
      final y = (pixel.y + dy).clamp(0, height - 1);
      final luma =
          48 +
          ((x * 13 + y * 17 + x * y * 7 + 41 * ((x ~/ 7 ^ y ~/ 9) & 3)) & 127);
      pixel.setRgb(luma + x ~/ 8, luma + y ~/ 8, luma);
    }
    source.add(frame);
    encoder.addFrame(frame);
  }
  final path = '${temp.path}/motion.avif';
  File(path).writeAsBytesSync(encoder.finish());
  final animation = AvifAnimation.open(path);
  try {
    final samples = animation
        .codedFrames()
        .map((entry) => entry.packet.size)
        .toList();
    check(samples.length == source.length, 'Motion fixture frame count');
    check(
      samples.skip(1).every((bytes) => bytes * 4 < samples.first),
      'The translated texture compresses into small inter samples',
    );
    for (final (i, frame) in animation.decodeFrames().indexed) {
      check(
        frameSsim(source[i], frame) >= 0.995,
        'Motion fixture fidelity at $i',
      );
    }
  } finally {
    animation.close();
  }
}

Future<void> _checkTransformAnimation(Directory temp, String? dav1d) async {
  const width = 97, height = 65, count = 34;
  final encoder = AvifEncoder(width, height, fps: 20, qIndex: 24);
  final source = <image.Image>[];
  for (var i = 0; i < count; i++) {
    if (i == 1 || (i >= 3 && i < 32)) {
      encoder.repeatFrame();
      source.add(source.last);
      continue;
    }
    final pixels = image.Image(width: width, height: height);
    for (final p in pixels) {
      if (p.x >= 10 + i && p.x < 28 + i && p.y >= 16 && p.y < 36) {
        p.setRgb(186, 91, 55);
      } else {
        p.setRgb(40 + p.x + p.y ~/ 2, 48 + p.x ~/ 2 + p.y, 62 + p.y);
      }
    }
    encoder.addFrame(pixels);
    source.add(pixels);
  }
  final encoded = encoder.finish();
  final path = '${temp.path}/dct-animation.avif';
  final container = File(path)..writeAsBytesSync(encoded);
  final input = container.openSync();
  final animation = AvifAnimation.open(path);
  final elementary = BytesBuilder(copy: false);
  final reconstructed = BytesBuilder(copy: false);
  try {
    final binary = BinaryFile(input), iso = IsoMedia(BinaryFile(input));
    final track = iso.child(iso.movie(), 'trak');
    final table = iso.sampleTable(iso.child(track, 'mdia')!)!;
    final sync = iso.child(table, 'stss')!.data;
    check(
      binary.unsigned(sync + 4, 4) == 2 &&
          binary.unsigned(sync + 8, 4) == 1 &&
          binary.unsigned(sync + 12, 4) == 33,
      'Only keyframes are AVIF sync samples',
    );
    check(
      animation.frameCount == count && animation.frameRate == '20/1',
      'DCT animation timing',
    );
    final decoder = Av1StreamDecoder();
    var index = 0;
    Av1Picture? previous;
    for (final sample in animation.codedFrames()) {
      final frame = sample.frame;
      final expectedKey = index == 0 || index == 32;
      check(frame.header.type.intra == expectedKey, 'AV1 frame type at $index');
      check(
        frame.sequence.color.depth == 10 &&
            frame.sequence.color.subsamplingX == 1,
        '10-bit 4:2:0 sequence',
      );
      final picture = decoder.decode(frame);
      check(
        frameSsim(source[index], picture.rgb()) > 0.95,
        'Transform fidelity at $index',
      );
      if (index == 1) {
        for (final (p, plane) in picture.planes.indexed) {
          final prior = previous!.planes[p];
          for (var y = 0; y < plane.height; y++) {
            for (var x = 0; x < plane.width; x++) {
              check(
                plane.samples[y * plane.stride + x] ==
                    prior.samples[y * prior.stride + x],
                'Repeat following keyframe',
              );
            }
          }
        }
      } else if (index >= 3 && index < 32) {
        check(
          frame.syntax.existingSlot == 0 && identical(picture, previous),
          'Repeat reuses the previous reconstruction',
        );
        check(
          sample.packet.size == 3,
          'A show-existing sample takes three bytes',
        );
      }
      if (dav1d != null) {
        elementary
          ..add([0x12, 0])
          ..add(binary.read(sample.packet.offset, sample.packet.size));
        for (final plane in picture.planes) {
          final bytes = ByteData(plane.width * plane.height * 2);
          for (var y = 0; y < plane.height; y++) {
            for (var x = 0; x < plane.width; x++) {
              bytes.setUint16(
                (y * plane.width + x) * 2,
                plane.samples[y * plane.stride + x],
                Endian.little,
              );
            }
          }
          reconstructed.add(bytes.buffer.asUint8List());
        }
      }
      previous = picture;
      index++;
    }
    check(index == count, 'DCT animation frame count');
  } finally {
    animation.close();
    input.closeSync();
  }
  if (dav1d == null) return;
  final obuPath = '${temp.path}/dct.obu', yuvPath = '${temp.path}/dct.yuv';
  File(obuPath).writeAsBytesSync(elementary.takeBytes());
  final result = await Process.run(dav1d, [
    '-q',
    '-i',
    obuPath,
    '--muxer',
    'yuv',
    '-o',
    yuvPath,
  ]);
  check(
    result.exitCode == 0,
    'dav1d transform decode failed: ${result.stderr}',
  );
  final expected = reconstructed.takeBytes();
  final actual = File(yuvPath).readAsBytesSync();
  check(expected.length == actual.length, 'External transform frame count');
  for (var i = 0; i < actual.length; i++) {
    if (actual[i] != expected[i])
      throw StateError('Transform sample differs at byte $i');
  }
}

Future<void> _checkAvif(
  Directory temp,
  int width,
  int height,
  int frameCount,
  String? dav1d,
) async {
  final encoder = AvifEncoder(width, height, fps: frameCount == 1 ? null : 20);
  final expected = BytesBuilder(copy: false);
  final planeSize = width * height;
  for (var frame = 0; frame < frameCount; frame++) {
    final pixels = image.Image(width: width, height: height);
    final planes = Uint8List(planeSize * 3);
    for (final pixel in pixels) {
      final index = pixel.y * width + pixel.x;
      final red = ((pixel.y ~/ 8) * 53 + (pixel.x % 4) * 37 + frame * 13) & 255;
      final green = ((pixel.x ~/ 8) * 33 + (pixel.y % 8) * 37) & 255;
      final blue = ((pixel.x ~/ 8) * 41 + ((pixel.y % 4) & 1) * 61) & 255;
      pixel.setRgb(red, green, blue);
      planes[index] = green;
      planes[planeSize + index] = blue;
      planes[2 * planeSize + index] = red;
    }
    encoder.addFrame(pixels);
    expected.add(planes);
  }
  if (frameCount > 1) encoder.repeatFrame();
  final path = '${temp.path}/$width-$height.avif';
  File(path).writeAsBytesSync(encoder.finish());
  final input = File(path).openSync();
  final elementary = BytesBuilder(copy: false);
  final decoder = Av1PaletteDecoder();
  final units = Av1AccessUnits();
  final source = expected.takeBytes();
  void checkSample(Uint8List sample, int frame) {
    final decoded = decoder.decode(sample);
    final general = decodeAv1IntraImage(units.readSample(sample).single);
    check(decoded.width == width && decoded.height == height, 'AV1 frame size');
    final start = (frame < frameCount ? frame : frameCount - 1) * planeSize * 3;
    for (final pixel in decoded) {
      final i = start + pixel.y * width + pixel.x;
      final generalPixel = general.getPixel(pixel.x, pixel.y);
      check(
        generalPixel.r == pixel.r &&
            generalPixel.g == pixel.g &&
            generalPixel.b == pixel.b,
        'General AV1 intra decoder palette round trip',
      );
      check(
        pixel.g == source[i] &&
            pixel.b == source[i + planeSize] &&
            pixel.r == source[i + 2 * planeSize],
        'Dart AV1 palette round trip',
      );
    }
  }

  try {
    final file = BinaryFile(input);
    final iso = IsoMedia(file);
    final boxes = {for (final box in iso.boxes(0, file.length)) box.type: box};
    check(
      iso.tag(boxes['ftyp']!.data) == (frameCount == 1 ? 'avif' : 'avis'),
      'AVIF file brand',
    );
    final meta = boxes['meta']!;
    final extent = iso
        .children(meta, skip: 4)
        .firstWhere((box) => box.type == 'iloc');
    var offset = file.unsigned(extent.data + 14, 4);
    final firstLength = file.unsigned(extent.data + 18, 4);
    check(offset == boxes['mdat']!.data, 'Primary image starts in mdat');
    if (frameCount == 1) {
      final sample = file.read(offset, firstLength);
      checkSample(sample, 0);
      elementary
        ..add([0x12, 0])
        ..add(sample);
    } else {
      final movie = iso.movie();
      final media = iso.child(iso.child(movie, 'trak'), 'mdia')!;
      final table = iso.sampleTable(media)!;
      final time = iso.child(table, 'stts')!.data;
      final sizes = iso.child(table, 'stsz')!.data;
      final count = file.unsigned(sizes + 8, 4);
      final timing = iso.timing(iso.child(media, 'mdhd'))!;
      check(
        count == frameCount + 1 &&
            timing.scale == 20 &&
            file.unsigned(time + 8, 4) == count &&
            file.unsigned(time + 12, 4) == 1,
        'Animated AVIF timing and sample count',
      );
      check(
        file.unsigned(iso.child(table, 'stco')!.data + 8, 4) == offset,
        'Chunk offset',
      );
      check(
        file.unsigned(sizes + 12, 4) == firstLength,
        'Cover matches first frame',
      );
      for (var frame = 0; frame < count; frame++) {
        final length = file.unsigned(sizes + 12 + frame * 4, 4);
        final sample = file.read(offset, length);
        checkSample(sample, frame);
        elementary
          ..add([0x12, 0])
          ..add(sample);
        offset += length;
      }
      check(offset == boxes['mdat']!.end, 'Sample extents cover mdat');
    }
  } finally {
    input.closeSync();
  }

  if (dav1d == null) return;
  final rawPath = '${temp.path}/samples.obu';
  final decodedPath = '${temp.path}/decoded.yuv';
  File(rawPath).writeAsBytesSync(elementary.takeBytes());
  final result = await Process.run(dav1d, [
    '-q',
    '-i',
    rawPath,
    '--muxer',
    'yuv',
    '-o',
    decodedPath,
  ]);
  check(result.exitCode == 0, 'dav1d failed: ${result.stderr}');
  final decoded = File(decodedPath).readAsBytesSync();
  final last = source.length - planeSize * 3;
  final length = source.length + (frameCount == 1 ? 0 : planeSize * 3);
  check(decoded.length == length, 'Decoded frame count');
  for (var i = 0; i < decoded.length; i++) {
    final expectedIndex = i < source.length ? i : last + i - source.length;
    if (decoded[i] != source[expectedIndex]) {
      throw StateError('AV1 pixel differs at byte $i of $width×$height');
    }
  }
}
