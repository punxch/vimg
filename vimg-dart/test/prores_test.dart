import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:image/image.dart' as image;
import 'package:vimg_dart/src/avif_animation.dart';
import 'package:vimg_dart/src/binary_file.dart';
import 'package:vimg_dart/src/iso_media.dart';
import 'package:vimg_dart/src/prores.dart';

import 'fixtures.dart';

const _fields = 'test/fixtures/prores-422-fields';
const _alpha = 'test/fixtures/prores-4444-alpha';

Future<void> main(List<String> arguments) async {
  // Synthetic moving 422 fields and a 4444 XQ color/alpha ramp, encoded with
  // prores_ks. The compressed reference files contain FFmpeg 8.1 raw planes.
  _checkPlanes(_fields, width: 146, height: 34, subsampling: 1, alphaDepth: 0);
  _checkPlanes(_alpha, width: 66, height: 34, subsampling: 0, alphaDepth: 16);
  await _checkCli(arguments.firstOrNull);
}

void _checkPlanes(
  String stem, {
  required int width,
  required int height,
  required int subsampling,
  required int alphaDepth,
}) {
  final handle = File('$stem.mov').openSync();
  try {
    final file = BinaryFile(handle);
    final expected = ByteData.sublistView(
      Uint8List.fromList(zlib.decode(File('$stem.yuv.z').readAsBytesSync())),
    );
    var offset = 0, frames = 0;
    for (final packet in isoFrames(IsoMedia(file))) {
      final bytes = file.read(packet.offset, packet.size);
      final picture = decodeProRes(bytes);
      check(
        picture.width == width && picture.height == height,
        'ProRes dimensions',
      );
      check(picture.subsamplingX == subsampling, 'ProRes chroma subsampling');
      check(
        picture.depth == (subsampling == 0 ? 12 : 10),
        'ProRes component depth',
      );
      check(picture.alphaDepth == alphaDepth, 'ProRes alpha depth');
      for (final plane in [picture.y, picture.cb, picture.cr]) {
        for (final sample in plane) {
          final reference = expected.getUint16(offset, Endian.little);
          if ((sample - reference).abs() > 1) {
            throw StateError('YUV sample differs at byte $offset of $stem');
          }
          offset += 2;
        }
      }
      if (picture.alpha case final alpha?) {
        for (final sample in alpha) {
          final reference = expected.getUint16(offset, Endian.little);
          if ((sample >> 4) != reference) {
            throw StateError('Alpha sample differs at byte $offset of $stem');
          }
          offset += 2;
        }
      }
      if (frames++ == 0) {
        // Matroska may store the same frame without its size and fourcc.
        final bare = decodeProRes(
          Uint8List.sublistView(bytes, 8),
          allowBareFrame: true,
        );
        _same(bare.y, picture.y, 'Headerless luma');
        _same(bare.cb, picture.cb, 'Headerless chroma');
        _same(bare.cr, picture.cr, 'Headerless chroma');
        if (picture.alpha case final alpha?)
          _same(bare.alpha!, alpha, 'Headerless alpha');
        _expectFormatError(
          () => decodeProRes(Uint8List.sublistView(bytes, 0, bytes.length - 1)),
        );
      }
    }
    check(
      frames == 4 && offset == expected.lengthInBytes,
      'ProRes oracle length',
    );
  } finally {
    handle.closeSync();
  }
}

