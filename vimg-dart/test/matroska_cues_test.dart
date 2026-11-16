import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:image/image.dart' as image;
import 'package:vimg_dart/src/binary_file.dart';
import 'package:vimg_dart/src/iso_media.dart';
import 'package:vimg_dart/src/video.dart';
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
  } finally {
    temp.deleteSync(recursive: true);
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
}) {
  const times = [0, 1000, 1500, 2000];
  final duration = ByteData(8)..setFloat64(0, 4000);
  final segment = <int>[
    ...ebml(
      [0x15, 0x49, 0xa9, 0x66],
      [
        ...ebml([0x2a, 0xd7, 0xb1], uint(2000000, 4)),
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
  for (final (index, sample) in samples.indexed) {
    final timestamp = ebml([0xe7], uint(times[index], 2));
    final audio = ebml([0xa3], [0x82, 0, 0, 0x80, 0]);
    final state = index == 1 && codecState != null
        ? ebml([0xa4], codecState)
        : null;
    final block = state == null
        ? ebml([0xa3], [0x81, 0, 0, 0x80, ...sample])
        : ebml(
            [0xa0],
            [
              ...ebml([0xa1], [0x81, 0, 0, 0, ...sample]),
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
          ...ebml([0xb3], uint(times[index], 2)),
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
