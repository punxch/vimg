import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:image/image.dart' as image;
import 'package:vimg_dart/src/msrle.dart';
import 'package:vimg_dart/src/video.dart';

import 'fixtures.dart';

// RGB24 hashes from FFmpeg. The mixed fixture uses a hand-checked index
// map because its compressed sample has exactly the size of a raw DIB.
const _rle4 = [
  0xaae831f9,
  0x59a935d2,
  0x4c09db81,
  0x4bd96eca,
  0x1136b67d,
  0x3c57a3c1,
];
const _rle8 = [
  0x80b6b8b9,
  0x0dfa08e0,
  0xfd79ba8c,
  0x2abfeeee,
  0xde80190c,
  0xfb77fa2d,
];
const _encoded = [
  0x85afe840,
  0x2dd2b45e,
  0x7ce22844,
  0x5d9b59e7,
  0x2f37da27,
  0xaccf2d9e,
  0xcd99389b,
  0x839afde1,
  0xaa9fbe67,
  0x25dec73f,
  0xe7e1b1a8,
  0x08c44c77,
  0x908a6fe3,
  0xa3e9b476,
  0xc88cab86,
  0x9b91a933,
];
const _mixed = [0x76a5e3bd, 0xb38d29e5, 0x48db104d];

Future<void> main(List<String> arguments) async {
  const sparsePts = [0, 1, 2, 3, 5, 6];
  await _checkVideo('rle4', _rle4, [0, 3, 5], pts: sparsePts);
  await _checkVideo('rle8', _rle8, [0, 3, 5], pts: sparsePts);
  await _checkVideo('encoded', _encoded, [0, 4, 8, 12]);
  await _checkVideo('mixed', _mixed, [0]);
  _checkBounds();
  await _checkCli(arguments.firstOrNull);
}

Future<void> _checkVideo(
  String name,
  List<int> hashes,
  List<int> anchors, {
  List<int>? pts,
}) async {
  final video = Video('test/fixtures/msrle-$name.avi');
  final capture = VideoCaptureDecoder(video, threads: 3);
  try {
    check(video.codec == 'msrle', '$name codec');
    final frames = video.packets().toList();
    check(frames.length == hashes.length, '$name frame count');
    for (final (i, packet) in frames.indexed) {
      check(packet.timestamp?.pts == (pts?[i] ?? i), '$name PTS at frame $i');
      check(_hash(video.decode(packet)) == hashes[i], '$name seek to frame $i');
    }
    final previews = video.packets(preview: true).toList();
    check(previews.length == anchors.length, '$name preview frame count');
    for (final (i, packet) in previews.indexed) {
      final index = anchors[i];
      check(frames[index] == packet, '$name preview anchor $i');
      check(
        _hash(video.decode(packet, preview: true)) == hashes[index],
        '$name preview $i',
      );
    }
    final expected = {
      for (final (i, packet) in frames.indexed) packet: hashes[i],
    };
    await for (final result in capture.decode(frames.reversed)) {
      check(
        _hash(result.frame) == expected.remove(result.packet),
        '$name parallel capture at ${result.packet.seconds}',
      );
    }
    check(expected.isEmpty, '$name parallel frame count');
  } finally {
    await capture.close();
    video.close();
  }
}

int _hash(image.Image frame) {
  var hash = 0x811c9dc5;
  for (final byte in frame.getBytes()) {
    hash = ((hash ^ byte) * 0x01000193) & 0xffffffff;
  }
  return hash;
}

void _checkBounds() {
  final format = MsRleFormat(3, 1, 4, topDown: false);
  final complete = Uint8List.fromList([4, 0x12, 0, 1]);
  check(format.isComplete(complete), 'RLE4 accepts a padded last nibble');
  final decoder = MsRleDecoder(format)..advance(complete, raw: false);
  final palette = List.generate(16, (i) => i << 16);
  final frame = decoder.rgb(palette);
  check(frame.getPixel(2, 0).r == 1, 'Padded nibble lies outside picture');

  for (final (data, reason) in [
    ([0, 2, 1], 'Truncated Microsoft RLE delta'),
    ([0, 2, 0, 1, 0, 1], 'Invalid Microsoft RLE delta'),
    ([0, 3, 0x12], 'Truncated Microsoft RLE absolute run'),
    ([5, 0x12, 0, 1], 'Microsoft RLE run crosses the picture edge'),
    ([0, 0, 0, 0], 'Invalid Microsoft RLE end of line'),
    ([1, 0x10], 'Truncated Microsoft RLE picture'),
  ]) {
    try {
      format.isComplete(Uint8List.fromList(data));
      throw StateError('Accepted invalid RLE: $reason');
    } on FormatException catch (error) {
      check(error.message == reason, reason);
    }
  }
}

Future<void> _checkCli(String? executable) async {
  const input = 'test/fixtures/msrle-encoded.avi';
  final output = Directory.systemTemp.createTempSync('vimg-msrle-');
  Future<void> run(List<String> args) async {
    final result = await Process.run(
      executable ?? Platform.resolvedExecutable,
      [if (executable == null) 'bin/vimg.dart', ...args],
    );
    check(result.exitCode == 0, '${result.stderr}');
  }

  try {
    final preview = '${output.path}/preview.jpg';
    await run(['preview', '--skip', '50', '--output', preview, input]);
    check(
      image.decodeJpg(File(preview).readAsBytesSync())?.width == 80,
      'RLE JPEG',
    );
    final sheet = '${output.path}/sheet.avif';
    await run([
      'vcs',
      '-c2',
      '-H22',
      '-n3',
      '-f3',
      '-t500ms',
      '-T3',
      '-o',
      sheet,
      input,
    ]);
    check(
      ascii.decode(File(sheet).readAsBytesSync().sublist(4, 12)) == 'ftypavis',
      'RLE animated AVIF',
    );
  } finally {
    output.deleteSync(recursive: true);
  }
}
