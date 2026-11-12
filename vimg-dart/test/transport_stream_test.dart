import 'dart:io';
import 'dart:typed_data';

import 'package:vimg_dart/src/frame_packet.dart';
import 'package:vimg_dart/src/video.dart';

import 'fixtures.dart';

const _avc = 'test/fixtures/cabac-b-aac.ts';
const _hevc = 'test/fixtures/hevc-open-gop.m2ts';
const _ntsc = 'test/fixtures/cabac-multislice-ntsc.ts';

Future<void> main() async {
  await _compare(
    _avc,
    'test/fixtures/cabac-b-temporal.mp4',
    pts: 148500,
    start: 146410,
    preview: [148500],
  );
  await _compare(
    _hevc,
    'test/fixtures/hevc-main.mkv',
    pts: 148500,
    start: 148500,
    preview: [148500, 238500, 328500],
  );
  await _checkNtsc();
  final temp = Directory.systemTemp.createTempSync('vimg-ts-');
  try {
    _checkWrapped204(temp);
    _checkContinuity(temp);
  } finally {
    temp.deleteSync(recursive: true);
  }
}

// The fixtures remux the existing MP4 and MKV with FFmpeg's mpegts muxer.
// The AVC fixture adds a 44.1 kHz AAC sine track starting before video.
// The HEVC fixture uses -mpegts_m2ts_mode 1 and contains CRA/RASL pairs.
Future<void> _compare(
  String path,
  String source, {
  required int pts,
  required int start,
  required List<int> preview,
}) async {
  final video = Video(path);
  final original = Video(source);
  final decoder = VideoCaptureDecoder(video, threads: 2);
  try {
    final stream = video.metadata.streams.single;
    check(stream.codec == original.codec, 'PMT video codec for $path');
    check(stream.width == 166 && stream.height == 110, 'SPS dimensions');
    check(stream.timeBase == '1/90000', 'MPEG video clock');
    check(stream.nominalFrameRate == 8, 'Nominal frame rate');
    final packets = video.packets().toList();
    check(packets.length == 17, 'One access unit per displayed frame');
    for (final (i, packet) in packets.indexed) {
      check(
        packet.timestamp ==
            frameTimestamp(pts + 11250 * i, 1, 90000, duration: 11250),
        'FFprobe presentation timestamp and duration at frame $i',
      );
      check(
        packet.seconds == (pts + 11250 * i - start) / 90000,
        'Playback uses program start time',
      );
    }
    check(
      video.metadata.duration == (pts + 17 * 11250 - start) / 90000,
      'FFprobe program duration',
    );

    final samples = original.packets().toList();
    final index = {for (final (i, packet) in samples.indexed) packet: i};
    final reference = {
      for (final frame in original.decodeSelected(samples))
        index[frame.packet]!: frame.frame.getBytes(),
    };
    final keys = video.packets(preview: true).toList();
    check(
      keys.map((packet) => packet.timestamp!.pts).join(',') ==
          preview.join(','),
      'Identify IDR/CRA NAL units',
    );
    _same(
      video.decode(keys.last, preview: true).getBytes(),
      reference[packets.indexOf(keys.last)]!,
      'Decode the preview random-access picture',
    );
    final positions = {for (final (i, packet) in packets.indexed) packet: i};
    var count = 0;
    await for (final frame in decoder.decode(packets)) {
      final i = positions[frame.packet]!;
      _same(frame.frame.getBytes(), reference[i]!, 'Remuxed RGB frame $i');
      count++;
    }
    check(
      count == packets.length,
      'Decode all frames including reordered pictures',
    );

    // Spread the captures across independent GOPs so the HEVC decode runs
    // exercise worker file seeking and parameter-set transfer.
    count = 0;
    final selected = [packets.first, packets.last];
    await for (final frame in decoder.decode(selected)) {
      final i = positions[frame.packet]!;
      _same(frame.frame.getBytes(), reference[i]!, 'Worker RGB frame $i');
      count++;
    }
    check(count == selected.length, 'Decode both requested captures');
  } finally {
    await decoder.close();
    video.close();
    original.close();
  }
}

