import 'dart:io';

import 'package:vimg_dart/src/matroska.dart';
import 'package:vimg_dart/src/matroska_frames.dart';
import 'package:vimg_dart/src/mpeg12/decode.dart';
import 'package:vimg_dart/src/mpeg_systems.dart';
import 'package:vimg_dart/src/video.dart';
import 'package:vimg_dart/src/video_configuration.dart';

import 'fixtures.dart';

// testsrc2 at 25 fps, -g 7 or 8 -bf 2 -q:v 4. Checksums are from
// FFmpeg -idct simple, over cropped Y, Cb and Cr in presentation order.
const _progressive = [
  0x20af853d,
  0x68bf0b90,
  0x308ec579,
  0xa2b854d0,
  0xc0ce4f3f,
  0x1febcf6b,
  0xd76d4851,
  0x45339754,
  0xf6fcce78,
  0x76ef779b,
  0x63c6e022,
  0x770b35d5,
  0x8089daed,
  0x6227ba9f,
  0x79f17bb7,
  0x03c656fd,
  0xe05f6093,
  0xa3ec211d,
  0x1b227712,
];

// Interlaced frame pictures with alternate scan, intra VLC and non-linear
// quantization. The coded height rounds to 128 lines for 112 visible lines.
const _interlaced = [
  0xa494129d,
  0x4521a650,
  0xf099a0bf,
  0x81571d03,
  0x52c2a944,
  0x56ccb225,
  0x0a132fc2,
  0xee1c2c5f,
  0x3c8b5a4c,
  0x464b1eb8,
  0xd6260c48,
  0x57104370,
  0x618124de,
  0xbb2585c2,
];

const _chroma422 = [
  0xf423f9cb,
  0xacfca63d,
  0xabf4005e,
  0xb3dec865,
  0x30fcadc7,
  0x3184723e,
  0x9170fe35,
  0x6eac1be6,
  0x2c7cbdcb,
  0x1af5d650,
  0x5a4e4a7c,
  0x7a379ec7,
];

const _legacy = [
  0x8a7e7811,
  0x20ebc3d4,
  0xc67c1ae7,
  0x1836c2e5,
  0xadf7d801,
  0xa5a477f3,
  0x60a467db,
  0xcaa6a831,
  0x4eb4149d,
  0x1faa5752,
  0x3a083a6a,
  0xb6e6cf2f,
];

Future<void> main(List<String> arguments) async {
  const ts = 'test/fixtures/mpeg2-open-gop.ts';
  await _compare(ts, _progressive, codec: 'mpeg2video', start: 129600);
  await _compare(
    'test/fixtures/mpeg2-interlaced.mkv',
    _interlaced,
    codec: 'mpeg2video',
  );
  await _compare(
    'test/fixtures/mpeg2-422.mkv',
    _chroma422,
    codec: 'mpeg2video',
  );
  await _compare(
    'test/fixtures/mpeg1-open-gop.mkv',
    _legacy,
    codec: 'mpeg1video',
  );
  // The FFmpeg muxer uses the MPEG-2 PMT stream type for this MPEG-1 clip.
  await _compare(
    'test/fixtures/mpeg1-open-gop.ts',
    _legacy,
    codec: 'mpeg1video',
    start: 129600,
  );
  if (arguments.isNotEmpty) await _commands(arguments.single, ts);
}

