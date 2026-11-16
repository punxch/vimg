import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:image/image.dart' as image;
import 'package:vimg_dart/src/yuv_image.dart';

import 'fixtures.dart';

Future<void> main(List<String> arguments) async {
  _checkRgb();
  _checkYuv();
  _checkLinearScale();
  _checkScaleAspect();
  _checkGraph();
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

  final rgba = image.Image(width: 8, height: 6, numChannels: 4);
  for (final p in rgba) {
    p.setRgba(
      p.x * 17,
      p.y * 32,
      p.x * 5 + p.y * 7,
      (p.x * 53 + p.y * 27) & 255,
    );
  }
  // FFmpeg 8.1.2 output in RGBA order for a 3×4 point resize.
  const subsampled = [
    (11, 3, 5, 53),
    (51, 8, 21, 213),
    (108, 0, 30, 62),
    (11, 67, 19, 107),
    (51, 72, 35, 10),
    (108, 61, 44, 116),
    (11, 99, 26, 135),
    (51, 104, 42, 37),
    (108, 93, 51, 144),
    (11, 163, 40, 189),
    (51, 168, 56, 91),
    (108, 157, 65, 198),
  ];
  const fullChroma = [
    (17, 0, 5, 53),
    (68, 0, 20, 213),
    (102, 0, 30, 62),
    (17, 64, 19, 107),
    (68, 64, 34, 10),
    (102, 64, 44, 116),
    (17, 96, 26, 135),
    (68, 96, 41, 37),
    (102, 96, 51, 144),
    (17, 160, 40, 189),
    (68, 160, 55, 91),
    (102, 160, 65, 198),
  ];
  for (final (filter, expected, flip) in [
    ('scale=3:4:flags=neighbor', subsampled, false),
    ('scale=3:4:flags=neighbor,hflip', subsampled, true),
    ('scale=3:4:flags=neighbor+full_chroma_inp', fullChroma, false),
  ]) {
    final output = YuvImageScaler(
      filters: VideoFilterChain.parse(filter),
    ).filterRgb(rgba);
    check(output.width == 3 && output.height == 4, 'RGBA resize dimensions');
    for (final p in output) {
      final i = p.y * output.width + (flip ? 2 - p.x : p.x);
      check(
        (p.r, p.g, p.b, p.a) == expected[i],
        '$filter sample ${p.x},${p.y}',
      );
    }
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

void _checkLinearScale() {
  int checksum(image.Image frame, image.ChannelOrder order) {
    var low = 0, high = 0;
    for (final sample in frame.getBytes(order: order)) {
      low = (low + sample) % 65521;
      high = (high + low) % 65521;
    }
    return high << 16 | low;
  }

  // FFmpeg 8.1.2 output for a packed RGBA gradient. Both sizes reduce the
  // source width by at least half, using paired source chroma and full alpha.
  final rgba = image.Image(width: 32, height: 24, numChannels: 4);
  for (final p in rgba) {
    p.setRgba(
      (13 * p.x + 7 * p.y) & 255,
      (5 * p.x + 19 * p.y) & 255,
      (27 * p.x + 13 * p.y) & 255,
      (43 * p.x + 29 * p.y) & 255,
    );
  }
  for (final (width, height, suffix, expected) in [
    (15, 11, '', 0x45204bdf),
    (16, 12, '', 0x6b318276),
    (16, 12, ',hflip', 0x8e9c8276),
  ]) {
    final filter = 'scale=$width:$height:flags=bilinear$suffix';
    final output = YuvImageScaler(
      filters: VideoFilterChain.parse(filter),
    ).filterRgb(rgba);
    check((output.width, output.height) == (width, height), filter);
    check(
      checksum(output, image.ChannelOrder.rgba) == expected,
      '$filter RGBA',
    );
  }

  Uint8List plane(int width, int height, int dx, int dy, int range) =>
      Uint8List.fromList([
        for (var y = 0; y < height; y++)
          for (var x = 0; x < width; x++) 16 + (x * dx + y * dy) % range,
      ]);
  final y = plane(32, 24, 13, 7, 220);
  final u = plane(16, 12, 5, 19, 225);
  final v = plane(16, 12, 27, 13, 225);
  List<int> samples(List<int> source, int depth) => depth == 8
      ? source
      : [for (final (i, value) in source.indexed) 4 * value + (i & 3)];
  image.Image filterYuv(String filter, int depth, {bool fullChroma = false}) =>
      yuvImage(
        y: samples(y, depth),
        cb: samples(fullChroma ? plane(32, 24, 5, 19, 225) : u, depth),
        cr: samples(fullChroma ? plane(32, 24, 27, 13, 225) : v, depth),
        stride: 32,
        chromaStride: fullChroma ? 32 : 16,
        width: 32,
        height: 24,
        cropLeft: 0,
        cropTop: 0,
        matrix: 6,
        fullRange: false,
        lumaDepth: depth,
        chromaDepth: depth,
        subsamplingX: fullChroma ? 0 : 1,
        subsamplingY: fullChroma ? 0 : 1,
        scaler: YuvImageScaler(filters: VideoFilterChain.parse(filter)),
      );
  for (final (flag, depth, expected) in [
    ('bilinear', 8, 0x77af208e),
    ('bicublin', 8, 0x22e81fdf),
    ('bilinear', 10, 0x5862215f),
    ('bilinear,hflip', 10, 0xfab41fd0),
    ('bicublin,hflip', 10, 0xa5da1ef7),
  ]) {
    final output = filterYuv('scale=16:12:flags=$flag', depth);
    check((output.width, output.height) == (16, 12), '$flag YUV dimensions');
    check(
      checksum(output, image.ChannelOrder.rgb) == expected,
      '$flag $depth-bit YUV pixels',
    );
  }

  // FFmpeg rgb24 after scale=15:11:flags=bilinear,format=yuv420p,hflip.
  final expected = base64Decode(
    '/6qU/Jlvr5NFVpAXCogAAG0AAFYA4cY5/7tB96kWoagAU58AAZoAAJQAAIMA/7G5/6CVy5lr'
    'dZc+J40SAHsAAFcAhIQH/8hh/7Y9v60RcqUAHaAAAJoAAIoA/5XX/6LT85eooZJ8U4pRBIQl'
    'AG4AGEoA+bRz/7566qlOnaEjRp4AAJcAAIcAtjqb/6r//5rn04y7foaPJoZkAHg5AEgOeXVQ'
    '/8iy/6eNyp5icZw3IpUMAIUAHw13snPm/6D//4j1p4XKUIOeB3lzAFxJA0U326Oy/6vH752d'
    'mppxSpNGEoMiAC2yOCzI/5H//4X/0IH/fX3iMHe1AGqIAEdbSTlr/6bv/6HZx5WtdY+COoBe'
    'AFTAAByrzVz//5H/9YP/q3n/W3TrBXHAAFuWAh9xxXbg/6n/8ZHpn4y+Y36aAIFeAEhRTiqB'
    '/6L//5D/2Hv/g3T/KXD/AGHYADG0OS3B/6f//5L/x4z6jX3VAKMDAHUAADkAs4ST/6z9/43/'
    'rIL/V3zwD27UAFHAACGqwGn//5X/7or/t3n/J64ABpAAAG8ANVMA/7Zy/7OB1alxg51nOI5m'
    'AHhmAEV0ZRO//4T//4r/43f/R7kAGKUAAJMAB1AAtlwA/9I68ccepLkbVacnCZY1AGFYSgCd'
    '/zj//5D//3z/',
  );
  final odd = filterYuv('scale=15:11:flags=bilinear,hflip', 8);
  check((odd.width, odd.height) == (15, 11), 'Odd-width filtered YUV');
  final actual = odd.getBytes(order: image.ChannelOrder.rgb);
  for (final (i, value) in actual.indexed) {
    check(
      (value - expected[i]).abs() <= 1,
      'Filtered odd-width RGB channel $i',
    );
  }
  final fullChroma = filterYuv(
    'scale=14:10:flags=bilinear',
    8,
    fullChroma: true,
  );
  check(
    checksum(fullChroma, image.ChannelOrder.rgb) == 0xfbd8d384,
    'Scaled 4:4:4 RGB pixels',
  );
}

void _checkScaleAspect() {
  final source = image.Image(width: 96, height: 64);
  final y = Uint8List(96 * 64);
  final chroma = Uint8List(48 * 32)..fillRange(0, 48 * 32, 128);
  final cases = [
    ('160:120:force_original_aspect_ratio=decrease', 160, 107),
    ('160:120:force_original_aspect_ratio=increase', 180, 120),
    ('157:117:force_original_aspect_ratio=1:force_divisible_by=8', 152, 104),
    ('157:117:force_original_aspect_ratio=2:force_divisible_by=8', 176, 120),
    (
      '157:117:force_original_aspect_ratio=decrease:force_divisible_by=8'
          ':reset_sar=1',
      152,
      80,
    ),
    (
      '157:117:force_original_aspect_ratio=increase:force_divisible_by=8'
          ':reset_sar=1',
      232,
      120,
    ),
    ('157:117:force_divisible_by=8:reset_sar=1', 157, 117),
    ('-4:117:reset_sar=1', 236, 117),
    ('157:-4:reset_sar=1', 157, 80),
    ('-4:-6:reset_sar=1', 128, 64),
    ('32:24:flags=neighbor:reset_sar=1,pad=aspect=1/1', 32, 32),
    ('32:24:flags=neighbor,pad=aspect=1/1', 32, 48),
    ('32:24:flags=neighbor:reset_sar=1,crop=trunc(16*sar):16', 16, 16),
    ('32:24:flags=neighbor,crop=trunc(16*sar):16', 24, 16),
  ];
  // Geometry measured with FFmpeg 8.1.2 for 96×64 input at SAR 4:3.
  for (final (options, width, height) in cases) {
    final scaler = YuvImageScaler(
      filters: VideoFilterChain.parse('scale=$options'),
    );
    final rgb = scaler.filterRgb(source, sampleAspect: 4 / 3);
    final yuv = yuvImage(
      y: y,
      cb: chroma,
      cr: chroma,
      stride: 96,
      chromaStride: 48,
      width: 96,
      height: 64,
      cropLeft: 0,
      cropTop: 0,
      matrix: 6,
      fullRange: true,
      sampleAspect: 4 / 3,
      scaler: scaler,
    );
    check((rgb.width, rgb.height) == (width, height), 'RGB scale=$options');
    check((yuv.width, yuv.height) == (width, height), 'YUV scale=$options');
  }

  final perFrame = YuvImageScaler(
    filters: VideoFilterChain.parse(
      'scale=w=160+n*8:h=120:eval=frame:reset_sar=1'
      ':force_original_aspect_ratio=decrease:force_divisible_by=8',
    ),
  );
  for (final (index, width) in [168, 176].indexed) {
    final frame = perFrame.renderCapture([
      (index: index, seconds: index / 2),
    ], () => perFrame.filterRgb(source, sampleAspect: 4 / 3));
    check((frame.width, frame.height) == (width, 88), 'Aspect with eval=frame');
  }
}

void _checkGraph() {
  final source = image.Image(width: 8, height: 6, numChannels: 4);
  for (final p in source) {
    p.setRgba(p.x * 29, p.y * 41, p.x * 13 + p.y * 11, p.x * 19 + p.y * 23);
  }
  const graph =
      '[middle]hflip@mirror[flipped]; '
      '[in]split=outputs=3[top][middle][lower]; '
      '[top][flipped]hstack[wide]; '
      '[lower]vflip,crop=8:3:0:0,split,hstack[bottom]; '
      '[wide][bottom]vstack=shortest=1[out]';
  final result = YuvImageScaler(
    filters: VideoFilterChain.parse(graph),
  ).filterRgb(source);
  check((result.width, result.height) == (16, 9), 'Nested stack dimensions');
  for (final p in result) {
    final expected = source.getPixel(
      p.y < 6 && p.x >= 8 ? 15 - p.x : p.x % 8,
      p.y < 6 ? p.y : 11 - p.y,
    );
    check(
      (p.r, p.g, p.b, p.a) == (expected.r, expected.g, expected.b, expected.a),
      'Nested stack RGBA pixel at ${p.x},${p.y}',
    );
  }
  const implicit = '[source]split[left],hflip[right]; [left][right]hstack';
  final top = YuvImageScaler(
    filters: VideoFilterChain.parse(implicit),
  ).filterRgb(source);
  _sameBytes(
    image.copyCrop(result, x: 0, y: 0, width: 16, height: 6).getBytes(),
    top.getBytes(),
    'Unlabelled split output connects to its next filter',
  );

  Uint16List samples(int width, int height, int bias) => Uint16List.fromList([
    for (var y = 0; y < height; y++)
      for (var x = 0; x < width; x++) bias + 23 * y + 37 * x,
  ]);
  final y = samples(8, 6, 120), u = samples(4, 3, 405), v = samples(4, 3, 480);
  Uint16List mirrorRows(Uint16List plane, int stride) => Uint16List.fromList([
    ...plane,
    for (var i = plane.length - stride; i >= 0; i -= stride)
      ...plane.sublist(i, i + stride),
  ]);
  image.Image render(
    List<int> y,
    List<int> u,
    List<int> v,
    int height, [
    String filter = 'null',
  ]) => yuvImage(
    y: y,
    cb: u,
    cr: v,
    stride: 8,
    chromaStride: 4,
    width: 8,
    height: height,
    cropLeft: 0,
    cropTop: 0,
    matrix: 6,
    fullRange: false,
    lumaDepth: 10,
    chromaDepth: 10,
    scaler: YuvImageScaler(filters: VideoFilterChain.parse(filter)),
  );
  final deep = render(y, u, v, 6, 'split[a][b];[b]vflip[c];[a][c]vstack');
  final expected = render(
    mirrorRows(y, 8),
    mirrorRows(u, 4),
    mirrorRows(v, 4),
    12,
  );
  _sameBytes(
    deep.getBytes(),
    expected.getBytes(),
    '10-bit stacked 4:2:0 planes',
  );
}

void _checkErrors() {
  for (final chain in [
    '',
    'hflip=1',
    'hflip;vflip',
    'split[a][a];[a]hflip',
    'split[a][b];[a]hflip',
    'split[a][b];[a]hstack',
    '[loop]split[loop][branch];split[a][b];[a][branch][b]hstack=3',
    'split[a][b];[a]trim=end_frame=2[c];[c][b]hstack',
    "scale=w='min(4,2):h=2",
    'scale=4:2:flags=lanczos',
    'scale=4:2:force_original_aspect_ratio=fit',
    'scale=4:2:force_divisible_by=0',
    'scale=4:2:force_divisible_by=257',
    'scale=4:2:reset_sar=2',
    'scale=w=iw-n:h=ih',
    'crop=5:2:w=4',
    'crop=iw-n:ih',
    'transpose=clock:passthrough=unknown',
    'reverse',
  ]) {
    _fails(() => VideoFilterChain.parse(chain), chain);
  }
  final source = image.Image(width: 8, height: 6);
  for (final chain in [
    'crop=9:5',
    'scale=1/0:ih',
    'scale=32768:32768',
    'split[a][b];[a]crop=8:4[c];[c][b]hstack',
    'split[a][b];[a]crop=6:6[c];[c][b]vstack',
  ]) {
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

    const graph =
        'fps=8,split[left][right];'
        '[left]crop=16:12:n*2:8*t[moving];'
        '[right]crop=16:12:0:0,hflip[fixed];'
        '[moving][fixed]hstack,trim=end_frame=8';
    // FFmpeg BGR24 output with the same graph and source rate.
    const graphReference = [
      0x913ac000,
      0x9317d5c0,
      0x45f0098f,
      0x47cd1f4f,
      0xfa97530f,
      0xfc7468cf,
      0xaf4d9c8f,
      0xb12ab24f,
    ];
    final graphSheet = File('${temp.path}/branch.avif');
    for (final command in ['extract', 'vcs']) {
      final folder = '${temp.path}/branch-$command';
      await run([
        command,
        '-n1',
        '-f8',
        '-t1s',
        '-T4',
        if (command == 'vcs') ...[
          '-c1',
          '-H12',
          '--keep',
          '-o',
          graphSheet.path,
        ],
        '--output-dir',
        folder,
        '--vfilter',
        graph,
        motion,
      ]);
      final outputs = ordered(folder);
      check(outputs.length == graphReference.length, '$command branch frames');
      for (final (index, file) in outputs.indexed) {
        final frame = image.decodeBmp(file.readAsBytesSync())!;
        check(
          frame.width == 32 &&
              frame.height == 12 &&
              _bgrChecksum(frame) == graphReference[index],
          '$command branch frame $index matches FFmpeg',
        );
      }
    }
    check(
      ascii.decode(graphSheet.readAsBytesSync().sublist(4, 12)) == 'ftypavis',
      'Branched graph produces an animated contact sheet',
    );

    final fitted = '${temp.path}/fitted';
    await run([
      'extract',
      '-n1',
      '-f4',
      '-t1s',
      '--output-dir',
      fitted,
      '--vfilter',
      'setsar=4/3,scale=50:39:force_original_aspect_ratio=decrease'
          ':force_divisible_by=2:reset_sar=1:flags=neighbor,pad=aspect=1/1',
      motion,
    ]);
    final fittedFrames = ordered(fitted);
    const fittedReference = [0xa66cb24b, 0xf2b81fba, 0x3f138d1a, 0x8b5ffa7a];
    check(
      fittedFrames.length == fittedReference.length,
      'Fitted capture count',
    );
    for (final (i, file) in fittedFrames.indexed) {
      final frame = image.decodeBmp(file.readAsBytesSync())!;
      check(
        (frame.width, frame.height) == (50, 50),
        'Square output dimensions',
      );
      check(
        _bgrChecksum(frame) == fittedReference[i],
        'Fitted frame $i pixels',
      );
    }

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
      check(_bgrChecksum(frame) == reference[i], 'Dynamic frame $i pixels');
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

    const timedShrink =
        "fps=8,scale=w=16:h='12+if(isnan(t),0,8*t)':flags=neighbor:eval=frame";
    const shrinkReference = [
      0x1740ce40,
      0xbc05db50,
      0x4bbbfca0,
      0x411f107f,
      0x6756358f,
      0xf50c488f,
      0x57ea70af,
      0x3e3a86ff,
    ];
    final shrink = '${temp.path}/shrink';
    await run([
      'extract',
      '-n1',
      '-f8',
      '-t1s',
      '--output-dir',
      shrink,
      '--vfilter',
      timedShrink,
      motion,
    ]);
    final reduced = ordered(shrink);
    check(reduced.length == 8, 'Downscale capture count');
    for (final (i, file) in reduced.indexed) {
      final frame = image.decodeBmp(file.readAsBytesSync())!;
      check(
        frame.width == 16 &&
            frame.height == 12 + i &&
            _bgrChecksum(frame) == shrinkReference[i],
        'Downscaled frame $i',
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

// FFmpeg showinfo uses Adler-32 over BGR24, initialized at zero.
int _bgrChecksum(image.Image frame) {
  var low = 0, high = 0;
  for (final pixel in frame) {
    for (final value in [pixel.b, pixel.g, pixel.r]) {
      low = (low + value.toInt()) % 65521;
      high = (high + low) % 65521;
    }
  }
  return high << 16 | low;
}
