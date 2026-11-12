import 'dart:io';
import 'dart:typed_data';

import 'package:vimg_dart/src/binary_file.dart';
import 'package:vimg_dart/src/iso_media.dart';
import 'package:vimg_dart/src/mpeg12/decode.dart';
import 'package:vimg_dart/src/mpeg12/syntax.dart';
import 'package:vimg_dart/src/video.dart';

import 'fixtures.dart';
import 'mpeg_checks.dart';

// FFmpeg -idct simple, hashed over the visible Y, Cb and Cr in PTS order.
const _mpeg1 = [
  0xb732aea1,
  0xb0ef6c40,
  0x1e24228e,
  0xafa7e003,
  0xc2b35d87,
  0xa8d490be,
  0xe2c00f06,
  0x6039326c,
  0x4e75e325,
  0xe399a34e,
  0x125e608b,
  0xba70ea28,
  0x4425646e,
  0xb17eb9c3,
  0x0f6c55a6,
];
const _mpeg2 = [
  0xd2ec4fc1,
  0x19fba05c,
  0x17f71878,
  0x51006103,
  0xd1d27b0d,
  0x499db8b1,
  0xd4141ede,
  0xa4350a28,
  0xb8135c79,
  0x9faf1a62,
  0x7401d18b,
  0x32edf56a,
  0xe009edf8,
  0x728ae53a,
  0x28f4406a,
];
const _fields = [
  0xfa3f236d,
  0x134ba8ed,
  0xb9d82156,
  0xf04a208c,
  0x371d321b,
  0xa1168396,
  0xb78df363,
  0xb78df363,
  0x8685b22d,
];

Future<void> main(List<String> args) async {
  const mpeg1 = 'test/fixtures/mpeg1-iso.mp4';
  const fragmented = 'test/fixtures/mpeg2-fragmented.mp4';
  const fields = 'test/fixtures/mpeg2-fields.mov';
  await _compare(mpeg1, 'mpeg1video', _mpeg1, 12800, 0, [0, 6, 12]);
  // The first trun stores a zero composition offset. FFprobe shifts the
  // reported PTS by one tick of frame duration for the signed offsets.
  await _compare(fragmented, 'mpeg2video', _mpeg2, 16000, 0, [
    0,
    6,
    12,
  ], externalConfiguration: true);
  await _compare(fields, 'mpeg2video', _fields, 16000, 0, [
    0,
    6,
  ], externalConfiguration: true);
  _checkEdit(mpeg1);
  _checkDescriptors();
  if (args.isNotEmpty) await _checkCommands(args.single, fragmented);
}

Future<void> _compare(
  String path,
  String codec,
  List<int> hashes,
  int scale,
  int start,
  List<int> keys, {
  bool externalConfiguration = false,
}) async {
  final video = Video(path);
  final workers = VideoCaptureDecoder(video, threads: 3);
  try {
    final metadata = video.metadata.streams.single;
    check(video.codec == codec && metadata.codec == codec, 'Codec for $path');
    check(metadata.width == 48 && metadata.height == 64, 'ISO MPEG size');
    check(metadata.timeBase == '1/$scale', 'ISO MPEG time base');
    check(
      (video.metadata.duration! - hashes.length / 25).abs() < 1e-9,
      'ISO MPEG duration for $path',
    );
    final media = IsoMedia(video.file);
    final configuration = media.mpegVideoConfiguration();
    check(
      (configuration != null) == externalConfiguration,
      'Sequence header storage for $path',
    );
    final decoder = MpegStreamDecoder(configuration);
    final packets = video.packets().toList();
    check(packets.length == hashes.length, 'ISO MPEG frame count');
    final indices = {for (final (i, packet) in packets.indexed) packet: i};
    final rgb = <int, Uint8List>{};
    for (final (i, packet) in isoFrames(media).indexed) {
      final bytes = video.file.read(packet.offset, packet.size);
      if (i == 0 && externalConfiguration) {
        check(
          !mpegStartCodes(bytes).any((unit) => unit.code == 0xb3),
          'First sample relies on the container sequence header',
        );
      }
      final frame = decoder.decode(bytes);
      final index = indices[packet]!;
      final stamp = packet.timestamp!;
      check(
        stamp.pts == start + index * (scale ~/ 25),
        'Raw PTS for $path frame $index: ${stamp.pts}',
      );
      check(
        (packet.seconds - index / 25).abs() < 1e-9,
        'Playback time for $path frame $index: ${packet.seconds}',
      );
      check(mpegYuvHash(frame) == hashes[index], 'YUV for $path frame $index');
      rgb[index] = frame.rgb().getBytes();
    }
    final previews = video.packets(preview: true).toList();
    check(
      previews.map((packet) => indices[packet]).join(',') == keys.join(','),
      'Preview keyframes for $path',
    );
    for (final packet in previews) {
      _samePixels(
        video.decode(packet, preview: true).getBytes(),
        rgb[indices[packet]]!,
      );
    }
    final selected = {packets.first, packets[5], packets[6], packets.last};
    final remaining = selected.toSet();
    await for (final result in workers.decode(selected)) {
      check(remaining.remove(result.packet), 'Each requested frame once');
      _samePixels(result.frame.getBytes(), rgb[indices[result.packet]]!);
    }
    check(remaining.isEmpty, 'All selected ISO MPEG frames returned');
  } finally {
    await workers.close();
    video.close();
  }
}

