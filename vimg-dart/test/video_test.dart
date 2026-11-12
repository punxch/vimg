import 'dart:convert';
import 'dart:io';

import 'package:image/image.dart' as image;

import 'fixtures.dart';

Future<void> main(List<String> arguments) async {
  final temp = Directory.systemTemp.createTempSync('vimg-dart-video-test-');
  Future<ProcessResult> run(List<String> args, {bool ok = true}) async {
    final executable = arguments.firstOrNull ?? Platform.resolvedExecutable;
    final result = await Process.run(executable, [
      if (arguments.isEmpty) 'bin/vimg.dart',
      ...args,
    ]);
    check((result.exitCode == 0) == ok, '$args failed: ${result.stderr}');
    return result;
  }

  try {
    final mkv = matroskaFixture(temp);
    final mov = isoFixture(temp);
    final webm = matroskaFixture(temp, vp8: true);
    final jpeg = File('${temp.path}/preview.cache');
    for (final source in [mkv, mov, webm]) {
      final result = await run([
        'preview',
        '--output',
        jpeg.path,
        '--max-width',
        '16',
        '--max-height',
        '12',
        '--skip',
        '20',
        '--timings',
        source.path,
      ]);
      final json = jsonDecode(result.stdout as String) as Map;
      check(json['preview_written'] == true, 'Preview response: $json');
      check(
        (result.stderr as String).startsWith('vimg-preview-timing '),
        'Preview timing',
      );
      final preview = image.decodeJpg(jpeg.readAsBytesSync())!;
      check(preview.width == 16 && preview.height == 12, 'Preview bounds');
      check(
        preview.getPixel(0, 0).b > 200,
        'Preview selected the 2-second frame',
      );
    }
    final upper = await run([
      'preview',
      '--output',
      jpeg.path,
      '--skip',
      '91',
      mov.path,
    ]);
    final limit = jsonDecode(upper.stdout as String) as Map;
    check(
      limit['preview_upper_bound'] == 90 && limit['preview_written'] == false,
      'Preview limit',
    );

    final extracted = Directory('${temp.path}/frames');
    await run([
      'extract',
      '-n2',
      '-f2',
      '-t2s',
      '--output-dir',
      extracted.path,
      mov.path,
    ]);
    check(extracted.listSync().length == 4, 'Extracted four frames');
    final bmp = image.decodeBmp(
      File('${extracted.path}/video-2s-1.bmp').readAsBytesSync(),
    )!;
    check(bmp.getPixel(0, 0).b > 200, 'Extracted the 2-second frame');

    final sheet = File('${temp.path}/grid.webp');
    await run([
      'vcs',
      '-c2',
      '-H24',
      '-n2',
      '-f2',
      '-t2s',
      '--webp',
      '1',
      mkv.path,
      '-o',
      sheet.path,
    ]);
    final decoded = image.decodeWebP(sheet.readAsBytesSync())!;
    check(
      decoded.width == 64 && decoded.height == 24 && decoded.numFrames == 2,
      'Animated grid layout',
    );
    check(
      decoded.frames.every((frame) => frame.frameDuration == 50),
      'Animation frame durations',
    );
    check(
      decoded.frames.first.getPixel(0, 0).b > 190 &&
          decoded.frames.last.getPixel(0, 0).r > 190,
      'Distinct sampled frames',
    );

    final still = File('${temp.path}/grid.jpg');
    await run(['vcs', '-c2', '-W16', '-n2', mov.path, '-o', still.path]);
    check(
      image.decodeJpg(still.readAsBytesSync())!.width == 32,
      'Static grid layout',
    );

    final avif = File('${temp.path}/grid.avif');
    final unsupported = await run([
      'vcs',
      '-c2',
      '-H24',
      '-n2',
      mkv.path,
      '-o',
      avif.path,
    ], ok: false);
    check(
      (unsupported.stderr as String).contains('AVIF') && !avif.existsSync(),
      'Explicit AVIF limitation',
    );
  } finally {
    temp.deleteSync(recursive: true);
  }
}
