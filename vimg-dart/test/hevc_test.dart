import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:image/image.dart' as image;
import 'package:vimg_dart/src/binary_file.dart';
import 'package:vimg_dart/src/hevc/access_unit.dart';
import 'package:vimg_dart/src/hevc/cabac.dart';
import 'package:vimg_dart/src/hevc/contexts.dart';
import 'package:vimg_dart/src/hevc/intra_picture.dart';
import 'package:vimg_dart/src/hevc/nal.dart';
import 'package:vimg_dart/src/hevc/picture.dart';
import 'package:vimg_dart/src/hevc/picture_order.dart';
import 'package:vimg_dart/src/hevc/slice_header.dart';
import 'package:vimg_dart/src/iso_frames.dart';
import 'package:vimg_dart/src/iso_media.dart';
import 'package:vimg_dart/src/matroska.dart';
import 'package:vimg_dart/src/matroska_frames.dart';
import 'package:vimg_dart/src/video_configuration.dart';

import 'fixtures.dart';

// x265 encode order and FFmpeg trace_headers for the two synthetic clips.
const _mainPocs = [0, 3, 2, 1, 6, 5, 4, 8, 7, 11, 10, 9, 14, 13, 12, 16, 15];
const _mainQps = [
  29,
  29,
  31,
  32,
  29,
  31,
  32,
  28,
  32,
  29,
  31,
  32,
  29,
  31,
  32,
  28,
  32,
];
const _mainNalTypes = [20, 1, 1, 0, 1, 1, 0, 21, 8, 1, 1, 0, 1, 1, 0, 21, 8];
const _mainEntries = [
  1697,
  1274,
  479,
  262,
  918,
  322,
  447,
  1769,
  154,
  721,
  291,
  213,
  445,
  321,
  225,
  1577,
  227,
];

const _main = 'test/fixtures/hevc-main.mkv';
const _main10 = 'test/fixtures/hevc-main10.mp4';
const _allIntra = 'test/fixtures/hevc-all-intra.mkv';
const _pcmTiles = 'test/fixtures/hevc-pcm-tiles.mkv';

// FFmpeg's cropped YUV planes, with all signalled loop filters applied.
const _mainPixels = {
  0: [0x59eda39e, 0xcf9ede00, 0x6efc8edf],
  8: [0x55ad8459, 0x1ee482e3, 0xd2ff8a30],
  16: [0xac8b7cdf, 0xf2e17a01, 0x8bd68d11],
};
const _main10Pixels = {
  0: [0xf9e6edad, 0x0587d4fe, 0xb89451b0],
  6: [0x2987d303, 0x881d0080, 0xcef5f016],
};
const _allIntraPixels = [
  [0x699a9741, 0x0291ec9b, 0x48e00d81],
  [0xb7705191, 0xb2a831fe, 0x729f8832],
  [0x9286709a, 0xf6bc2ec8, 0xd2610260],
  [0x7c9d9ffb, 0xfd58bebf, 0xd2e6c798],
  [0x07666432, 0x145a7c72, 0xb0143536],
];

Future<void> main(List<String> arguments) async {
  _check(_main, main10: false);
  _check(_main10, main10: true);
  _checkIntraClip(_allIntra, _allIntraPixels);
  _checkIntraClip(_pcmTiles, [
    [0x00729694, 0x036a662d, 0x8a7f1505],
  ]);
  await _checkCli(arguments);
}

