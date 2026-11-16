import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:vimg_dart/src/mpeg4/decoder.dart';
import 'package:vimg_dart/src/video.dart';

import 'fixtures.dart';

Future<void> main() async {
  // The two hand-authored streams have the same reference and motion.
  // Ordinary GOBs share remote vectors. Structured slices use local
  // replacements. Annex F prediction values are calculated from a
  // DC-only reference, including the skip before a four-vector block,
  // an intra neighbor, RTYPE 1, and one inter residual.
  await _verify('gob', 2883794541, 2055726131);
  await _verify('slices', 2078077317, 2199630050);
}

Future<void> _verify(String mode, int lumaHash, int frameHash) async {
  final path = 'test/fixtures/h263-overlap-$mode.h263';
  final file = File(path).readAsBytesSync();
  final offsets = [
    for (var i = 0; i + 2 < file.length; i++)
      if (file[i] == 0 && file[i + 1] == 0 && file[i + 2] & 0xfc == 0x80) i,
    file.length,
  ];
  check(offsets.length == 4, '$mode picture starts');
  final planeHashes = [
    [3891315688, 1713793138, 695552975],
    [lumaHash, 2603014063, 828780369],
    [lumaHash, 2603014063, 828780369],
  ];
  final decoder = H263Decoder();
  for (var i = 0; i < 3; i++) {
    final picture = decoder.decode(
      Uint8List.sublistView(file, offsets[i], offsets[i + 1]),
    );
    check((picture.width, picture.height) == (48, 32), '$mode geometry');
    for (final (plane, bytes) in picture.planes.indexed) {
      check(
        getCrc32(bytes) == planeHashes[i][plane],
        '$mode frame $i plane $plane',
      );
    }
  }

  final video = Video(path);
  final worker = VideoCaptureDecoder(video, threads: 2);
  try {
    final hashes = [1182910710, frameHash, frameHash];
    final packets = video.packets().toList();
    check(packets.length == hashes.length, '$mode display frame count');
    final captures = {
      for (final capture in video.decodeSelected(packets))
        capture.packet: getCrc32(capture.frame.getBytes()),
    };
    for (final (i, packet) in packets.indexed) {
      check(captures[packet] == hashes[i], '$mode display frame $i');
    }
    for (final i in [2, 0, 1]) {
      final capture = await worker.decode([packets[i]]).single;
      check(getCrc32(capture.frame.getBytes()) == hashes[i], '$mode seek $i');
    }
  } finally {
    await worker.close();
    video.close();
  }
}
