import 'dart:io';

import 'package:archive/archive.dart';
import 'package:image/image.dart' as image;
import 'package:vimg_dart/src/yuv_image.dart';

import 'fixtures.dart';

// Scalar FFmpeg BMP output from the four-frame inputs at an 8 fps capture rate.
// Each checksum covers RGB or RGBA in display order, including any mask.
const _cases = [
  (
    'linear',
    "fps=8,hflip@window=enable='between(n,2,4)',vflip=enable='gte(t,0.625)'",
    (32, 24),
    [
      0x02858573,
      0x02858573,
      0x79293848,
      0x79293848,
      0x1cdbcee1,
      0x1752447d,
      0x9de564fa,
      0x9de564fa,
    ],
  ),
  (
    'geometry',
    "crop=16:12:2:4,vflip=enable='eq(w,16)*eq(h,12)'",
    (16, 12),
    [
      0x45dcb46e,
      0x45dcb46e,
      0xd53040b4,
      0xd53040b4,
      0xd2e07102,
      0xd2e07102,
      0x2720247a,
      0x2720247a,
    ],
  ),
  (
    'branch',
    "split[a][b];[b]fps=8,hflip=enable='between(n,3,6)'[r];[a][r]hstack",
    (64, 24),
    [
      0x4e223eaa,
      0x4e223eaa,
      0x2484101c,
      0xc35ffb2c,
      0x1989aa22,
      0x1989aa22,
      0x3eed4e5c,
      0xbf43ed37,
    ],
  ),
  (
    'paint',
    "drawbox=x=1:y=1:w=4:h=3:color=red:t=fill:enable='gte(t,0.5)'",
    (8, 6),
    [
      0x8fd11bb7,
      0x8fd11bb7,
      0x0c2199ca,
      0x0c2199ca,
      0xdef7898e,
      0xdef7898e,
      0x576d348b,
      0x576d348b,
    ],
  ),
  (
    'negate',
    'negate=components=r+g+b:enable=-0.5,vflip=enable=0.49',
    (8, 6),
    [
      0xad000280,
      0xad000280,
      0x2ef080fd,
      0x2ef080fd,
      0xf4e05ef2,
      0xf4e05ef2,
      0xd766f241,
      0xd766f241,
    ],
  ),
  (
    'overlay',
    'split[a][b];[a]fps=8[m];[b]trim=start_frame=1:end_frame=3,crop=4:4:2:2,hflip[s];'
        "[m][s]overlay=0:0:format=rgb:enable='eq(n,3)+gte(t,0.75)'",
    (8, 6),
    [
      0x8fd11bb7,
      0x8fd11bb7,
      0x0c2199ca,
      0xa108f493,
      0xd63147c5,
      0xd63147c5,
      0xaef8fc4e,
      0xaef8fc4e,
    ],
  ),
  (
    'overlay-shared-clock',
    'fps=8,split[a][b];[b]crop=4:4:2:2,hflip[s];'
        "[a][s]overlay=0:0:format=rgb:enable='gte(n,3)*eq(w,8)'",
    (8, 6),
    [
      0x8fd11bb7,
      0x8fd11bb7,
      0x0c2199ca,
      0xa108f493,
      0x718fb8b8,
      0x718fb8b8,
      0x532242bd,
      0x532242bd,
    ],
  ),
  (
    'merge',
    'split[a][b];[a]fps=8[m];[b]trim=start_frame=1:end_frame=3,alphaextract,hflip,'
        "settb=1/16,setpts=PTS+1[mask];[m][mask]alphamerge=ts_sync_mode=nearest:enable='mod(n,2)'",
    (8, 6),
    [
      0x8fd11bb7,
      0x8fd11bb7,
      0x0c2199ca,
      0xcbcd922f,
      0xd63147c5,
      0x206679be,
      0xf5b7eb76,
      0x49377881,
    ],
  ),
  (
    'merge-after-main-end',
    'split[a][b];[a]trim=end_frame=2,fps=8[m];[b]alphaextract,hflip[mask];'
        "[m][mask]alphamerge=enable='eq(n,3)*lt(t,0.5)'",
    (8, 6),
    [
      0x8fd11bb7,
      0x8fd11bb7,
      0x0c2199ca,
      0xcbcd922f,
      0xbbd78b50,
      0xb0367c86,
      0xb0367c86,
      0xb0367c86,
    ],
  ),
  (
    'premultiply-inplace',
    "format=gbrap,premultiply=inplace=1:enable='eq(n,1)+eq(n,3)',fps=8",
    (8, 6),
    [
      0x8fd11bb7,
      0x8fd11bb7,
      0xdfa4df87,
      0xdfa4df87,
      0xd63147c5,
      0xd63147c5,
      0xe6c64dbd,
      0xe6c64dbd,
    ],
  ),
  (
    'unpremultiply-inplace',
    "format=gbrap,unpremultiply=inplace=1:enable='eq(n,1)',fps=8",
    (8, 6),
    [
      0xd7eb4aee,
      0xd7eb4aee,
      0x34902ccc,
      0x34902ccc,
      0x7092553f,
      0x7092553f,
      0xe6c64dbd,
      0xe6c64dbd,
    ],
  ),
  (
    // The first output uses main frame 0 while enable is on main frame 1.
    'premultiply-lookahead',
    'format=gray,split[a][b];[a]fps=2[m];[b]trim=start_frame=1,hflip[mask];'
        "[m][mask]premultiply=enable='eq(n,1)',settb=1/8,setpts=N,fps=8,format=rgb24",
    (8, 6),
    [
      0x01d92e3d,
      0x36adb6ba,
      0x277adb43,
      0x277adb43,
      0x277adb43,
      0x277adb43,
      0x277adb43,
      0x277adb43,
    ],
  ),
];

