import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:image/image.dart' as image;
import 'package:vimg_dart/src/avi.dart';
import 'package:vimg_dart/src/ffv1.dart';
import 'package:vimg_dart/src/iso_media.dart';
import 'package:vimg_dart/src/matroska.dart';
import 'package:vimg_dart/src/video.dart';
import 'package:vimg_dart/src/video_configuration.dart';

import 'fixtures.dart';

const _rice = 'test/fixtures/ffv1-rice.mkv';
const _range16 = 'test/fixtures/ffv1-range16.avi';
const _rgba = 'test/fixtures/ffv1-rgba.mov';

Future<void> main(List<String> arguments) async {
  await _checkVideo(_rice);
  await _checkVideo(_range16);
  await _checkVideo(_rgba);
  await _checkCli(arguments.firstOrNull);
}

Future<void> _checkVideo(String path) async {
  final video = Video(path);
  final workers = VideoCaptureDecoder(video, threads: 2);
  try {
    final stream = video.metadata.streams.single;
    check(stream.codec == 'ffv1', '$path codec');
    final width = stream.width, height = stream.height;
    check(width == 22 && height == 18, '$path dimensions');
    final configuration = switch (path) {
      _rice => matroskaVideoConfiguration(Matroska(video.file), 'ffv1')!,
      _range16 => Avi(video.file).videoPrivateData()!,
      _ => isoVideoConfiguration(IsoMedia(video.file), 'ffv1')!,
    };
    final decoder = Ffv1Decoder(width, height, configuration);
    final packets = video.packets().toList();
    check(packets.length == 5, '$path packet count');
    final keys = video.packets(preview: true).toList();
    check(
      keys.length == 2 && keys[0] == packets[0] && keys[1] == packets[3],
      '$path FFV1 keyframe selection',
    );

    final expectedRgb = <Uint8List>[];
    for (final (frame, packet) in packets.indexed) {
      final picture = decoder.decode(
        video.file.read(packet.offset, packet.size),
      );
      final planes = path == _rgba
          ? [picture.cb, picture.y, picture.cr, picture.alpha!]
          : [picture.y, picture.cb, picture.cr];
      for (final (plane, samples) in planes.indexed) {
        final length = path == _rgba || plane == 0
            ? width * height
            : width * height ~/ 4;
        check(samples.length == length, '$path plane dimensions $plane');
        for (final (i, sample) in samples.indexed) {
          final expected = switch (path) {
            _range16 =>
              (i * 6013 + (i ~/ 7) * 3011 + frame * 19091 + plane * 5999) &
                  65535,
            _rgba =>
              (i * (plane + 1) + (i ~/ 3) * 29 + frame * 47 + plane * 69) & 255,
            _ when i % 25 < 9 => (frame * 21 + plane * 51) & 255,
            _ => (i * 3 + (i ~/ 7) * 11 + frame * 19 + plane * 59) & 255,
          };
          check(
            sample == expected,
            '$path frame $frame plane $plane sample $i',
          );
        }
      }
      expectedRgb.add(picture.rgb().getBytes());
    }

    check(
      _equal(video.decode(packets[4]).getBytes(), expectedRgb[4]),
      '$path seek from the second keyframe',
    );
    final positions = {for (final (i, p) in packets.indexed) p: i};
    var decoded = 0;
    await for (final capture in workers.decode([packets[2], packets[4]])) {
      check(
        _equal(
          capture.frame.getBytes(),
          expectedRgb[positions[capture.packet]!],
        ),
        '$path worker capture from a non-keyframe',
      );
      decoded++;
    }
    check(decoded == 2, '$path capture count');

    final badConfig = Uint8List.fromList(configuration)..[1] ^= 1;
    _formatError(() => Ffv1Decoder(width, height, badConfig));
    if (path != _range16) {
      final damaged = video.file.read(packets[0].offset, packets[0].size)
        ..[2] ^= 1;
      _formatError(() => decoder.decode(damaged));
      final restart = packets[3];
      check(
        _equal(
          decoder
              .decode(video.file.read(restart.offset, restart.size))
              .rgb()
              .getBytes(),
          expectedRgb[3],
        ),
        '$path restart after a damaged slice',
      );
    }
  } finally {
    await workers.close();
    video.close();
  }
}

bool _equal(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

void _formatError(void Function() decode) {
  try {
    decode();
  } on FormatException catch (error) {
    check(error.message.contains('CRC'), 'FFV1 checksum error');
    return;
  }
  throw StateError('Expected an FFV1 checksum error');
}

Future<void> _checkCli(String? executable) async {
  final temp = Directory.systemTemp.createTempSync('vimg-ffv1-');
  Future<void> run(List<String> arguments) async {
    final result = await Process.run(
      executable ?? Platform.resolvedExecutable,
      [if (executable == null) 'bin/vimg.dart', ...arguments],
    );
    check(result.exitCode == 0, '${result.stderr}');
  }

  try {
    final preview = '${temp.path}/preview.jpg';
    final sheet = '${temp.path}/sheet.avif';
    await run(['preview', '--output', preview, '--skip', '50', _range16]);
    check(
      image.decodeJpg(File(preview).readAsBytesSync())?.width == 22,
      'FFV1 JPEG preview',
    );
    await run(['extract', '-n3', '--output-dir', '${temp.path}/frames', _rgba]);
    final frames = Directory('${temp.path}/frames').listSync();
    check(frames.length == 3, 'FFV1 BMP extraction');
    await run([
      'vcs',
      '-c2',
      '-H18',
      '-n3',
      '-f3',
      '-t500ms',
      '-o',
      sheet,
      _rice,
    ]);
    final bytes = File(sheet).readAsBytesSync();
    check(
      ascii.decode(bytes.sublist(4, 12)) == 'ftypavis',
      'FFV1 contact sheet',
    );
  } finally {
    temp.deleteSync(recursive: true);
  }
}
