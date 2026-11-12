import 'dart:typed_data';

import 'frame_packet.dart';
import 'matroska.dart';

Iterable<FramePacket> matroskaCovers(Matroska media) sync* {
  for (final element in media.segmentElements()) {
    if (element.id != 0x1941a469) continue;
    for (final attachment in media.pictureAttachments(element)) {
      final data = attachment[0x465c]!;
      yield (
        seconds: 0,
        offset: data.data,
        size: data.end - data.data,
        timestamp: null,
      );
    }
  }
}

Iterable<FramePacket> matroskaFrames(
  Matroska media, {
  bool keyframes = false,
  FrameVisitor? onSample,
}) sync* {
  int? trackNumber;
  int? frameDuration;
  var timestampScale = 1000000;
  for (final element in media.segmentElements()) {
    switch (element.id) {
      case 0x1549a966:
        timestampScale =
            media.number(media.fields(element)[0x2ad7b1]) ?? 1000000;
        if (timestampScale <= 0)
          throw const FormatException('Invalid Matroska timestamp scale');
      case 0x1654ae6b:
        final track = media.videoTracks(element).firstOrNull;
        if (track == null) break;
        if (track.containsKey(0x6d80)) {
          throw const FormatException(
            'Encoded Matroska track contents are unsupported',
          );
        }
        trackNumber = media.number(track[0xd7]);
        frameDuration = media.number(track[0x23e383]);
      case matroskaCluster:
        if (trackNumber == null) continue;
        // Timestamp can occur anywhere in a Cluster.
        final timestamp = media
            .elements(element.data, element.end)
            .where((child) => child.id == 0xe7)
            .firstOrNull;
        final clusterTime = media.number(timestamp);
        if (clusterTime == null)
          throw const FormatException('Missing Cluster timestamp');
        for (final child in media.elements(element.data, element.end)) {
          if (child.id == 0xa3) {
            yield* _block(
              media,
              child,
              trackNumber,
              clusterTime,
              timestampScale,
              frameDuration,
              keyframes: keyframes,
              onSample: onSample,
            );
          } else if (child.id == 0xa0) {
            final group = media.fields(child);
            final block = group[0xa1];
            if (block == null) continue;
            final sync = !group.containsKey(0xfb);
            if (keyframes && !sync) continue;
            final duration = media.number(group[0x9b]);
            yield* _block(
              media,
              block,
              trackNumber,
              clusterTime,
              timestampScale,
              frameDuration,
              blockDuration: duration,
              groupKeyframe: sync,
              onSample: onSample,
            );
          }
        }
    }
  }
}

Iterable<FramePacket> _block(
  Matroska media,
  EbmlElement block,
  int track,
  int clusterTime,
  int timestampScale,
  int? frameDuration, {
  int? blockDuration,
  bool keyframes = false,
  bool? groupKeyframe,
  FrameVisitor? onSample,
}) sync* {
  final trackField = media.vint(block.data, block.end);
  if (trackField.value != track) return;
  var offset = block.data + trackField.width;
  if (block.end - offset < 3)
    throw const FormatException('Truncated Matroska Block');
  final header = ByteData.sublistView(media.file.read(offset, 3));
  final flags = header.getUint8(2);
  final sync = groupKeyframe ?? flags & 0x80 != 0;
  if (keyframes && !sync) return;
  final pts = clusterTime + header.getInt16(0);
  final seconds = pts * (timestampScale / 1e9);
  offset += 3;
  final lacing = (flags >> 1) & 3;
  if (lacing == 0) {
    final packet = (
      seconds: seconds,
      offset: offset,
      size: block.end - offset,
      timestamp: frameTimestamp(
        pts,
        timestampScale,
        1000000000,
        duration: blockDuration ?? (frameDuration ?? 0) ~/ timestampScale,
      ),
    );
    onSample?.call(packet, sync);
    yield packet;
    return;
  }

  int nextByte() {
    if (offset == block.end)
      throw const FormatException('Truncated Matroska lace');
    return media.file.unsigned(offset++, 1);
  }

  final count = nextByte() + 1;
  final sizes = <int>[];
  if (lacing == 2) {
    if ((block.end - offset) % count != 0) {
      throw const FormatException('Invalid fixed Matroska lace');
    }
    sizes.addAll(List.filled(count, (block.end - offset) ~/ count));
  } else {
    var remaining = block.end - offset;
    for (var index = 0; index < count - 1; index++) {
      var size = 0;
      final previousOffset = offset;
      if (lacing == 1) {
        int part;
        do {
          part = nextByte();
          size += part;
        } while (part == 255);
      } else {
        final field = media.vint(offset, block.end);
        offset += field.width;
        size = index == 0
            ? field.value
            : sizes.last + field.value - ((1 << (7 * field.width - 1)) - 1);
      }
      remaining -= size + offset - previousOffset;
      if (size <= 0 || remaining < 0) {
        throw const FormatException('Invalid Matroska lace size');
      }
      sizes.add(size);
    }
    sizes.add(remaining);
  }
  final step = blockDuration == null
      ? (frameDuration ?? 0) / 1e9
      : blockDuration * (timestampScale / 1e9) / count;
  FrameTimestamp laceTimestamp(int index) {
    if (blockDuration == null) {
      final duration = frameDuration ?? 0;
      final unit = timestampScale.gcd(duration);
      final lacePts =
          pts * (timestampScale ~/ unit) + index * (duration ~/ unit);
      return frameTimestamp(
        lacePts,
        unit,
        1000000000,
        duration: duration ~/ unit,
      );
    }
    final divisor = count.gcd(blockDuration);
    final ticks = count ~/ divisor;
    return frameTimestamp(
      pts * ticks + index * (blockDuration ~/ divisor),
      timestampScale,
      1000000000 * ticks,
      duration: blockDuration ~/ divisor,
    );
  }

  for (var index = 0; index < count; index++) {
    final packet = (
      seconds: seconds + index * step,
      offset: offset,
      size: sizes[index],
      timestamp: laceTimestamp(index),
    );
    onSample?.call(packet, sync);
    yield packet;
    offset += sizes[index];
  }
}
