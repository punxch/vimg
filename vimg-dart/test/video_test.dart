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
    final avi = aviFixture(temp);
    final raw = aviFixture(temp, raw: true);
    final jpeg = File('${temp.path}/preview.cache');
    for (final source in [mkv, mov, webm, avi]) {
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
    final rawProbe = await run(['probe', raw.path]);
    final rawMetadata = jsonDecode(rawProbe.stdout as String) as Map;
    check(
      rawMetadata['streams'][0]['codec_name'] == 'rawvideo',
      'AVI raw video metadata',
    );
    final rawOutput = Directory('${temp.path}/raw');
    await run(['extract', '-n1', '--output-dir', rawOutput.path, raw.path]);
    final rawFrame = image.decodeBmp(
      (rawOutput.listSync().single as File).readAsBytesSync(),
    )!;
    check(
      rawFrame.width == 3 &&
          rawFrame.height == 2 &&
          rawFrame.getPixel(2, 0).r == 255 &&
          rawFrame.getPixel(2, 1).b == 255,
      'AVI BGR pixels, bottom-up rows and alignment',
    );

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

    final sheet = File('${temp.path}/webp-grid.avif');
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
    await run([
      'vcs',
      '-c2',
      '-W16',
      '-n2',
      '--webp',
      '1',
      mov.path,
      '-o',
      still.path,
    ]);
    check(
      image.decodeJpg(still.readAsBytesSync())!.width == 32,
      'Static grid layout',
    );

    final avif = File('${temp.path}/grid.avif');
    final gridArgs = ['vcs', '-c2', '-H24', '-n2', '-f2', mkv.path];
    await run([...gridArgs, '-T0', '-o', avif.path]);
    check(
      ascii.decode(avif.readAsBytesSync().sublist(4, 12)) == 'ftypavis',
      'Default VCS format is an AVIF image sequence',
    );
    final serial = File('${temp.path}/grid-serial.cache');
    await run([...gridArgs, '--threads', '1', '-o', serial.path]);
    check(
      base64Encode(avif.readAsBytesSync()) ==
          base64Encode(serial.readAsBytesSync()),
      'Serial and automatic-thread MJPEG grids are identical',
    );
    for (final codec in ['dart', 'libsvtav1', 'libaom-av1']) {
      await run([
        ...gridArgs,
        '--avif-codec',
        codec,
        '--avif-preset',
        '8',
        '-o',
        serial.path,
      ]);
      check(
        base64Encode(avif.readAsBytesSync()) ==
            base64Encode(serial.readAsBytesSync()),
        'Codec alias $codec uses the Dart encoder',
      );
    }
    final invalidPreset = await run([
      ...gridArgs,
      '--avif-preset',
      '14',
      '-o',
      serial.path,
    ], ok: false);
    check(
      (invalidPreset.stderr as String).contains('--avif-preset'),
      'Reject an AVIF preset outside the supported range',
    );

    final avifStill = File('${temp.path}/grid-still.avif');
    await run([
      'vcs',
      '-c2',
      '-H24',
      '-n2',
      '-f1',
      '--avif-crf',
      '42',
      '--avif-preset',
      '4',
      mkv.path,
      '-o',
      avifStill.path,
    ]);
    check(
      ascii.decode(avifStill.readAsBytesSync().sublist(4, 12)) == 'ftypavif',
      'VCS uses the AVIF still format with a custom CRF and preset',
    );
  } finally {
    temp.deleteSync(recursive: true);
  }
}
