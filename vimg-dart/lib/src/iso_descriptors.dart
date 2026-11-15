part of 'iso_media.dart';

typedef _DescriptorExtent = ({int data, int end});

extension IsoVisualDescription on IsoMedia {
  MediaBox? visualExtension(MediaBox entry, String type) {
    var offset = entry.data + 78;
    while (offset < entry.end) {
      // A QuickTime video sample description may end with a four-byte zero.
      if (entry.end - offset == 4 && file.unsigned(offset, 4) == 0) return null;
      final box = boxes(offset, entry.end).first;
      if (box.type == type) return box;
      offset = box.end;
    }
    return null;
  }

  ({int matrix, bool? fullRange})? visualColor(MediaBox entry) {
    final color = visualExtension(entry, 'colr');
    if (color == null || color.end - color.data < 4) return null;
    final type = tag(color.data);
    if (type != 'nclc' && type != 'nclx') return null;
    requireBytes(color, type == 'nclx' ? 11 : 10);
    return (
      matrix: file.unsigned(color.data + 8, 2),
      fullRange: type == 'nclx'
          ? file.unsigned(color.data + 10, 1) & 128 != 0
          : null,
    );
  }

  double? visualSampleAspect(MediaBox entry) {
    final aspect = visualExtension(entry, 'pasp');
    if (aspect == null) return null;
    requireBytes(aspect, 8);
    final h = file.unsigned(aspect.data, 4);
    final v = file.unsigned(aspect.data + 4, 4);
    return h == 0 || v == 0 ? null : h / v;
  }

  ({String? codec, _DescriptorExtent? specific})? _visualDescriptor(
    MediaBox entry,
  ) {
    final esds = visualExtension(entry, 'esds');
    if (esds == null) return null;
    requireBytes(esds, 4);
    final es = _descriptor(0x03, esds.data + 4, esds.end);
    if (es == null) return null;
    if (es.end - es.data < 3) {
      throw const FormatException('Truncated ISO media ES descriptor');
    }
    final flags = file.unsigned(es.data + 2, 1);
    var start = es.data + 3;
    if (flags & 0x80 != 0) start += 2; // dependsOn_ES_ID
    if (flags & 0x40 != 0) {
      if (start >= es.end) {
        throw const FormatException('Truncated ISO media ES descriptor URL');
      }
      start += 1 + file.unsigned(start, 1);
    }
    if (flags & 0x20 != 0) start += 2; // OCR_ES_Id
    final decoder = _descriptor(0x04, start, es.end);
    if (decoder == null) return null;
    if (decoder.end - decoder.data < 13) {
      throw const FormatException('Truncated ISO media decoder descriptor');
    }
    final objectType = file.unsigned(decoder.data, 1);
    final streamType = file.unsigned(decoder.data + 1, 1) >> 2;
    if (streamType != 4) return null;
    // MP4 Registration Authority object type indications for VisualStream.
    final codec = switch (objectType) {
      0x6a => 'mpeg1video',
      >= 0x60 && <= 0x65 => 'mpeg2video',
      _ => null,
    };
    return (
      codec: codec,
      specific: _descriptor(0x05, decoder.data + 13, decoder.end),
    );
  }

  _DescriptorExtent? _descriptor(int type, int start, int end) {
    var cursor = start;
    while (cursor < end) {
      final tag = file.unsigned(cursor++, 1);
      var size = 0, octet = 0x80;
      for (var i = 0; i < 4 && octet & 0x80 != 0 && cursor < end; i++) {
        octet = file.unsigned(cursor++, 1);
        size = (size << 7) | (octet & 0x7f);
      }
      if (octet & 0x80 != 0 || size > end - cursor) {
        throw const FormatException('Invalid ISO media descriptor length');
      }
      if (tag == type) return (data: cursor, end: cursor + size);
      cursor += size;
    }
    if (cursor != end) {
      throw const FormatException('Invalid ISO media descriptor length');
    }
    return null;
  }
}
