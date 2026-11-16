import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as image;
import 'package:vimg_dart/src/binary_file.dart';
import 'package:vimg_dart/src/capture.dart';
import 'package:vimg_dart/src/iso_media.dart';
import 'package:vimg_dart/src/matroska.dart';
import 'package:vimg_dart/src/matroska_frames.dart';
import 'package:vimg_dart/src/video.dart';
import 'package:vimg_dart/src/video_commands.dart';
import 'package:vimg_dart/src/video_configuration.dart';

import 'fixtures.dart';

Future<void> main(List<String> arguments) async {
  final temp = Directory.systemTemp.createTempSync('vimg-matroska-cues-');
  try {
    Future<({String jpeg, List<Object?> stages})> preview(File input) async {
      final output = File('${temp.path}/preview.jpg');
      final result = await Process.run(
        arguments.firstOrNull ?? Platform.resolvedExecutable,
        [
          if (arguments.isEmpty) 'bin/vimg.dart',
          'preview',
          '--output',
          output.path,
          '--skip',
          '45',
          '--timings',
          input.path,
        ],
      );
      check(result.exitCode == 0, 'Preview failed: ${result.stderr}');
      final meta = jsonDecode(result.stdout as String) as Map;
      check(meta['preview_written'] == true, 'Preview response $meta');
      final line = result.stderr as String;
      const prefix = 'vimg-preview-timing ';
      check(line.startsWith(prefix), 'Preview timing output');
      final trace = jsonDecode(line.substring(prefix.length)) as Map;
      return (
        jpeg: base64Encode(output.readAsBytesSync()),
        stages: [
          for (final stage in trace['stages_ms'] as List) (stage as List).first,
        ],
      );
    }

    final images = [for (var i = 0; i < 4; i++) image.encodeJpg(solidFrame(i))];
    final mjpeg = _movie(temp, 'mjpeg', 'V_MJPEG', images, cueSamples: [0, 1]);
    final plain = _movie(temp, 'plain', 'V_MJPEG', images);
    final linear = await preview(plain);
    final indexed = await preview(mjpeg);
    check(
      indexed.stages.contains('cue_index') &&
          !indexed.stages.contains('cue_fallback') &&
          indexed.jpeg == linear.jpeg,
      'Sparse video cues choose the same JPEG as the sequential scan',
    );

    final malformed = _movie(
      temp,
      'malformed',
      'V_MJPEG',
      images,
      cueSamples: [0, 1],
      badRelativePosition: true,
    );
    final fallback = await preview(malformed);
    check(
      fallback.stages.contains('cue_fallback') &&
          fallback.stages.contains('seek') &&
          fallback.jpeg == linear.jpeg,
      'Cue that points to another track falls back to the same JPEG',
    );

    final damaged = _movie(
      temp,
      'damaged',
      'V_MJPEG',
      [
        ...images.take(3),
        [0],
      ],
      cueSamples: [0, 1],
    );
    final retry = await preview(damaged);
    final before = image.decodeJpg(base64Decode(retry.jpeg))!.getPixel(0, 0);
    check(
      retry.stages.contains('cue_index') &&
          !retry.stages.contains('cue_fallback') &&
          retry.stages.contains('decode_retry') &&
          before.b > 200,
      'Failed target retries the uncued frame immediately preceding it',
    );

    final avc1 = _keyframe('test/fixtures/cabac-idr.mp4', 'h264');
    final avc2 = _keyframe('test/fixtures/cavlc-baseline.mp4', 'h264');
    final samples = [avc1.packet, avc2.packet, avc2.packet, avc2.packet];
    final avc = _movie(
      temp,
      'avc-state',
      'V_MPEG4/ISO/AVC',
      samples,
      codecPrivate: avc1.configuration,
      codecState: avc2.configuration,
      cueSamples: [0, 1, 2],
    );
    final avcWithoutCues = _movie(
      temp,
      'avc-state-linear',
      'V_MPEG4/ISO/AVC',
      samples,
      codecPrivate: avc1.configuration,
      codecState: avc2.configuration,
    );
    final state = await preview(avc);
    final stateLinear = await preview(avcWithoutCues);
    final picture = image.decodeJpg(base64Decode(state.jpeg))!;
    check(
      state.stages.contains('cue_index') &&
          !state.stages.contains('cue_fallback') &&
          state.jpeg == stateLinear.jpeg &&
          (picture.width, picture.height) == avc2.size,
      'CueCodecState restores an earlier BlockGroup configuration',
    );
    final stateVideo = Video(avc.path);
    try {
      final packets = stateVideo.packets().toList();
      final sizes = stateVideo
          .decodeSelected([packets.first, packets.last])
          .map((c) => (c.frame.width, c.frame.height))
          .toList();
      check(
        sizes.length == 2 &&
            sizes.first == avc1.size &&
            sizes.last == avc2.size,
        'Capture restores CodecState on each side of the update',
      );
    } finally {
      stateVideo.close();
    }
    _checkCaptureSelection(avc, const CaptureOptions(number: 1, frames: 3), 4);
    final brokenTail = _movie(
      temp,
      'avc-broken-tail',
      'V_MPEG4/ISO/AVC',
      [
        ...samples.take(3),
        [0],
      ],
      codecPrivate: avc1.configuration,
      codecState: avc2.configuration,
      cueSamples: [0, 1, 2],
    );
    const beforeTail = CaptureOptions(
      number: 1,
      frames: 3,
      end: VideoOffset(4),
      window: 0.35,
    );
    final goodOutput = Directory('${temp.path}/capture-reference');
    final indexedOutput = Directory('${temp.path}/capture-bounded');
    await extractFrames(avcWithoutCues.path, goodOutput.path, beforeTail);
    await extractFrames(brokenTail.path, indexedOutput.path, beforeTail);
    List<String> bmps(Directory dir) => [
      for (final file in dir.listSync().whereType<File>())
        base64Encode(file.readAsBytesSync()),
    ]..sort();
    check(
      bmps(indexedOutput).length == 3 &&
          bmps(indexedOutput).join() == bmps(goodOutput).join(),
      'Extract uses the same frames without parsing a later damaged cluster',
    );

    final hevc = _keyframe('test/fixtures/hevc-main10.mp4', 'hevc');
    final hevcSamples = List.filled(4, hevc.packet);
    final hevcWithCues = _movie(
      temp,
      'hevc',
      'V_MPEGH/ISO/HEVC',
      hevcSamples,
      codecPrivate: hevc.configuration,
      cueSamples: [0, 1],
    );
    final hevcWithoutCues = _movie(
      temp,
      'hevc-linear',
      'V_MPEGH/ISO/HEVC',
      hevcSamples,
      codecPrivate: hevc.configuration,
    );
    final hevcIndexed = await preview(hevcWithCues);
    final hevcLinear = await preview(hevcWithoutCues);
    check(
      hevcIndexed.stages.contains('cue_index') &&
          !hevcIndexed.stages.contains('cue_fallback') &&
          hevcIndexed.jpeg == hevcLinear.jpeg,
      'HEVC cues preserve the decoded preview',
    );
    final openGop = _openGopMovie(temp);
    _checkCaptureSelection(
      openGop,
      const CaptureOptions(
        number: 1,
        frames: 3,
        end: VideoOffset(4.25),
        window: 0.375,
      ),
      3.875, // RASL picture decoded after the next random-access point.
    );
  } finally {
    temp.deleteSync(recursive: true);
  }
}

