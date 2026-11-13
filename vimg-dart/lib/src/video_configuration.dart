import 'dart:typed_data';

import 'dib_palette.dart';
import 'huffyuv.dart';
import 'iso_media.dart';
import 'matroska.dart';
import 'msvideo1.dart';
import 'raw_video.dart';

RawVideoFormat? matroskaRawVideoConfiguration(Matroska media) {
  final track = _firstVideoTrack(media, 'rawvideo');
  if (track == null) return null;
  final video = media.fields(track[0xe0]!);
  final width = media.number(video[0xb0]) ?? 0;
  final height = media.number(video[0xba]) ?? 0;
  final vfw = media.text(track[0x86]) == 'V_MS/VFW/FOURCC';
  final box = vfw ? track[0x63a2] : video[0x2eb524];
  final offset = vfw ? 16 : 0;
  if (box == null ||
      box.end - box.data < offset + 4 ||
      (!vfw && box.end - box.data != 4)) {
    throw const FormatException('Missing or invalid Matroska raw video FourCC');
  }
  final colorBox = video[0x55b0];
  final color = colorBox == null ? null : media.fields(colorBox);
  final matrix = media.number(color?[0x55b1]);
  final range = media.number(color?[0x55b9]);
  return RawVideoFormat(
    String.fromCharCodes(media.file.read(box.data + offset, 4)),
    width,
    height,
    matrix: matrix,
    fullRange: switch (range) {
      1 => false,
      2 => true,
      _ => null,
    },
  );
}

({MsVideo1Format format, List<int>? palette}) matroskaVideo1Configuration(
  Matroska media,
) {
  final config = _firstVideoTrack(media, 'msvideo1')?[0x63a2];
  if (config == null || config.end - config.data < 40) {
    throw const FormatException('Missing Microsoft Video 1 bitmap header');
  }
  final data = ByteData.sublistView(media.file.read(config.data, 40));
  final headerSize = data.getUint32(0, Endian.little);
  if (headerSize < 40 || headerSize > config.end - config.data) {
    throw const FormatException('Invalid Microsoft Video 1 bitmap header');
  }
  final bits = data.getUint16(14, Endian.little);
  final format = MsVideo1Format(
    data.getInt32(4, Endian.little),
    data.getInt32(8, Endian.little).abs(),
    bits,
  );
  return (
    format: format,
    palette: format.indexed
        ? readDibPalette(media.file, config.data, config.end, bits)
        : null,
  );
}

Uint8List? matroskaVideoConfiguration(Matroska media, String codec) {
  final track = _firstVideoTrack(media, codec);
  final config = track?[0x63a2];
  if (config == null) return null;
  final start = media.text(track![0x86]) == 'V_MS/VFW/FOURCC'
      ? config.data + 40
      : config.data;
  final length = config.end - start;
  if (length < _minimumSize(codec) || length > 1024 * 1024) return null;
  return media.file.read(start, length);
}

HuffYuvDecoder? matroskaHuffYuvConfiguration(Matroska media, String codec) {
  final config = _firstVideoTrack(media, codec)?[0x63a2];
  return config == null
      ? null
      : readHuffYuvFormat(media.file, config.data, config.end);
}

Map<int, EbmlElement>? _firstVideoTrack(Matroska media, String codec) {
  final tracks = media
      .segmentElements()
      .where((box) => box.id == 0x1654ae6b)
      .firstOrNull;
  if (tracks == null) return null;
  final track = media.videoTracks(tracks).firstOrNull;
  if (track == null || media.trackCodec(track) != codec) return null;
  return track;
}

Uint8List? isoVideoConfiguration(
  IsoMedia media,
  String codec, {
  MediaBox? description,
}) {
  final boxType = switch (codec) {
    'hevc' => 'hvcC',
    'av1' => 'av1C',
    _ => 'avcC',
  };
  final entry =
      description ??
      media.sampleDescription(
        media.sampleTable(media.child(media.firstVideoTrack(), 'mdia')),
      );
  if (entry == null) return null;
  final configuration = media
      .children(entry, skip: 78)
      .where((box) => box.type == boxType)
      .firstOrNull;
  if (configuration == null) return null;
  final size = configuration.end - configuration.data;
  if (size < _minimumSize(codec) || size > 1024 * 1024) return null;
  return media.file.read(configuration.data, size);
}

int _minimumSize(String codec) => switch (codec) {
  'hevc' => 23,
  'av1' => 4,
  _ => 7,
};
