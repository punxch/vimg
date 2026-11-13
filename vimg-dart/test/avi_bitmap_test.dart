import 'dart:io';

import 'package:image/image.dart' as image;
import 'package:vimg_dart/src/video.dart';

import 'fixtures.dart';

Future<void> main(List<String> arguments) async {
  // RGB hashes from FFmpeg. The bitfields are also checked by decoding the
  // same DIB header and pixel bytes as a standalone BMP.
  for (final (name, width, pts, hashes) in [
    ('dib1', 9, [0], [0x3473c6ca]),
    ('dib4', 5, [0, 1, 3], [0x286f1425, 0x07fad6eb, 0xa5ccd6f3]),
    ('dib8', 3, [0], [0xcbd60bfd]),
    ('rgb555', 3, [0], [0x7f2c4d52]),
    ('rgb565', 3, [0], [0xc9efb342]),
    ('rgb32-mask', 3, [0], [0x6f487ebd]),
  ]) {
    final video = Video('test/fixtures/avi-$name.avi');
    final capture = VideoCaptureDecoder(video, threads: 3);
    try {
      check(video.codec == 'rawvideo', '$name codec');
      final packets = video.packets().toList();
      check(packets.length == hashes.length, '$name frame count');
      final expected = {
        for (final (i, packet) in packets.indexed) packet: hashes[i],
      };
      for (final (i, packet) in packets.indexed) {
        check(packet.timestamp?.pts == pts[i], '$name timestamp at frame $i');
        final frame = video.decode(packet, preview: true);
        check(frame.width == width && frame.height == 2, '$name geometry');
        check(_hash(frame) == hashes[i], '$name preview frame $i');
      }
      await for (final result in capture.decode(packets.reversed)) {
        check(
          _hash(result.frame) == expected.remove(result.packet),
          '$name parallel frame at ${result.packet.seconds}',
        );
      }
      check(expected.isEmpty, '$name parallel capture count');
    } finally {
      await capture.close();
      video.close();
    }
  }
  await _checkExtract(arguments.firstOrNull);
}

Future<void> _checkExtract(String? executable) async {
  final output = Directory.systemTemp.createTempSync('vimg-avi-');
  try {
    final result =
        await Process.run(executable ?? Platform.resolvedExecutable, [
          if (executable == null) 'bin/vimg.dart',
          'extract',
          '-n1',
          '-f3',
          '-t2s',
          '-T3',
          '--output-dir',
          output.path,
          'test/fixtures/avi-dib4.avi',
        ]);
    check(result.exitCode == 0, '${result.stderr}');
    final files = output.listSync().whereType<File>().toList()
      ..sort((a, b) => a.path.compareTo(b.path));
    // Constant-rate capture holds the first source picture for two outputs.
    const expected = [0x286f1425, 0x286f1425, 0x07fad6eb];
    check(files.length == expected.length, 'AVI BMP extraction count');
    for (final (i, file) in files.indexed) {
      final bitmap = image.decodeBmp(file.readAsBytesSync())!;
      check(_hash(bitmap.convert(numChannels: 3)) == expected[i], 'AVI BMP $i');
    }
  } finally {
    output.deleteSync(recursive: true);
  }
}

int _hash(image.Image frame) {
  var hash = 0x811c9dc5;
  for (final byte in frame.getBytes()) {
    hash = ((hash ^ byte) * 0x01000193) & 0xffffffff;
  }
  return hash;
}
