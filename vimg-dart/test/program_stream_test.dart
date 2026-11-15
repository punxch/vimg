import 'dart:io';
import 'dart:typed_data';

import 'package:vimg_dart/src/mpeg12/decode.dart';
import 'package:vimg_dart/src/mpeg12/syntax.dart';
import 'package:vimg_dart/src/mpeg_systems.dart';
import 'package:vimg_dart/src/video.dart';

import 'fixtures.dart';
import 'mpeg_checks.dart';

const _mpeg = 'test/fixtures/mpeg1-mp2.mpg';
const _vob = 'test/fixtures/dvd-ac3.vob';
const _sparseVob = 'test/fixtures/mpeg2-sparse-pts.vob';

// FFmpeg -idct simple, cropped Y/Cb/Cr in presentation order. The PS inputs
// use MPEG-1 with MP2, MPEG-2 with DVD navigation and AC-3, and MPEG-2 with
// multiple pictures per PES and sparse timestamps, respectively.
// dart format off
const _legacy = [
  0x8a7e7811, 0x20ebc3d4, 0xc67c1ae7, 0x1836c2e5, 0xadf7d801,
  0xa5a477f3, 0x60a467db, 0xcaa6a831, 0x4eb4149d, 0x1faa5752,
  0xe5105b32, 0xf667b573, 0xd198ff5d, 0x59e8fc05, 0xc422f4c8,
  0xccdebda3, 0x9a430419, 0x846f126a, 0xa367b6dc,
];

const _dvd = [
  0x138ff872, 0x0cd4a238, 0xc794106e, 0xcee8c81d, 0x15fb213f,
  0xb511ba64, 0x74c9c811, 0x046e7207, 0x1fa455d5, 0x55565aa2,
  0x22e6142a, 0xd81e0731, 0xe9699e25, 0x1d12ce5e, 0xe852b445,
  0xf9700aa5, 0xeeae6730, 0x09fb768f, 0xa514f0cd,
];

const _sparse = [
  0x5a292e88, 0x1a67b7b1, 0x1a67b7b1, 0xd001cce2, 0xfd3f3a8d,
  0xfd3f3a8d, 0x0f787fa2, 0x97868698, 0x97868698, 0x76b25875,
  0xbe6aa208, 0xc9412efe, 0xc6f31301, 0x51c7f4ef, 0x51c7f4ef,
  0x3533920a, 0x655e1205, 0x655e1205, 0x2a2efe5e, 0xcb85e211,
  0xcb85e211, 0xf81366d8, 0x83e86dea, 0x97096755, 0x65fa56c9,
  0x6a6da001, 0x563c624d, 0xd1824f5a, 0x874404f6, 0x378f3ed7,
  0xd508ed47, 0x70fe0ba0, 0x8f51018d, 0x657494d9, 0x4c9a1f35,
  0x4c9a1f35, 0xadb5afbc, 0x119432a8,
];
// dart format on

Future<void> main(List<String> arguments) async {
  await _compare(
    _mpeg,
    _legacy,
    codec: 'mpeg1video',
    start: 47618,
    duration: '0.809800',
  );
  await _compare(
    _vob,
    _dvd,
    codec: 'mpeg2video',
    start: 48120,
    duration: '0.800000',
  );
  await _compare(
    _sparseVob,
    _sparse,
    codec: 'mpeg2video',
    start: 48600,
    duration: '1.280000',
  );
  _checkProgramMap();
  final temp = Directory.systemTemp.createTempSync('vimg-program-stream-');
  try {
    final split = _splitFirstHeader(temp);
    await _compare(
      split,
      _sparse,
      codec: 'mpeg2video',
      start: 48600,
      duration: '1.280000',
    );
    _checkElementaryVideo(temp);
    await _checkSparseNalTiming(temp, 'test/fixtures/cabac-b-aac.ts');
    await _checkSparseNalTiming(temp, 'test/fixtures/hevc-open-gop.m2ts');
    _checkTruncatedPes(temp);
    _checkIsoBoxSizes(temp);
    if (arguments.isNotEmpty) await _checkCommands(arguments.single, temp);
  } finally {
    temp.deleteSync(recursive: true);
  }
}

