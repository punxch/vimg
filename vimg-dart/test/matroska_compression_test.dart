import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:vimg_dart/src/matroska.dart';
import 'package:vimg_dart/src/video.dart';

import 'fixtures.dart';

const _rice = 'test/fixtures/ffv1-rice.mkv';
// The same FFV1 frames and private data, compressed with liblzo2 LZO1X.
const _lzo = 'test/fixtures/ffv1-lzo.mkv';
const _avc = 'test/fixtures/avc-422-cabac.mkv';
const _vfw = 'test/fixtures/msvideo1-indexed.mkv';
const _alpha = 'test/fixtures/vp8-alpha-staggered.webm';

void main() {
  final directory = Directory.systemTemp.createTempSync(
    'vimg-mkv-compression-',
  );
  try {
    _checkVideo(_rice, _lzo);
    _checkVideo(
      _rice,
      _rewrite(
        directory,
        _rice,
        [_encoding(scope: 3)],
        zlib.encode,
        zlib.encode,
      ),
    );
    final bzip2 = BZip2Encoder().encodeBytes;
    _checkVideo(
      _vfw,
      _rewrite(directory, _vfw, [_encoding(algo: 1, scope: 3)], bzip2, bzip2),
    );
    _checkVideo(
      _avc,
      _rewrite(
        directory,
        _avc,
        [
          _encoding(order: 2, scope: 3),
          _encoding(algo: 3, settings: [0]),
          _encoding(order: 1, scope: 2, algo: 3, settings: [1]),
        ],
        (frame) {
          check(frame.first == 0, 'AVC frame has a leading zero');
          return zlib.encode(frame.sublist(1));
        },
        (configuration) {
          check(configuration.first == 1, 'AVC configuration version');
          return zlib.encode(configuration.sublist(1));
        },
      ),
    );
    _checkVideo(
      _alpha,
      _rewrite(directory, _alpha, [_encoding()], zlib.encode, (data) => data),
    );
    _checkEmptyLaces(directory);
    _checkInvalidChecksum(
      _rewrite(directory, _rice, [_encoding()], (frame) {
        final compressed = zlib.encode(frame);
        return compressed..[compressed.length - 1] ^= 1;
      }, (data) => data),
    );
  } finally {
    directory.deleteSync(recursive: true);
  }
}

void _checkVideo(String source, String compressed) {
  final reference = Video(source);
  final actual = Video(compressed);
  try {
    check(
      actual.metadata.streams.single.codec ==
          reference.metadata.streams.single.codec,
      '$source video codec',
    );
    final expectedMedia = Matroska(reference.file);
    final actualMedia = Matroska(actual.file);
    final expectedPrivate = expectedMedia.codecPrivate(
      expectedMedia.firstVideoTrack!,
    );
    final actualPrivate = actualMedia.codecPrivate(
      actualMedia.firstVideoTrack!,
    );
    check(
      expectedPrivate == null
          ? actualPrivate == null
          : actualPrivate != null && _equal(expectedPrivate, actualPrivate),
      '$source restored codec private data',
    );
    final expected = reference.packets().toList();
    final packets = actual.packets().toList();
    check(packets.length == expected.length, '$source packet count');
    for (final (i, packet) in packets.indexed) {
      check(packet.seconds == expected[i].seconds, '$source packet $i time');
      check(
        _equal(
          actualMedia.readFrame(packet),
          expectedMedia.readFrame(expected[i]),
        ),
        '$source restored packet $i',
      );
    }
    final preview = actual.packets(preview: true).map((p) => p.seconds);
    final expectedPreview = reference
        .packets(preview: true)
        .map((p) => p.seconds);
    check(
      _equal(preview.toList(), expectedPreview.toList()),
      '$source preview',
    );
    final frames = actual.decodeSelected(packets).toList();
    final expectedFrames = reference.decodeSelected(expected).toList();
    check(
      frames.length == expectedFrames.length,
      '$source decoded frame count',
    );
    for (final (i, frame) in frames.indexed) {
      check(
        _equal(frame.frame.getBytes(), expectedFrames[i].frame.getBytes()),
        '$source decoded frame $i',
      );
    }
  } finally {
    actual.close();
    reference.close();
  }
}

bool _equal<T>(List<T> first, List<T> second) {
  if (first.length != second.length) return false;
  for (var i = 0; i < first.length; i++) {
    if (first[i] != second[i]) return false;
  }
  return true;
}

