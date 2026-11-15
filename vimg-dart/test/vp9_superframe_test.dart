import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:image/image.dart' as image;
import 'package:vimg_dart/src/frame_packet.dart';
import 'package:vimg_dart/src/matroska.dart';
import 'package:vimg_dart/src/video.dart';
import 'package:vimg_dart/src/vp9/decoder.dart';
import 'package:vimg_dart/src/yuv_image.dart';

import 'fixtures.dart';

const _ivf = 'test/fixtures/vp9-multiple-display.ivf';
const _mkv = 'test/fixtures/vp9-multiple-display-alpha.mkv';
const _ordinary = 'test/fixtures/vp9-alpha-staggered.webm';
const _ivfTicks = [
  0,
  3,
  6,
  10,
  14,
  18,
  22,
  26,
  30,
  34,
  38,
  42,
  46,
  50,
  54,
  58,
  62,
  66,
];
const _sourcePts = [0, 0, 1, 1, 1, 3, 3, 3, 5, 5, 5, 7, 7, 7, 9, 9, 9, 11];

Future<void> main(List<String> arguments) async {
  final ivfFrames = await _checkIvf();
  await _checkMatroska();
  if (arguments.firstOrNull case final cli?) await _checkCli(cli, ivfFrames);
}

Future<List<int>> _checkIvf() async {
  final video = Video(_ivf);
  try {
    final packets = video.packets().toList();
    check(
      packets.length == 18,
      'VP9 seven IVF samples display eighteen frames',
    );
    check(
      video.filterTiming.timeBase == (numerator: 1, denominator: 72),
      'VP9 capture clock represents halves and thirds',
    );
    check(
      video.metadata.duration == 13 / 12,
      'VP9 IVF total duration unchanged',
    );
    for (final (i, packet) in packets.indexed) {
      final timestamp = packet.timestamp!;
      check(
        timestamp.pts * timestamp.numerator * 72 ==
            _ivfTicks[i] * timestamp.denominator,
        'VP9 exact fractional time for display frame $i',
      );
      check(
        (packet.seconds - _ivfTicks[i] / 72).abs() < 1e-12,
        'VP9 playback time for frame $i',
      );
      check(
        packet.sourceTimestamp?.pts == _sourcePts[i] &&
            packet.sourceTimestamp?.denominator == 12,
        'VP9 source sample time for frame $i',
      );
    }

    // Decode the original physical samples in sequence and compare to libvpx
    // after FFmpeg's superframe split, then compare the capture entry point.
    final decoder = Vp9Decoder();
    final parentPackets = <int, FramePacket>{
      for (final packet in packets) packet.offset: packet,
    };
    final decoded = [
      for (final packet in parentPackets.values)
        ...decoder.decodePacket(video.file.read(packet.offset, packet.size)),
    ];
    check(decoded.length == packets.length, 'VP9 all decoder outputs retained');
    final crc = [0, 0, 0];
    for (final picture in decoded) {
      for (final (plane, data) in [picture.y, picture.u, picture.v].indexed) {
        final width = plane == 0 ? 176 : 88, height = plane == 0 ? 112 : 56;
        final row = Uint8List(width);
        for (var y = 0; y < height; y++) {
          row.setRange(0, width, data.samples, y * data.stride);
          crc[plane] = getCrc32(row, crc[plane]);
        }
      }
    }
    check(
      crc[0] == 0xac44b4bd && crc[1] == 0x698c0f33 && crc[2] == 0xa084e7fb,
      'VP9 split frames match libvpx planes',
    );
    final rgb = [
      for (final picture in decoded) getCrc32(picture.rgb().getBytes()),
    ];
    final previews = video.packets(preview: true).toList();
    check(
      previews.length == 2 &&
          previews[0] == packets[0] &&
          previews[1] == packets[15],
      'VP9 previews select the hidden key display and the mid-sample key',
    );
    for (final (i, packet) in previews.indexed) {
      check(
        getCrc32(video.decode(packet, preview: true).getBytes()) ==
            rgb[i == 0 ? 0 : 15],
        'VP9 keyframe preview pixels in a multi-picture sample',
      );
    }
    check(
      getCrc32(video.decode(packets[16]).getBytes()) == rgb[16],
      'VP9 seek starts at the keyframe inside the sample',
    );
    await _checkWorkers(video, packets, rgb, [16, 15, 14, 4, 3, 1, 0]);
    return rgb;
  } finally {
    video.close();
  }
}

