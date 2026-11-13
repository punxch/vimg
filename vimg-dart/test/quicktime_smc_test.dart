import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:image/image.dart' as image;
import 'package:vimg_dart/src/quicktime_smc.dart';
import 'package:vimg_dart/src/video.dart';

import 'fixtures.dart';

// FNV-1a hashes of FFmpeg's RGB24 output for the two source sequences.
const _encoded = [
  0x5a6ecd40,
  0xdf1717ba,
  0xdf1717ba,
  0x0ee9f693,
  0x66d24c58,
  0xc0ffe36c,
  0xa5ba5fe4,
  0x51defef5,
  0x53015881,
  0x0912b9d1,
  0x9e608189,
  0xf0d06599,
  0x37f8bea9,
  0xd0107ba9,
  0xfb81e039,
  0x56c35539,
];
const _commands = [
  0xd1c1bda0,
  0x6cb3a145,
  0xaf1f5c75,
  0x44851d15,
  0x0b1a8dd5,
  0x2ac2e0b5,
  0x26096205,
];

Future<void> main(List<String> arguments) async {
  // FFmpeg marks its ninth sample as a keyframe, but it still uses an
  // earlier block palette. Every frame must also decode from a sparse seek.
  await _checkVideo('smc-encoded.mov', _encoded, [0], 8);
  await _checkVideo('smc-commands.mov', _commands, [0, 1, 3, 5], 4);
  await _checkVideo(
    'smc-description-switch.mov',
    [..._commands.take(2), ..._encoded.take(3), ..._commands.take(2)],
    [0, 1, 2, 5, 6],
    4,
  );
  _checkInvalidBlocks();
  _checkPaletteWrap();
  await _checkCli(arguments.firstOrNull);
}

void _checkPaletteWrap() {
  const blocks = 258;
  final entry = Uint8List(78);
  ByteData.sublistView(entry)
    ..setUint16(24, blocks * 4)
    ..setUint16(26, 4)
    ..setUint16(74, 40)
    ..setUint16(76, 65535);
  final decoder = QuickTimeSmcDecoder(entry);
  final payload = [
    for (var i = 0; i < 257; i++) ...[0x80, i & 255, 1, 0, 0],
    0x90,
    0,
    0,
    0,
  ];
  final sample = Uint8List.fromList([
    ...uint(4 + payload.length, 4),
    ...payload,
  ]);
  final order = SmcPictureOrder(blocks);
  check(
    order.anchor(sample, 0) == 0,
    'Palette wrap remains independently decodable',
  );
  decoder.advance(sample);
  final frame = decoder.rgb();
  check(frame.getPixel(4, 0).r == 254, 'SMC grayscale ramp');
  check(
    frame.getPixel((blocks - 1) * 4, 0).r == 255,
    'Reused wrapped palette slot',
  );
}

Future<void> _checkVideo(
  String name,
  List<int> expected,
  List<int> keys,
  int rate,
) async {
  final video = Video('test/fixtures/$name');
  final workers = VideoCaptureDecoder(video, threads: 3);
  try {
    check(video.codec == 'smc', '$name codec');
    final packets = video.packets().toList();
    check(packets.length == expected.length, '$name frame count');
    final positions = {for (final (i, packet) in packets.indexed) packet: i};
    for (final (i, packet) in packets.indexed) {
      check(packet.seconds == i / rate, '$name PTS');
      check(
        _hash(video.decode(packet)) == expected[i],
        '$name seek to frame $i',
      );
    }
    final previews = video.packets(preview: true).toList();
    check(previews.length == keys.length, '$name preview frame count');
    for (final (i, packet) in previews.indexed) {
      check(positions[packet] == keys[i], '$name preview anchor');
      check(
        _hash(video.decode(packet, preview: true)) == expected[keys[i]],
        '$name preview pixels',
      );
    }
    // Cross both a stale palette reference and a newer independent picture.
    final selected = {
      packets.last,
      packets[2],
      for (final i in keys.skip(1)) packets[i],
    };
    await for (final result in workers.decode(selected.toList().reversed)) {
      final i = positions[result.packet]!;
      check(selected.remove(result.packet), '$name parallel frame identity');
      check(_hash(result.frame) == expected[i], '$name parallel frame $i');
    }
    check(selected.isEmpty, '$name parallel frame count');
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

void _checkInvalidBlocks() {
  final entry = Uint8List(78);
  ByteData.sublistView(entry)
    ..setUint16(24, 4)
    ..setUint16(26, 4)
    ..setUint16(74, 8)
    ..setUint16(76, 65535);
  for (final (payload, reason) in [
    ([0x00], 'Missing SMC reference frame'),
    ([0x90, 0, 0, 0], 'Missing SMC reference frame'),
    ([0x20], 'Invalid SMC block repeat'),
    ([0x61, 4], 'Invalid SMC block extent'),
    ([0x80, 1, 2, 0], 'Truncated SMC block'),
    (<int>[], 'Incomplete SMC picture'),
  ]) {
    final decoder = QuickTimeSmcDecoder(entry);
    try {
      decoder.advance(
        Uint8List.fromList([...uint(payload.length + 4, 4), ...payload]),
      );
      throw StateError('Accepted invalid SMC: $reason');
    } on FormatException catch (error) {
      check(error.message == reason, reason);
    }
  }
}

Future<void> _checkCli(String? executable) async {
  const input = 'test/fixtures/smc-description-switch.mov';
  final directory = Directory.systemTemp.createTempSync('vimg-smc-');
  Future<void> run(List<String> arguments) async {
    final result = await Process.run(
      executable ?? Platform.resolvedExecutable,
      [if (executable == null) 'bin/vimg.dart', ...arguments],
    );
    check(result.exitCode == 0, '${result.stderr}');
  }

  try {
    final preview = '${directory.path}/preview.jpg';
    final sheet = '${directory.path}/sheet.avif';
    await run(['preview', '--output', preview, '--skip', '50', input]);
    check(
      image.decodeJpg(File(preview).readAsBytesSync())?.width == 48,
      'SMC JPEG',
    );
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
      'SMC AVIF',
    );
  } finally {
    directory.deleteSync(recursive: true);
  }
}
