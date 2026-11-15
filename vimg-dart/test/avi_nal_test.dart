import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:image/image.dart' as image;
import 'package:vimg_dart/src/iso_media.dart';
import 'package:vimg_dart/src/mpeg_systems.dart';
import 'package:vimg_dart/src/video.dart';
import 'package:vimg_dart/src/video_configuration.dart';

import 'fixtures.dart';

Future<void> main(List<String> arguments) async {
  final temp = Directory.systemTemp.createTempSync('vimg-avi-nal-');
  try {
    await _check(
      temp,
      'test/fixtures/cabac-b-temporal.mp4',
      'avc1',
      gap: true,
      executable: arguments.firstOrNull,
    );
    await _check(temp, 'test/fixtures/hevc-main10.mp4', 'hvc1');
    await _check(temp, 'test/fixtures/hevc-open-gop.m2ts', 'HEVC');
    await _check(
      temp,
      'test/fixtures/avc-field-cavlc.mp4',
      'avc3',
      fields: true,
    );
  } finally {
    temp.deleteSync(recursive: true);
  }
}

Future<void> _check(
  Directory temp,
  String input,
  String tag, {
  bool gap = false,
  bool fields = false,
  String? executable,
}) async {
  final source = Video(input);
  try {
    final info = source.metadata.streams.single;
    final display = source.packets().toList();
    final sourceIndices = {
      for (final (i, packet) in display.indexed) packet: i,
    };
    final pixels = {
      for (final frame in source.decodeSelected(display))
        sourceIndices[frame.packet]!: frame.frame.getBytes(),
    };
    final systems = MpegSystemsVideo.detect(source.file);
    Uint8List? record;
    final frames = <List<int>>[];
    if (systems == null) {
      final iso = IsoMedia(source.file);
      record = isoVideoConfiguration(iso, source.codec)!;
      for (final packet in isoFrames(iso)) {
        frames.add(source.file.read(packet.offset, packet.size));
      }
    } else {
      for (final packet in systems.packets(false)) {
        final sample = systems.read(packet);
        final lengths = ByteData.sublistView(sample);
        for (var at = 0; at < sample.length;) {
          final length = lengths.getUint32(at);
          lengths.setUint32(at, 1);
          at += 4 + length;
        }
        frames.add(sample);
      }
    }
    if (gap) frames.insert(1, const []);
    final rate = fields ? 16 : 8;
    final path = File('${temp.path}/$tag.avi')
      ..writeAsBytesSync(
        _avi(tag, info.width, info.height, rate, frames, extra: record),
      );
    final video = Video(path.path);
    final workers = VideoCaptureDecoder(video, threads: 2);
    try {
      final stream = video.metadata.streams.single;
      check(
        stream.codec == info.codec && stream.timeBase == '1/$rate',
        '$tag stream information',
      );
      check(
        video.metadata.duration == frames.length / rate,
        '$tag AVI duration',
      );
      final packets = video.packets().toList();
      check(packets.length == display.length, '$tag displayed picture count');
      final positions = {for (final (i, packet) in packets.indexed) packet: i};
      for (final (i, packet) in packets.indexed) {
        final expected = fields ? 2 * i : (gap && i > 0 ? i + 1 : i);
        check(
          packet.timestamp!.pts == expected &&
              packet.seconds == expected / rate,
          '$tag presentation slot $i',
        );
        check(
          packet.timestamp!.duration == (fields ? 2 : 1),
          '$tag sample duration',
        );
      }
      var decoded = 0;
      await for (final frame in workers.decode(packets)) {
        _same(frame.frame.getBytes(), pixels[positions[frame.packet]!]!, tag);
        decoded++;
      }
      check(decoded == packets.length, '$tag decoded picture count');
      final keyframes = video.packets(preview: true).toList();
      for (final key in keyframes) {
        _same(
          video.decode(key, preview: true).getBytes(),
          pixels[positions[key]!]!,
          tag,
        );
      }
      check(keyframes.isNotEmpty, '$tag random-access preview');
    } finally {
      await workers.close();
      video.close();
    }
    if (executable != null)
      await _checkCli(executable, temp, path, info.width, info.height);
  } finally {
    source.close();
  }
}

List<int> _avi(
  String tag,
  int width,
  int height,
  int rate,
  List<List<int>> frames, {
  Uint8List? extra,
}) {
  List<int> little(int value, int size) => uint(value, size).reversed.toList();
  List<int> chunk(String name, List<int> data) => [
    ...ascii.encode(name),
    ...little(data.length, 4),
    ...data,
    if (data.length.isOdd) 0,
  ];
  List<int> list(String name, List<int> data) =>
      chunk('LIST', [...ascii.encode(name), ...data]);
  return chunk('RIFF', [
    ...ascii.encode('AVI '),
    ...list(
      'hdrl',
      list('strl', [
        ...chunk('strh', [
          ...ascii.encode('vids$tag'),
          ...List.filled(12, 0),
          ...little(1, 4),
          ...little(rate, 4),
          ...little(0, 4),
          ...little(frames.length, 4),
          ...List.filled(20, 0),
        ]),
        ...chunk('strf', [
          ...little(40 + (extra?.length ?? 0), 4),
          ...little(width, 4),
          ...little(height, 4),
          ...little(1, 2),
          ...little(24, 2),
          ...ascii.encode(tag),
          ...List.filled(20, 0),
          ...?extra,
        ]),
      ]),
    ),
    ...list('movi', [for (final frame in frames) ...chunk('00dc', frame)]),
  ]);
}

Future<void> _checkCli(
  String cli,
  Directory temp,
  File input,
  int width,
  int height,
) async {
  Future<void> run(List<String> args) async {
    final result = await Process.run(cli, [...args, input.path]);
    check(result.exitCode == 0, '$args: ${result.stderr}');
  }

  final preview = File('${temp.path}/preview.jpg');
  await run(['preview', '--output', preview.path]);
  final jpg = image.decodeJpg(preview.readAsBytesSync())!;
  check((jpg.width, jpg.height) == (width, height), 'AVI JPEG preview');
  final dir = Directory('${temp.path}/extracted');
  await run(['extract', '-n1', '-f2', '-t500ms', '--output-dir', dir.path]);
  check(dir.listSync().length == 2, 'AVI BMP extraction');
  final sheet = File('${temp.path}/sheet.avif');
  await run(['vcs', '-n1', '-c1', '-f2', '-t500ms', '-H24', '-o', sheet.path]);
  check(sheet.lengthSync() > 0, 'AVI AVIF contact sheet');
}

void _same(Uint8List actual, Uint8List expected, String label) {
  check(actual.length == expected.length, '$label pixel count');
  for (var i = 0; i < actual.length; i++) {
    if (actual[i] != expected[i]) throw StateError('$label pixel $i');
  }
}
