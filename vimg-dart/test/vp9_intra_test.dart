import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:image/image.dart' as image;
import 'package:vimg_dart/src/video.dart';
import 'package:vimg_dart/src/vp9/bitstream.dart';
import 'package:vimg_dart/src/vp9/intra.dart';

import 'fixtures.dart';

const _tiled = 'test/fixtures/vp9-intra-tiled.ivf';
const _lossless = 'test/fixtures/vp9-intra-lossless.avi';
const _deep444 = 'test/fixtures/vp9-intra-444-10.mp4';
const _deep422 = 'test/fixtures/vp9-intra-422-12.ivf';
const _inter = 'test/fixtures/vp9-key-inter.webm';

// Packets encoded with libvpx. The CRCs cover visible Y, U and V samples
// from libvpx's decoder, using little-endian words for high-bit-depth video.
const _oracles = [
  (
    path: _tiled,
    depth: 8,
    subX: 1,
    subY: 1,
    lossless: false,
    crc: [
      [0x6186f027, 0xe394ce0c, 0xce2c98bd],
    ],
  ),
  (
    path: _lossless,
    depth: 8,
    subX: 1,
    subY: 1,
    lossless: true,
    crc: [
      [0x00dbdee7, 0x1384e754, 0xdfe97300],
      [0xccd66512, 0x50721733, 0x262dfd41],
    ],
  ),
  (
    path: _deep444,
    depth: 10,
    subX: 0,
    subY: 0,
    lossless: false,
    crc: [
      [0x1e7d6249, 0xb100cf7d, 0x1b0a2954],
      [0x8b781c80, 0x426f821b, 0x87ae576e],
    ],
  ),
  (
    path: _deep422,
    depth: 12,
    subX: 1,
    subY: 0,
    lossless: false,
    crc: [
      [0x1b8de6bf, 0x979c6654, 0xe3c3efdc],
      [0x49270509, 0x1ebc552d, 0x58a0f65b],
    ],
  ),
];

Future<void> main(List<String> arguments) async {
  for (final fixture in _oracles) {
    final video = Video(fixture.path);
    try {
      check(video.codec == 'vp9', '${fixture.path} codec');
      final packets = video.packets().toList();
      check(
        packets.length == fixture.crc.length,
        '${fixture.path} packet count',
      );
      check(
        video.packets(preview: true).length == packets.length,
        '${fixture.path} previews',
      );
      final decoder = Vp9Decoder();
      for (final (i, packet) in packets.indexed) {
        final picture = decoder.decodePacket(
          video.file.read(packet.offset, packet.size),
        )!;
        final header = picture.header;
        check(
          header.tag.key && header.lossless == fixture.lossless,
          'VP9 keyframe coding mode',
        );
        check(
          header.color.depth == fixture.depth &&
              header.color.subX == fixture.subX &&
              header.color.subY == fixture.subY,
          'VP9 sample layout',
        );
        if (fixture.path == _tiled) {
          check(
            header.tileColumnLog == 1 && header.tileRowLog == 0,
            'VP9 two tile columns',
          );
        }
        if (fixture.path == _deep422) {
          check(
            header.segmentation.enabled,
            'VP9 adaptive quantization segments',
          );
        }
        final direct = picture.rgb();
        check(
          _same(video.decode(packet).getBytes(), direct.getBytes()),
          '${fixture.path} video integration',
        );
        for (final (plane, samples) in [
          picture.y,
          picture.u,
          picture.v,
        ].indexed) {
          final sx = plane == 0 ? 0 : fixture.subX;
          final sy = plane == 0 ? 0 : fixture.subY;
          final width = (header.width + sx) >> sx;
          final height = (header.height + sy) >> sy;
          final bytes = BytesBuilder(copy: false);
          for (var y = 0; y < height; y++) {
            for (var x = 0; x < width; x++) {
              final sample = samples.samples[y * samples.stride + x];
              bytes.addByte(sample & 255);
              if (fixture.depth > 8) bytes.addByte(sample >> 8);
            }
          }
          final crc = getCrc32(bytes.takeBytes());
          check(
            crc == fixture.crc[i][plane],
            '${fixture.path} frame $i plane $plane',
          );
        }
      }
    } finally {
      video.close();
    }
  }
  _checkWebmPreview();
  final directory = Directory.systemTemp.createTempSync('vimg-vp9-');
  try {
    _checkSuperframes(directory);
    await _checkCli(directory, arguments.firstOrNull);
  } finally {
    directory.deleteSync(recursive: true);
  }
}