void _samePixels(Uint8List actual, Uint8List expected) {
  check(actual.length == expected.length, 'RGB byte count');
  for (var i = 0; i < actual.length; i++) {
    check(actual[i] == expected[i], 'ISO MPEG RGB at byte $i');
  }
}

void _checkEdit(String source) {
  final directory = Directory.systemTemp.createTempSync('vimg-mpeg-edit-');
  final edited = File('${directory.path}/edit.mp4');
  final original = Video(source);
  try {
    final media = IsoMedia(original.file);
    final edit = media.child(
      media.child(media.firstVideoTrack(), 'edts'),
      'elst',
    )!;
    final bytes = File(source).readAsBytesSync();
    // The edit hides the first two frames. The first I-picture is still
    // required to decode the first visible B-picture.
    final view = ByteData.sublistView(bytes)
      ..setUint32(edit.data + 8, 520)
      ..setUint32(edit.data + 12, 1024);
    edited.writeAsBytesSync(view.buffer.asUint8List());
    final video = Video(edited.path);
    try {
      final packets = video.packets().toList();
      final reference = original.packets().toList();
      final previews = video.packets(preview: true).toList();
      check(packets.length == 13 && packets.first.seconds == 0, 'MPEG edit');
      check(
        previews.length == 2 &&
            previews.first.timestamp == reference[6].timestamp,
        'Preview skips the hidden I-picture',
      );
      _samePixels(
        video.decode(packets.first).getBytes(),
        original.decode(reference[2]).getBytes(),
      );
    } finally {
      video.close();
    }
  } finally {
    original.close();
    directory.deleteSync(recursive: true);
  }
}

void _checkDescriptors() {
  List<int> descriptor(int type, List<int> payload) => [
    type,
    payload.length,
    ...payload,
  ];
  const sequence = [0, 0, 1, 0xb3, 3, 0, 64, 0x13, 255, 255, 224, 24];
  List<int> entry(int objectType, {bool badLength = false}) => box('mp4v', [
    ...List.filled(78, 0),
    ...box('esds', [
      0,
      0,
      0,
      0,
      ...descriptor(3, [
        0, 1, 0xe0, // ES ID and the three optional fields.
        0, 2, // Dependency.
        3, 117, 114, 108, // Length-prefixed URL.
        0, 3, // Clock reference.
        ...descriptor(4, [
          objectType,
          0x11,
          ...List.filled(11, 0),
          5,
          badLength ? 0xff : sequence.length,
          ...sequence,
        ]),
      ]),
    ]),
    0, 0, 0, 0, // Optional QuickTime terminator.
  ]);
  final directory = Directory.systemTemp.createTempSync('vimg-esds-');
  try {
    for (final (objectType, expected) in [
      (0x20, 'mpeg4'),
      (0x65, 'mpeg2video'),
      (0x6a, 'mpeg1video'),
    ]) {
      final file = File('${directory.path}/descriptor.mp4');
      for (final badLength in [false, true]) {
        file.writeAsBytesSync(
          box(
            'moov',
            box(
              'trak',
              box('mdia', [
                ...box('hdlr', [0, 0, 0, 0, 0, 0, 0, 0, 118, 105, 100, 101]),
                ...box('mdhd', [
                  ...List.filled(12, 0),
                  ...uint(1000, 4),
                  ...uint(40, 4),
                ]),
                ...box(
                  'minf',
                  box(
                    'stbl',
                    box('stsd', [
                      0,
                      0,
                      0,
                      0,
                      0,
                      0,
                      0,
                      1,
                      ...entry(objectType, badLength: badLength),
                    ]),
                  ),
                ),
              ]),
            ),
          ),
        );
        final handle = file.openSync();
        try {
          final media = IsoMedia(BinaryFile(handle));
          check(
            media.metadata().streams.single.codec == expected,
            'ES object type',
          );
          check(!badLength, 'Accepted a descriptor crossing its parent extent');
          _samePixels(
            media.mpegVideoConfiguration()!,
            Uint8List.fromList(sequence),
          );
        } on FormatException catch (error) {
          check(
            badLength && error.message == 'Invalid ISO media descriptor length',
            'Reject an invalid descriptor extent',
          );
        } finally {
          handle.closeSync();
        }
      }
    }
  } finally {
    directory.deleteSync(recursive: true);
  }
}

Future<void> _checkCommands(String executable, String input) async {
  final dir = Directory.systemTemp.createTempSync('vimg-iso-mpeg-');
  try {
    final preview = '${dir.path}/preview.jpg';
    final captures = '${dir.path}/frames';
    final output = '${dir.path}/sheet.avif';
    for (final args in [
      ['preview', '--output', preview, input],
      ['extract', '-n3', '-T2', '--output-dir', captures, input],
      ['vcs', '-c2', '-H32', '-n3', '-f3', '-T2', '-o', output, input],
    ]) {
      final result = await Process.run(executable, args);
      check(result.exitCode == 0, '${args.first}: ${result.stderr}');
    }
    check(File(preview).lengthSync() > 0, 'ISO MPEG JPEG');
    check(Directory(captures).listSync().length == 3, 'ISO MPEG BMPs');
    check(File(output).lengthSync() > 0, 'ISO MPEG animated AVIF');
  } finally {
    dir.deleteSync(recursive: true);
  }
}
