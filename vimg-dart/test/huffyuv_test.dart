import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:image/image.dart' as image;
import 'package:vimg_dart/src/avi.dart';
import 'package:vimg_dart/src/binary_file.dart';
import 'package:vimg_dart/src/huffyuv.dart';
import 'package:vimg_dart/src/matroska.dart';
import 'package:vimg_dart/src/video.dart';
import 'package:vimg_dart/src/video_configuration.dart';
import 'package:vimg_dart/src/yuv_image.dart';

import 'fixtures.dart';

// FNV-1a hashes of FFmpeg's native decoded samples. Packed RGB uses
// RGB(A) byte order. High-depth planar samples use little-endian words.
const _hashes = {
  'alpha.avi': [0xb524a52f, 0xe1cfe23e, 0xd28a7c84, 0xa1c6e9f2],
  'classic.avi': [0x3ccd3cde, 0xeddab431, 0xa9c36844, 0xb72ff0af],
  'ff-argb.avi': [0x27036519, 0x3d55aa4d, 0x9a196b75, 0xbbc44e05],
  'ff-gbr.avi': [0x1a6cf949, 0x514add7d, 0x01414ea5, 0xabafcf35],
  'ff-gray.avi': [0x85fad639, 0x61f6e5e5, 0x8d1532f1, 0x04968f5d],
  'ff-yuv10.avi': [0xace41ef2, 0xd28e3b63, 0x1f9b5d9e, 0x938cfede],
  'ff-yuv10.mkv': [0xace41ef2, 0xd28e3b63, 0x1f9b5d9e, 0x938cfede],
  'odd.avi': [0xfe76d5b4, 0xc565ad21, 0xb7000292, 0xb0919f7d],
  'packed420-median.avi': [0x0e65b17b, 0xe76234bf, 0x60384706, 0x9a4dc5d3],
  'packed420-plane.avi': [0xaed5c77e, 0x27617bf7, 0xacb61980, 0x0a295765],
  'rand16.avi': [0xe6b66158, 0x7a44f7b2, 0xad6baa65, 0x6c6a7262],
  'rgb-left.avi': [0xb245ce75, 0xe8202319, 0x297e4fa1, 0x9974e299],
  'rgb-plane.avi': [0xb245ce75, 0xe8202319, 0x297e4fa1, 0x9974e299],
  'yuv-left.avi': [0x99044125, 0xb46e6331, 0x22f427e1, 0x6e803cc1],
  'yuv-median-fields.avi': [0x99044125, 0xb46e6331, 0x22f427e1, 0x6e803cc1],
  'yuv-median.avi': [0x99044125, 0xb46e6331, 0x22f427e1, 0x6e803cc1],
  'yuv-plane.mkv': [0x99044125, 0xb46e6331, 0x22f427e1, 0x6e803cc1],
  'mt-alpha-sliced.avi': [0xc531e081, 0x4e80e5b5, 0x60837a45, 0xc467ef85],
  'mt-no-dir.avi': [0x3ccd3cde, 0xeddab431, 0xa9c36844, 0xb72ff0af],
  'mt-rgb-partial.avi': [0xe66cd7aa, 0xd9be6e25, 0xd3780bb1, 0x4c4ceeb9],
  'mt-rgb-sliced.avi': [0xec8c4cea, 0xb120ffe5, 0x91c71e71, 0x863ec179],
  'mt-rgb-sliced.mkv': [0xec8c4cea, 0xb120ffe5, 0x91c71e71, 0x863ec179],
  'mt-single-dir.avi': [0xb245ce75, 0xe8202319, 0x297e4fa1, 0x9974e299],
  'mt-yuv-plane.avi': [0x21f4eab6, 0x30dd1644, 0x7f6efa6a, 0x3d4a880a],
  // Assemble the independently decoded bands for median prediction.
  'mt-yuv-median.avi': [0x21f4eab6, 0x30dd1644, 0x7f6efa6a, 0x3d4a880a],
  // These reference planes come from the generator's sample values.
  'mt-context.avi': [0x599f2c05, 0x98288325, 0xd7a165c5, 0x33a5a325],
};