void _check(String path, {required bool main10}) {
  final handle = File(path).openSync();
  try {
    final file = BinaryFile(handle);
    final mkv = main10 ? null : Matroska(file);
    final iso = main10 ? IsoMedia(file) : null;
    final config = mkv != null
        ? matroskaVideoConfiguration(mkv, 'hevc')!
        : isoVideoConfiguration(iso!, 'hevc')!;
    final parser = HevcConfiguration(config);
    final decoder = HevcIntraDecoder(HevcConfiguration(config));
    final vps = parser.videos.values.single;
    final sps = parser.sequences.values.single;
    final pps = parser.pictures.values.single;
    final depth = main10 ? 10 : 8;
    check(vps.profile.id == (main10 ? 2 : 1), 'HEVC VPS profile');
    check((sps.width, sps.height) == (166, 110), 'HEVC conformance crop');
    check(
      (sps.codedWidth, sps.codedHeight) == (168, 112),
      'HEVC coded dimensions',
    );
    check(
      (sps.lumaDepth, sps.chromaDepth) == (depth, depth),
      'HEVC bit depths',
    );
    check(
      (sps.ctbWidth, sps.ctbHeight) == (3, 2) && pps.wavefront,
      'HEVC CTU and WPP configuration',
    );
    _expectFormatError(
      () => HevcConfiguration(
        Uint8List.sublistView(config, 0, config.length - 1),
      ),
    );

    final order = HevcPictureOrder();
    HevcPictureOrder? seek;
    var index = 0;
    for (final packet in mkv != null ? matroskaFrames(mkv) : isoFrames(iso!)) {
      final bytes = file.read(packet.offset, packet.size);
      final slices = parser.slices(bytes);
      check(slices.length == (main10 ? 2 : 1), 'HEVC slice count');
      final first = slices.first;
      final expectedPoc = main10 ? index : _mainPocs[index];
      final actual = order.observe(first);
      check(
        actual.poc == expectedPoc && actual.output && !actual.discardRasl,
        'HEVC decode-order POC',
      );
      check(packet.seconds == expectedPoc / 8, 'HEVC container PTS');
      final expectedNal = main10
          ? (index == 0 ? 20 : (index == 6 ? 21 : 1))
          : _mainNalTypes[index];
      final random = expectedNal >= 16;
      check(
        first.nal.type == expectedNal &&
            parser.containsRandomAccess(
                  packet.offset,
                  packet.size,
                  file.unsigned,
                ) ==
                random,
        'HEVC IRAP detection',
      );
      if (random) {
        final pixels = (main10 ? _main10Pixels : _mainPixels)[expectedPoc]!;
        _checkPixels(
          decoder.decode(bytes)!,
          pixels,
          '$path picture $expectedPoc',
        );
      }
      final qp = main10 ? (index == 6 ? 27 : 29) : _mainQps[index];
      for (final (sliceIndex, slice) in slices.indexed) {
        check(
          slice.address == 3 * sliceIndex && slice.parameters.qp == qp,
          'HEVC slice position and QP',
        );
        final streams = slice.substreams().toList();
        check(
          streams.length == (main10 ? 1 : 2),
          'HEVC entropy substream count',
        );
        if (!main10) {
          check(
            streams.first.bytes.length == _mainEntries[index],
            'HEVC WPP entry point',
          );
        }
        final cabac = HevcCabac(streams.first, slice.parameters);
        if (!main10 && index < 3) {
          check(
            cabac.copyModels()[HevcContext.splitCuFlag.offset] ==
                [2, 38, 42][index],
            'HEVC I/P/B CABAC initialization',
          );
        }
      }
      if (!main10 && index == 0) _checkPrevention(first);
      if (!main10 && index == 7) seek = HevcPictureOrder();
      if (!main10 && seek != null && index <= 9) {
        final afterSeek = seek.observe(first);
        check(
          afterSeek.poc == expectedPoc && afterSeek.discardRasl == (index == 8),
          'HEVC CRA leading picture',
        );
      }
      index++;
    }
    check(index == (main10 ? 12 : _mainPocs.length), 'HEVC sample count');
  } finally {
    handle.closeSync();
  }
}

void _checkIntraClip(String path, List<List<int>> expected) {
  final handle = File(path).openSync();
  try {
    final file = BinaryFile(handle);
    final mkv = Matroska(file);
    final decoder = HevcIntraDecoder(
      HevcConfiguration(matroskaVideoConfiguration(mkv, 'hevc')!),
    );
    var index = 0;
    for (final packet in matroskaFrames(mkv)) {
      final picture = decoder.decode(file.read(packet.offset, packet.size))!;
      _checkPixels(picture, expected[index], '$path picture $index');
      index++;
    }
    check(index == expected.length, 'HEVC intra fixture frame count');
  } finally {
    handle.closeSync();
  }
}

