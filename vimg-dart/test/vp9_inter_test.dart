import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:image/image.dart' as image;
import 'package:vimg_dart/src/matroska.dart';
import 'package:vimg_dart/src/matroska_frames.dart';
import 'package:vimg_dart/src/video.dart';
import 'package:vimg_dart/src/vp9/bitstream.dart';
import 'package:vimg_dart/src/vp9/decoder.dart';
import 'package:vimg_dart/src/yuv_image.dart';

import 'fixtures.dart';

const _compound = 'test/fixtures/vp9-inter-compound.mp4';
const _deep = 'test/fixtures/vp9-inter-422-12.ivf';
const _staggered = 'test/fixtures/vp9-alpha-staggered.webm';
const _alpha = [
  0xf77f79c7,
  0xb3b4ff58,
  0x3686268f,
  0x79a73ef4,
  0xae619d85,
  0x200c38a3,
  0x919eeabf,
  0x8ef58d29,
  0x171daae7,
  0x15541ba6,
  0x6fd0f090,
];

Future<void> main(List<String> arguments) async {
  // Per-plane CRCs over all libvpx output samples in display order.
  _checkSequence(_compound, 68, [
    0x90402ac3,
    0xc91e5428,
    0x9280a558,
  ], hidden: 6);
  _checkSequence(_deep, 13, [0x6c0f1522, 0x97f1fb9c, 0x29802f2f], hidden: 0);
  await _checkParallelSeek();
  await _checkAlpha();
  if (arguments.firstOrNull case final executable?) await _checkCli(executable);
}

void _checkSequence(
  String path,
  int count,
  List<int> expected, {
  required int hidden,
}) {
  final video = Video(path);
  try {
    final packets = video.packets().toList();
    check(
      video.codec == 'vp9' && packets.length == count,
      '$path display pictures',
    );
    final decoder = Vp9Decoder();
    final crc = [0, 0, 0];
    var hiddenCount = 0;
    var inter = 0;
    var repeatedReference = false;
    for (final packet in packets) {
      final bytes = video.file.read(packet.offset, packet.size);
      final extents = vp9FrameExtents(
        bytes.length,
        (offset, length) =>
            Uint8List.sublistView(bytes, offset, offset + length),
      );
      hiddenCount += extents
          .where(
            (frame) => !vp9FrameTag(
              Uint8List.sublistView(
                bytes,
                frame.offset,
                frame.offset + frame.length,
              ),
            ).shown,
          )
          .length;
      final picture = decoder.decodePacket(bytes)!;
      final header = picture.header;
      if (!header.intra) {
        inter++;
        if (!repeatedReference &&
            header.tag.profile == 0 &&
            header.refreshMask & 1 != 0) {
          final again = decoder.decodePacket(Uint8List.fromList([0x88]));
          check(identical(again, picture), 'VP9 show-existing inter reference');
          repeatedReference = true;
        }
      }
      for (final (i, plane) in [picture.y, picture.u, picture.v].indexed) {
        final sx = i == 0 ? 0 : header.color.subX;
        final sy = i == 0 ? 0 : header.color.subY;
        final width = (header.width + sx) >> sx;
        final height = (header.height + sy) >> sy;
        final word = header.color.depth > 8;
        final row = Uint8List(width * (word ? 2 : 1));
        for (var y = 0; y < height; y++) {
          var at = 0;
          for (var x = 0; x < width; x++) {
            final value = plane.samples[y * plane.stride + x];
            row[at++] = value & 255;
            if (word) row[at++] = value >> 8;
          }
          crc[i] = getCrc32(row, crc[i]);
        }
      }
    }
    check(
      inter > 0 && hiddenCount == hidden,
      '$path inter and hidden picture counts',
    );
    if (hidden > 0)
      check(repeatedReference, '$path displayed a saved inter reference');
    check(crc.join(',') == expected.join(','), '$path libvpx plane CRCs');
  } finally {
    video.close();
  }
}

