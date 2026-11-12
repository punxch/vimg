import 'dart:convert';
import 'dart:io';

import 'package:vimg_dart/src/binary_file.dart';
import 'package:vimg_dart/src/frame_packet.dart';
import 'package:vimg_dart/src/iso_media.dart';

import 'fixtures.dart';

Future<void> main(List<String> arguments) async {
  final temp = Directory.systemTemp.createTempSync('vimg-fragments-');
  try {
    _checkRuns(temp);
    await _checkCapture(temp, arguments.firstOrNull);
  } finally {
    temp.deleteSync(recursive: true);
  }
}

void _checkRuns(Directory temp) {
  final (path, frames) = _fixture(temp);
  _withMedia(path, (media) {
    final seen = <(FramePacket, bool)>[];
    final packets = isoFrames(
      media,
      onSample: (packet, sync) => seen.add((packet, sync)),
    ).toList();
    check(packets.length == 3 && seen.length == 3, 'Read all fragment runs');
    check(
      (media.metadata().duration! - 2.85).abs() < 1e-9,
      'Fragment duration',
    );

    const expectedPts = [250, 500, 2200];
    const expectedTime = [0.25, 0.5, 2.2];
    const expectedDuration = [1000, 1000, 600];
    const expectedSync = [true, false, true];
    for (final (index, packet) in packets.indexed) {
      check(
        packet.timestamp!.pts == expectedPts[index],
        'Raw composition time',
      );
      check(packet.timestamp!.denominator == 1000, 'Video timescale');
      check(
        packet.timestamp!.duration == expectedDuration[index],
        'Sample duration defaults',
      );
      check(
        (packet.seconds - expectedTime[index]).abs() < 1e-9,
        'Edited playback time',
      );
      check(seen[index] == (packet, expectedSync[index]), 'Sample flags');
      final bytes = media.file.read(packet.offset, packet.size);
      _sameBytes(bytes, frames[index], 'Sample data addressing');
    }
    final sync = isoFrames(media, keyframes: true).toList();
    check(sync.length == 2 && sync.last == packets.last, 'Fragment keyframes');
  });

  final (trimmed, _) = _fixture(temp, trimFirst: true);
  _withMedia(trimmed, (media) {
    var count = 0;
    final visible = isoFrames(media, onSample: (_, _) => count++).toList();
    check(count == 3 && visible.length == 2, 'Keep edit preroll for decoding');
    check(
      visible.first.timestamp!.pts == 500,
      'Trim the first presentation sample',
    );
    check(visible.first.seconds == 0.25, 'Retain the leading empty edit');
    check(media.metadata().duration == 3.2, 'Movie extends duration');
  });

  final (unedited, _) = _fixture(temp, applyEdit: false);
  _withMedia(unedited, (media) {
    final first = isoFrames(media).first;
    check(first.timestamp!.pts == 250, 'Composition shift preserves raw PTS');
    check(first.seconds == 0.75, 'Composition shift relative to audio start');
    check(
      (media.metadata().duration! - 3.35).abs() < 1e-9,
      'Composition shift contributes to the movie duration',
    );
  });

  final (invalid, _) = _fixture(temp, badExtent: true);
  _withMedia(invalid, (media) {
    try {
      isoFrames(media).toList();
    } on FormatException catch (error) {
      check(
        error.message == 'Invalid ISO media fragment sample extent',
        'Reject the sample before reading through the end of mdat',
      );
      return;
    }
    throw StateError('Accepted a sample extent outside mdat');
  });
}