bool _same(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

void _checkWebmPreview() {
  final video = Video(_inter);
  try {
    check(video.metadata.streams.single.codec == 'vp9', 'VP9 WebM probe');
    final frames = video.packets().toList();
    final keys = video.packets(preview: true).toList();
    check(
      frames.length == 11 && keys.length == 3,
      'VP9 interframes excluded from the preview choices',
    );
    check(
      keys.map((p) => p.seconds).join(',') == '0.0,1.0,2.0',
      'VP9 keyframe times',
    );
    for (final packet in keys) {
      final preview = video.decode(packet, preview: true);
      check(
        preview.width == 72 && preview.height == 46,
        'VP9 WebM preview image',
      );
    }
  } finally {
    video.close();
  }
}

void _checkSuperframes(Directory directory) {
  final source = Video(_tiled);
  late final Uint8List hidden, ivfHeader, pixels;
  try {
    final packet = source.packets().single;
    final shown = source.file.read(packet.offset, packet.size);
    pixels = source.decode(packet).getBytes();
    hidden = Uint8List.fromList(shown)..[0] &= ~2;
    ivfHeader = Uint8List.fromList(source.file.read(0, 32));
    ByteData.sublistView(ivfHeader).setUint32(24, 3, Endian.little);
  } finally {
    source.close();
  }
  const existing = [0x8b]; // Profile 0 show-existing command for slot 3.
  const marker = 0xc9; // Two sizes, two little-endian bytes per size.
  final superframe = Uint8List.fromList([
    ...hidden,
    ...existing,
    marker,
    hidden.length & 255,
    hidden.length >> 8,
    1,
    0,
    marker,
  ]);
  final truncated = Uint8List.fromList(superframe)
    ..[superframe.length - 4] ^= 1;
  _formatError(() => Vp9Decoder().decodePacket(truncated), 'superframe');
  _formatError(
    () => Vp9Decoder().decodePacket(Uint8List.fromList(existing)),
    'display reference',
  );
  _formatError(
    () => Vp9FrameHeader.read(Uint8List.sublistView(hidden, 0, 4)),
    'header',
  );

  final path = '${directory.path}/superframe.ivf';
  final output = BytesBuilder(copy: false)..add(ivfHeader);
  for (final (index, data) in [hidden, existing, superframe].indexed) {
    final header = ByteData(12)
      ..setUint32(0, data.length, Endian.little)
      ..setUint64(4, index * 2, Endian.little);
    output
      ..add(header.buffer.asUint8List())
      ..add(data);
  }
  File(path).writeAsBytesSync(output.takeBytes());
  final video = Video(path);
  try {
    final packets = video.packets().toList();
    check(packets.length == 2, 'VP9 hidden IVF sample excluded from display');
    check(
      packets.first.seconds == 0 && packets.last.seconds == 0.4,
      'VP9 IVF display time origin',
    );
    check(video.metadata.duration == 0.8, 'VP9 IVF visible duration');
    check(
      video.packets(preview: true).single == packets.last,
      'VP9 superframe key preview',
    );
    check(
      _same(video.decode(packets.last, preview: true).getBytes(), pixels),
      'VP9 independently decodable superframe preview',
    );
    final frames = video.decodeSelected(packets).toList();
    check(frames.length == 2, 'VP9 two display pictures across the timeline');
    for (final frame in frames) {
      check(
        _same(frame.frame.getBytes(), pixels),
        'VP9 reused hidden reference pixels',
      );
    }
  } finally {
    video.close();
  }
}

void _formatError(void Function() action, String text) {
  try {
    action();
    throw StateError('Accepted invalid VP9 $text');
  } on FormatException catch (error) {
    check(error.message.contains(text), 'VP9 $text error');
  }
}

Future<void> _checkCli(Directory directory, String? executable) async {
  if (executable == null) return;
  Future<void> run(List<String> args) async {
    final result = await Process.run(executable, args);
    check(result.exitCode == 0, '$args failed: ${result.stderr}');
  }

  final jpg = '${directory.path}/preview.jpg';
  await run(['preview', '--output', jpg, '--skip', '50', _inter]);
  check(
    image.decodeJpg(File(jpg).readAsBytesSync())?.width == 72,
    'VP9 JPEG preview',
  );

  final frames = Directory('${directory.path}/extract');
  await run(['extract', '-n2', '-T2', '--output-dir', frames.path, _deep444]);
  final captures = frames.listSync().whereType<File>().toList();
  check(captures.length == 2, 'VP9 two BMP captures');
  for (final file in captures) {
    check(
      image.decodeBmp(file.readAsBytesSync())?.width == 226,
      'VP9 BMP width',
    );
  }

  final sheet = '${directory.path}/sheet.avif';
  await run([
    'vcs',
    '-c2',
    '-H22',
    '-n2',
    '-f1',
    '--vfilter',
    'hflip',
    '-o',
    sheet,
    _lossless,
  ]);
  check(File(sheet).lengthSync() > 16, 'VP9 filtered contact sheet');
}
