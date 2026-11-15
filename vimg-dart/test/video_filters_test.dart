import 'dart:io';
import 'dart:typed_data';

import 'package:image/image.dart' as image;
import 'package:vimg_dart/src/yuv_image.dart';

import 'fixtures.dart';

Future<void> main(List<String> arguments) async {
  _checkRgb();
  _checkYuv();
  _checkErrors();
  await _checkCli(arguments.firstOrNull);
}

void _checkRgb() {
  final source = image.Image(width: 8, height: 6);
  for (final p in source) {
    p.setRgb(p.x * 17, p.y * 32, p.x * 5 + p.y * 7);
  }
  final filters = VideoFilterChain.parse(
    "crop=w='min(iw,6)':h=4:x=2:y=2,hflip,transpose=clock,"
    'scale=w=8:h=-2:flags=neighbor,vflip',
  );
  final frame = YuvImageScaler(filters: filters).filterRgb(source);
  check(frame.width == 8 && frame.height == 12, 'Filter chain dimensions');
  for (final p in frame) {
    final expected = source.getPixel(7 - (11 - p.y) ~/ 2, 5 - p.x ~/ 2);
    check(
      p.r == expected.r && p.g == expected.g && p.b == expected.b,
      'Ordered RGB filters at ${p.x},${p.y}',
    );
  }

  final passthrough = YuvImageScaler(
    filters: VideoFilterChain.parse('transpose=clock:passthrough=landscape'),
  ).filterRgb(source);
  _sameBytes(
    source.getBytes(),
    passthrough.getBytes(),
    'Transpose passthrough',
  );

  final constant = image.Image(width: 8, height: 6)
    ..clear(image.ColorRgb8(41, 129, 221));
  final scaled = YuvImageScaler(
    filters: VideoFilterChain.parse(r'scale=h=max(3\,5):w=0'),
  ).filterRgb(constant);
  check(scaled.width == 8 && scaled.height == 5, 'Escaped scale expression');
  for (final p in scaled) {
    check(p.r == 41 && p.g == 129 && p.b == 221, 'Bicubic preserves constants');
  }
}

void _checkYuv() {
  final y = Uint8List.fromList([
    for (var row = 0; row < 10; row++)
      for (var col = 0; col < 12; col++) 20 + 10 * row + col,
  ]);
  final chroma = Uint8List(6 * 5)..fillRange(0, 6 * 5, 128);
  image.Image filter(String chain) => yuvImage(
    y: y,
    cb: chroma,
    cr: chroma,
    stride: 12,
    chromaStride: 6,
    width: 8,
    height: 6,
    cropLeft: 2,
    cropTop: 2,
    matrix: 6,
    fullRange: true,
    scaler: YuvImageScaler(filters: VideoFilterChain.parse(chain)),
  );

  final aligned = filter('crop=5:3:3:1,transpose=cclock');
  // 4:2:0 crop dimensions and offsets align to even pixels by default.
  check(aligned.width == 2 && aligned.height == 4, 'Aligned crop dimensions');
  check(aligned.getPixel(0, 0).r == 47, 'Cropped transpose top-left sample');
  check(
    aligned.getPixel(1, 3).r == 54,
    'Cropped transpose bottom-right sample',
  );

  final exact = filter('crop=5:3:3:1:exact=1');
  check(exact.width == 5 && exact.height == 3, 'Exact odd crop');
  check(exact.getPixel(0, 0).r == 55, 'Exact crop sample');

  final deep = yuvImage(
    y: Uint16List(8 * 6)..fillRange(0, 8 * 6, 768),
    cb: const [],
    cr: const [],
    stride: 8,
    chromaStride: 0,
    width: 8,
    height: 6,
    cropLeft: 0,
    cropTop: 0,
    matrix: 6,
    fullRange: true,
    lumaDepth: 10,
    scaler: YuvImageScaler(filters: VideoFilterChain.parse('scale=4:3,hflip')),
  );
  check(deep.width == 4 && deep.height == 3, 'Scaled 10-bit dimensions');
  for (final p in deep) {
    check(p.r == 191 && p.g == 191 && p.b == 191, 'Scaled 10-bit intensity');
  }
}

