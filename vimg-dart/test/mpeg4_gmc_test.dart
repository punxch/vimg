import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:vimg_dart/src/mpeg4/decoder.dart';
import 'package:vimg_dart/src/video.dart';
import 'package:vimg_dart/src/yuv_image.dart';

import 'fixtures.dart';

const _fixture = 'test/fixtures/mpeg4-gmc-';
const _affine = '${_fixture}affine.mp4';

Future<void> main(List<String> arguments) async {
  // All clips start with testsrc2 encoded by FFmpeg at 82x50 and 8 fps.
  // Authored S-VOPs mix implicit GMC, locally predicted motion, and
  // explicit GMC with residuals. Two intervening B-VOPs use direct mode.
  _verifyPlanes('identity', [
    745934216,
    290449365,
    1469067156,
    3918098085,
    2455528641,
  ]);
  _verifyPlanes('translate', [
    745934216,
    129435210,
    3804564491,
    2324868964,
    2154441379,
  ]);
  // The reference carries FFmpeg's fix for a zero shift in GMC1 AMVs.
  _verifyPlanes('zero-accuracy', [
    745934216,
    3105098357,
    9867437,
    2732626243,
    986259907,
  ]);

  // The three-point MP4 uses data partitions. Its hashes are from FFmpeg
  // decoding the equivalent non-partitioned macroblocks.
  await _verifyCaptures(_affine, [
    3327275831,
    3191400871,
    966737720,
    2128350793,
    61378635,
  ]);
  // The two-point Matroska repeats the trajectory in a video packet header.
  await _verifyCaptures('${_fixture}rotate.mkv', [
    3327275831,
    1311750047,
    1328432922,
    384014753,
    1132615659,
  ]);
  // The DivX AVI uses the historical build 413 trajectory syntax.
  await _verifyCaptures('${_fixture}divx.avi', [
    3327275831,
    566731300,
    1039931839,
    3643860329,
    2310819464,
  ]);
  if (arguments.firstOrNull case final cli?) await _verifyContactSheet(cli);
}

void _verifyPlanes(String name, List<int> expected) {
  final bytes = File('$_fixture$name.m4v').readAsBytesSync();
  final frames = Mpeg4Decoder().decode(bytes).toList()
    ..sort((a, b) => a.pts.compareTo(b.pts));
  check(frames.length == expected.length, '$name display frames');
  for (final (i, frame) in frames.indexed) {
    final visible = BytesBuilder(copy: false);
    for (final (plane, data) in frame.planes.indexed) {
      final shift = plane == 0 ? 0 : 1;
      final width = frame.volume.width >> shift;
      final height = frame.volume.height >> shift;
      final stride = frame.stride >> shift;
      for (var y = 0; y < height; y++) {
        visible.add(
          Uint8List.sublistView(data, y * stride, y * stride + width),
        );
      }
    }
    check(frame.pts == i, '$name display tick $i');
    check(getCrc32(visible.takeBytes()) == expected[i], '$name YUV frame $i');
  }
}

Future<void> _verifyCaptures(String path, List<int> expected) async {
  final video = Video(path);
  final worker = VideoCaptureDecoder(
    video,
    threads: 2,
    scaler: YuvImageScaler(height: 20),
    includeOriginal: true,
  );
  try {
    final packets = video.packets().toList();
    check(packets.length == expected.length, '$path frame count');
    check(
      video.packets(preview: true).single == packets.first,
      '$path keyframe',
    );
    for (final i in [4, 1, 3, 0, 2]) {
      check(packets[i].seconds == i / 8, '$path display time $i');
      final capture = await worker.decode([packets[i]]).single;
      check(capture.frame.height == 20, '$path scaled capture $i');
      check(
        getCrc32(capture.original!.getBytes()) == expected[i],
        '$path RGB frame $i',
      );
    }
  } finally {
    await worker.close();
    video.close();
  }
}

Future<void> _verifyContactSheet(String cli) async {
  final directory = Directory.systemTemp.createTempSync('vimg-mpeg4-gmc-');
  try {
    final sheet = File('${directory.path}/sheet.avif');
    final result = await Process.run(cli, [
      'vcs',
      '-c2',
      '-H24',
      '-n2',
      '-f3',
      '-t250ms',
      '-o',
      sheet.path,
      _affine,
    ]);
    check(result.exitCode == 0, '${result.stderr}');
    check(
      ascii.decode(sheet.readAsBytesSync().sublist(4, 12)) == 'ftypavis',
      'Partitioned GMC produces an animated contact sheet',
    );
  } finally {
    directory.deleteSync(recursive: true);
  }
}
