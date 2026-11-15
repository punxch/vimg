import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:image/image.dart' as image;
import 'package:vimg_dart/src/mpeg4/decoder.dart';
import 'package:vimg_dart/src/video.dart';
import 'package:vimg_dart/src/yuv_image.dart';

import 'fixtures.dart';

const _asp = 'test/fixtures/mpeg4-asp';
const _resync = 'test/fixtures/mpeg4-resync.m4v';

Future<void> main(List<String> arguments) async {
  // FFmpeg mpeg4, testsrc2 at 96x62 and 6 fps. The ASP clip uses two B-VOPs,
  // four motion vectors, quarter-sample motion and MPEG quantization.
  // The resync clip uses three slices and a packet size limit of 200 bytes.
  // Plane hashes in display order from FFmpeg's simple IDCT and raw YUV420.
  final expected = _verifyPlanes('$_asp.m4v', [
    159257369,
    1651166916,
    3782710142,
    3249062096,
    1152747508,
    2006487257,
    435434478,
    3272771905,
    4215588021,
    1539033004,
    983362316,
    3712058047,
    634329265,
  ]);
  _verifyPlanes(_resync, [
    1067221215,
    2411966396,
    2479974348,
    622945166,
    4110316087,
    1396960101,
    2910094179,
  ]);
  for (final suffix in ['.mp4', '.mkv', '-packed.avi']) {
    await _verifyContainer('$_asp$suffix', expected);
  }
  if (arguments.firstOrNull case final cli?) await _verifyCli(cli, expected);
}

List<int> _verifyPlanes(String path, List<int> expected) {
  final frames = Mpeg4Decoder().decode(File(path).readAsBytesSync()).toList()
    ..sort((a, b) => a.pts.compareTo(b.pts));
  check(frames.length == expected.length, '$path frame count');
  for (final (index, frame) in frames.indexed) {
    final pixels = BytesBuilder(copy: false);
    for (final (plane, bytes) in frame.planes.indexed) {
      final shift = plane == 0 ? 0 : 1;
      final width = frame.volume.width >> shift;
      final height = frame.volume.height >> shift;
      final stride = frame.stride >> shift;
      for (var y = 0; y < height; y++) {
        pixels.add(
          Uint8List.sublistView(bytes, y * stride, y * stride + width),
        );
      }
    }
    check(frame.pts == index, '$path display timestamp $index');
    check(getCrc32(pixels.takeBytes()) == expected[index], '$path YUV $index');
  }
  return [for (final frame in frames) getCrc32(frame.rgb().getBytes())];
}

Future<void> _verifyContainer(String path, List<int> expected) async {
  final video = Video(path);
  final worker = VideoCaptureDecoder(
    video,
    threads: 2,
    scaler: YuvImageScaler(height: 29),
    includeOriginal: true,
  );
  try {
    final packets = video.packets().toList();
    check(packets.length == expected.length, '$path display frame count');
    check(video.packets(preview: true).length == 2, '$path I-VOP previews');
    final captures = {
      for (final result in video.decodeSelected(packets)) result.packet: result,
    };
    final timeTolerance = path.endsWith('.mkv') ? 0.0005 : 1e-12;
    for (final (i, packet) in packets.indexed) {
      check((packet.seconds - i / 6).abs() < timeTolerance, '$path time $i');
      final frame = captures[packet]?.frame;
      check(
        frame != null && getCrc32(frame.getBytes()) == expected[i],
        '$path capture $i',
      );
    }
    if (path.endsWith('.avi')) {
      // The B-VOP at tick 1 shares the same physical chunk as the P-VOP
      // at tick 3. Their display identity and timing must remain distinct.
      check(packets[1].offset == packets[3].offset, 'AVI B-VOP is packed');
      check(packets[1].subframe != packets[3].subframe, 'AVI VOP extents');
    }
    for (final i in [11, 1, 12, 6, 0]) {
      final result = await worker.decode([packets[i]]).single;
      check(result.frame.height == 29, '$path scaled capture $i');
      check(
        getCrc32(result.original!.getBytes()) == expected[i],
        '$path seek $i',
      );
    }
  } finally {
    await worker.close();
    video.close();
  }
}

Future<void> _verifyCli(String cli, List<int> expected) async {
  final directory = Directory.systemTemp.createTempSync('vimg-mpeg4-');
  Future<ProcessResult> run(List<String> args) async {
    final result = await Process.run(cli, args);
    check(result.exitCode == 0, '$args failed: ${result.stderr}');
    return result;
  }

  try {
    final preview = File('${directory.path}/preview.jpg');
    final result = await run(['preview', '--output', preview.path, '$_asp.mp4']);
    final metadata =
        jsonDecode(result.stdout as String) as Map<String, dynamic>;
    check(metadata['native_preview'] == true, 'MPEG-4 native preview');
    final jpeg = image.decodeJpg(preview.readAsBytesSync());
    check(jpeg?.width == 96 && jpeg?.height == 62, 'MPEG-4 preview dimensions');

    final frames = Directory('${directory.path}/frames');
    await run([
      'extract',
      '-n3',
      '-t200ms',
      '-T2',
      '--output-dir',
      frames.path,
      '$_asp-packed.avi',
    ]);
    final hashes = [
      for (final file in frames.listSync().whereType<File>())
        getCrc32(image.decodeBmp(file.readAsBytesSync())!.getBytes()),
    ];
    check(
      hashes.length == 3 &&
          hashes.toSet().length == 3 &&
          expected.toSet().containsAll(hashes),
      'MPEG-4 BMPs contain three distinct source frames',
    );

    final sheet = File('${directory.path}/sheet.avif');
    await run([
      'vcs',
      '-c2',
      '-H24',
      '-n2',
      '-f3',
      '-t200ms',
      '-o',
      sheet.path,
      '$_asp.mkv',
    ]);
    check(
      ascii.decode(sheet.readAsBytesSync().sublist(4, 12)) == 'ftypavis',
      'MPEG-4 animated AVIF contact sheet',
    );
  } finally {
    directory.deleteSync(recursive: true);
  }
}
