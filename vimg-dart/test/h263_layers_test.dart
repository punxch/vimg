import 'dart:io';

import 'package:archive/archive.dart';
import 'package:image/image.dart' as image;
import 'package:vimg_dart/src/video.dart';

import 'fixtures.dart';

const _spatial = [
  3376933934,
  2904621002,
  1672528716,
  3691609459,
  4268687912,
  2791463765,
  178421204,
  3407379774,
];

Future<void> main(List<String> arguments) async {
  // Independent samples exercise the EI/EP texture syntax, inherited layer
  // options, B-pictures referencing EP anchors, and a base-layer I-picture
  // whose EP enhancement still needs the preceding GOP.
  final times = [
    for (final tick in [0, 2, 4, 6, 8, 12, 14, 16]) tick * 1001 / 30000,
  ];
  await _verify(
    'snr.h263',
    [
      3148634004,
      3505822976,
      3093766788,
      2424131212,
      460438003,
      1009947981,
      1486464369,
      735425954,
    ],
    times,
    (64, 32),
  );
  await _verify(
    'snr-aic.h263',
    [
      3432200584,
      172450395,
      425965299,
      1704489852,
      895354132,
      1127671270,
      3819980621,
      678310833,
    ],
    times,
    (64, 32),
  );
  // The second layer doubles width, and the third layer doubles height.
  await _verify('spatial.h263', _spatial, times, (64, 32));
  await _verify(
    'spatial.mkv',
    _spatial,
    [0, 0.06, 0.12, 0.20, 0.28, 0.44, 0.50, 0.56],
    (64, 32),
  );
  // A single two-axis expansion must round once. Pad the coded macroblocks
  // without treating padding beyond the 36x20 source as visible pixels.
  await _verify('2d.h263', [1702357813], [0], (72, 40));
  if (arguments.firstOrNull case final cli?) await _checkCli(cli);
}

Future<void> _verify(
  String name,
  List<int> hashes,
  List<double> times,
  (int, int) dimensions,
) async {
  final video = Video('test/fixtures/h263-layer-$name');
  final worker = VideoCaptureDecoder(video, threads: 2);
  try {
    final stream = video.metadata.streams.single;
    check(
      (stream.width, stream.height) == dimensions,
      '$name display dimensions',
    );
    final packets = video.packets().toList();
    check(packets.length == hashes.length, '$name one layer per display time');
    final keys = video.packets(preview: true).toList();
    final indices = hashes.length == 1 ? [0] : [0, 5];
    check(keys.length == indices.length, '$name key count');
    for (final (i, index) in indices.indexed) {
      check(keys[i] == packets[index], '$name key selects the enhancement');
    }
    final decoded = {
      for (final capture in video.decodeSelected(packets))
        capture.packet: capture.frame,
    };
    for (final (i, packet) in packets.indexed) {
      final frame = decoded[packet]!;
      check((packet.seconds - times[i]).abs() < 1e-8, '$name display time $i');
      check(
        (frame.width, frame.height) == dimensions,
        '$name frame dimensions $i',
      );
      check(getCrc32(frame.getBytes()) == hashes[i], '$name pixels $i');
    }
    final selected = hashes.length == 1 ? [0] : [7, 6, 3, 4, 0, 5, 1];
    for (final i in selected) {
      final capture = await worker.decode([packets[i]]).single;
      check(getCrc32(capture.frame.getBytes()) == hashes[i], '$name seek $i');
    }
    final captures = {
      await for (final capture in worker.decode(
        selected.map((i) => packets[i]),
      ))
        capture.packet: getCrc32(capture.frame.getBytes()),
    };
    check(
      selected.every((i) => captures[packets[i]] == hashes[i]),
      '$name parallel captures',
    );
  } finally {
    await worker.close();
    video.close();
  }
}

Future<void> _checkCli(String cli) async {
  final directory = Directory.systemTemp.createTempSync('vimg-h263-layers-');
  try {
    const input = 'test/fixtures/h263-layer-spatial.mkv';
    final preview = File('${directory.path}/layers.jpg');
    final result = await Process.run(cli, [
      'preview',
      '--output',
      preview.path,
      input,
    ]);
    check(result.exitCode == 0, 'H.263 enhancement preview ${result.stderr}');
    final jpeg = image.decodeJpg(preview.readAsBytesSync());
    check(
      jpeg?.width == 64 && jpeg?.height == 32,
      'H.263 spatial preview dimensions',
    );
    final sheet = File('${directory.path}/layers.avif');
    final capture = await Process.run(cli, [
      'vcs',
      '-c2',
      '-n2',
      '-H24',
      '-f3',
      '-t120ms',
      '--vfilter',
      'crop=48:24,setpts=PTS-STARTPTS',
      '-o',
      sheet.path,
      input,
    ]);
    check(
      capture.exitCode == 0,
      'H.263 enhancement contact sheet ${capture.stderr}',
    );
    check(
      String.fromCharCodes(sheet.readAsBytesSync().sublist(4, 12)) ==
          'ftypavis',
      'H.263 animated enhancement contact sheet',
    );
  } finally {
    directory.deleteSync(recursive: true);
  }
}
