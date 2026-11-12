import 'dart:io';
import 'dart:typed_data';

import 'package:vimg_dart/src/binary_file.dart';
import 'package:vimg_dart/src/hevc/access_unit.dart';
import 'package:vimg_dart/src/hevc/cabac.dart';
import 'package:vimg_dart/src/hevc/contexts.dart';
import 'package:vimg_dart/src/hevc/nal.dart';
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

void main() {
  _check('test/fixtures/hevc-main.mkv', main10: false);
  _check('test/fixtures/hevc-main10.mp4', main10: true);
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