void _checkCaptureSelection(
  File file,
  CaptureOptions options,
  double firstTime,
) {
  final video = Video(file.path);
  final linear = Video(file.path);
  try {
    final plan = CapturePlan(video.metadata.duration, options);
    final selected = video.indexedCaptures(plan);
    check(selected != null, 'Use the bounded coded-video index');
    final expected = plan.selectFrames(linear.packets());
    check(
      selected!.single.first.packet.seconds == firstTime &&
          selected.single.length == expected.single.length &&
          selected.single.indexed.every(
            (item) => item.$2 == expected.single[item.$1],
          ),
      'Cues preserve the source packets selected by the CFR schedule',
    );
    final packets = selected.single.map((capture) => capture.packet).toSet();
    final frames = {
      for (final result in video.decodeSelected(packets))
        result.packet: base64Encode(result.frame.getBytes()),
    };
    check(frames.length == packets.length, 'Decode all indexed captures');
    for (final result in linear.decodeSelected(packets)) {
      check(
        frames[result.packet] == base64Encode(result.frame.getBytes()),
        'Indexed capture preserves decoded pixels around a GOP boundary',
      );
    }
  } finally {
    linear.close();
    video.close();
  }
}

File _openGopMovie(Directory directory) {
  final file = File('test/fixtures/hevc-main.mkv').openSync();
  try {
    final media = Matroska(BinaryFile(file));
    final units = <({List<int> data, double seconds, bool sync})>[];
    for (final _ in matroskaFrames(
      media,
      onSample: (packet, sync) {
        units.add((
          data: media.readFrame(packet),
          seconds: packet.seconds,
          sync: sync,
        ));
      },
    )) {}
    final samples = <List<int>>[];
    final ticks = <int>[], cues = <int>[];
    for (var repeat = 0; repeat < 4; repeat++) {
      for (final unit in units) {
        if (unit.sync) cues.add(samples.length);
        samples.add(unit.data);
        ticks.add(((repeat * 3 + unit.seconds) * _ticksPerSecond).round());
      }
    }
    return _movie(
      directory,
      'hevc-open-gop',
      'V_MPEGH/ISO/HEVC',
      samples,
      codecPrivate: media.codecPrivate(media.firstVideoTrack!),
      cueSamples: cues,
      syncSamples: cues.toSet(),
      presentationTicks: ticks,
      durationSeconds: 12,
    );
  } finally {
    file.closeSync();
  }
}

