import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:image/image.dart' as image;
import 'package:vimg_dart/src/msvideo1.dart';
import 'package:vimg_dart/src/video.dart';

import 'fixtures.dart';

// FNV-1a hashes of FFmpeg's RGB24 output.
const _indexed = [
  0x05e10737,
  0x35446979,
  0x4b5b92b9,
  0x05f7ea47,
  0xf3dbbb5f,
  0xadbbea15,
];
const _indexedMkv = [
  0x05e10737,
  0x35446979,
  0x35446979,
  0x9d363282,
  0x20f4ac32,
  0xa9fd90a5,
];
const _rgb555 = [0x6381cad0, 0x4ea01935, 0x4ea01935, 0xe14d1275, 0x0702faab];
const _encoded = [
  0x92dd7e18,
  0x3557850e,
  0x65610f6a,
  0x5f39e50d,
  0xad60cd7d,
  0x0a6f5cf7,
  0xff412c49,
  0x2af3bd13,
  0x929d2797,
  0x5a3a1856,
  0x99cb3dcb,
  0x5923ba64,
  0x99f77392,
  0x2e658154,
  0xf44e8360,
  0x1f2d2248,
];

Future<void> main(List<String> arguments) async {
  // Frame 2 skips every block and changes only the container palette.
  await _checkVideo(
    'indexed.avi',
    _indexed,
    [0, 3, 5],
    pts: [0, 1, 2, 3, 5, 6],
  );
  await _checkVideo('rgb555.avi', _rgb555, [0, 3]);
  await _checkVideo('long-skip.avi', [0xeab927c5, 0xe3cf7075], [0]);
  await _checkVideo('encoded.avi', _encoded, [0, 4, 8, 12]);
  await _checkVideo(
    'indexed.mkv',
    _indexedMkv,
    [0, 3, 5],
    pts: [0, 250, 500, 750, 1250, 1500],
  );
  await _checkVideo(
    'encoded.mkv',
    _encoded,
    [0, 4, 8, 12],
    pts: [for (var i = 0; i < 16; i++) i * 125],
  );
  _checkBounds();
  await _checkCli(arguments.firstOrNull);
}

Future<void> _checkVideo(
  String name,
  List<int> hashes,
  List<int> anchors, {
  List<int>? pts,
}) async {
  final video = Video('test/fixtures/msvideo1-$name');
  final capture = VideoCaptureDecoder(video, threads: 3);
  try {
    check(video.codec == 'msvideo1', '$name codec');
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
  final indexed = MsVideo1Format(4, 4, 8);
  final rgb = MsVideo1Format(4, 4, 16);
  final solid = Uint8List.fromList([19, 0x80]);
  check(indexed.isComplete(solid), 'The block count can terminate the picture');
  check(
    indexed.isComplete(Uint8List.fromList([0, 0x84, ...solid])),
    'Zero-length skip leaves the block position intact',
  );
  check(
    !indexed.isComplete(Uint8List.fromList([1, 0x84, 0, 0])),
    'Whole-picture skip requires the previous frame',
  );

  for (final (format, data, reason) in [
    (indexed, [1], 'Truncated Microsoft Video 1 block'),
    (indexed, [2, 0x84], 'Microsoft Video 1 skip crosses the picture edge'),
    (
      indexed,
      [0, 0x90, 1, 2, 3, 4, 5, 6, 7],
      'Truncated Microsoft Video 1 colors',
    ),
    (rgb, [0, 0, 0, 0x80, 1, 0], 'Truncated Microsoft Video 1 colors'),
  ]) {
    try {
      format.isComplete(Uint8List.fromList(data));
      throw StateError('Accepted invalid Microsoft Video 1: $reason');
    } on FormatException catch (error) {
      check(error.message == reason, reason);
    }
  }
}

Future<void> _checkCli(String? executable) async {
  const input = 'test/fixtures/msvideo1-encoded.avi';
  final output = Directory.systemTemp.createTempSync('vimg-msvideo1-');
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
      'Microsoft Video 1 JPEG',
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
      'Microsoft Video 1 animated AVIF',
    );
  } finally {
    output.deleteSync(recursive: true);
  }
}
