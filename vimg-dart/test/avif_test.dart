import 'dart:io';
import 'dart:typed_data';

import 'package:image/image.dart' as image;
import 'package:vimg_dart/src/avif_encoder.dart';
import 'package:vimg_dart/src/binary_file.dart';
import 'package:vimg_dart/src/iso_media.dart';

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
  } finally {
    temp.deleteSync(recursive: true);
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
      elementary
        ..add([0x12, 0])
        ..add(file.read(offset, firstLength));
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
        elementary
          ..add([0x12, 0])
          ..add(file.read(offset, length));
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
  final source = expected.takeBytes();
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