Future<void> _checkCli(String? executable) async {
  final directory = Directory.systemTemp.createTempSync('vimg-prores-');
  Future<String> run(List<String> args) async {
    final result = await Process.run(
      executable ?? Platform.resolvedExecutable,
      [if (executable == null) 'bin/vimg.dart', ...args],
    );
    check(result.exitCode == 0, '$args: ${result.stderr}');
    return result.stdout as String;
  }

  try {
    const source = '$_alpha.mov';
    final preview = '${directory.path}/preview.jpg';
    final response =
        jsonDecode(
              await run([
                'preview',
                '--skip',
                '20',
                '--output',
                preview,
                source,
              ]),
            )
            as Map;
    check(response['preview_written'] == true, 'Native ProRes preview');
    check(response['streams'][0]['codec_name'] == 'prores', 'ProRes metadata');
    final jpeg = image.decodeJpg(File(preview).readAsBytesSync())!;
    check(jpeg.width == 66 && jpeg.height == 34, 'Preview dimensions');

    const capture = ['-n3', '-f2', '-t250ms'];
    final serial = '${directory.path}/serial';
    final parallel = '${directory.path}/parallel';
    for (final (output, threads) in [(serial, 1), (parallel, 4)]) {
      await run([
        'extract',
        ...capture,
        '-T$threads',
        '--output-dir',
        output,
        source,
      ]);
    }
    final frames = Directory(serial).listSync().cast<File>();
    check(frames.length == 6, 'ProRes capture count');
    for (final file in frames) {
      final bytes = file.readAsBytesSync();
      final other = File('$parallel/${file.uri.pathSegments.last}');
      _same(bytes, other.readAsBytesSync(), 'Parallel BMP including alpha');
      final bitmap = image.decodeBmp(bytes)!;
      check(bitmap.numChannels == 4, 'BMP retains ProRes alpha');
      check(
        bitmap.getPixel(0, 0).a != bitmap.getPixel(12, 12).a,
        'Alpha varies across pixels',
      );
    }

    final kept = '${directory.path}/kept';
    final grid = '${directory.path}/grid.avif';
    await run([
      'vcs',
      '-c2',
      '-H16',
      ...capture,
      '-T4',
      '--keep',
      '--output-dir',
      kept,
      '--vfilter',
      'crop=60:30:2:4,hflip,transpose=clock',
      '-o',
      grid,
      source,
    ]);
    final animation = AvifAnimation.open(grid);
    try {
      check(
        animation.width == 16 &&
            animation.height == 32 &&
            animation.frameCount == 2,
        'Filtered ProRes animated contact sheet',
      );
      check(
        animation.decodeFrames().length == 2,
        'Decode ProRes contact sheet',
      );
    } finally {
      animation.close();
    }
    for (final file in frames) {
      final original = image.decodeBmp(file.readAsBytesSync())!;
      final output = File('$kept/${file.uri.pathSegments.last}');
      final filtered = image.decodeBmp(output.readAsBytesSync())!;
      check(
        filtered.width == 30 && filtered.height == 60,
        'Kept capture dimensions',
      );
      for (final p in filtered) {
        final expected = original.getPixel(61 - p.y, 33 - p.x);
        check(
          p.r == expected.r &&
              p.g == expected.g &&
              p.b == expected.b &&
              p.a == expected.a,
          'Filtered kept capture at ${p.x},${p.y}',
        );
      }
    }

    final scaled = '${directory.path}/scaled';
    await run([
      'extract',
      ...capture,
      '-T4',
      '--output-dir',
      scaled,
      '--vfilter',
      'scale=132:68:flags=neighbor',
      source,
    ]);
    final file = frames.first;
    final original = image.decodeBmp(file.readAsBytesSync())!;
    final scaledFile = File('$scaled/${file.uri.pathSegments.last}');
    final enlarged = image.decodeBmp(scaledFile.readAsBytesSync())!;
    check(
      enlarged.width == 132 && enlarged.height == 68,
      'Filtered BMP dimensions',
    );
    for (final p in enlarged) {
      check(p.a == original.getPixel(p.x ~/ 2, p.y ~/ 2).a, 'Scaled BMP alpha');
    }
  } finally {
    directory.deleteSync(recursive: true);
  }
}

void _expectFormatError(void Function() action) {
  try {
    action();
  } on FormatException {
    return;
  }
  throw StateError('Accepted a truncated ProRes frame');
}

void _same(List<int> a, List<int> b, String label) {
  check(a.length == b.length, '$label length');
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) throw StateError('$label differs at $i');
  }
}