Future<void> main(List<String> arguments) async {
  for (final entry in _hashes.entries) {
    await _checkVideo(entry.key, entry.value);
  }
  _checkMalformed();
  _checkMalformedSlices();
  await _checkCli(arguments.firstOrNull);
}

Future<void> _checkVideo(String name, List<int> hashes) async {
  final path = 'test/fixtures/huffyuv-$name';
  final input = File(path).openSync();
  final video = Video(path);
  final workers = VideoCaptureDecoder(video, threads: 3, includeOriginal: true);
  try {
    final container = BinaryFile(input);
    final codec = name.startsWith('mt-')
        ? 'hymt'
        : (name.startsWith('ff-') ||
              name.startsWith('rand16') ||
              name.startsWith('odd'))
        ? 'ffvhuff'
        : 'huffyuv';
    check(video.codec == codec, '$name codec');
    final decoder = name.endsWith('.avi')
        ? Avi(container).huffYuvDecoder()!
        : matroskaHuffYuvConfiguration(Matroska(container), codec)!;
    final frames = video.packets().toList();
    check(frames.length == hashes.length, '$name frame count');
    check(
      video.packets(preview: true).length == frames.length,
      '$name intra frames',
    );
    final rendered = <int, int>{};
    for (final (i, packet) in frames.indexed) {
      check((packet.seconds - i * .25).abs() < 1e-9, '$name frame time');
      final picture = decoder.decode(
        container.read(packet.offset, packet.size),
      );
      final packed =
          name.contains('rgb-') ||
          name.contains('alpha') ||
          name.startsWith('mt-single-dir');
      final raw = packed ? picture.rgb().getBytes() : _planes(picture);
      check(_hash(raw) == hashes[i], '$name native samples at frame $i');
      final rgb = video.decode(packet);
      check(rgb.hasAlpha == picture.hasAlpha, '$name source alpha');
      final renderHash = _hash(rgb.getBytes());
      check(
        renderHash == _hash(picture.rgb().getBytes()),
        '$name direct decode',
      );
      rendered[packet.offset] = renderHash;
    }
    await for (final result in workers.decode(frames.reversed)) {
      final expected = rendered.remove(result.packet.offset);
      check(_hash(result.frame.getBytes()) == expected, '$name parallel frame');
      check(_hash(result.original!.getBytes()) == expected, '$name original');
    }
    check(rendered.isEmpty, '$name parallel frame count');

    if (name == 'ff-yuv10.mkv') {
      final selected = frames.last;
      final picture = decoder.decode(
        container.read(selected.offset, selected.size),
      );
      final scaler = YuvImageScaler(
        filters: VideoFilterChain.parse('crop=10:8:2:2,negate=components=y'),
      );
      final filtered = video
          .decodeSelected([selected], scaler: scaler)
          .single
          .frame;
      check(
        filtered.width == 10 && filtered.height == 8,
        'HuffYUV plane filters',
      );
      check(
        _hash(filtered.getBytes()) ==
            _hash(picture.rgb(scaler: scaler).getBytes()),
        'HuffYUV capture filters run on native components',
      );
    }
  } finally {
    await workers.close();
    video.close();
    input.closeSync();
  }
}

Iterable<int> _planes(HuffYuvPicture picture) sync* {
  for (final plane in picture.planes) {
    for (final value in plane) {
      yield value & 255;
      if (picture.depth > 8) yield value >> 8;
    }
  }
}

int _hash(Iterable<int> bytes) {
  var hash = 0x811c9dc5;
  for (final byte in bytes) {
    hash = ((hash ^ byte) * 0x01000193) & 0xffffffff;
  }
  return hash;
}

void _rejects(void Function() read, String reason) {
  try {
    read();
    throw StateError('Accepted malformed HuffYUV: $reason');
  } on FormatException catch (error) {
    check(error.message == reason, reason);
  }
}

