import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:image/image.dart' as image;
import 'package:vimg_dart/src/avif_animation.dart';
import 'package:vimg_dart/src/binary_file.dart';
import 'package:vimg_dart/src/hevc/access_unit.dart';
import 'package:vimg_dart/src/hevc/decode_picture.dart';
import 'package:vimg_dart/src/hevc/picture.dart';
import 'package:vimg_dart/src/matroska.dart';
import 'package:vimg_dart/src/matroska_frames.dart';
import 'package:vimg_dart/src/video.dart';

import 'fixtures.dart';

// Planar checksums come from the original input for the lossless sequence
// and x265's reconstructed output for the lossy sequence. Each source
// plane was encoded independently and its slices interleaved in each sample.
// The 10-bit RGB checksums use FFmpeg's scalar conversion of the source planes.
const _lossless = [
  (1896435931, 555403358, 2603968749, 500919902),
  (3073586812, 3165923672, 2711194800, 2359372632),
  (2619271833, 957295936, 116965155, 1007808350),
  (2630467194, 690607145, 1702457841, 2238397560),
  (894275110, 1499167055, 3489712198, 955575806),
  (698758034, 2226286262, 2652950499, 1123635008),
  (1876478555, 791935239, 599558220, 1711411830),
  (3925048048, 2944250394, 586382897, 3116111668),
  (4272302578, 1137007259, 2558206806, 803456605),
  (563166434, 3112402243, 4235077015, 2891868735),
];
const _lossy = [
  (605189758, 2364969101, 1982903954, 3740435356),
  (28001581, 1573554647, 2986301129, 368785656),
  (3247973911, 3797661854, 1046375283, 1760600036),
  (3279736369, 1872244638, 865658795, 247121905),
  (2396127437, 2702142544, 1460356484, 4185811581),
  (3503870011, 2282773527, 604376500, 3693064358),
  (3376483014, 2106871439, 2184204199, 4131475558),
  (2296993057, 3730625924, 3365147096, 1425481711),
  (680524173, 1358831786, 2139300958, 582116876),
  (3965341096, 2824258931, 1674701412, 2005573863),
];

Future<void> main(List<String> arguments) async {
  const input = 'test/fixtures/hevc-separate-10.mkv';
  await _checkDecoding(input, 10, _lossless);
  await _checkDecoding('test/fixtures/hevc-separate-8.mkv', 8, _lossy);

  if (arguments.firstOrNull case final cli?) {
    final directory = Directory.systemTemp.createTempSync('vimg-hevc-planes-');
    try {
      final jpeg = File('${directory.path}/preview.jpg');
      final preview = await Process.run(cli, [
        'preview',
        '--skip',
        '90',
        '--output',
        jpeg.path,
        input,
      ]);
      check(preview.exitCode == 0, 'Separated HEVC preview ${preview.stderr}');
      final picture = image.decodeJpg(jpeg.readAsBytesSync())!;
      check((picture.width, picture.height) == (96, 64), 'Preview size');
      final output = '${directory.path}/grid.avif';
      final result = await Process.run(cli, [
        'vcs',
        '-c2',
        '-H24',
        '-n2',
        '-f2',
        '-t250ms',
        '-o',
        output,
        input,
      ]);
      check(
        result.exitCode == 0,
        'Separated HEVC contact sheet ${result.stderr}',
      );
      final animation = AvifAnimation.open(output);
      try {
        check(
          (animation.width, animation.height, animation.frameCount) ==
              (72, 24, 2),
          'Separated HEVC contact sheet dimensions and animation',
        );
        check(
          animation.decodeFrames().length == 2,
          'Decode the generated AVIF',
        );
      } finally {
        animation.close();
      }
    } finally {
      directory.deleteSync(recursive: true);
    }
  }
}

Future<void> _checkDecoding(
  String path,
  int depth,
  List<(int, int, int, int)> expected,
) async {
  final file = File(path).openSync();
  try {
    final media = Matroska(BinaryFile(file));
    final record = media.codecPrivate(media.firstVideoTrack!)!;
    final stream = HevcStreamDecoder(HevcConfiguration(record));
    final intra = HevcIntraDecoder(HevcConfiguration(record));
    var decoded = 0;
    for (final packet in matroskaFrames(media)) {
      final frame = (packet.seconds * 8).round();
      final bytes = media.readFrame(packet);
      _checkPicture(stream.decode(bytes)!, depth, expected[frame]);
      if (frame % 5 == 0) {
        final slices = intra.configuration.slices(bytes);
        final order = slices.map((s) => s.parameters.colourPlane).join();
        check(
          order == (frame == 0 ? '012012' : '201201'),
          'Interleaved slices',
        );
        _checkPicture(intra.decode(bytes)!, depth, expected[frame]);
        if (frame == 0) _rejectMissingPlane(record, bytes);
      }
      decoded++;
    }
    check(decoded == expected.length, 'All separated HEVC pictures decoded');
  } finally {
    file.closeSync();
  }

  final video = Video(path);
  final capture = VideoCaptureDecoder(video, threads: 2);
  try {
    final packets = video.packets().toList();
    check(packets.length == expected.length, 'Presentation frame count');
    for (final (index, packet) in packets.indexed) {
      check(packet.seconds == index / 8, 'Presentation order of B-pictures');
    }
    final rgb = {
      for (final (index, packet) in packets.indexed) packet: expected[index].$4,
    };
    await for (final result in capture.decode(packets.reversed)) {
      check(
        rgb.remove(result.packet) == getCrc32(result.frame.getBytes()),
        'Parallel decoding restores each plane from its own references',
      );
    }
    check(rgb.isEmpty, 'Every requested HEVC picture was returned');
  } finally {
    await capture.close();
    video.close();
  }
}

void _checkPicture(HevcPicture picture, int depth, (int, int, int, int) crc) {
  int checksum(HevcPlane plane) {
    check(
      (plane.width, plane.height, plane.depth) == (96, 64, depth),
      'Plane shape',
    );
    if (depth == 8) return getCrc32(Uint8List.fromList(plane.samples));
    final raw = ByteData(plane.samples.length * 2);
    for (final (index, value) in plane.samples.indexed) {
      raw.setUint16(index * 2, value, Endian.little);
    }
    return getCrc32(raw.buffer.asUint8List());
  }

  check(
    (
          checksum(picture.luma),
          checksum(picture.cb!),
          checksum(picture.cr!),
          getCrc32(picture.rgb().getBytes()),
        ) ==
        crc,
    'Separate-plane samples and RGB match their independent references',
  );
}

void _rejectMissingPlane(Uint8List record, Uint8List sample) {
  final decoder = HevcIntraDecoder(HevcConfiguration(record));
  final nals = decoder.configuration.nals(sample).toList();
  final incomplete = Uint8List.fromList([
    for (final index in [0, 2, 3, 5]) ...[
      ...uint(nals[index].bytes.length, 4),
      ...nals[index].bytes,
    ],
  ]);
  try {
    decoder.decode(incomplete);
  } on FormatException catch (error) {
    check(error.message == 'Missing HEVC colour plane', 'Missing plane error');
    return;
  }
  throw StateError('Incomplete picture was accepted');
}
