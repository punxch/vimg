import 'dart:convert';
import 'dart:io';

import 'package:image/image.dart' as image;
import 'package:path/path.dart' as paths;
import 'package:vimg_dart/src/avif_animation.dart';
import 'package:vimg_dart/src/avif_encoder.dart';

import 'fixtures.dart';

Future<void> main(List<String> arguments) async {
  final temp = Directory.systemTemp.createTempSync('vimg-dart-authority-test-');
  Future<ProcessResult> run(List<String> options) => Process.run(
    arguments.firstOrNull ?? Platform.resolvedExecutable,
    [if (arguments.isEmpty) 'bin/vimg.dart', 'authority', ...options],
  );

  try {
    final input = File('test/fixtures/hevc-main.mkv').absolute.path;
    final output = paths.join(temp.path, 'video', 'preview.avif');
    final manifest = paths.join(temp.path, 'manifest', 'preview.json');
    final record = [
      'record',
      '-c3',
      '-H160',
      '-n9',
      '--output',
      output,
      '--manifest',
      manifest,
      input,
    ];
    for (final overrides in [
      ['--avif-preset', '8'],
      ['--avif-codec', 'libaom-av1'],
    ]) {
      final rejected = await run([...record, ...overrides]);
      check(
        rejected.exitCode != 0 &&
            (rejected.stderr as String).contains('fixed Preview profile'),
        'Authority rejects changes to its fixed encoder profile',
      );
    }
    final result = await run(record);
    check(result.exitCode == 0, 'Authority recording failed ${result.stderr}');
    final json = File(manifest).readAsStringSync();
    final document = jsonDecode(json) as Map<String, dynamic>;
    check(
      document['authority'] == 'production-dart-capture',
      'Authority provenance',
    );
    final selected = document['selected_frames'] as List;
    check(selected.length == 270, 'Authority selection count');
    for (final (i, frame) in selected.indexed) {
      check(
        frame['animation_index'] == i ~/ 9 &&
            frame['capture_index'] == i % 9 &&
            frame['source_time_base'] == '1/1000' &&
            frame['source_pts'] == frame['input_frame_index'] * 125,
        'Authority source PTS and display index',
      );
    }
    final animation = document['animation'] as Map<String, dynamic>;
    check(
      animation['frame_rate'] == '20/1' &&
          animation['duration_s'] == 1.5 &&
          animation['frame_count'] == 30 &&
          animation['stream_index'] == 1,
      'Authority animation timing',
    );
    File visual(String relative) =>
        File(paths.join(paths.dirname(manifest), relative));
    for (final kind in ['pre_encoder_visual_frames', 'decoded_visual_frames']) {
      final references = animation[kind] as List;
      check(references.length == 30, 'Authority PNG count');
      for (final path in references.cast<String>()) {
        check(
          paths.isRelative(path) && visual(path).existsSync(),
          'Authority PNG path',
        );
      }
    }
    final source = AvifAnimation.open(output);
    try {
      final decodedPaths = animation['decoded_visual_frames'] as List;
      for (final (i, frame) in source.decodeFrames().indexed) {
        final png = image.decodePng(visual(decodedPaths[i]).readAsBytesSync())!;
        check(
          png.width == frame.width &&
              png.height == frame.height &&
              png.getPixel(17, 27) == frame.getPixel(17, 27),
          'Decoded authority PNG matches its AVIF sample',
        );
      }
    } finally {
      source.close();
    }

    final before = File(output).readAsBytesSync();
    final first =
        (animation['pre_encoder_visual_frames'] as List).first as String;
    visual(first).writeAsStringSync('changed existing reference');
    final collision = await run(record);
    check(
      collision.exitCode != 0 &&
          (collision.stderr as String).contains('digest collision'),
      'Authority publication rejects a modified immutable generation',
    );
    check(
      File(manifest).readAsStringSync() == json,
      'Previous manifest retained',
    );
    final after = File(output).readAsBytesSync();
    check(
      after.length == before.length &&
          after.asMap().entries.every(
            (entry) => entry.value == before[entry.key],
          ),
      'Previous AVIF retained',
    );
    final bad = paths.join(temp.path, 'blocked.json');
    final foreign = Directory('$bad.frames')..createSync();
    final marker = File(paths.join(foreign.path, 'user.txt'))
      ..writeAsStringSync('keep');
    final refused = await run([
      'record',
      '-c3',
      '-H160',
      '-n9',
      '--output',
      output,
      '--manifest',
      bad,
      input,
    ]);
    check(
      refused.exitCode != 0 && marker.readAsStringSync() == 'keep',
      'Authority leaves unowned directories intact',
    );

    String sheet(String name, int red, {double fps = 20}) {
      final encoder = AvifEncoder(24, 24, fps: fps);
      for (final value in [40, red]) {
        final pixels = image.Image(width: 24, height: 24)
          ..clear(image.ColorRgb8(value, 85, 165));
        encoder.addFrame(pixels);
      }
      final file = File(paths.join(temp.path, name))
        ..writeAsBytesSync(encoder.finish());
      return file.path;
    }

    final left = sheet('left.avif', 40);
    final right = sheet('right.avif', 180);
    final identical = await run(['verify', left, left]);
    check(
      identical.exitCode == 0 &&
          (identical.stdout as String).contains('1.000000'),
      'Authority verifies identical visual frames',
    );
    final different = await run(['verify', left, right]);
    check(
      different.exitCode != 0 &&
          (different.stderr as String).contains('Frame 2 SSIM'),
      'Authority reports the individual frame below the threshold',
    );
    final accepted = await run(['verify', '--min-ssim', '0.75', left, right]);
    check(accepted.exitCode == 0, 'Authority honors the requested threshold');
    final structure = await run([
      'verify',
      left,
      sheet('fps.avif', 40, fps: 25),
    ]);
    check(
      structure.exitCode != 0 &&
          (structure.stderr as String).contains('Structural inspection failed'),
      'Authority checks frame rate before visual comparison',
    );
  } finally {
    temp.deleteSync(recursive: true);
  }
}
