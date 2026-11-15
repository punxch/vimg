part of 'video.dart';

typedef _Vp8AlphaExtent = ({int offset, int size});
typedef _Vp8AlphaRun = ({
  List<_Vp8AlphaExtent> warmup,
  Map<FramePacket, _Vp8AlphaExtent> blocks,
});

/// The opacity stream can start its GOPs at different packets from the color
/// stream. A color decode job carries just the alpha history it needs.
final class _Vp8AlphaIndex {
  _Vp8AlphaIndex(this.file);

  final BinaryFile file;
  final _packets = <FramePacket, int>{};
  final _payloads = <_Vp8AlphaExtent>[];
  final _anchors = <int>[];
  int _key = -1;

  void add(FramePacket packet, EbmlElement data) {
    final index = _payloads.length;
    if (vp8FrameTag(file.read(data.data, 3)).key) _key = index;
    _packets[packet] = index;
    _payloads.add((offset: data.data, size: data.end - data.data));
    _anchors.add(_key);
  }

  _Vp8AlphaRun? forRun(List<FramePacket> packets) {
    if (_packets.isEmpty) return null;
    final blocks = <FramePacket, _Vp8AlphaExtent>{};
    int? first;
    for (final packet in packets) {
      final index = _packets[packet];
      if (index == null) continue;
      first ??= index;
      blocks[packet] = _payloads[index];
    }
    if (first == null) return null;
    final key = _anchors[first];
    if (key < 0) throw const FormatException('Missing VP8 alpha keyframe');
    return (warmup: _payloads.sublist(key, first), blocks: blocks);
  }
}

final class _Vp8AlphaDecoder {
  _Vp8AlphaDecoder(this.file, this.run) {
    for (final extent in run.warmup) {
      _decoder.decode(file.read(extent.offset, extent.size));
    }
  }

  final BinaryFile file;
  final _Vp8AlphaRun run;
  final _decoder = Vp8Decoder();

  Vp8Picture? decode(FramePacket packet) {
    final extent = run.blocks[packet];
    if (extent == null) return null;
    final bytes = file.read(extent.offset, extent.size);
    final picture = _decoder.decode(bytes);
    return vp8FrameTag(bytes).shown ? picture : null;
  }
}