Future<void> _checkMatroska() async {
  final reference = Video(_ordinary);
  final video = Video(_mkv);
  try {
    check(
      Matroska(video.file).hasEncodedFrames,
      'VP9 Matroska zlib sample fixture',
    );
    final ordinary = reference.decodeSelected(reference.packets()).toList();
    final packets = video.packets().toList();
    check(
      packets.length == 11 && packets.length == ordinary.length,
      'VP9 packed Matroska alpha and color frame count',
    );
    final rgb = [
      for (final frame in ordinary) getCrc32(frame.frame.getBytes()),
    ];
    final packed = video.decodeSelected(packets).toList();
    check(packed.length == rgb.length, 'VP9 packed Matroska display count');
    for (final (i, frame) in packed.indexed) {
      check(
        (frame.packet.seconds - i * 0.2).abs() < 1e-9,
        'VP9 Matroska frame interval $i',
      );
      check(
        frame.frame.hasAlpha && getCrc32(frame.frame.getBytes()) == rgb[i],
        'VP9 compressed Matroska color and opacity association $i',
      );
    }
    check(
      packets[6].timestamp?.pts == 1200 &&
          packets[6].sourceTimestamp?.pts == 1000,
      'VP9 missing BlockDuration inferred from next block',
    );
    await _checkWorkers(video, packets, rgb, [
      10,
      9,
      8,
      7,
      6,
      5,
      3,
      2,
    ], alpha: true);
  } finally {
    reference.close();
    video.close();
  }
}

Future<void> _checkWorkers(
  Video video,
  List<FramePacket> packets,
  List<int> crc,
  List<int> targets, {
  bool alpha = false,
}) async {
  final worker = VideoCaptureDecoder(
    video,
    threads: 2,
    scaler: YuvImageScaler(height: 29),
    includeOriginal: true,
  );
  final remaining = {for (final i in targets) packets[i]: crc[i]};
  try {
    await for (final result in worker.decode([
      for (final i in targets) packets[i],
    ])) {
      final expected = remaining.remove(result.packet);
      check(
        expected != null && getCrc32(result.original!.getBytes()) == expected,
        'VP9 worker returns the selected original picture',
      );
      check(
        result.frame.height == 29 && result.frame.hasAlpha == alpha,
        'VP9 worker scales each picture independently',
      );
    }
    check(remaining.isEmpty, 'VP9 worker retains all requested pictures');
  } finally {
    await worker.close();
  }
}

Future<void> _checkCli(String cli, List<int> ivfFrames) async {
  final directory = Directory.systemTemp.createTempSync('vimg-vp9-superframe-');
  Future<void> run(List<String> args) async {
    final result = await Process.run(cli, args);
    check(result.exitCode == 0, '$args failed: ${result.stderr}');
  }

  try {
    final frames = Directory('${directory.path}/frames');
    await run([
      'extract',
      '-n4',
      '-t200ms',
      '-T2',
      '--vfilter',
      'fps=18',
      '--output-dir',
      frames.path,
      _ivf,
    ]);
    final bmp = frames.listSync().whereType<File>().toList();
    check(bmp.length == 4, 'VP9 filtered extraction writes four captures');
    final hashes = {
      for (final file in bmp)
        getCrc32(image.decodeBmp(file.readAsBytesSync())!.getBytes()),
    };
    check(
      hashes.length == 4 && ivfFrames.toSet().containsAll(hashes),
      'VP9 filtered BMPs contain distinct source pictures',
    );

    final sheet = '${directory.path}/sheet.avif';
    final manifest = '${directory.path}/sheet.json';
    await run([
      'authority',
      'record',
      '-c3',
      '-H160',
      '-n9',
      '--output',
      sheet,
      '--manifest',
      manifest,
      _ivf,
    ]);
    final json =
        jsonDecode(File(manifest).readAsStringSync()) as Map<String, dynamic>;
    final selected = json['selected_frames'] as List;
    final frameIndices = <int>{};
    for (final item in selected) {
      final index = item['input_frame_index'] as int;
      frameIndices.add(index);
      check(
        item['source_pts'] == _sourcePts[index] &&
            item['source_time_base'] == '1/12',
        'VP9 authority stores original sample PTS for frame $index',
      );
    }
    check(
      frameIndices.containsAll([14, 15, 16]),
      'VP9 authority preserves distinct frame indices within one sample',
    );
  } finally {
    directory.deleteSync(recursive: true);
  }
}
