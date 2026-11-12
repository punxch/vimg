import 'dart:typed_data';

import '../iso_media.dart';
import '../matroska.dart';

Uint8List? matroskaAvcConfiguration(Matroska media) {
  final tracks = media
      .segmentElements()
      .where((box) => box.id == 0x1654ae6b)
      .firstOrNull;
  if (tracks == null) return null;
  final track = media.videoTracks(tracks).firstOrNull;
  if (track == null || media.trackCodec(track) != 'h264') return null;
  final config = track[0x63a2];
  if (config == null) return null;
  final start = media.text(track[0x86]) == 'V_MS/VFW/FOURCC'
      ? config.data + 40
      : config.data;
  final length = config.end - start;
  if (length < 7 || length > 1024 * 1024) return null;
  return media.file.read(start, length);
}

Uint8List? isoAvcConfiguration(IsoMedia media) {
  final track = media.firstVideoTrack();
  final entry = media.sampleDescription(
    media.sampleTable(media.child(track, 'mdia')),
  );
  if (entry == null) return null;
  final configuration = media
      .children(entry, skip: 78)
      .where((box) => box.type == 'avcC')
      .firstOrNull;
  if (configuration == null) return null;
  final size = configuration.end - configuration.data;
  if (size < 7 || size > 1024 * 1024) return null;
  return media.file.read(configuration.data, size);
}
