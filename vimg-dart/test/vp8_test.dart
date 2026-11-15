import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:image/image.dart' as image;
import 'package:vimg_dart/src/binary_file.dart';
import 'package:vimg_dart/src/ivf.dart';
import 'package:vimg_dart/src/video.dart';
import 'package:vimg_dart/src/vp8/decoder.dart';

import 'fixtures.dart';

const _ivf = 'test/fixtures/vp8-altref.ivf';
const _webm = 'test/fixtures/vp8-altref.webm';
const _avi = 'test/fixtures/vp8-altref.avi';
const _selected = [9, 17, 29, 43];

// FNV-1a over FFmpeg's cropped, planar 8-bit YUV in presentation order.
// dart format off
const _samples = [
  0xe95d8f9f, 0x1911400b, 0xe3e8f577, 0x93c4b050, 0xa881f3da, 0xa6fa7691,
  0x4434c937, 0x78174a08, 0x0726ff04, 0x0054f93c, 0x861a6109, 0x38a95188,
  0x86043067, 0x12c0cc59, 0xfb06b544, 0xcbc04100, 0x131612bb, 0xaba83d83,
  0x81fbed78, 0xb7591373, 0xf3553491, 0x02b641c9, 0x63f4427b, 0xae71032f,
  0x3d96437c, 0x8b8313c4, 0x8a2cdbcf, 0x82eac0bd, 0x7e403d99, 0x0a28d578,
  0xd102194f, 0x9e7ce0f4, 0xe6755c2b, 0x0dd0ae5f, 0xd3b7e4c4, 0x728e8728,
  0xe2a2435b, 0xa1743f1b, 0x77a04516, 0xe8b83635, 0xfe4286f1, 0xfd14bbcd,
  0x61019aec, 0x82cf7cf3, 0x24520864, 0xbce3490b, 0x76bc6f7a, 0x43d564d8,
];
// dart format on

Future<void> main(List<String> arguments) async {
  final temp = Directory.systemTemp.createTempSync('vimg-vp8-');
  try {
    final (rawFrames, frames) = _decodeReference();
    final mov = _quickTimeFixture(temp, rawFrames);
    for (final path in [_ivf, _webm, _avi, mov.path]) {
      await _checkVideo(path, frames);
    }
    if (arguments.firstOrNull case final executable?) {
      await _checkCli(temp, executable);
    }
  } finally {
    temp.deleteSync(recursive: true);
  }
}

(List<Uint8List>, Map<int, Uint8List>) _decodeReference() {
  final handle = File(_ivf).openSync();
  try {
    final file = BinaryFile(handle);
    final ivf = Ivf(file);
    final decoder = Vp8Decoder();
    final rawFrames = <Uint8List>[];
    final expected = <int, Uint8List>{};
    var shown = 0, hidden = 0;
    final visible = ivf
        .packets(
          false,
          onSample: (packet, sync) {
            final bytes = file.read(packet.offset, packet.size);
            rawFrames.add(bytes);
            final tag = vp8FrameTag(bytes);
            check(tag.key == sync, 'VP8 bitstream sync flag');
            final picture = decoder.decode(bytes);
            if (!tag.shown) {
              hidden++;
              return;
            }
            check(
              _hash(picture) == _samples[shown],
              'VP8 frame $shown matches FFmpeg YUV',
            );
            if (_selected.contains(shown)) {
              check(!tag.key, 'VP8 selected frame requires references');
              expected[shown] = picture.rgb().getBytes();
            }
            shown++;
          },
        )
        .toList();
    check(
      shown == 48 && hidden == 2 && visible.length == shown,
      'VP8 coded and visible pictures',
    );
    return (rawFrames, expected);
  } finally {
    handle.closeSync();
  }
}

int _hash(Vp8Picture picture) {
  var hash = 0x811c9dc5;
  for (final (index, plane) in [picture.y, picture.u, picture.v].indexed) {
    final width = index == 0 ? picture.width : (picture.width + 1) >> 1;
    final height = index == 0 ? picture.height : (picture.height + 1) >> 1;
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        hash =
            ((hash ^ plane.samples[y * plane.width + x]) * 0x1000193) &
            0xffffffff;
      }
    }
  }
  return hash;
}

