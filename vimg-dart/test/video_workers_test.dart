import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:vimg_dart/src/frame_packet.dart';
import 'package:vimg_dart/src/video.dart';
import 'package:vimg_dart/src/yuv_image.dart';

import 'fixtures.dart';

const _timeout = Duration(seconds: 20);

Future<void> main() async {
  for (final file in [
    'cabac-b-spatial.mkv',
    'hevc-main.mkv',
    'av1-intra.mp4',
  ]) {
    await _checkReferences('test/fixtures/$file');
  }
  final temp = Directory.systemTemp.createTempSync('vimg-workers-');
  try {
    final input = matroskaFixture(temp);
    await _checkWorkerFailure(input.path);
    await _checkCancellation(input.path);
  } finally {
    temp.deleteSync(recursive: true);
  }
}

Future<void> _checkReferences(String path) async {
  final video = Video(path);
  final scaler = YuvImageScaler(height: 24);
  final decoder = VideoCaptureDecoder(
    video,
    threads: 4,
    scaler: scaler,
    includeOriginal: true,
  );
  try {
    final packets = video.packets().toList();
    final selected = [packets.first, ...packets.reversed];
    final expected = {
      for (final item in video.decodeSelected(
        selected,
        scaler: scaler,
        includeOriginal: true,
      ))
        item.packet: (item.frame.getBytes(), item.original!.getBytes()),
    };
    final parallel = await decoder.decode(selected).toList().timeout(_timeout);
    check(
      parallel.length == expected.length,
      'Parallel capture count for $path',
    );
    for (final item in parallel) {
      final reference = expected.remove(item.packet);
      check(reference != null, 'Parallel capture packet identity for $path');
      _sameBytes(
        reference!.$1,
        item.frame.getBytes(),
        'Scaled frame from $path',
      );
      _sameBytes(
        reference.$2,
        item.original!.getBytes(),
        'Original frame from $path',
      );
    }
    check(expected.isEmpty, 'All selected packets decoded for $path');
  } finally {
    await decoder.close();
    video.close();
  }
}

Future<void> _checkWorkerFailure(String path) async {
  final video = Video(path);
  final decoder = VideoCaptureDecoder(video, threads: 2);
  try {
    final good = video.packets().first;
    final FramePacket bad = (
      seconds: good.seconds,
      offset: good.offset,
      size: 0,
      timestamp: good.timestamp,
    );
    try {
      await decoder.decode([good, bad]).drain<void>().timeout(_timeout);
      throw StateError('Accepted an invalid packet');
    } on FormatException catch (error) {
      check(
        error.message == 'Invalid video frame size',
        'Worker forwards decode errors',
      );
    }
  } finally {
    await decoder.close();
    video.close();
  }
}

Future<void> _checkCancellation(String path) async {
  final video = Video(path);
  final decoder = VideoCaptureDecoder(video, threads: 3);
  final stream = StreamIterator(decoder.decode(video.packets()));
  try {
    check(await stream.moveNext().timeout(_timeout), 'Parallel first capture');
    await stream.cancel().timeout(_timeout);
  } finally {
    await stream.cancel();
    await decoder.close();
    video.close();
  }
}

void _sameBytes(Uint8List reference, Uint8List frame, String label) {
  check(reference.length == frame.length, '$label length');
  for (var i = 0; i < frame.length; i++) {
    if (frame[i] != reference[i]) throw StateError('$label differs at $i');
  }
}