Future<void> _compare(
  String path,
  List<int> reference, {
  required String codec,
  required int start,
  required String duration,
}) async {
  final video = Video(path);
  final workers = VideoCaptureDecoder(video, threads: 2);
  try {
    final metadata = video.metadata;
    check(
      metadata.streams.single.codec == codec,
      'Probe the MPEG video sequence',
    );
    check(
      metadata.duration!.toStringAsFixed(6) == duration,
      'Program stream duration',
    );
    check(
      metadata.streams.single.timeBase == '1/90000',
      'Program stream clock',
    );
    final packets = video.packets().toList();
    check(packets.length == reference.length, 'Index all video pictures');
    final positions = {for (final (i, packet) in packets.indexed) packet: i};
    for (final (i, packet) in packets.indexed) {
      final pts = 48600 + i * 3600;
      check(packet.timestamp!.pts == pts, 'Presentation PTS of frame $i');
      check(packet.timestamp!.duration == 3600, 'Picture duration');
      check(packet.seconds == (pts - start) / 90000, 'Use program start time');
    }

    final systems = MpegSystemsVideo.detect(video.file)!;
    final decoder = MpegStreamDecoder();
    final rgb = <int, Uint8List>{};
    for (final packet in systems.packets(false)) {
      final picture = decoder.decode(systems.read(packet));
      final i = positions[packet]!;
      check(mpegYuvHash(picture) == reference[i], '$path YUV of frame $i');
      rgb[i] = picture.rgb().getBytes();
    }

    final keys = video.packets(preview: true).toList();
    check(keys.length >= 3, 'Find I-pictures across program packs');
    _equal(
      video.decode(keys.last, preview: true).getBytes(),
      rgb[positions[keys.last]!]!,
    );
    final targets = [packets.first, packets[7], packets.last];
    final received = <int>{};
    await for (final result in workers.decode(targets)) {
      final i = positions[result.packet]!;
      _equal(result.frame.getBytes(), rgb[i]!);
      received.add(i);
    }
    check(
      received.length == targets.length,
      'Decode all selected pictures in separate GOPs',
    );
  } finally {
    await workers.close();
    video.close();
  }
}

void _checkProgramMap() {
  // HEVC Annex B remux with a program stream map entry (stream type 0x24).
  final video = Video('test/fixtures/hevc-main10-psm.vob');
  final original = Video('test/fixtures/hevc-main10.mp4');
  try {
    check(video.codec == 'hevc', 'Read the program stream map');
    check(video.metadata.duration == 1.375, 'HEVC program duration');
    final packets = video.packets().toList();
    final samples = original.packets().toList();
    check(
      packets.length == samples.length && packets.length == 12,
      'HEVC frames',
    );
    for (final (i, packet) in packets.indexed) {
      check(
        packet.timestamp!.pts == 45000 + i * 11250,
        'HEVC presentation PTS',
      );
    }
    final source = {
      for (final frame in original.decodeSelected(samples))
        samples.indexOf(frame.packet): frame.frame.getBytes(),
    };
    for (final frame in video.decodeSelected(packets)) {
      _equal(frame.frame.getBytes(), source[packets.indexOf(frame.packet)]!);
    }
  } finally {
    video.close();
    original.close();
  }
}

