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
  await _checkParameterChanges(
    'avc3-parameter-change.mp4',
    ['cabac-idr.mp4', 'cavlc-baseline.mp4'],
    [0, 1, 0],
  );
  await _checkParameterChanges(
    'hevc-parameter-change.mkv',
    ['hevc-fields-tff-b.mp4', 'hevc-main10.mp4'],
    [0, 8, 0],
  );
  final temp = Directory.systemTemp.createTempSync('vimg-workers-');
  try {
    final input = matroskaFixture(temp);
    await _checkWorkerFailure(input.path);
    await _checkCancellation(input.path);
  } finally {
    temp.deleteSync(recursive: true);
  }
}

Future<void> _checkParameterChanges(
  String fixture,
  List<String> sources,
  List<int> firstSequence,
) async {
  const root = 'test/fixtures';
  final video = Video('$root/$fixture');
  final first = Video('$root/${sources[0]}');
  final second = Video('$root/${sources[1]}');
  final workers = VideoCaptureDecoder(video, threads: 3);
  try {
    // Reuse the same parameter IDs at different sizes. Each update is in a
    // parameter-only sample, before the GOP that needs it. The AVC samples
    // use two-byte NAL lengths, while the source clips use four bytes.
    final firstPackets = first.packets().toList();
    final secondPackets = second.packets().take(3).toList();
    final expected = [
      for (final index in firstSequence.take(2))
        first.decode(firstPackets[index]),
      for (final packet in secondPackets) second.decode(packet),
      first.decode(firstPackets[firstSequence.last]),
    ];
    final packets = video.packets().toList();
    check(packets.length == expected.length, 'Exclude parameter-only samples');
    for (final (i, time) in [0, 0.25, 0.75, 1, 1.25, 1.75].indexed) {
      check(packets[i].seconds == time, 'Preserve video sample timestamps');
    }

    final keys = video.packets(preview: true).toList();
    const keyIndexes = [0, 1, 2, 5];
    check(keys.length == keyIndexes.length, 'Parameter update preview count');
    for (final (i, key) in keys.indexed.toList().reversed) {
      final index = keyIndexes[i];
      check(key == packets[index], 'Parameter update preview identity');
      final decoded = video.decode(key, preview: true);
      _sameBytes(decoded.getBytes(), expected[index].getBytes(), fixture);
    }
    _sameBytes(
      video.decode(packets[4]).getBytes(),
      expected[4].getBytes(),
      'Independent seek into updated GOP',
    );
    final positions = {for (final (i, packet) in packets.indexed) packet: i};
    final selected = [packets[4], packets.last, packets.first];
    final result = await workers.decode(selected).toList().timeout(_timeout);
    check(result.length == selected.length, 'Parallel parameter update count');
    for (final item in result) {
      final reference = expected[positions[item.packet]!];
      check(
        (item.frame.width, item.frame.height) ==
            (reference.width, reference.height),
        'Use updated sequence dimensions in workers',
      );
      _sameBytes(item.frame.getBytes(), reference.getBytes(), fixture);
    }
  } finally {
    await workers.close();
    second.close();
    first.close();
    video.close();
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
