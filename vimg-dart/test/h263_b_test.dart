import 'dart:io';

import 'package:archive/archive.dart';
import 'package:vimg_dart/src/video.dart';

import 'fixtures.dart';

const _standard = [
  115672953,
  3456157475,
  651096239,
  1323034346,
  3857762517,
  3779272508,
  3137979850,
  156463470,
  4263584294,
];
const _custom = [
  115672953,
  356485689,
  1718361906,
  1323034346,
  3691147550,
  3779272508,
  4090644610,
  156463470,
  4263584294,
];

Future<void> main(List<String> arguments) async {
  // Independently calculated from Annex O prediction, starting with
  // DC-only anchor blocks. Both streams have a B-picture before a new
  // I-picture and a later B-picture that inherits its layer's PLUSPTYPE.
  const ticks = [0, 2, 6, 8, 11, 16, 20, 24, 32];
  await _verify(
    'h263-b.h263',
    _standard,
    [for (final tick in ticks) tick * 1001 / 30000],
    (64, 32),
    [5, 0],
  );
  await _verify(
    'h263-b-custom.h263',
    _custom,
    [for (final tick in ticks) tick / 20],
    (64, 32),
    [5, 0],
  );
  await _verify(
    'h263-b.avi',
    _standard,
    [0, 0.01, 0.03, 0.04, 0.085, 0.16, 0.20, 0.24, 0.32],
    (64, 32),
    [5, 0],
  );
  await _verify(
    'h263-b-pts.mkv',
    _standard,
    [0, 0.02, 0.06, 0.08, 0.11, 0.16, 0.20, 0.24, 0.32],
    (64, 32),
    [5, 0],
  );
  // Direct prediction uses all four vectors in the colocated macroblock.
  await _verify(
    'h263-b-direct.h263',
    [1182910710, 2973819681, 2199630050, 2199630050],
    [
      for (final tick in [0, 2, 4, 5]) tick * 1001 / 30000,
    ],
    (48, 32),
    [0],
  );
  await _verify(
    'h263-b-base-inherit.h263',
    [165548718, 271083572, 1415725058],
    [
      for (final tick in [0, 4, 18]) tick * 1001 / 30000,
    ],
    (128, 96),
    [0, 2],
  );
  if (arguments.firstOrNull case final cli?) await _checkCli(cli);
}

Future<void> _verify(
  String name,
  List<int> expected,
  List<double> times,
  (int, int) dimensions,
  List<int> keyIndices,
) async {
  final video = Video('test/fixtures/$name');
  final worker = VideoCaptureDecoder(video, threads: 2);
  try {
    final stream = video.metadata.streams.single;
    check((stream.width, stream.height) == dimensions, '$name dimensions');
    final packets = video.packets().toList();
    check(packets.length == expected.length, '$name display frame count');
    final keys = video.packets(preview: true).toSet();
    check(
      keys.length == keyIndices.length &&
          keyIndices.every((i) => keys.contains(packets[i])),
      '$name random access',
    );
    final captures = {
      for (final capture in video.decodeSelected(packets))
        capture.packet: getCrc32(capture.frame.getBytes()),
    };
    for (final (i, packet) in packets.indexed) {
      check((packet.seconds - times[i]).abs() < 1e-8, '$name display time $i');
      check(captures[packet] == expected[i], '$name display pixels $i');
    }
    if (name.endsWith('.avi')) {
      final stamp = packets[4].subframe!.sampleTimestamp!;
      check(
        (stamp.pts * stamp.numerator / stamp.denominator - 0.2).abs() < 1e-8,
        '$name retains the coded sample timestamp',
      );
    }
    if (name.endsWith('.mkv')) {
      check(
        packets[4].subframe == null,
        '$name keeps the supplied B-picture timestamp',
      );
    }
    final seek = switch (expected.length) {
      3 => [1, 2, 0],
      4 => [1, 3, 0],
      _ => [4, 6, 2, 7, 1, 8],
    };
    for (final i in seek) {
      final capture = await worker.decode([packets[i]]).single;
      check(getCrc32(capture.frame.getBytes()) == expected[i], '$name seek $i');
    }
    final parallel = {
      await for (final capture in worker.decode(seek.map((i) => packets[i])))
        capture.packet: getCrc32(capture.frame.getBytes()),
    };
    check(
      seek.every((i) => parallel[packets[i]] == expected[i]),
      '$name parallel captures',
    );
  } finally {
    await worker.close();
    video.close();
  }
}

Future<void> _checkCli(String cli) async {
  final directory = Directory.systemTemp.createTempSync('vimg-h263-b-');
  try {
    final output = File('${directory.path}/b.avif');
    final result = await Process.run(cli, [
      'vcs',
      '-c2',
      '-H24',
      '-n2',
      '-f3',
      '-t130ms',
      '--vfilter',
      'setpts=PTS-STARTPTS',
      '-o',
      output.path,
      'test/fixtures/h263-b.avi',
    ]);
    check(result.exitCode == 0, 'H.263+ B contact sheet: ${result.stderr}');
    check(
      String.fromCharCodes(output.readAsBytesSync().sublist(4, 12)) ==
          'ftypavis',
      'H.263+ B animated contact sheet',
    );
  } finally {
    directory.deleteSync(recursive: true);
  }
}