void _checkMalformed() {
  _rejects(
    () => HuffYuvDecoder(4, 4, 16, Uint8List.fromList([0, 16, 32, 0, 8, 0])),
    'Invalid HuffYUV Huffman table run',
  );
  _rejects(
    () => HuffYuvDecoder(
      4,
      4,
      16,
      Uint8List.fromList([0, 16, 32, 0, 0, 255, 32]),
    ),
    'Invalid HuffYUV Huffman lengths',
  );
  final decoder = HuffYuvDecoder(4, 4, 16, Uint8List(0));
  _rejects(() => decoder.decode(Uint8List(3)), 'Invalid HuffYUV frame size');
  _rejects(
    () => decoder.decode(Uint8List(4)),
    'Truncated HuffYUV residual data',
  );
}

void _checkMalformedSlices() {
  const path = 'test/fixtures/huffyuv-mt-rgb-sliced.avi';
  final input = File(path).openSync();
  try {
    final file = BinaryFile(input);
    final avi = Avi(file);
    final decoder = avi.huffYuvDecoder()!;
    final packet = avi.packets().first;
    final original = file.read(packet.offset, packet.size);
    final size = original.length;
    final originalData = ByteData.sublistView(original);
    final directory = originalData.getUint32(size - 4, Endian.little);
    final firstSlice = originalData.getUint32(directory, Endian.little);
    final expected = _hashes['mt-rgb-sliced.avi']!.first;

    for (final (offset, value, message) in [
      (size - 12, 0, 'Invalid HuffYUV MT slice table'),
      (size - 8, 0, 'Invalid HuffYUV MT slice table'),
      (size - 4, size - 12, 'Invalid HuffYUV MT slice table'),
      (directory, firstSlice + 1, 'Invalid HuffYUV MT slice range'),
      (directory + 4, 0, 'Invalid HuffYUV MT slice range'),
      (directory + 4, directory + 4, 'Invalid HuffYUV MT slice range'),
      (directory + 8, firstSlice, 'Overlapping HuffYUV MT slices'),
      (directory + 4, 4, 'Truncated HuffYUV residual data'),
    ]) {
      final copy = Uint8List.fromList(original);
      ByteData.sublistView(copy).setUint32(offset, value, Endian.little);
      _rejects(() => decoder.decode(copy), message);
      check(
        _hash(decoder.decode(original).rgb().getBytes()) == expected,
        'A rejected slice leaves later decodes intact',
      );
    }
  } finally {
    input.closeSync();
  }
}

Future<void> _checkCli(String? executable) async {
  final directory = Directory.systemTemp.createTempSync('vimg-huffyuv-');
  Future<void> run(List<String> args) async {
    final result = await Process.run(
      executable ?? Platform.resolvedExecutable,
      [if (executable == null) 'bin/vimg.dart', ...args],
    );
    check(result.exitCode == 0, '${result.stderr}');
  }

  try {
    final preview = '${directory.path}/preview.jpg';
    await run([
      'preview',
      '--output',
      preview,
      'test/fixtures/huffyuv-mt-alpha-sliced.avi',
    ]);
    check(
      image.decodeJpg(File(preview).readAsBytesSync())?.width == 20,
      'HuffYUV JPEG preview',
    );

    final frames = Directory('${directory.path}/frames')..createSync();
    await run([
      'extract',
      '-n1',
      '--output-dir',
      frames.path,
      'test/fixtures/huffyuv-mt-alpha-sliced.avi',
    ]);
    final bmp = image.decodeBmp(
      frames.listSync().whereType<File>().first.readAsBytesSync(),
    )!;
    check(
      bmp.hasAlpha &&
          _hash(bmp.getBytes()) == _hashes['mt-alpha-sliced.avi']!.first,
      'HuffYUV BMP alpha',
    );

    final sheet = '${directory.path}/sheet.avif';
    await run([
      'vcs',
      '-c2',
      '-H16',
      '-n2',
      '-f2',
      '-t500ms',
      '-T3',
      '-o',
      sheet,
      'test/fixtures/huffyuv-mt-rgb-sliced.mkv',
    ]);
    check(
      ascii.decode(File(sheet).readAsBytesSync().sublist(4, 12)) == 'ftypavis',
      'HuffYUV MT animated AVIF',
    );
  } finally {
    directory.deleteSync(recursive: true);
  }
}
