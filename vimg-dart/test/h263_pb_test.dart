import 'dart:io';

import 'package:archive/archive.dart';
import 'package:vimg_dart/src/video.dart';

import 'fixtures.dart';

const _classic = [
  165548718,
  2913328936,
  67729954,
  67729954,
  67729954,
  1415725058,
  1450752973,
  1791891444,
];
const _improved = [
  960830381,
  1463089118,
  2113649902,
  2113649902,
  2113649902,
  3178482867,
  2439413037,
  3360344254,
];

Future<void> main(List<String> arguments) async {
  // Annex G/M predictions calculated from flat DC-coded reference blocks.
  // The same syntax is authored with VLC and SAC. Both 8-bit and 10-bit
  // temporal references wrap, and H.263+ predictive pictures inherit UFEP.
  const classicTicks = [0, 2, 6, 9, 12, 18, 20, 24];
  const improvedTicks = [0, 6, 10, 15, 20, 30, 34, 40];
  for (final suffix in ['.h263', '-sac.h263']) {
    await _verify(
      'h263-pb$suffix',
      _classic,
      [for (final tick in classicTicks) tick * 1001 / 30000],
      (128, 96),
    );
    await _verify(
      'h263-improved-pb$suffix',
      _improved,
      [for (final tick in improvedTicks) tick / 20],
      (64, 32),
    );
  }
  // The muxed sample's P timestamps are 40 ms apart. TRB/TRD places
  // B at 1/3, 1/2 or 1/3 of the interval before its paired P picture.
  await _verify(
    'h263-pb.3gp',
    _classic,
    [0, 1 / 75, 0.04, 0.06, 0.08, 0.12, 2 / 15, 0.16],
    (128, 96),
  );
  if (arguments.firstOrNull case final cli?) {
    final directory = Directory.systemTemp.createTempSync('vimg-h263-pb-');
    try {
      final output = File('${directory.path}/pb.avif');
      final result = await Process.run(cli, [
        'vcs',
        '-c2',
        '-H24',
        '-n2',
        '-f3',
        '-t100ms',
        '--vfilter',
        'setpts=PTS-STARTPTS',
        '-o',
        output.path,
        'test/fixtures/h263-improved-pb.h263',
      ]);
      check(result.exitCode == 0, 'PB contact sheet: ${result.stderr}');
      check(
        String.fromCharCodes(output.readAsBytesSync().sublist(4, 12)) ==
            'ftypavis',
        'PB animated contact sheet',
      );
    } finally {
      directory.deleteSync(recursive: true);
    }
  }
}

Future<void> _verify(
  String name,
  List<int> hashes,
  List<double> times,
  (int, int) dimensions,
) async {
  final video = Video('test/fixtures/$name');
  final worker = VideoCaptureDecoder(video, threads: 2);
  try {
    final stream = video.metadata.streams.single;
    check((stream.width, stream.height) == dimensions, '$name dimensions');
    final packets = video.packets().toList();
    check(packets.length == hashes.length, '$name display frame count');
    check(video.packets(preview: true).length == 2, '$name random access');
    final captures = {
      for (final capture in video.decodeSelected(packets))
        capture.packet: getCrc32(capture.frame.getBytes()),
    };
    for (final (i, packet) in packets.indexed) {
      check((packet.seconds - times[i]).abs() < 1e-7, '$name display time $i');
      check(captures[packet] == hashes[i], '$name display pixels $i');
      if ({0, 2, 5}.contains(i)) {
        final stamp = packet.timestamp!;
        final duration = stamp.duration! * stamp.numerator / stamp.denominator;
        check(
          (duration - (times[i + 1] - times[i])).abs() < 1e-7,
          '$name reference ends at its next B picture $i',
        );
      }
      if ({1, 3, 6}.contains(i)) {
        final next = packets[i + 1];
        check(
          packet.offset == next.offset && packet.size == next.size,
          '$name shared PB payload $i',
        );
        check(
          packet.subframe?.displayIndex == 0 &&
              next.subframe?.displayIndex == 1,
          '$name PB order $i',
        );
        final stamp = packet.timestamp!;
        final duration = stamp.duration! * stamp.numerator / stamp.denominator;
        check(
          (duration - (times[i + 1] - times[i])).abs() < 1e-7,
          '$name B duration $i',
        );
      }
    }
    // Decode a selected P alone, then select the B from the same coded unit.
    for (final i in [7, 6, 2, 1, 4, 3]) {
      final capture = await worker.decode([packets[i]]).single;
      check(getCrc32(capture.frame.getBytes()) == hashes[i], '$name seek $i');
    }
    // The two B pictures start from different intra anchors and may use
    // different worker isolates.
    final parallel = {
      await for (final capture in worker.decode([packets[6], packets[1]]))
        capture.packet: getCrc32(capture.frame.getBytes()),
    };
    check(
      parallel[packets[1]] == hashes[1] && parallel[packets[6]] == hashes[6],
      '$name parallel B captures',
    );
  } finally {
    await worker.close();
    video.close();
  }
}