(File, List<List<int>>) _fixture(
  Directory temp, {
  bool applyEdit = true,
  bool trimFirst = false,
  bool badExtent = false,
}) {
  // Two tracks and three video runs. The first video track fragment follows
  // the audio data implicitly. The last run uses an absolute base with a
  // negative offset, and continues DTS without a tfdt.
  final frames = [
    // Distinct opaque payloads for exercising sample offsets and lengths.
    for (var i = 0; i < 3; i++) [for (var j = 0; j < i + 5; j++) i * 10 + j],
  ];
  final type = box('ftyp', ascii.encode('isom'));
  final timing = [...List.filled(12, 0), ...uint(1000, 4), ...uint(0, 4)];
  List<int> track(int id, {bool video = false}) => box('trak', [
    ..._full('tkhd', [
      ...List.filled(video ? 16 : 8, 0),
      ...uint(id, 4),
    ], version: video ? 1 : 0),
    if (video && applyEdit)
      ...box(
        'edts',
        _full('elst', [
          ...uint(2, 4),
          ...uint(250, 4),
          ...uint(-1, 4),
          ...uint(0x10000, 4),
          ...uint(0, 4),
          ...uint(trimFirst ? 500 : 250, 4),
          ...uint(0x10000, 4),
        ]),
      ),
    ...box('mdia', [
      ...box('mdhd', timing),
      ..._full('hdlr', [0, 0, 0, 0, ...ascii.encode(video ? 'vide' : 'soun')]),
      ...box(
        'minf',
        box('stbl', [
          ..._full('stsz', List.filled(8, 0)),
          if (video)
            ..._full('stsd', [
              ...uint(1, 4),
              ...box('jpeg', [
                ...List.filled(24, 0),
                ...uint(32, 2),
                ...uint(24, 2),
              ]),
            ]),
        ]),
      ),
    ]),
  ]);
  List<int> defaults(int id, int duration, int size) =>
      _full('trex', _fields([id, 1, duration, size, 0x02000000]));
  final movie = box('moov', [
    ...box('mvhd', timing),
    ...track(4),
    ...track(17, video: true),
    ...box('mvex', [
      ...defaults(4, 1000, 5),
      ...defaults(17, 500, 0),
      if (trimFirst) ..._full('mehd', uint(3200, 8), version: 1),
    ]),
  ]);
  List<int> first(int audioOffset) => box('moof', [
    ..._full('mfhd', uint(1, 4)),
    ...box('traf', [
      ..._full('tfhd', uint(4, 4), flags: 0x020000),
      ..._full('tfdt', uint(0, 4)),
      ..._full('trun', _fields([2, audioOffset]), flags: 1),
    ]),
    ...box('traf', [
      ..._full('tfhd', _fields([17, 1000, 0x01010000]), flags: 0x28),
      ..._full('tfdt', uint(0, 8), version: 1),
      ..._full(
        'trun',
        _fields([1, 0x02000000, frames[0].length, 250]),
        flags: 0xa04,
        version: 1,
      ),
      ..._full(
        'trun',
        _fields([1, frames[1].length, 0x01010000, -500]),
        flags: 0xe00,
        version: 1,
      ),
    ]),
  ]);
  final firstFragment = first(first(0).length + 8);
  final firstData = box('mdat', [
    ...List.filled(10, 0),
    ...frames[0],
    ...frames[1],
  ]);

  List<int> second(int base) => box('moof', [
    ..._full('mfhd', uint(2, 4)),
    ...box('traf', [
      ..._full('tfhd', [
        ...uint(17, 4),
        ...uint(base, 8),
        ..._fields([1, frames[2].length]),
      ], flags: 0x13),
      ..._full(
        'trun',
        _fields([1, -frames[2].length + (badExtent ? 1 : 0), 600, 200]),
        flags: 0x901,
      ),
    ]),
  ]);
  final secondData = box('mdat', frames[2]);
  final size =
      type.length +
      movie.length +
      firstFragment.length +
      firstData.length +
      second(0).length +
      secondData.length;
  final name = switch ((applyEdit, trimFirst, badExtent)) {
    (_, _, true) => 'broken',
    (_, true, _) => 'trimmed',
    (false, _, _) => 'unedited',
    _ => 'edited',
  };
  final file = File('${temp.path}/fragment-$name.mp4')
    ..writeAsBytesSync([
      ...type,
      ...movie,
      ...firstFragment,
      ...firstData,
      ...second(size),
      ...secondData,
    ]);
  return (file, frames);
}

List<int> _fields(List<int> fields) => [
  for (final field in fields) ...uint(field, 4),
];

List<int> _full(
  String type,
  List<int> body, {
  int version = 0,
  int flags = 0,
}) => box(type, [version, ...uint(flags, 3), ...body]);

void _withMedia(File path, void Function(IsoMedia) callback) {
  final file = path.openSync();
  try {
    callback(IsoMedia(BinaryFile(file)));
  } finally {
    file.closeSync();
  }
}

Future<void> _checkCapture(Directory temp, String? executable) async {
  Future<String> run(List<String> args) async {
    final result = await Process.run(
      executable ?? Platform.resolvedExecutable,
      [if (executable == null) 'bin/vimg.dart', ...args],
    );
    check(result.exitCode == 0, '$args: ${result.stderr}');
    return result.stdout as String;
  }

  final probes = <String>[];
  final previews = <File>[];
  final sheets = <File>[];
  final captures = <List<File>>[];
  for (final variant in ['temporal', 'fragmented']) {
    final input = 'test/fixtures/cabac-b-$variant.mp4';
    probes.add(await run(['probe', input]));
    final output = '${temp.path}/$variant';
    final preview = File('$output.jpg');
    final sheet = File('$output.avif');
    await run(['preview', '--skip', '20', '--output', preview.path, input]);
    await run([
      'extract',
      '-n4',
      '-f2',
      '-t500ms',
      '--output-dir',
      output,
      input,
    ]);
    await run([
      'vcs',
      '-c2',
      '-H40',
      '-n4',
      '-f4',
      '-t500ms',
      '-o',
      sheet.path,
      input,
    ]);
    previews.add(preview);
    sheets.add(sheet);
    captures.add(
      Directory(output).listSync().cast<File>().toList()
        ..sort((a, b) => a.path.compareTo(b.path)),
    );
  }

  check(probes[0] == probes[1], 'Probe matches nonfragmented MP4');
  final probe = jsonDecode(probes[1]) as Map;
  check(probe['format']['duration'] == '2.125000', 'Real fragment duration');
  _sameBytes(
    previews[0].readAsBytesSync(),
    previews[1].readAsBytesSync(),
    'JPEG preview',
  );
  _sameBytes(
    sheets[0].readAsBytesSync(),
    sheets[1].readAsBytesSync(),
    'Animated AVIF',
  );
  check(
    captures.every((frames) => frames.length == 8),
    'Real fragment capture count',
  );
  for (var i = 0; i < captures[0].length; i++) {
    _sameBytes(
      captures[0][i].readAsBytesSync(),
      captures[1][i].readAsBytesSync(),
      'BMP capture $i',
    );
  }
}

void _sameBytes(List<int> a, List<int> b, String label) {
  check(a.length == b.length, '$label length');
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) throw StateError('$label differs at byte $i');
  }
}