void _checkErrors() {
  for (final chain in [
    '',
    'hflip=1',
    'hflip;vflip',
    '[in]crop=4:2[out]',
    "scale=w='min(4,2):h=2",
    'scale=4:2:flags=lanczos',
    'scale=w=iw-n:h=ih',
    'crop=5:2:w=4',
    'crop=iw-n:ih',
    'transpose=clock:passthrough=unknown',
    'reverse',
  ]) {
    _fails(() => VideoFilterChain.parse(chain), chain);
  }
  final source = image.Image(width: 8, height: 6);
  for (final chain in ['crop=9:5', 'scale=1/0:ih', 'scale=32768:32768']) {
    _fails(
      () => YuvImageScaler(
        filters: VideoFilterChain.parse(chain),
      ).filterRgb(source),
      chain,
    );
  }
}

Future<void> _checkCli(String? executable) async {
  final temp = Directory.systemTemp.createTempSync('vimg-filters-');
  Future<ProcessResult> run(List<String> args, {bool ok = true}) async {
    final result = await Process.run(
      executable ?? Platform.resolvedExecutable,
      [if (executable == null) 'bin/vimg.dart', ...args],
    );
    check((result.exitCode == 0) == ok, '$args: ${result.stderr}');
    return result;
  }

  try {
    const input = 'test/fixtures/cabac-b-spatial.mkv';
    const chain = 'crop=80:60:8:4,transpose=clock,hflip';
    final original = '${temp.path}/extract';
    final parallel = '${temp.path}/parallel';
    for (final (threads, directory) in [(1, original), (4, parallel)]) {
      await run([
        'extract',
        '-n4',
        '-f2',
        '-T$threads',
        '--output-dir',
        directory,
        '--vfilter',
        chain,
        input,
      ]);
    }
    final frames = Directory(original).listSync().cast<File>();
    check(frames.length == 8, 'Filtered extract count');
    for (final file in frames) {
      final bytes = file.readAsBytesSync();
      final frame = image.decodeBmp(bytes)!;
      check(frame.width == 60 && frame.height == 80, 'Filtered BMP dimensions');
      final other = File('$parallel/${file.uri.pathSegments.last}');
      _sameBytes(bytes, other.readAsBytesSync(), 'Filtered parallel BMP');
    }

    final captures = '${temp.path}/keep';
    final gridPath = '${temp.path}/grid.jpg';
    await run([
      'vcs',
      '-c2',
      '-H40',
      '-n4',
      '-T4',
      '--keep',
      '--output-dir',
      captures,
      '--vfilter',
      chain,
      '-o',
      gridPath,
      input,
    ]);
    final grid = image.decodeJpg(File(gridPath).readAsBytesSync())!;
    check(grid.width == 60 && grid.height == 80, 'Grid uses filtered aspect');
    final keptFiles = Directory(captures).listSync().cast<File>();
    check(keptFiles.length == 4, 'Filtered keep count');
    for (final file in keptFiles) {
      final kept = image.decodeBmp(file.readAsBytesSync())!;
      check(kept.width == 60 && kept.height == 80, 'Kept filtered tile');
    }

    final raw = aviFixture(temp, raw: true);
    final still = '${temp.path}/raw.jpg';
    final rawCaptures = '${temp.path}/raw-keep';
    await run([
      'vcs',
      '-c1',
      '-W6',
      '-n1',
      '--keep',
      '--output-dir',
      rawCaptures,
      '--vfilter',
      'transpose=clock',
      '-o',
      still,
      raw.path,
    ]);
    final rawGrid = image.decodeJpg(File(still).readAsBytesSync())!;
    check(
      rawGrid.width == 6 && rawGrid.height == 9,
      'RGB grid uses filtered aspect',
    );
    final kept = Directory(rawCaptures).listSync().cast<File>().single;
    final rawFrame = image.decodeBmp(kept.readAsBytesSync())!;
    check(rawFrame.width == 2 && rawFrame.height == 3, 'Kept RGB tile');

    // Four 32×24 BGR gradients at 4 fps, with RGB values (7x, 9y, 20i+2x+2y).
    const motion = 'test/fixtures/filter-motion.avi';
    const dynamicChain =
        "fps=8,crop=16:12:n*2:8*t,scale=w='16+2*if(isnan(n),0,n)'"
        ':h=12:flags=neighbor:eval=frame';
    const reference = [
      0xe0506b94,
      0xf5149408,
      0xa707d4dc,
      0x33c40a1f,
      0x1dc55a9b,
      0x59629a07,
      0x1485fd8b,
      0x76e84a9e,
    ];
    List<File> ordered(String path) =>
        Directory(path).listSync().cast<File>()
          ..sort((a, b) => a.path.compareTo(b.path));
    final dynamicPath = '${temp.path}/dynamic-extract';
    await run([
      'extract',
      '-n1',
      '-f8',
      '-t1s',
      '-T4',
      '--output-dir',
      dynamicPath,
      '--vfilter',
      dynamicChain,
      motion,
    ]);
    final dynamicFrames = ordered(dynamicPath);
    check(dynamicFrames.length == 8, 'Dynamic extract count');
    for (final (i, file) in dynamicFrames.indexed) {
      final frame = image.decodeBmp(file.readAsBytesSync())!;
      check(
        frame.width == 18 + 2 * i && frame.height == 12,
        'Dynamic scale size',
      );
      // FFmpeg 8 showinfo reports Adler-32 over BGR24, initialized at zero.
      var low = 0, high = 0;
      for (final pixel in frame) {
        for (final value in [pixel.b, pixel.g, pixel.r]) {
          low = (low + value.toInt()) % 65521;
          high = (high + low) % 65521;
        }
      }
      check((high << 16 | low) == reference[i], 'Dynamic frame $i pixels');
    }
    final dynamicKeep = '${temp.path}/dynamic-keep';
    await run([
      'vcs',
      '-c1',
      '-n1',
      '-f8',
      '-t1s',
      '-T1',
      '-H12',
      '--keep',
      '--output-dir',
      dynamicKeep,
      '--vfilter',
      dynamicChain,
      '-o',
      '${temp.path}/dynamic.avif',
      motion,
    ]);
    final keptDynamic = ordered(dynamicKeep);
    check(keptDynamic.length == 8, 'Dynamic keep count');
    for (final (i, file) in keptDynamic.indexed) {
      _sameBytes(
        file.readAsBytesSync(),
        dynamicFrames[i].readAsBytesSync(),
        'Kept dynamic frame $i',
      );
    }

    for (final (name, filter) in [
      ('before-fps', 'crop=16:12:n*2:8*t,fps=8'),
      ('retimed', 'fps=8,setpts=PTS+1,crop=16:12:n*2:8*t,setpts=PTS-1'),
    ]) {
      final folder = '${temp.path}/$name';
      await run([
        'extract',
        '-n1',
        '-f8',
        '-t1s',
        '--output-dir',
        folder,
        '--vfilter',
        filter,
        motion,
      ]);
      final outputs = ordered(folder);
      check(outputs.length == 8, '$name capture count');
      for (final (i, file) in outputs.indexed) {
        final frame = image.decodeBmp(file.readAsBytesSync())!;
        final x = name == 'before-fps' ? (i ~/ 2) * 2 : i * 2;
        final y = name == 'before-fps' ? (i ~/ 2) * 2 : i + 1;
        final first = frame.getPixel(0, 0);
        check(
          first.r == 7 * x &&
              first.g == 9 * y &&
              first.b == 20 * (i ~/ 2) + 2 * (x + y),
          '$name evaluates on its input timeline at frame $i',
        );
      }
    }

    final rejected = '${temp.path}/rejected';
    final result = await run([
      'extract',
      '-n1',
      '--output-dir',
      rejected,
      '--vfilter',
      'reverse',
      input,
    ], ok: false);
    check(
      (result.stderr as String).contains('Unsupported video filter: reverse') &&
          !Directory(rejected).existsSync(),
      'Reject unsupported filters before publishing',
    );
    final authority = await run([
      'authority',
      'record',
      '-c3',
      '-H160',
      '-n9',
      '-o',
      '${temp.path}/authority.avif',
      '--manifest',
      '${temp.path}/authority.json',
      '--vfilter',
      'hflip',
      input,
    ], ok: false);
    check(
      (authority.stderr as String).contains('fixed Preview profile'),
      'Authority rejects custom filters',
    );
  } finally {
    temp.deleteSync(recursive: true);
  }
}

void _fails(void Function() invoke, String label) {
  try {
    invoke();
  } on FormatException {
    return;
  }
  throw StateError('Accepted $label');
}

void _sameBytes(Uint8List a, Uint8List b, String label) {
  check(a.length == b.length, '$label length');
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) throw StateError('$label differs at byte $i');
  }
}