Future<void> _checkVideo(String path, Map<int, Uint8List> expected) async {
  final video = Video(path);
  final workers = VideoCaptureDecoder(video, threads: 2);
  try {
    final stream = video.metadata.streams.single;
    check(
      stream.codec == 'vp8' && stream.width == 97 && stream.height == 67,
      '$path VP8 metadata',
    );
    final packets = video.packets().toList();
    check(packets.length == 48, '$path shown packet count');
    final keys = video.packets(preview: true).toList();
    check(
      keys.length == 2 &&
          keys.first == packets.first &&
          keys.every(
            (packet) => vp8FrameTag(video.file.read(packet.offset, 3)).key,
          ),
      '$path bitstream keyframe previews',
    );
    final preview = video.decode(keys.last, preview: true);
    check(preview.width == 97 && preview.height == 67, '$path preview size');
    final positions = {for (final (i, packet) in packets.indexed) packet: i};
    var captures = 0;
    await for (final frame in workers.decode([
      for (final i in _selected.reversed) packets[i],
    ])) {
      final index = positions[frame.packet]!;
      final bytes = frame.frame.getBytes();
      final reference = expected[index]!;
      check(bytes.length == reference.length, '$path frame $index size');
      for (var i = 0; i < bytes.length; i++) {
        check(bytes[i] == reference[i], '$path frame $index RGB byte $i');
      }
      captures++;
    }
    check(captures == _selected.length, '$path cross-GOP capture count');
  } finally {
    await workers.close();
    video.close();
  }
}

File _quickTimeFixture(Directory temp, List<Uint8List> frames) {
  // Deliberately omit stss so container sync defaults disagree with VP8.
  final ftyp = box('ftyp', ascii.encode('qt  '));
  List<int> table(String type, int entries, List<int> data) =>
      box(type, [...uint(0, 4), ...uint(entries, 4), ...data]);
  final duration = [
    ...List.filled(12, 0),
    ...uint(16, 4),
    ...uint(frames.length, 4),
  ];
  final description = box('vp08', [
    ...List.filled(24, 0),
    ...uint(97, 2),
    ...uint(67, 2),
    ...List.filled(50, 0),
  ]);
  final track = box(
    'trak',
    box('mdia', [
      ...box('hdlr', [...List.filled(8, 0), ...ascii.encode('vide')]),
      ...box('mdhd', duration),
      ...box(
        'minf',
        box('stbl', [
          ...table('stsd', 1, description),
          ...table('stts', 1, [...uint(frames.length, 4), ...uint(1, 4)]),
          ...table('stsc', 1, [
            ...uint(1, 4),
            ...uint(frames.length, 4),
            ...uint(1, 4),
          ]),
          ...table('stco', 1, uint(ftyp.length + 8, 4)),
          ...table('stsz', 0, [
            ...uint(frames.length, 4),
            for (final frame in frames) ...uint(frame.length, 4),
          ]),
        ]),
      ),
    ]),
  );
  return File('${temp.path}/vp8.mov')..writeAsBytesSync([
    ...ftyp,
    ...box('mdat', [for (final frame in frames) ...frame]),
    ...box('moov', [...box('mvhd', duration), ...track]),
  ]);
}

Future<void> _checkCli(Directory temp, String executable) async {
  Future<void> run(List<String> args) async {
    final result = await Process.run(executable, args);
    check(result.exitCode == 0, '${result.stderr}');
  }

  final jpeg = '${temp.path}/preview.jpg', sheet = '${temp.path}/sheet.avif';
  await run(['preview', '--output', jpeg, '--skip', '50', _webm]);
  check(
    image.decodeJpg(File(jpeg).readAsBytesSync())?.width == 97,
    'VP8 JPEG preview',
  );
  final destination = '${temp.path}/frames';
  await run(['extract', '-n4', '--output-dir', destination, _avi]);
  check(Directory(destination).listSync().length == 4, 'VP8 BMP extraction');
  await run([
    'vcs',
    '-c2',
    '-H32',
    '-n4',
    '-f3',
    '-t500ms',
    '-o',
    sheet,
    _webm,
  ]);
  check(
    ascii.decode(File(sheet).readAsBytesSync().sublist(4, 12)) == 'ftypavis',
    'VP8 AVIF contact sheet',
  );
}