Future<void> _compare(
  String path,
  List<int> hashes, {
  required String codec,
  int start = 0,
}) async {
  final video = Video(path);
  final workers = VideoCaptureDecoder(video, threads: 2);
  try {
    final transport = MpegSystemsVideo.detect(video.file);
    final matroska = transport == null ? Matroska(video.file) : null;
    final sequence = matroska == null
        ? null
        : matroskaVideoConfiguration(matroska, codec);
    final decoder = MpegStreamDecoder(sequence);
    final source = transport?.packets(false) ?? matroskaFrames(matroska!);
    final packets = video.packets().toList();
    final metadata = video.metadata.streams.single;
    final period = transport == null ? 40 : 3600;
    final progressiveTs = transport != null && codec == 'mpeg2video';
    final expectedWidth = progressiveTs ? 158 : 160;
    final expectedHeight = progressiveTs ? 110 : 112;
    final halfTail = transport != null && codec == 'mpeg1video';
    final duration = (hashes.length - (halfTail ? 0.5 : 0)) / 25;
    check(
      metadata.codec == codec && video.codec == codec,
      'Probe MPEG codec for $path',
    );
    check(
      metadata.width == expectedWidth && metadata.height == expectedHeight,
      'MPEG dimensions',
    );
    check((video.metadata.duration! - duration).abs() < 1e-9, 'MPEG duration');
    check(packets.length == hashes.length, 'MPEG frame count');

    final positions = {for (final (i, packet) in packets.indexed) packet: i};
    final rgb = <int, int>{};
    for (final packet in source) {
      final frame = decoder.decode(
        transport?.read(packet) ?? video.file.read(packet.offset, packet.size),
      );
      final index = positions[packet]!;
      check(
        packet.timestamp!.pts == start + period * index,
        'MPEG presentation order',
      );
      check(packet.timestamp!.duration == period, 'MPEG frame duration');
      check(
        _yuvHash(frame) == hashes[index],
        '$path MPEG YUV for frame $index',
      );
      rgb[index] = _hash(frame.rgb().getBytes());
    }

    final keys = video
        .packets(preview: true)
        .map((packet) => positions[packet]!)
        .toList();
    check(
      keys.join(',') == (progressiveTs ? '0,9,15' : '0,9'),
      'MPEG I-picture positions',
    );
    check(
      _hash(video.decode(packets[keys.last], preview: true).getBytes()) ==
          rgb[keys.last],
      'Decode a later MPEG keyframe independently',
    );
    // The final frame is in a later GOP. It must decode even when unrelated
    // leading B-pictures in that GOP still need references from earlier GOPs.
    final selected = [packets.first, packets[7], packets.last];
    var count = 0;
    await for (final result in workers.decode(selected)) {
      final index = positions[result.packet]!;
      check(
        _hash(result.frame.getBytes()) == rgb[index],
        '$path seek to frame $index',
      );
      count++;
    }
    check(count == selected.length, 'All selected MPEG frames returned');
  } finally {
    await workers.close();
    video.close();
  }
}

int _yuvHash(MpegPicture picture) {
  var hash = 2166136261;
  for (final (component, plane) in picture.planes.indexed) {
    final sx = component == 0 ? 0 : picture.subsamplingX;
    final sy = component == 0 ? 0 : picture.subsamplingY;
    final stride = picture.stride >> sx;
    final width = (picture.width + sx) >> sx;
    final height = (picture.height + sy) >> sy;
    for (var y = 0; y < height; y++) {
      final row = y * stride;
      for (var x = 0; x < width; x++) {
        hash = ((hash ^ plane[row + x]) * 16777619) & 0xffffffff;
      }
    }
  }
  return hash;
}

int _hash(List<int> bytes) {
  var hash = 2166136261;
  for (final byte in bytes) {
    hash = ((hash ^ byte) * 16777619) & 0xffffffff;
  }
  return hash;
}

Future<void> _commands(String executable, String input) async {
  final dir = Directory.systemTemp.createTempSync('vimg-mpeg-video-');
  try {
    final preview = '${dir.path}/preview.jpg';
    final sheet = '${dir.path}/sheet.avif';
    final captures = '${dir.path}/frames';
    for (final arguments in [
      ['preview', '--output', preview, input],
      ['extract', '-n3', '-T2', '--output-dir', captures, input],
      ['vcs', '-c2', '-H48', '-n3', '-f3', '-T2', '-o', sheet, input],
    ]) {
      final result = await Process.run(executable, arguments);
      check(result.exitCode == 0, '${arguments.first}: ${result.stderr}');
    }
    check(File(preview).lengthSync() > 0, 'MPEG JPEG preview');
    check(Directory(captures).listSync().length == 3, 'MPEG BMP captures');
    check(File(sheet).lengthSync() > 0, 'MPEG animated AVIF');
  } finally {
    dir.deleteSync(recursive: true);
  }
}