Future<void> _checkSparseNalTiming(Directory temp, String input) async {
  final original = Video(input);
  try {
    final systems = MpegSystemsVideo.detect(original.file)!;
    final physical = systems.packets(false).toList();
    final display = original.packets().toList();
    final firstPts = display.first.timestamp!.pts;
    final decoded = {
      for (final frame in original.decodeSelected(display))
        frame.packet.timestamp!.pts - firstPts: frame.frame.getBytes(),
    };
    final hevc = original.codec == 'hevc';
    for (final flags in [0xc0, 0x80, 0]) {
      final output = File('${temp.path}/${original.codec}-$flags.vob');
      final bytes = BytesBuilder(copy: false)
        // MPEG-2 pack and program stream map with a single video stream.
        ..add([
          0,
          0,
          1,
          0xba,
          0x44,
          0,
          4,
          0,
          4,
          1,
          0,
          4,
          0x53,
          0xf8,
          0,
          0,
          1,
          0xbc,
          0,
          14,
          0xe0,
          0xff,
          0,
          0,
          0,
          4,
          hevc ? 0x24 : 0x1b,
          0xe0,
          0,
          0,
          ...uint(hevc ? 0x0c49b076 : 0xf4dcbd45, 4),
        ]);
      final base = flags == 0 ? 0 : 45000;
      final known = <int>[];
      for (final (i, frame) in physical.indexed) {
        final data = systems.read(frame);
        final view = ByteData.sublistView(data);
        for (var offset = 0; offset < data.length;) {
          final size = view.getUint32(offset);
          view.setUint32(offset, 1);
          offset += size + 4;
        }
        final pts = frame.timestamp!.pts - firstPts + base;
        final timestamp = <int>[
          if (flags != 0 && i % 3 == 1) ...[
            ..._pesTimestamp(pts, flags >> 6),
            if (flags == 0xc0) ..._pesTimestamp(base + (i - 2) * 11250, 1),
          ],
        ];
        if (timestamp.isNotEmpty) known.add(pts);
        bytes.add([
          0,
          0,
          1,
          0xe0,
          ...uint(data.length + timestamp.length + 3, 2),
          0x80,
          timestamp.isEmpty ? 0 : flags,
          timestamp.length,
          ...timestamp,
        ]);
        bytes.add(data);
      }
      output.writeAsBytesSync(bytes.takeBytes());

      final video = Video(output.path);
      final workers = VideoCaptureDecoder(video, threads: 2);
      try {
        final packets = video.packets().toList();
        check(video.codec == original.codec, 'Sparse program codec');
        check(packets.length == display.length, 'Sparse program frame count');
        known.sort();
        final lastPts = known.lastOrNull ?? packets.last.timestamp!.pts;
        check(
          video.metadata.duration == (lastPts - base + 11250) / 90000,
          'Program duration uses signalled PTS when present',
        );
        for (final (i, packet) in packets.indexed) {
          final ticks = display[i].timestamp!.pts - firstPts;
          check(packet.timestamp!.pts == ticks + base, 'Restored PTS $i');
          check(packet.seconds == ticks / 90000, 'Sparse presentation time $i');
          check(packet.timestamp!.duration == 11250, 'NAL picture duration');
        }
        final keys = video.packets(preview: true).toList();
        final key = keys.last;
        _equal(
          video.decode(key, preview: true).getBytes(),
          decoded[key.timestamp!.pts - base]!,
        );
        final targets = [
          packets.first,
          packets[packets.length ~/ 2],
          packets.last,
        ];
        var count = 0;
        await for (final frame in workers.decode(targets)) {
          _equal(
            frame.frame.getBytes(),
            decoded[frame.packet.timestamp!.pts - base]!,
          );
          count++;
        }
        check(count == targets.length, 'Sparse program captures');
      } finally {
        await workers.close();
        video.close();
      }
    }
  } finally {
    original.close();
  }
}

List<int> _pesTimestamp(int pts, int prefix) => [
  (prefix << 4) | ((pts >> 29) & 0x0e) | 1,
  (pts >> 22) & 0xff,
  ((pts >> 14) & 0xfe) | 1,
  (pts >> 7) & 0xff,
  ((pts << 1) & 0xfe) | 1,
];

String _splitFirstHeader(Directory temp) {
  final source = File(_sparseVob).readAsBytesSync();
  final units = mpegStartCodes(source).toList();
  final pes = units.firstWhere((unit) => unit.code == 0xe0);
  final sequence = units.firstWhere((unit) => unit.code == 0xb3);
  final picture = units.firstWhere((unit) => unit.code == 0);
  // Leave the PES timestamp on the picture when its sequence and GOP
  // headers move into a preceding untimed PES.
  final prefixLength = picture.start - sequence.start;
  final view = ByteData.sublistView(source);
  view.setUint16(pes.data, view.getUint16(pes.data) - prefixLength);
  final output = File('${temp.path}/split.vob')
    ..writeAsBytesSync([
      ...source.sublist(0, pes.start),
      0,
      0,
      1,
      0xe0,
      ...uint(prefixLength + 3, 2),
      0x80,
      0,
      0,
      ...source.sublist(sequence.start, picture.start),
      ...source.sublist(pes.start, sequence.start),
      ...source.sublist(picture.start),
    ]);
  return output.path;
}

