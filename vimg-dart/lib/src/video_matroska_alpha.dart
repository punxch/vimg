part of 'video.dart';

typedef _MatroskaAlphaExtent = ({int offset, int size});
typedef _MatroskaAlphaRun = ({
  List<_MatroskaAlphaExtent> warmup,
  Map<FramePacket, _MatroskaAlphaExtent> blocks,
});

/// The opacity stream can start its GOPs at different packets from the color
/// stream. A color decode job carries just the alpha history it needs.
final class _MatroskaAlphaIndex {
  _MatroskaAlphaIndex(this.file, this.codec);

  final BinaryFile file;
  final String codec;
  final _packets = <FramePacket, int>{};
  final _payloads = <_MatroskaAlphaExtent>[];
  final _anchors = <int>[];
  int _key = -1;

  void add(FramePacket packet, EbmlElement data) {
    final index = _payloads.length;
    final size = data.end - data.data;
    final key = codec == 'vp9'
        ? vp9PacketTag(
            size,
            (offset, length) => file.read(data.data + offset, length),
          ).key
        : vp8FrameTag(file.read(data.data, size < 3 ? size : 3)).key;
    if (key) _key = index;
    _packets[packet] = index;
    _payloads.add((offset: data.data, size: size));
    _anchors.add(_key);
  }

  _MatroskaAlphaRun? forRun(List<FramePacket> packets) {
    if (_packets.isEmpty) return null;
    final blocks = <FramePacket, _MatroskaAlphaExtent>{};
    int? first;
    for (final packet in packets) {
      final index = _packets[packet];
      if (index == null) continue;
      first ??= index;
      blocks[packet] = _payloads[index];
    }
    if (first == null) return null;
    final key = _anchors[first];
    if (key < 0)
      throw FormatException('Missing ${codec.toUpperCase()} alpha keyframe');
    return (warmup: _payloads.sublist(key, first), blocks: blocks);
  }
}

final class _MatroskaAlphaDecoder<T> {
  _MatroskaAlphaDecoder(this.file, this.run, this._decode) {
    for (final extent in run.warmup) {
      _decode(file.read(extent.offset, extent.size));
    }
  }

  final BinaryFile file;
  final _MatroskaAlphaRun run;
  final T? Function(Uint8List) _decode;

  T? decode(FramePacket packet) {
    final extent = run.blocks[packet];
    if (extent == null) return null;
    return _decode(file.read(extent.offset, extent.size));
  }
}
