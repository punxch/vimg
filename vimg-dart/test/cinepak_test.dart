import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:image/image.dart' as image;
import 'package:vimg_dart/src/cinepak.dart';
import 'package:vimg_dart/src/video.dart';

import 'fixtures.dart';

// FNV-1a hashes of FFmpeg's RGB24 output.
const _color = [
  0xdd904eb8,
  0x53c76fe7,
  0xb48b51b7,
  0xed846ee8,
  0xe52719c0,
  0x45e64b92,
  0xd0848e24,
  0x7f47cd51,
  0xb381c96b,
  0x931dd834,
  0xe1317a27,
  0xc15669af,
  0xea015e70,
  0x85238630,
  0x540049ce,
  0xc3af53e8,
];
const _gray = [
  0x4c0acfd5,
  0x371620cd,
  0x371620cd,
  0x371620cd,
  0x53b244e7,
  0xc85b550a,
  0x551f3d2d,
  0x9c147e96,
];
const _palette = [
  0x893b7a05,
  0xec7d54e5,
  0x489e0c65,
  0xbf29fc8d,
  0xee7930ad,
  0xac910061,
];

Future<void> main(List<String> arguments) async {
  await _checkVideo('color.mov', _color, [0, 8], 8);
  await _checkVideo('color.avi', _color, [0, 8], 8);
  await _checkVideo('gray.mov', _gray, [0, 4], 8);
  // The fourth sample reuses a codebook entry last updated in the second
  // sample, even though the third sample can be decoded on its own.
  await _checkVideo('palette.mov', _palette, [0, 2, 4], 4);
  await _checkVideo('palette.avi', _palette, [0, 2, 4], 4);
  _checkPaddedPicture();
  await _checkCli(arguments.firstOrNull);
}

Future<void> _checkVideo(
  String fixture,
  List<int> expected,
  List<int> keys,
  int rate,
) async {
  final video = Video('test/fixtures/cinepak-$fixture');
  final workers = VideoCaptureDecoder(video, threads: 3);
  try {
    check(video.codec == 'cinepak', '$fixture codec');
    final packets = video.packets().toList();
    check(packets.length == expected.length, '$fixture frame count');
    final positions = {for (final (i, packet) in packets.indexed) packet: i};
    for (final (i, packet) in packets.indexed) {
      check(
        (packet.seconds - i / rate).abs() < 1e-9,
        '$fixture PTS at frame $i',
      );
      check(_hash(video.decode(packet)) == expected[i], '$fixture seek to $i');
    }
    final previews = video.packets(preview: true).toList();
    check(previews.length == keys.length, '$fixture preview count');
    for (final (i, packet) in previews.indexed) {
      check(positions[packet] == keys[i], '$fixture preview anchor');
      check(
        _hash(video.decode(packet, preview: true)) == expected[keys[i]],
        '$fixture preview pixels',
      );
    }
    final selected = {
      packets.last,
      packets[3],
      for (final i in keys.skip(1)) packets[i],
    };
    await for (final result in workers.decode(selected.toList().reversed)) {
      final i = positions[result.packet]!;
      check(selected.remove(result.packet), '$fixture parallel frame identity');
      check(_hash(result.frame) == expected[i], '$fixture parallel frame $i');
    }
    check(selected.isEmpty, '$fixture parallel frame count');
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

void _checkPaddedPicture() {
  final entry = Uint8List(78);
  ByteData.sublistView(entry)
    ..setUint16(24, 3)
    ..setUint16(26, 3)
    ..setUint16(74, 24);
  final sample = Uint8List.fromList([
    0, 0, 0, 35, 0, 4, 0, 4, 0, 1, // frame
    0x10, 0, 0, 25, 0, 0, 0, 0, 0, 4, 0, 4, // strip
    0x26, 0, 0, 8, 10, 20, 30, 40, // grayscale V1 codebook
    0x32, 0, 0, 5, 0, // one 4-by-4 block
  ]);
  final decoder = CinepakDecoder(entry)..advance(sample);
  final frame = decoder.rgb();
  check(frame.width == 3 && frame.height == 3, 'Crop Cinepak edge padding');
  check(frame.getPixel(2, 2).r == 40, 'Decode the last visible quadrant');
  final order = CinepakPictureOrder(3, 3);
  check(
    order.anchor(sample, 0) == 0,
    'Padded sample is independently decodable',
  );
  sample[25] = 9;
  try {
    decoder.advance(sample);
    throw StateError('Accepted a truncated Cinepak codebook entry');
  } on FormatException catch (error) {
    check(error.message == 'Truncated Cinepak bitstream', 'Bounded codebook');
  }
}

Future<void> _checkCli(String? executable) async {
  const input = 'test/fixtures/cinepak-color.avi';
  final directory = Directory.systemTemp.createTempSync('vimg-cinepak-');
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
      image.decodeJpg(File(preview).readAsBytesSync())?.width == 80,
      'Cinepak JPEG preview',
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
      'Cinepak animated AVIF',
    );
  } finally {
    directory.deleteSync(recursive: true);
  }
}