Future<void> main(List<String> arguments) async {
  for (final filter in [
    'scale=8:6:enable=1',
    'crop=4:4:enable=1',
    'hflip=enable=',
    'hflip=enable=1:enable=0',
    "negate=enable='eq(unknown,0)'",
  ]) {
    try {
      VideoFilterChain.parse(filter);
    } on FormatException {
      continue;
    }
    throw StateError('Accepted invalid timeline expression $filter');
  }

  final cli = arguments.firstOrNull;
  final temp = Directory.systemTemp.createTempSync('vimg-enable-');
  try {
    final alpha = aviFixture(temp, rgba: true).path;
    const motion = 'test/fixtures/filter-motion.avi';
    for (final (name, filter, (width, height), expected) in _cases) {
      final input = const {'linear', 'geometry', 'branch'}.contains(name)
          ? motion
          : alpha;
      for (final command in [
        'extract',
        if (const {'linear', 'merge', 'premultiply-lookahead'}.contains(name))
          'vcs',
      ]) {
        final folder = Directory('${temp.path}/$name-$command');
        final result = await Process.run(cli ?? Platform.resolvedExecutable, [
          if (cli == null) 'bin/vimg.dart',
          command,
          '-n1',
          '-f8',
          '-t1s',
          '-T4',
          '--output-dir',
          folder.path,
          '--vfilter',
          filter,
          if (command == 'vcs') ...[
            '-c1',
            '-H$height',
            '--keep',
            '-o',
            '${temp.path}/$name.avif',
          ],
          input,
        ]);
        check(result.exitCode == 0, '$command $name failed: ${result.stderr}');
        final files = folder.listSync().cast<File>()
          ..sort((a, b) => a.path.compareTo(b.path));
        check(files.length == expected.length, '$command $name frame count');
        for (final (i, file) in files.indexed) {
          final frame = image.decodeBmp(file.readAsBytesSync())!;
          check(
            frame.width == width &&
                frame.height == height &&
                getCrc32(frame.getBytes()) == expected[i],
            '$command $name frame $i matches FFmpeg',
          );
        }
      }
    }
  } finally {
    temp.deleteSync(recursive: true);
  }
}
