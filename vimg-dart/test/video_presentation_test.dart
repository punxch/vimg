import 'dart:io';
import 'dart:typed_data';

import 'package:image/image.dart' as image;
import 'package:vimg_dart/src/avif_image.dart';
import 'package:vimg_dart/src/binary_file.dart';
import 'package:vimg_dart/src/iso_media.dart';
import 'package:vimg_dart/src/video.dart';
import 'package:vimg_dart/src/yuv_image.dart';

import 'fixtures.dart';

Future<void> main(List<String> arguments) async {
  final temp = Directory.systemTemp.createTempSync('vimg-presentation-');
  Future<void> run(List<String> command) async {
    final result = await Process.run(
      arguments.firstOrNull ?? Platform.resolvedExecutable,
      [if (arguments.isEmpty) 'bin/vimg.dart', ...command],
    );
    check(result.exitCode == 0, '$command: ${result.stderr}');
  }

  try {
    final iso = isoFixture(temp, sampleAspects: [(2, 1), (1, 2)]);
    await _checkDescriptions(iso.path);
    _checkCodecOverride(temp);
    final mkv = matroskaFixture(
      temp,
      videoFields: [
        ...ebml([0x54, 0xcc], [4]), // left
        ...ebml([0x54, 0xdd], [2]), // right
        ...ebml([0x54, 0xbb], [2]), // top
        ...ebml([0x54, 0xaa], [4]), // bottom
        ...ebml([0x54, 0xb2], [3]), // display-aspect-ratio units
        ...ebml([0x54, 0xb0], [26]),
        ...ebml([0x54, 0xba], [9]), // cropped 26x18, SAR 2:1
        ...ebml(
          [0x76, 0x70],
          [
            ...ebml([
              0x76,
              0x75,
            ], (ByteData(4)..setFloat32(0, 90)).buffer.asUint8List()),
          ],
        ),
      ],
    );
    final preview = '${temp.path}/preview.jpg';
    await run(['preview', '--output', preview, mkv.path]);
    final jpeg = image.decodeJpg(File(preview).readAsBytesSync())!;
    check(
      (jpeg.width, jpeg.height) == (18, 26),
      'Crop before preview rotation',
    );
    final extract = '${temp.path}/frames';
    const filter = 'pad=aspect=1:x=-1:y=-1';
    await run([
      'extract',
      '-n2',
      '-T2',
      '--output-dir',
      extract,
      '--vfilter',
      filter,
      mkv.path,
    ]);
    final files = Directory(extract).listSync().cast<File>().toList();
    check(files.length == 2, 'Two filtered Matroska captures');
    for (final file in files) {
      final pixels = image.decodeBmp(file.readAsBytesSync())!;
      check((pixels.width, pixels.height) == (52, 26), 'Rotated SAR is 1:2');
      check(pixels.getPixel(0, 0).luminance == 0, 'Padded border');
      check(pixels.getPixel(26, 13).luminance > 0, 'Cropped source at center');
    }
    final grid = '${temp.path}/sheet.avif';
    await run([
      'vcs',
      '-c2',
      '-H13',
      '-n2',
      '-f1',
      '-T2',
      '--vfilter',
      filter,
      '-o',
      grid,
      mkv.path,
    ]);
    final sheet = readAvifImage(grid)!;
    check(
      (sheet.width, sheet.height) == (52, 13),
      'Grid uses filtered geometry',
    );
  } finally {
    temp.deleteSync(recursive: true);
  }
}

void _checkCodecOverride(Directory directory) {
  final path = '${directory.path}/override.mp4';
  const source = 'test/fixtures/cabac-anamorphic.mp4';
  final file = File(source).copySync(path).openSync(mode: FileMode.append);
  try {
    final media = IsoMedia(BinaryFile(file));
    final table = media.sampleTable(
      media.child(media.firstVideoTrack(), 'mdia'),
    );
    final pasp = media.visualExtension(
      media.sampleDescription(table)!,
      'pasp',
    )!;
    file.setPositionSync(pasp.data);
    file.writeFromSync([...uint(1, 4), ...uint(2, 4)]);
  } finally {
    file.closeSync();
  }
  final video = Video(path);
  try {
    final packet = video.packets().first;
    final native = video.decodeSelected([packet]).single.frame;
    final scaler = YuvImageScaler(
      filters: VideoFilterChain.parse('pad=aspect=2:x=-1:y=-1'),
    );
    final filtered = video
        .decodeSelected([packet], scaler: scaler)
        .single
        .frame;
    check(
      filtered.width == native.height * 4 && filtered.height == native.height,
      'MP4 pasp overrides the H.264 sequence sample aspect',
    );
  } finally {
    video.close();
  }
}

Future<void> _checkDescriptions(String path) async {
  final video = Video(path);
  final scaler = YuvImageScaler(
    filters: VideoFilterChain.parse('pad=aspect=2:x=-1:y=-1'),
  );
  final workers = VideoCaptureDecoder(video, threads: 2, scaler: scaler);
  try {
    final packets = video.packets().toList();
    final selected = [packets.first, packets.last];
    final expected = {selected[0]: (32, 32), selected[1]: (96, 24)};
    for (final result in video.decodeSelected(selected, scaler: scaler)) {
      check(
        (result.frame.width, result.frame.height) == expected[result.packet],
        'Serial capture uses the sample description aspect',
      );
    }
    await for (final result in workers.decode(selected.reversed)) {
      check(
        (result.frame.width, result.frame.height) ==
            expected.remove(result.packet),
        'Parallel capture uses the sample description aspect',
      );
    }
    check(expected.isEmpty, 'Both description changes reached the workers');
  } finally {
    await workers.close();
    video.close();
  }
}