Future<void> _checkNtsc() async {
  final video = Video(_ntsc);
  try {
    final packets = video.packets().toList();
    const pts = [
      133508,
      137262,
      141016,
      144769,
      148523,
      152277,
      156031,
      159784,
      163538,
    ];
    check(packets.length == pts.length, 'Group three H.264 slices per picture');
    check(
      video.metadata.streams.single.nominalFrameRate == 24000 / 1001,
      'Retain the exact fractional SPS frame rate',
    );
    for (final (i, packet) in packets.indexed) {
      check(
        packet.timestamp == frameTimestamp(pts[i], 1, 90000, duration: 3753),
        'FFprobe fractional frame timing',
      );
    }
    final pictures = video.decodeSelected(packets);
    check(pictures.length == pts.length, 'Decode all multi-slice pictures');
  } finally {
    video.close();
  }
}

void _checkWrapped204(Directory temp) {
  final source = File(_avc).readAsBytesSync();
  final padded = BytesBuilder();
  const shift = 303092;
  for (var i = 0; i < source.length; i += 188) {
    final packet = Uint8List.sublistView(source, i, i + 188);
    final offset = 4 + (packet[3] & 32 != 0 ? 1 + packet[4] : 0);
    if (packet[1] & 64 != 0 &&
        offset + 19 < 188 &&
        packet[offset] == 0 &&
        packet[offset + 1] == 0 &&
        packet[offset + 2] == 1) {
      final flags = packet[offset + 7] >> 6;
      if (flags >= 2) _shiftTimestamp(packet, offset + 9, shift);
      if (flags == 3) _shiftTimestamp(packet, offset + 14, shift);
    }
    padded.add(packet);
    padded.add(Uint8List(16));
  }
  final file = File('${temp.path}/wrap.ts')
    ..writeAsBytesSync(padded.takeBytes());
  final video = Video(file.path);
  try {
    final packets = video.packets().toList();
    check(packets.length == 17, 'Read 204-byte packets');
    check(packets.first.timestamp!.pts == -154592, 'Negative pre-wrap PTS');
    check(packets.last.timestamp!.pts == 25408, 'Positive post-wrap PTS');
    check(
      packets.first.seconds == 2090 / 90000,
      'Unwrap audio on the video clock',
    );
    check(video.decode(packets.last).width == 166, 'Seek after the wrap');
  } finally {
    video.close();
  }
}

void _shiftTimestamp(Uint8List bytes, int i, int shift) {
  final raw =
      ((bytes[i] & 14) << 29) |
      (bytes[i + 1] << 22) |
      ((bytes[i + 2] & 254) << 14) |
      (bytes[i + 3] << 7) |
      (bytes[i + 4] >> 1);
  final value = (raw - shift) % (1 << 33);
  bytes[i] = (bytes[i] & 0xf1) | ((value >> 29) & 14);
  bytes[i + 1] = (value >> 22) & 255;
  bytes[i + 2] = ((value >> 14) & 254) | 1;
  bytes[i + 3] = (value >> 7) & 255;
  bytes[i + 4] = ((value << 1) & 254) | 1;
}

void _checkContinuity(Directory temp) {
  final source = File(_avc).readAsBytesSync();
  // The fourth packet starts the first video PES. Drop its first continuation.
  final truncated = File('${temp.path}/continuity.ts')
    ..writeAsBytesSync([
      ...Uint8List.sublistView(source, 0, 4 * 188),
      ...Uint8List.sublistView(source, 5 * 188),
    ]);
  final video = Video(truncated.path);
  try {
    video.metadata;
    throw StateError('Accepted video with a missing transport packet');
  } on FormatException catch (error) {
    check(error.message.contains('continuity'), 'Report the damaged PID');
  } finally {
    video.close();
  }
}

void _same(Uint8List a, Uint8List b, String message) {
  check(a.length == b.length, '$message byte length');
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) throw StateError('$message differs at byte $i');
  }
}
