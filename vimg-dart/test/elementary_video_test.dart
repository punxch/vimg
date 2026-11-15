import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:image/image.dart' as image;
import 'package:vimg_dart/src/avif_animation.dart';
import 'package:vimg_dart/src/mpeg_systems.dart';
import 'package:vimg_dart/src/video.dart';

import 'fixtures.dart';

Future<void> main(List<String> arguments) async {
  final temp = Directory.systemTemp.createTempSync('vimg-annex-b-');
  try {
    await _checkStream(
      temp,
      'test/fixtures/cabac-b-aac.ts',
      arguments.firstOrNull,
    );
    await _checkStream(
      temp,
      'test/fixtures/hevc-open-gop.m2ts',
      arguments.firstOrNull,
    );
  } finally {
    temp.deleteSync(recursive: true);
  }
}

Future<void> _checkStream(
  Directory temp,
  String input,
  String? executable,
) async {
  final original = Video(input);
  try {
    final systems = MpegSystemsVideo.detect(original.file)!;
    final displayed = original.packets().toList();
    final indices = {for (final (i, packet) in displayed.indexed) packet: i};
    final source = {
      for (final frame in original.decodeSelected(displayed))
        indices[frame.packet]!: frame.frame.getBytes(),
    };
    final codec = original.codec;
    final hevc = codec == 'hevc';
    // Sequence headers from these fixtures with their timing fields removed.
    // The alternate HEVC VPS sets num_units_in_tick=1001 and time_scale=24000.
    final noTiming = hevc
        ? _nal('42010101600000030090000003000003001ea0152071d56595924932b80080')
        : _nal('6764000aacd942cfe6a8078912cb');
    final timedVps = _nal(
      '40010c01ffff01600000030090000003000003001e95900c00000fa40001770140',
    );
    for (final (label, ticks, headers) in [
      ('sps', 150000, const <int, Uint8List>{}),
      ('default', 48000, {hevc ? 33 : 7: noTiming}),
      if (hevc) ('vps', 50050, {33: noTiming, 32: timedVps}),
    ]) {
      final bytes = BytesBuilder(copy: false)..add([0, 0, 0]);
      for (final (i, packet) in systems.packets(false).indexed) {
        final sample = systems.read(packet);
        final sizes = ByteData.sublistView(sample);
        for (var start = 0; start < sample.length;) {
          final end = start + 4 + sizes.getUint32(start);
          final nal = Uint8List.sublistView(sample, start + 4, end);
          final type = hevc ? (nal[0] >> 1) & 63 : nal[0] & 31;
          bytes.add([if (i.isEven) 0, 0, 0, 1]);
          bytes.add(headers[type] ?? nal);
          start = end;
        }
      }
      final path = File('${temp.path}/$codec-$label.bin')
        ..writeAsBytesSync(bytes.takeBytes());
      final video = Video(path.path);
      try {
        final stream = video.metadata.streams.single;
        final packets = video.packets().toList();
        check(
          stream.codec == codec && stream.timeBase == '1/1200000',
          '$label raw codec and clock',
        );
        check(
          (stream.width, stream.height) == (166, 110),
          '$label raw dimensions',
        );
        check(packets.length == source.length, '$label raw picture count');
        check(
          video.metadata.duration == source.length * ticks / 1200000,
          '$label raw duration',
        );
        for (final (i, packet) in packets.indexed) {
          check(
            packet.timestamp!.pts == i * ticks &&
                packet.timestamp!.duration == ticks,
            '$label raw timing at $i',
          );
        }
        final positions = {
          for (final (i, packet) in packets.indexed) packet: i,
        };
        final decoded = video.decodeSelected(packets).toList();
        check(decoded.length == packets.length, '$label decoded picture count');
        for (final frame in decoded) {
          final position = positions[frame.packet]!;
          final actual = frame.frame.getBytes();
          final expected = source[position]!;
          check(actual.length == expected.length, '$label RGB geometry');
          for (var i = 0; i < actual.length; i++) {
            if (actual[i] != expected[i]) {
              throw StateError(
                '$codec $label frame $position pixel differs at $i',
              );
            }
          }
        }
      } finally {
        video.close();
      }
      if (executable != null && label == 'sps') {
        await _checkCommands(executable, temp, path.path, codec);
      }
    }
  } finally {
    original.close();
  }
}

Uint8List _nal(String hex) => Uint8List.fromList([
  for (var i = 0; i < hex.length; i += 2)
    int.parse(hex.substring(i, i + 2), radix: 16),
]);

Future<void> _checkCommands(
  String program,
  Directory temp,
  String path,
  String codec,
) async {
  Future<String> run(List<String> args) async {
    final result = await Process.run(program, [...args, path]);
    check(result.exitCode == 0, '$args: ${result.stderr}');
    return result.stdout as String;
  }

  final preview = File('${temp.path}/$codec.jpg');
  final response =
      jsonDecode(
            await run(['preview', '--skip', '0', '--output', preview.path]),
          )
          as Map;
  check(response['preview_written'] == true, '$codec preview');
  final jpg = image.decodeJpg(preview.readAsBytesSync())!;
  check((jpg.width, jpg.height) == (166, 110), '$codec preview dimensions');

  final dir = Directory('${temp.path}/$codec-extract');
  await run(['extract', '-n1', '-f4', '-t1s', '--output-dir', dir.path]);
  check(dir.listSync().length == 4, '$codec BMP count');

  final sheet = '${temp.path}/$codec.avif';
  await run(['vcs', '-n1', '-f2', '-t500ms', '-c1', '-H16', '-o', sheet]);
  final avif = AvifAnimation.open(sheet);
  try {
    check(
      avif.frameCount == 2 && avif.height == 16,
      '$codec AVIF contact sheet',
    );
  } finally {
    avif.close();
  }
}
