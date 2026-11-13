import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:image/image.dart' as image;
import 'package:vimg_dart/src/binary_file.dart';
import 'package:vimg_dart/src/iso_media.dart';
import 'package:vimg_dart/src/quicktime_raw.dart';
import 'package:vimg_dart/src/video.dart';
import 'package:vimg_dart/src/yuv_image.dart';

import 'fixtures.dart';

const _width = 8, _height = 3;
typedef _Sample = ({
  String tag,
  int depth,
  List<int> data,
  List<int> extensions,
});

Future<void> main() async {
  final temp = Directory.systemTemp.createTempSync('vimg-quicktime-raw-');
  try {
    final samples = [_rgb(16), _rgb(24), _rgb(32), ..._componentSamples()];
    final input = _movie(temp, samples);
    final file = input.openSync();
    final video = Video(input.path);
    final decoder = VideoCaptureDecoder(video, threads: 3);
    try {
      final media = IsoMedia(BinaryFile(file));
      final table = media.sampleTable(
        media.child(media.firstVideoTrack(), 'mdia'),
      );
      final entries = media.sampleDescriptions(table).toList();
      final packets = video.packets().toList();
      check(
        packets.length == samples.length,
        'Read every raw sample description',
      );
      final expected = <int, image.Image>{};
      for (final (index, packet) in packets.indexed) {
        final format = QuickTimeRawFormat(media, entries[index]);
        final sample = samples[index];
        final payload = media.file.read(packet.offset, packet.size);
        final direct = video.decode(packet);
        check(
          (direct.width, direct.height) == (_width, _height),
          'Raw sample size',
        );
        if (sample.tag == 'raw ') {
          final pixel = direct.getPixel(0, 0);
          check(
            (pixel.r, pixel.g, pixel.b, pixel.a) ==
                switch (sample.depth) {
                  16 => (255, 0, 132, 255),
                  32 => (17, 63, 211, 71),
                  _ => (17, 63, 211, 255),
                },
            'QuickTime RGB channel order and depth',
          );
        } else {
          final planes = format.components(payload, includeAlpha: true);
          final isWide = sample.tag == 'yuv2';
          final precision = format.componentDepth - 8;
          final subsampled = !['v308', 'v408', 'v410'].contains(sample.tag);
          final chromaWidth = subsampled ? _width ~/ 2 : _width;
          for (var y = 0; y < _height; y++) {
            for (var x = 0; x < _width; x++) {
              final index = y * _width + x;
              final c = y * chromaWidth + (subsampled ? x ~/ 2 : x);
              check(planes.y[index] == (_y(y, x) << precision), 'Unpack luma');
              check(
                planes.cb[c] == (_cb(y, c % chromaWidth) << precision),
                'Unpack Cb',
              );
              check(
                planes.cr[c] == (_cr(y, c % chromaWidth) << precision),
                'Unpack Cr',
              );
            }
          }
          check(format.fullRange == isWide, 'QuickTime luma range');
          check(
            format.matrix == 1 && format.sampleAspect == 2,
            'QuickTime colr and pasp',
          );
          if (sample.tag == 'v408') {
            check(
              planes.alpha!.first == 0 && planes.alpha!.last == 255,
              'Video-range alpha',
            );
          }
        }
        expected[packet.offset] = direct;
      }
      for (final packet in video.packets(preview: true)) {
        check(
          !video.decode(packet, preview: true).hasAlpha,
          'Preview is opaque RGB',
        );
      }
      final seen = <int>{};
      await for (final result in decoder.decode(packets.reversed)) {
        final frame = expected[result.packet.offset]!;
        final actual = result.frame.getBytes();
        check(seen.add(result.packet.offset), 'Raw parallel identity');
        check(
          frame.numChannels == result.frame.numChannels,
          'Raw parallel alpha',
        );
        check(
          frame.getBytes().indexed.every(
            (entry) => actual[entry.$1] == entry.$2,
          ),
          'Raw parallel pixels',
        );
      }
      check(seen.length == samples.length, 'Raw parallel frame count');
      final scaled = VideoCaptureDecoder(
        video,
        threads: 2,
        includeOriginal: true,
        scaler: YuvImageScaler(width: 4),
      );
      try {
        final alphaFrames = [packets[2], packets[6]];
        final results = await scaled.decode(alphaFrames).toList();
        check(results.length == alphaFrames.length, 'Raw scaled frame count');
        for (final result in results) {
          check(
            result.frame.width == 4 && !result.frame.hasAlpha,
            'Scaled tile is RGB',
          );
          final source = expected[result.packet.offset]!.getPixel(0, 0);
          check(
            result.original!.getPixel(0, 0).a == source.a,
            'Keep original alpha',
          );
        }
      } finally {
        await scaled.close();
      }
    } finally {
      await decoder.close();
      video.close();
      file.closeSync();
    }
  } finally {
    temp.deleteSync(recursive: true);
  }
}

int _y(int y, int x) => 48 + y * 48 + x * 9;
int _cb(int y, int x) => 91 + y * 3 + x * 4;
int _cr(int y, int x) => 162 - y * 5 - x * 3;