List<int> _element(int id, List<int> data) =>
    ebml(uint(id, (id.bitLength + 7) ~/ 8), data);

List<int> _encoding({
  int order = 0,
  int scope = 1,
  int algo = 0,
  List<int> settings = const [],
}) => _element(0x6240, [
  if (order != 0) ..._element(0x5031, [order]),
  if (scope != 1) ..._element(0x5032, [scope]),
  ..._element(0x5034, [
    if (algo != 0) ..._element(0x4254, [algo]),
    if (settings.isNotEmpty) ..._element(0x4255, settings),
  ]),
]);

String _rewrite(
  Directory directory,
  String source,
  List<List<int>> encodings,
  List<int> Function(Uint8List) frame,
  List<int> Function(Uint8List) privateData,
) {
  final video = Video(source);
  final media = Matroska(video.file);
  List<int> rewrite(EbmlElement item) {
    final id = item.id;
    if (id == 0xbf || id == 0x114d9b74 || id == 0x1c53bb6b) return const [];
    if (id == 0x18538067 ||
        id == 0x1654ae6b ||
        id == 0xae ||
        id == matroskaCluster ||
        id == 0xa0) {
      return _element(id, [
        for (final child in media.elements(item.data, item.end))
          ...rewrite(child),
        if (id == 0xae)
          ..._element(0x6d80, [for (final encoding in encodings) ...encoding]),
      ]);
    }
    final data = media.file.read(item.data, item.end - item.data);
    if (id == 0x63a2) return _element(id, privateData(data));
    if (id == 0xa1 || id == 0xa3) {
      final headerLength = media.vint(item.data, item.end).width + 3;
      check(data[headerLength - 1] & 6 == 0, 'expected unlaced fixture block');
      return _element(id, [
        ...Uint8List.sublistView(data, 0, headerLength),
        ...frame(Uint8List.sublistView(data, headerLength)),
      ]);
    }
    return _element(id, data);
  }

  try {
    final path = '${directory.path}/compressed.mkv';
    File(path).writeAsBytesSync([
      for (final item in media.elements(0, media.file.length)) ...rewrite(item),
    ]);
    return path;
  } finally {
    video.close();
  }
}

void _checkEmptyLaces(Directory directory) {
  final source = Video(matroskaFixture(directory).path);
  late final Uint8List picture;
  try {
    final packet = source.packets().first;
    picture = source.file.read(packet.offset, packet.size);
  } finally {
    source.close();
  }
  final file = File('${directory.path}/laced.mkv')
    ..writeAsBytesSync([
      ..._element(0x1a45dfa3, _element(0x4282, 'matroska'.codeUnits)),
      ..._element(0x18538067, [
        ..._element(
          0x1654ae6b,
          _element(0xae, [
            ..._element(0xd7, [1]),
            ..._element(0x83, [1]),
            ..._element(0x23e383, uint(200000000, 4)),
            ..._element(0x86, 'V_MJPEG'.codeUnits),
            ..._element(0xe0, [
              ..._element(0xb0, [32]),
              ..._element(0xba, [24]),
            ]),
            ..._element(0x6d80, _encoding(algo: 3, settings: picture)),
          ]),
        ),
        ..._element(matroskaCluster, [
          ..._element(0xe7, [0]),
          // Two Xiph-laced pictures entirely contained in the stripped header.
          ..._element(0xa3, [0x81, 0, 0, 0x82, 1, 0]),
        ]),
      ]),
    ]);
  final video = Video(file.path);
  try {
    final packets = video.packets().toList();
    final media = Matroska(video.file);
    check(
      packets.length == 2 && packets[1].seconds == 0.2,
      'header-stripped lace timestamps',
    );
    for (final packet in packets) {
      check(packet.size == 0, 'header-stripped lace stored size');
      check(_equal(media.readFrame(packet), picture), 'header-stripped lace');
      check(video.decode(packet).width == 32, 'header-stripped lace decode');
    }
  } finally {
    video.close();
  }
}

void _checkInvalidChecksum(String path) {
  final video = Video(path);
  try {
    Matroska(video.file).readFrame(video.packets().first);
    throw StateError('Invalid Matroska zlib checksum was accepted');
  } on FormatException catch (error) {
    check(error.message.contains('zlib checksum'), 'Matroska checksum error');
  } finally {
    video.close();
  }
}