void _checkElementaryVideo(Directory temp) {
  final source = Video(_sparseVob);
  final bytes = BytesBuilder(copy: false);
  try {
    final systems = MpegSystemsVideo.detect(source.file)!;
    for (final packet in systems.packets(false)) {
      bytes.add(systems.read(packet));
    }
  } finally {
    source.close();
  }
  final stream = bytes.takeBytes();
  final coding = mpegStartCodes(
    stream,
  ).firstWhere((unit) => unit.code == 0xb5 && stream[unit.data] >> 4 == 8);
  stream[coding.data + 3] = (stream[coding.data + 3] & 0x7f) | 2;
  final output = File('${temp.path}/repeat.m2v')..writeAsBytesSync(stream);
  final video = Video(output.path);
  try {
    final packets = video.packets().toList();
    check(packets.length == _sparse.length, 'Read standalone MPEG pictures');
    check(
      packets.first.timestamp!.pts == 0,
      'Begin the elementary clock at zero',
    );
    check(packets.first.timestamp!.duration == 7200, 'Repeated frame duration');
    check(
      packets[1].timestamp!.pts == 7200,
      'Advance by the repeated frame duration',
    );
    check(
      video.metadata.duration == 1.56,
      'Count the repeated fields in the duration',
    );
    check(
      video.decode(packets.last).width == 64,
      'Seek in an elementary stream',
    );
  } finally {
    video.close();
  }
}

void _checkTruncatedPes(Directory temp) {
  final bytes = File(_sparseVob).readAsBytesSync();
  final first = mpegStartCodes(bytes).firstWhere((unit) => unit.code == 0xe0);
  ByteData.sublistView(bytes).setUint16(first.data, 0xffff);
  final path = File('${temp.path}/truncated.vob')..writeAsBytesSync(bytes);
  final video = Video(path.path);
  try {
    video.metadata;
    throw StateError('Accepted a PES packet extending beyond EOF');
  } on FormatException catch (error) {
    check(
      error.message.contains('Truncated MPEG program packet'),
      'Reject a truncated PES',
    );
  } finally {
    video.close();
  }
}

void _checkIsoBoxSizes(Directory temp) {
  final source = File('test/fixtures/cabac-b-temporal.mp4').readAsBytesSync();
  // An ISO box size can share the four bytes of an MPEG start code.
  for (final size in [0x1b3, 0x1ba]) {
    final file = File('${temp.path}/$size.mp4')
      ..writeAsBytesSync([...box('free', Uint8List(size - 8)), ...source]);
    final video = Video(file.path);
    try {
      check(
        video.codec == 'h264',
        'Probe an ISO file with an MPEG-like box size',
      );
    } finally {
      video.close();
    }
  }
}

Future<void> _checkCommands(String executable, Directory temp) async {
  final preview = '${temp.path}/preview.jpg';
  final captures = '${temp.path}/captures';
  final sheet = '${temp.path}/sheet.avif';
  for (final arguments in [
    ['preview', '--output', preview, _vob],
    ['extract', '-n3', '-T2', '--output-dir', captures, _mpeg],
    ['vcs', '-c2', '-H48', '-n3', '-f3', '-T2', '-o', sheet, _sparseVob],
  ]) {
    final result = await Process.run(executable, arguments);
    check(result.exitCode == 0, '${arguments.first}: ${result.stderr}');
  }
  check(File(preview).lengthSync() > 0, 'DVD JPEG preview');
  check(Directory(captures).listSync().length == 3, 'MPEG BMP captures');
  check(File(sheet).lengthSync() > 0, 'VOB animated AVIF');
}

void _equal(Uint8List pixels, Uint8List reference) {
  check(pixels.length == reference.length, 'RGB frame length');
  for (var i = 0; i < pixels.length; i++) {
    if (pixels[i] != reference[i]) throw StateError('RGB differs at byte $i');
  }
}