_Sample _rgb(int depth) => (
  tag: 'raw ',
  depth: depth,
  data: [
    for (var x = 0; x < _width * _height; x++)
      ...switch (depth) {
        16 => [0x7c, 0x10],
        32 => [71, 17, 63, 211],
        _ => [17, 63, 211],
      },
  ],
  extensions: [],
);

Iterable<_Sample> _componentSamples() sync* {
  const tags = ['2vuy', 'yuv2', 'v308', 'v408', 'v210', 'v216', 'v410'];
  for (final tag in tags) {
    final bits = switch (tag) {
      'v216' => 12,
      'v210' || 'v410' => 10,
      _ => 8,
    };
    yield (
      tag: tag,
      depth: tag == 'v408' ? 32 : 24,
      data: [
        for (final y in tag == 'v216' ? [1, 0, 2] : [0, 1, 2]) ..._row(tag, y),
      ],
      extensions: [
        ...box('colr', [...ascii.encode('nclc'), 0, 1, 0, 1, 0, 1]),
        ...box('pasp', [...uint(2, 4), ...uint(1, 4)]),
        if (tag == 'v216') ...box('fiel', [2, 6]),
        if (tag == 'v216') ...box('sgbt', [bits]),
      ],
    );
  }
}

List<int> _le(int value, int width) => uint(value, width).reversed.toList();

List<int> _row(String tag, int y) {
  if (tag == 'v210') {
    int word(int a, int b, int c) => (a | b << 10 | c << 20);
    int luma(int x) => _y(y, x) << 2;
    int cb(int x) => _cb(y, x) << 2;
    int cr(int x) => _cr(y, x) << 2;
    return [
      ..._le(word(cb(0), luma(0), cr(0)), 4),
      ..._le(word(luma(1), cb(1), luma(2)), 4),
      ..._le(word(cr(1), luma(3), cb(2)), 4),
      ..._le(word(luma(4), cr(2), luma(5)), 4),
      ..._le(word(cb(3), luma(6), cr(3)), 4),
      ..._le(luma(7), 4),
      ...List.filled(104, 0),
    ];
  }
  if (tag == 'v308' || tag == 'v408' || tag == 'v410') {
    return [
      for (var x = 0; x < _width; x++)
        ...switch (tag) {
          'v308' => [_cr(y, x), _y(y, x), _cb(y, x)],
          'v408' => [_cb(y, x), _y(y, x), _cr(y, x), x == 0 ? 16 : 235],
          _ => _le(_cb(y, x) << 4 | _y(y, x) << 14 | _cr(y, x) << 24, 4),
        },
    ];
  }
  return [
    for (var x = 0; x < _width; x += 2)
      ...switch (tag) {
        '2vuy' => [_cb(y, x ~/ 2), _y(y, x), _cr(y, x ~/ 2), _y(y, x + 1)],
        'yuv2' => [
          _y(y, x),
          _cb(y, x ~/ 2) ^ 128,
          _y(y, x + 1),
          _cr(y, x ~/ 2) ^ 128,
        ],
        _ => [
          ..._le(_cb(y, x ~/ 2) << 8, 2),
          ..._le(_y(y, x) << 8, 2),
          ..._le(_cr(y, x ~/ 2) << 8, 2),
          ..._le(_y(y, x + 1) << 8, 2),
        ],
      },
  ];
}

File _movie(Directory dir, List<_Sample> samples) {
  final type = box('ftyp', ascii.encode('qt  '));
  final sizes = samples.map((sample) => sample.data.length).toList();
  final chunks = <int>[];
  var offset = type.length + 8;
  for (final size in sizes) {
    chunks.add(offset);
    offset += size;
  }
  List<int> integers(Iterable<int> values) => [
    for (final v in values) ...uint(v, 4),
  ];
  List<int> table(String tag, List<int> data) =>
      box(tag, [0, 0, 0, 0, ...data]);
  final timing = [
    ...List.filled(12, 0),
    ...uint(1000, 4),
    ...uint(samples.length * 250, 4),
  ];
  final descriptions = [
    for (final sample in samples)
      ...box(sample.tag, [
        ...List.filled(6, 0),
        0,
        1,
        ...List.filled(16, 0),
        ...uint(_width, 2),
        ...uint(_height, 2),
        ...List.filled(46, 0),
        ...uint(sample.depth, 2),
        255,
        255,
        ...sample.extensions,
      ]),
  ];
  final path = File('${dir.path}/uncompressed.mov');
  return path..writeAsBytesSync(
    Uint8List.fromList([
      ...type,
      ...box('mdat', [for (final sample in samples) ...sample.data]),
      ...box('moov', [
        ...box('mvhd', timing),
        ...box(
          'trak',
          box('mdia', [
            ...box('mdhd', timing),
            ...box('hdlr', [...List.filled(8, 0), ...ascii.encode('vide')]),
            ...box(
              'minf',
              box('stbl', [
                ...table('stsd', [...uint(samples.length, 4), ...descriptions]),
                ...table('stsz', integers([0, samples.length, ...sizes])),
                ...table('stco', integers([samples.length, ...chunks])),
                ...table('stts', integers([1, samples.length, 250])),
                ...table(
                  'stsc',
                  integers([
                    samples.length,
                    for (var i = 1; i <= samples.length; i++) ...[i, 1, i],
                  ]),
                ),
              ]),
            ),
          ]),
        ),
      ]),
    ]),
  );
}
