import 'dart:io';

import 'package:archive/archive.dart';
import 'package:image/image.dart' as image;
import 'package:vimg_dart/src/capture.dart';
import 'package:vimg_dart/src/video_commands.dart';
import 'package:vimg_dart/src/yuv_image.dart';

import 'fixtures.dart';

const _motion = 'test/fixtures/filter-motion.avi';
const _original = [0x02858573, 0xc98c1c3f, 0x650f8dd9, 0x2067da59];
const _fileFrames = [0x1bfe4145, 0x02a4a92e, 0x108d02de, 0x8a4adaa6];

List<int> _twice(List<int> frames) => [
  for (final frame in frames) ...[frame, frame],
];

Future<void> main(List<String> args) async {
  for (final invalid in [
    'sendcmd',
    "sendcmd=c='0 hflip enable 1':f=commands",
    "sendcmd='0-0.5 [sometime] hflip enable 1',hflip",
    "sendcmd='0.5-0 hflip enable 1',hflip",
    "sendcmd='0 hflip',hflip",
  ]) {
    try {
      VideoFilterChain.parse(invalid);
    } on FormatException {
      continue;
    }
    throw StateError('Accepted invalid sendcmd specification $invalid');
  }

  final temp = Directory.systemTemp.createTempSync('vimg-sendcmd-');
  try {
    final cli = args.firstOrNull ?? Platform.resolvedExecutable;
    final alpha = aviFixture(temp, rgba: true).path;
    final script = File('${temp.path}/alpha commands.txt')
      ..writeAsStringSync('''
# The sender sees a 32 × 24 frame before crop.
0-0.75 [expr] vflip@v enable 'eq(mod(N,2),0)*eq(W,32)*eq(H,24)+gt(TI,0.6)*eq(PTS,2)';
0.75 vflip@v enable 'eq(n,3)';
''');
    final fromFile =
        "sendcmd=f='${script.path}',fps=8,crop=16:12:0:0,vflip@v=enable=0";
    const window = "sendcmd='0.25 hflip enable 1',hflip=enable=0";
    // FFmpeg BMP checksums in source presentation order at 8 fps.
    for (final (name, filter, dimensions, expected, input) in [
      (
        'inline',
        "sendcmd=c='0.25-0.75 [enter] hflip@flip enable 1,[leave] hflip@flip enable 0',hflip@flip=enable=0",
        (32, 24),
        _twice([0x02858573, 0x79293848, 0x1cdbcee1, 0x2067da59]),
        _motion,
      ),
      (
        'type',
        "sendcmd='0.25 hflip enable 0',hflip,crop=16:12:0:0,hflip",
        (16, 12),
        _twice([0x6251cfae, 0xb5712e13, 0x78750e27, 0x60c7c1f8]),
        _motion,
      ),
      (
        'instance',
        "sendcmd='0.25 Parsed_hflip_3 enable 0',hflip,crop=16:12:0:0,hflip",
        (16, 12),
        _twice([0x6251cfae, 0xff44807f, 0x218b3c52, 0x59c0c29e]),
        _motion,
      ),
      (
        'upstream',
        "hflip@before=enable=0,sendcmd='0.25 hflip@before enable 1'",
        (32, 24),
        _twice([0x02858573, 0xc98c1c3f, 0x1cdbcee1, 0x5f2a54ff]),
        _motion,
      ),
      (
        'all',
        "sendcmd='0.25 all enable 1',hflip=enable=0",
        (32, 24),
        _twice(_original),
        _motion,
      ),
      (
        'intervals',
        "sendcmd='0.5 hflip enable 1;0.25-0.75 [enter] hflip enable 0,[leave] hflip enable 0;"
            "0.5 hflip enable 0;0.75 hflip enable 1',hflip",
        (32, 24),
        _twice([0xf25664cd, 0xc98c1c3f, 0x650f8dd9, 0x5f2a54ff]),
        _motion,
      ),
      (
        'escaped',
        r"sendcmd=c='0.25 hflip enable eq(n\\,2)',hflip=enable=0",
        (32, 24),
        _twice([0x02858573, 0xc98c1c3f, 0x1cdbcee1, 0x2067da59]),
        _motion,
      ),
      ('file', fromFile, (16, 12), _twice(_fileFrames), _motion),
      (
        'unmatched',
        "sendcmd='0.25 missing enable 1'",
        (32, 24),
        _twice(_original),
        _motion,
      ),
      (
        'secondary',
        'split[a][b];[a]fps=8[m];[b]trim=start_frame=1:end_frame=3,'
            "sendcmd='0.25 overlay@o enable 1',crop=4:4:2:2,hflip[s];"
            '[m][s]overlay@o=0:0:format=rgb:enable=0',
        (8, 6),
        _twice([0x8fd11bb7, 0xa108f493, 0x718fb8b8, 0xaef8fc4e]),
        alpha,
      ),
    ]) {
      for (final command in [
        'extract',
        if (name == 'file' || name == 'secondary') 'vcs',
      ]) {
        final directory = Directory('${temp.path}/$name-$command');
        final result = await Process.run(cli, [
          if (args.isEmpty) 'bin/vimg.dart',
          command,
          '-n1',
          '-f8',
          '-t1s',
          '-T4',
          '--vfilter',
          filter,
          '--output-dir',
          directory.path,
          if (command == 'vcs') ...[
            '-c1',
            '-H${dimensions.$2}',
            '--keep',
            '-o',
            '${temp.path}/$name.avif',
          ],
          input,
        ]);
        check(result.exitCode == 0, '$command $name failed ${result.stderr}');
        _checkFrames(directory, dimensions, expected);
      }
    }

    final saved = VideoFilterChain.parse(fromFile);
    script.deleteSync();
    final directory = Directory('${temp.path}/snapshot');
    await extractFrames(
      _motion,
      directory.path,
      const CaptureOptions(number: 1, frames: 8, window: 1),
      filters: saved,
    );
    _checkFrames(directory, (16, 12), _twice(_fileFrames));

    final windows = Directory('${temp.path}/windows');
    await extractFrames(
      _motion,
      windows.path,
      const CaptureOptions(number: 2, frames: 4, window: 0.5),
      filters: VideoFilterChain.parse(window),
    );
    // The paths of the second window sort before the first with these names.
    _checkFrames(
      windows,
      (32, 24),
      [
        0x650f8dd9,
        0xc98c1c3f,
        0x650f8dd9,
        0xc98c1c3f,
        0x5f2a54ff,
        0x1cdbcee1,
        0x5f2a54ff,
        0x1cdbcee1,
      ],
    );
  } finally {
    temp.deleteSync(recursive: true);
  }
}

void _checkFrames(
  Directory directory,
  (int, int) dimensions,
  List<int> expected,
) {
  final files = directory.listSync().cast<File>()
    ..sort((a, b) => a.path.compareTo(b.path));
  check(files.length == expected.length, '${directory.path} frame count');
  for (final (i, file) in files.indexed) {
    final frame = image.decodeBmp(file.readAsBytesSync())!;
    check(
      (frame.width, frame.height) == dimensions &&
          getCrc32(frame.getBytes()) == expected[i],
      '${file.path} matches FFmpeg',
    );
  }
}
