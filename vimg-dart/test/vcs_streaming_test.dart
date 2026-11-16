import 'dart:convert';
import 'dart:io';

import 'package:image/image.dart' as image;
import 'package:vimg_dart/src/capture.dart';
import 'package:vimg_dart/src/video_commands.dart';

import 'fixtures.dart';

Future<void> main() async {
  final temp = Directory.systemTemp.createTempSync('vimg-vcs-streaming-');
  try {
    await _verifyGridBeforeLastCapture(temp);
    final input = matroskaFixture(temp);
    await _verifyWebpTimingAndPayloads(temp, input);
    await _verifyLongRepeatedAnimation(temp, input);
  } finally {
    temp.deleteSync(recursive: true);
  }
}

Future<void> _verifyGridBeforeLastCapture(Directory directory) async {
  const frames = 8;
  final captures = Directory('${directory.path}/captures');
  final output = File('${directory.path}/stream.avif');
  int? firstGrid;
  await writeContactSheet(
    'test/fixtures/cabac-b-spatial.mkv',
    output.path,
    const CaptureOptions(number: 1, frames: frames),
    columns: 1,
    height: 24,
    threads: 1,
    captureDirectory: captures.path,
    onGrid: (index, _, _, _) {
      if (index == 0) firstGrid = captures.listSync().length;
    },
  );
  check(
    firstGrid != null && firstGrid! > 0 && firstGrid! < frames,
    'Compose the first AVIF grid before the remaining H.264 captures',
  );
  check(captures.listSync().length == frames, 'Keep all scheduled BMP files');
}

Future<void> _verifyWebpTimingAndPayloads(
  Directory directory,
  File input,
) async {
  const fps = 7.5;
  final output = File('${directory.path}/durations.webp');
  image.Image? reference;
  await writeContactSheet(
    input.path,
    output.path,
    const CaptureOptions(number: 2, frames: 5, window: 2),
    columns: 2,
    height: 24,
    fps: fps,
    onGrid: (index, grid, _, _) {
      final frame = image.Image.from(grid)
        ..frameDuration =
            ((index + 1) * 1000 / fps).round() - (index * 1000 / fps).round();
      if (reference == null) {
        reference = frame;
      } else {
        reference!.addFrame(frame);
      }
    },
  );
  final webp = image.WebPEncoder(lossless: false, quality: 75, method: 1);
  check(
    base64Encode(output.readAsBytesSync()) ==
        base64Encode(webp.encode(reference!)),
    'Streaming RIFF and fractional frame durations match the encoder',
  );
}

Future<void> _verifyLongRepeatedAnimation(
  Directory directory,
  File input,
) async {
  const frames = 640;
  final output = File('${directory.path}/repeated.webp');
  await writeContactSheet(
    input.path,
    output.path,
    const CaptureOptions(number: 1, frames: frames, window: 0.1),
    columns: 1,
    height: 384,
  );
  final decoder = image.WebPDecoder(output.readAsBytesSync());
  final info = decoder.info!;
  check(
    (info.width, info.height, info.numFrames) == (512, 384, frames),
    'Produce a WebP whose decoded frame sequence exceeds 256 MiB',
  );
  final first = decoder.decodeFrame(0)!;
  final last = decoder.decodeFrame(frames - 1)!;
  check(
    base64Encode(first.getBytes()) == base64Encode(last.getBytes()),
    'The repeated VP8 chunks decode to the same full canvas',
  );
}