({Uint8List packet, Uint8List configuration, (int, int) size}) _keyframe(
  String path,
  String codec,
) {
  final video = Video(path);
  final file = File(path).openSync();
  try {
    final packet = video.packets(preview: true).first;
    final picture = video.decode(packet, preview: true);
    final iso = IsoMedia(BinaryFile(file));
    return (
      packet: video.file.read(packet.offset, packet.size),
      configuration: isoVideoConfiguration(iso, codec)!,
      size: (picture.width, picture.height),
    );
  } finally {
    file.closeSync();
    video.close();
  }
}

File _movie(
  Directory directory,
  String name,
  String codec,
  List<List<int>> samples, {
  Uint8List? codecPrivate,
  Uint8List? codecState,
  List<int> cueSamples = const [],
  bool badRelativePosition = false,
  List<int>? presentationTicks,
  Set<int>? syncSamples,
  int durationSeconds = 8,
}) {
  final times =
      presentationTicks ??
      [0, 2 * _ticksPerSecond, 3 * _ticksPerSecond, 4 * _ticksPerSecond];
  final duration = ByteData(8)
    ..setFloat64(0, (durationSeconds * _ticksPerSecond).toDouble());
  final segment = <int>[
    ...ebml(
      [0x15, 0x49, 0xa9, 0x66],
      [
        ...ebml([0x2a, 0xd7, 0xb1], uint(1000000000 ~/ _ticksPerSecond, 4)),
        ...ebml([0x44, 0x89], duration.buffer.asUint8List()),
      ],
    ),
    ...ebml(
      [0x16, 0x54, 0xae, 0x6b],
      [
        ...ebml(
          [0xae],
          [
            ...ebml([0xd7], [1]),
            ...ebml([0x83], [1]),
            ...ebml([0x9c], [0]),
            ...ebml([0x86], ascii.encode(codec)),
            ...ebml(
              [0xe0],
              [
                ...ebml([0xb0], [32]),
                ...ebml([0xba], [24]),
              ],
            ),
            if (codecPrivate != null) ...ebml([0x63, 0xa2], codecPrivate),
          ],
        ),
      ],
    ),
  ];
  final points = <int>[];
  int? stateOffset;
  var clusterTime = 0;
  for (final (index, sample) in samples.indexed) {
    final time = times[index];
    clusterTime = math.max(clusterTime, time);
    check(time - clusterTime >= -32768, 'Test block timestamp range');
    final timestamp = ebml([0xe7], uint(clusterTime, 4));
    final blockTime = uint((time - clusterTime) & 0xffff, 2);
    final sync = syncSamples?.contains(index) ?? true;
    final audio = ebml([0xa3], [0x82, 0, 0, 0x80, 0]);
    final state = index == 1 && codecState != null
        ? ebml([0xa4], codecState)
        : null;
    final block = state == null
        ? ebml([0xa3], [0x81, ...blockTime, sync ? 0x80 : 0, ...sample])
        : ebml(
            [0xa0],
            [
              ...ebml([0xa1], [0x81, ...blockTime, 0, ...sample]),
              ...state,
            ],
          );
    final offset = segment.length;
    segment.addAll(
      ebml([0x1f, 0x43, 0xb6, 0x75], [...timestamp, ...audio, ...block]),
    );
    if (state != null) stateOffset = segment.length - state.length;
    if (!cueSamples.contains(index)) continue;
    points.addAll(
      ebml(
        [0xbb],
        [
          ...ebml([0xb3], uint(time, 4)),
          ...ebml(
            [0xb7],
            [
              ...ebml([0xf7], [2]),
              ...ebml([0xf1], uint(offset, 4)),
              ...ebml([0xf0], uint(timestamp.length, 2)),
            ],
          ),
          ...ebml(
            [0xb7],
            [
              ...ebml([0xf7], [1]),
              ...ebml([0xf1], uint(offset, 4)),
              ...ebml(
                [0xf0],
                uint(
                  timestamp.length + (badRelativePosition ? 0 : audio.length),
                  2,
                ),
              ),
              if (!badRelativePosition) ...ebml([0x53, 0x78], [2]),
              if (stateOffset != null) ...ebml([0xea], uint(stateOffset, 4)),
            ],
          ),
        ],
      ),
    );
  }
  if (points.isNotEmpty) {
    segment.addAll(ebml([0x1c, 0x53, 0xbb, 0x6b], points));
  }
  return File('${directory.path}/$name.mkv')..writeAsBytesSync([
    ...ebml([
      0x1a,
      0x45,
      0xdf,
      0xa3,
    ], ebml([0x42, 0x82], ascii.encode('matroska'))),
    ...ebml([0x18, 0x53, 0x80, 0x67], segment),
  ]);
}

const _ticksPerSecond = 40000;