Future<void> _checkParallelSeek() async {
  final video = Video(_compound);
  final scaler = YuvImageScaler(
    height: 29,
    filters: VideoFilterChain.parse('hflip'),
  );
  final worker = VideoCaptureDecoder(
    video,
    threads: 2,
    scaler: scaler,
    includeOriginal: true,
  );
  try {
    final packets = video.packets().toList();
    check(
      video.packets(preview: true).length >= 2,
      'VP9 more than one seek anchor',
    );
    final targets = [
      for (final i in [67, 61, 60, 29, 13, 1]) packets[i],
    ];
    final expected = {
      for (final capture in video.decodeSelected(
        targets,
        scaler: scaler,
        includeOriginal: true,
      ))
        capture.packet: (
          full: getCrc32(capture.original!.getBytes()),
          scaled: getCrc32(capture.frame.getBytes()),
        ),
    };
    check(expected.length == targets.length, 'VP9 serial seek count');
    await for (final actual in worker.decode(targets)) {
      final gold = expected.remove(actual.packet);
      check(gold != null, 'VP9 unique worker result');
      check(
        actual.frame.height == 29 &&
            getCrc32(actual.frame.getBytes()) == gold!.scaled,
        'VP9 scaled seek pixels',
      );
      check(
        getCrc32(actual.original!.getBytes()) == gold!.full,
        'VP9 original seek pixels',
      );
    }
    check(expected.isEmpty, 'VP9 parallel seek count');
  } finally {
    await worker.close();
    video.close();
  }
}

Future<void> _checkAlpha() async {
  final video = Video(_staggered);
  final worker = VideoCaptureDecoder(
    video,
    threads: 2,
    scaler: YuvImageScaler(height: 31),
    includeOriginal: true,
  );
  try {
    final packets = video.packets().toList();
    final indices = {for (final (i, packet) in packets.indexed) packet: i};
    check(packets.length == _alpha.length, 'VP9 alpha frame count');
    var mismatchedKeys = 0;
    matroskaFrames(
      Matroska(video.file),
      onAlpha: (packet, data) {
        bool key(int start, int size) => vp9PacketTag(
          size,
          (offset, length) => video.file.read(start + offset, length),
        ).key;
        if (key(packet.offset, packet.size) &&
            !key(data.data, data.end - data.data)) {
          mismatchedKeys++;
        }
      },
    ).length;
    check(mismatchedKeys > 0, 'VP9 independent opacity keyframes');
    for (final (index, packet) in packets.indexed) {
      check(
        _alphaCrc(video.decode(packet)) == _alpha[index],
        'VP9 opacity $index',
      );
    }
    final targets = {10, 9, 6, 3, 0};
    await for (final result in worker.decode([
      for (final i in targets) packets[i],
    ])) {
      final index = indices[result.packet]!;
      check(targets.remove(index), 'VP9 unique alpha worker result');
      check(
        _alphaCrc(result.original!) == _alpha[index],
        'VP9 seek opacity $index',
      );
      check(
        result.frame.height == 31 && result.frame.hasAlpha,
        'VP9 resized opacity',
      );
    }
    check(targets.isEmpty, 'VP9 parallel alpha count');
  } finally {
    await worker.close();
    video.close();
  }
}

int _alphaCrc(image.Image picture) {
  check(picture.hasAlpha, 'VP9 alpha channel');
  return getCrc32([for (final pixel in picture) pixel.a.toInt()]);
}

Future<void> _checkCli(String executable) async {
  final dir = Directory.systemTemp.createTempSync('vimg-vp9-inter-');
  Future<void> run(List<String> args) async {
    final result = await Process.run(executable, args);
    check(result.exitCode == 0, '$args failed: ${result.stderr}');
  }

  try {
    final captures = Directory('${dir.path}/frames');
    await run([
      'extract',
      '-n3',
      '-T2',
      '--output-dir',
      captures.path,
      _staggered,
    ]);
    final files = captures.listSync().whereType<File>().toList();
    check(files.length == 3, 'VP9 inter BMP output count');
    for (final file in files) {
      final bmp = image.decodeBmp(file.readAsBytesSync())!;
      check(_alpha.contains(_alphaCrc(bmp)), 'VP9 BMP opacity pixels');
    }
    final sheet = '${dir.path}/grid.avif';
    await run([
      'vcs',
      '-c2',
      '-n2',
      '-H24',
      '-f3',
      '-t450ms',
      '--vfilter',
      'hflip',
      '-T2',
      '-o',
      sheet,
      _compound,
    ]);
    final output = File(sheet).readAsBytesSync();
    check(
      String.fromCharCodes(output.sublist(4, 12)) == 'ftypavis',
      'VP9 inter animated AVIF output',
    );
  } finally {
    dir.deleteSync(recursive: true);
  }
}
