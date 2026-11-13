import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:image/image.dart' as image;
import 'package:vimg_dart/src/quicktime_rpza.dart';
import 'package:vimg_dart/src/video.dart';

import 'fixtures.dart';

const _firstGop = [
  0xed9746a0,
  0xe5a7540b,
  0xe5a7540b,
  0x1f1a1062,
  0x2691ce7a,
  0xf3b848d5,
  0x0ee31c9b,
  0x39c8d89f,
];
const _edges = [
  0x1d617c2a,
  0x1d617c2a,
  0xe4019795,
  0x0143ecef,
  0x0143ecef,
  0xce8ff17b,
  0xce8ff17b,
  0x711e7a31,
];

Future<void> main(List<String> arguments) async {
  // FNV-1a hashes of FFmpeg's RGB24 output. The MOV muxer marks
  // dependent and independent RPZA packets alike as sync samples.
  await _checkVideo('rpza-two-gops.mov', [..._firstGop, ..._firstGop], [0, 8]);
  await _checkVideo('rpza-edge-blocks.mov', _edges, [0]);
  await _checkVideo('rpza-palettes.mov', [0xe3fef7c5, 0xfaf16f05], [0]);
  await _checkVideo(
    'rpza-two-sequences.mov',
    [..._firstGop.take(5), ..._edges.take(4), ..._firstGop.take(4)],
    [0, 5, 9],
  );
  _checkMalformed();
  await _checkCli(arguments.firstOrNull);
}

Future<void> _checkVideo(
  String name,
  List<int> expected,
  List<int> keys,
) async {
  final video = Video('test/fixtures/$name');
  final workers = VideoCaptureDecoder(video, threads: 3);
  try {
    check(video.codec == 'rpza', '$name codec');
    final packets = video.packets().toList();
    check(packets.length == expected.length, '$name frame count');
    final positions = {for (final (i, packet) in packets.indexed) packet: i};
    final previews = video.packets(preview: true).toList();
    check(previews.length == keys.length, '$name actual keyframe count');
    for (final (i, packet) in previews.indexed) {
      check(positions[packet] == keys[i], '$name preview anchor');
      check(
        _hash(video.decode(packet, preview: true)) == expected[keys[i]],
        '$name preview pixels',
      );
    }
    final serial = video.decodeSelected(packets).toList();
    check(serial.length == expected.length, '$name sequential frame count');
    for (final result in serial) {
      final i = positions[result.packet]!;
      final size = switch (name) {
        'rpza-palettes.mov' => (12, 8),
        'rpza-edge-blocks.mov' => (50, 34),
        'rpza-two-sequences.mov' when i >= 5 && i < 9 => (50, 34),
        _ => (64, 44),
      };
      check(
        (result.frame.width, result.frame.height) == size,
        '$name frame $i dimensions',
      );
      check(
        _hash(result.frame) == expected[i],
        '$name frame $i differs from FFmpeg',
      );
    }
    final selected = {for (final i in keys) packets[i + 1], packets.last};
    await for (final result in workers.decode(selected.toList().reversed)) {
      final i = positions[result.packet]!;
      check(selected.remove(result.packet), '$name sparse capture identity');
      check(_hash(result.frame) == expected[i], '$name sparse frame $i');
    }
    check(selected.isEmpty, '$name sparse frame count');
  } finally {
    await workers.close();
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

void _checkMalformed() {
  final entry = Uint8List(78);
  ByteData.sublistView(entry)
    ..setUint16(24, 4)
    ..setUint16(26, 4);
  final decoder = QuickTimeRpzaDecoder(entry);
  for (final (bytes, reason) in [
    ([0xe1, 0, 0, 5, 0x80], 'Missing RPZA reference frame'),
    ([0xe1, 0, 0, 7, 0xa1, 0x7c, 0], 'Invalid RPZA block extent'),
    ([0xe1, 0, 0, 5, 0xe0], 'Invalid RPZA opcode'),
    ([0xe1, 0, 0, 4], 'Incomplete RPZA keyframe'),
    ([0xe1, 0, 0, 7, 0xa0, 0x7c], 'Invalid RPZA chunk size'),
  ]) {
    try {
      decoder.advance(Uint8List.fromList(bytes));
      throw StateError('Accepted invalid RPZA: $reason');
    } on FormatException catch (error) {
      check(error.message == reason, reason);
    }
  }
}

Future<void> _checkCli(String? executable) async {
  const input = 'test/fixtures/rpza-two-gops.mov';
  final dir = Directory.systemTemp.createTempSync('vimg-rpza-');
  Future<void> run(List<String> arguments) async {
    final result = await Process.run(
      executable ?? Platform.resolvedExecutable,
      [if (executable == null) 'bin/vimg.dart', ...arguments],
    );
    check(result.exitCode == 0, '${result.stderr}');
  }

  try {
    final preview = '${dir.path}/preview.jpg';
    final sheet = '${dir.path}/sheet.avif';
    await run(['preview', '--output', preview, '--skip', '50', input]);
    check(
      image.decodeJpg(File(preview).readAsBytesSync())?.width == 64,
      'RPZA JPEG',
    );
    await run([
      'vcs',
      '-c2',
      '-H22',
      '-n4',
      '-f3',
      '-t750ms',
      '-T3',
      '-o',
      sheet,
      input,
    ]);
    check(
      ascii.decode(File(sheet).readAsBytesSync().sublist(4, 12)) == 'ftypavis',
      'RPZA AVIF',
    );
  } finally {
    dir.deleteSync(recursive: true);
  }
}