void _checkPixels(HevcPicture picture, List<int> expected, String name) {
  final sps = picture.sps;
  for (final (index, plane) in [
    picture.luma,
    picture.cb!,
    picture.cr!,
  ].indexed) {
    final shift = index == 0 ? 0 : 1;
    final width = sps.width >> shift, height = sps.height >> shift;
    final top = sps.crop.top >> shift, left = sps.crop.left >> shift;
    var hash = 0x811c9dc5;
    for (var row = 0; row < height; row++) {
      final start = (top + row) * plane.width + left;
      for (var col = 0; col < width; col++) {
        hash = ((hash ^ plane.samples[start + col]) * 0x01000193) & 0xffffffff;
      }
    }
    check(
      hash == expected[index],
      'HEVC $name plane $index differs from FFmpeg',
    );
  }
}

Future<void> _checkCli(List<String> arguments) async {
  final directory = Directory.systemTemp.createTempSync('vimg-hevc-test-');
  Future<String> run(List<String> options) async {
    final result = await Process.run(
      arguments.firstOrNull ?? Platform.resolvedExecutable,
      [if (arguments.isEmpty) 'bin/vimg.dart', ...options],
    );
    check(result.exitCode == 0, 'HEVC CLI failed: ${result.stderr}');
    return result.stdout as String;
  }

  try {
    for (final (input, skip) in [(_main, 0), (_main, 50), (_main10, 0)]) {
      final jpeg = File('${directory.path}/preview.jpg');
      final response =
          jsonDecode(
                await run([
                  'preview',
                  '--output',
                  jpeg.path,
                  '--max-width',
                  '83',
                  '--skip',
                  '$skip',
                  input,
                ]),
              )
              as Map;
      check(response['preview_written'] == true, 'HEVC preview response');
      final decoded = image.decodeJpg(jpeg.readAsBytesSync())!;
      check(
        (decoded.width, decoded.height) == (83, 55),
        'HEVC JPEG dimensions',
      );
    }
    final output = '${directory.path}/frames';
    await run(['extract', '-n2', '-t200ms', '--output-dir', output, _allIntra]);
    final files = Directory(output).listSync().cast<File>();
    check(files.length == 2, 'HEVC BMP count');
    for (final file in files) {
      final bmp = image.decodeBmp(file.readAsBytesSync())!;
      check((bmp.width, bmp.height) == (166, 110), 'HEVC BMP dimensions');
    }
    final avif = File('${directory.path}/grid.avif');
    await run([
      'vcs',
      '-c2',
      '-n2',
      '-H24',
      '-f3',
      '-t400ms',
      '-o',
      avif.path,
      _allIntra,
    ]);
    check(
      ascii.decode(avif.readAsBytesSync().sublist(4, 12)) == 'ftypavis',
      'HEVC animated contact sheet',
    );
  } finally {
    directory.deleteSync(recursive: true);
  }
}

void _checkPrevention(HevcSliceHeader original) {
  final nal = HevcNal(Uint8List.fromList([0x28, 1, 0x80, 0, 0, 3, 1, 0xf0, 1]));
  final bits = nal.rbsp()..readStopBit();
  final slice = HevcSliceHeader(
    nal: original.nal,
    sps: original.sps,
    pps: original.pps,
    first: true,
    dependent: false,
    address: 0,
    discardPrior: false,
    parameters: original.parameters,
    entryLengths: [4],
    bits: bits,
  );
  final streams = slice.substreams().toList();
  check(
    streams.first.read(24) == 1 && streams.last.read(16) == 0xf001,
    'HEVC entry point with prevention byte',
  );
}

void _expectFormatError(void Function() run) {
  try {
    run();
  } on FormatException {
    return;
  }
  throw StateError('Expected malformed HEVC data to fail');
}
