part of 'mpeg_systems.dart';

/// A standalone video bitstream has byte-aligned start codes and no PES clock.
final class _ElementaryVideo implements _PacketSource {
  _ElementaryVideo(this.file, this.codec);

  static _ElementaryVideo? detect(BinaryFile file) {
    if (file.length < 16) return null;
    final prefix = file.read(0, math.min(1024, file.length));
    final first = prefix.indexWhere((byte) => byte != 0);
    if (first < 2 || prefix[first] != 1 || first + 1 == prefix.length) {
      return null;
    }
    if (first == 2 && prefix[3] == 0xb3) {
      return _isMpegSequence(prefix)
          ? _ElementaryVideo(file, 'mpeg2video')
          : null;
    }
    final probe = file.length <= prefix.length
        ? prefix
        : file.read(0, math.min(1024 * 1024, file.length));
    final codec = _annexBCodec(probe);
    return codec == null ? null : _ElementaryVideo(file, codec);
  }

  static bool _isMpegSequence(Uint8List bytes) {
    final units = mpegStartCodes(bytes).iterator;
    if (!units.moveNext()) return false;
    final header = units.current;
    if (!units.moveNext() ||
        !const {0, 0xb2, 0xb5, 0xb8}.contains(units.current.code)) {
      return false;
    }
    try {
      MpegSequence(Uint8List.sublistView(bytes, header.data, header.end));
      return true;
    } on FormatException {
      return false;
    }
  }

  final BinaryFile file;
  final String codec;

  @override
  _Program program() => (videoId: 0, codec: codec, audio: const {});

  @override
  Iterable<_AudioClock> scan(_Program program, _AccessUnits video) {
    const chunkSize = 256 * 1024;
    for (var offset = 0; offset < file.length; offset += chunkSize) {
      final bytes = file.read(
        offset,
        math.min(chunkSize, file.length - offset),
      );
      video.payload(bytes, 0, bytes.length, offset);
    }
    return const [];
  }

  @override
  Uint8List read(FramePacket frame, int videoId) =>
      file.read(frame.offset, frame.size);
}

String? _annexBCodec(Uint8List bytes) {
  final avcSequences = <int>{};
  final hevcVideos = <int>{};
  final hevcSequences = <int>{};
  for (final unit in mpegStartCodes(bytes)) {
    final header = unit.code;
    if (header & 0x80 != 0 || unit.data >= unit.end) continue;
    final avcType = header & 31;
    final hevcType = (header >> 1) & 63;
    final avcParameter = header & 0x60 != 0 && (avcType == 7 || avcType == 8);
    final hevcParameter =
        header.isEven &&
        bytes[unit.data] >= 1 &&
        bytes[unit.data] <= 7 &&
        hevcType >= 32 &&
        hevcType <= 34;
    if (!avcParameter && !hevcParameter) continue;
    // The fixed three-byte start-code scanner can leave a preceding zero
    // byte at the end of a NAL when the next start code uses four bytes.
    var end = unit.end;
    while (end > unit.data && bytes[end - 1] == 0) end--;
    final nal = Uint8List.sublistView(bytes, unit.data - 1, end);
    try {
      if (avcParameter) {
        if (avcType == 7) {
          avcSequences.add(H264Sps.parse(nal).id);
        } else {
          final pps = Rbsp.fromNal(nal)..ue(255);
          if (avcSequences.contains(pps.ue(31))) return 'h264';
        }
        continue;
      }
      final hevc = HevcNal(nal);
      switch (hevcType) {
        case 32:
          hevcVideos.add(hevc.rbsp().read(4));
        case 33:
          final sps = HevcSps.parse(hevc);
          if (hevcVideos.contains(sps.vpsId)) hevcSequences.add(sps.id);
        case 34:
          final pps = hevc.rbsp()..ue(63);
          if (hevcSequences.contains(pps.ue(15))) return 'hevc';
      }
    } on FormatException {
      // An unknown parameter set or a truncated probe is not a signature.
    }
  }
  return null;
}
