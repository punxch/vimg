part of 'mpeg_systems.dart';

const _tsPacketSize = 188;

final class _TransportInput implements _PacketSource {
  _TransportInput(this.file, this.stride, this.sync);

  static _TransportInput? detect(BinaryFile file) {
    final count = math.min(file.length, 5 * 204);
    final bytes = file.read(0, count);
    for (final (stride, sync) in [(188, 0), (192, 4), (204, 0)]) {
      var packets = 0;
      for (var i = sync; i + _tsPacketSize <= count; i += stride) {
        if (bytes[i] != 0x47 || bytes[i + 3] & 0x30 == 0) {
          packets = 0;
          break;
        }
        packets++;
      }
      if (packets >= 3) return _TransportInput(file, stride, sync);
    }
    return null;
  }

  final BinaryFile file;
  final int stride, sync;
  var _chunkPosition = -1;
  var _chunk = Uint8List(0);

  Iterable<_TransportPacket> packets([int? offset]) sync* {
    final chunkSize = stride * 1024;
    final first = offset == null
        ? sync
        : sync + (offset - sync) ~/ stride * stride;
    for (
      var position = first;
      position + _tsPacketSize <= file.length;
      position += stride
    ) {
      final chunkPosition = sync + (position - sync) ~/ chunkSize * chunkSize;
      if (chunkPosition != _chunkPosition) {
        _chunk = file.read(
          chunkPosition,
          math.min(chunkSize, file.length - chunkPosition),
        );
        _chunkPosition = chunkPosition;
      }
      yield _TransportPacket(_chunk, position - chunkPosition, position);
    }
  }

  @override
  _Program program() {
    final pat = _Sections(0);
    final tables = <int, _Sections>{};
    final programs = <int, _Program?>{};
    for (final packet in packets()) {
      if (packet.pid == 0) {
        for (final section in pat.read(packet)) {
          final end = section.length - 4;
          for (var i = 8; i + 4 <= end; i += 4) {
            if (_uint16(section, i) == 0) continue;
            tables.putIfAbsent(
              _uint16(section, i + 2) & 8191,
              () => _Sections(2),
            );
          }
        }
      } else {
        final table = tables[packet.pid];
        if (table == null || programs.containsKey(packet.pid)) continue;
        for (final section in table.read(packet)) {
          programs[packet.pid] = _programMap(section);
        }
        for (final pid in tables.keys) {
          if (!programs.containsKey(pid)) break;
          final program = programs[pid];
          if (program != null) return program;
        }
        if (programs.length == tables.length) break;
      }
    }
    for (final program in programs.values) {
      if (program != null) return program;
    }
    if (programs.isNotEmpty) {
      throw UnsupportedError('MPEG-TS has no supported video stream');
    }
    throw const FormatException('Missing MPEG-TS program tables');
  }

  @override
  Iterable<_AudioClock> scan(_Program program, _AccessUnits video) {
    final audio = {
      for (final entry in program.audio.entries)
        entry.key: _TransportAudio(entry.value),
    };
    final continuity = _Continuity();
    final pes = _PesReader(video.payload, onTime: video.timestamp);
    for (final packet in packets()) {
      if (packet.pid == program.videoId) {
        if (continuity.accept(packet)) pes.add(packet);
      } else {
        audio[packet.pid]?.add(packet);
      }
    }
    if (pes.incomplete && isMpegVideo(program.codec)) {
      video.discardTail();
    } else {
      pes.finish();
    }
    return audio.values.map((track) => track.clock);
  }

  @override
  Uint8List read(FramePacket frame, int videoId) {
    final data = Uint8List(frame.size);
    var written = 0;
    final pes = _PesReader((bytes, start, end, _) {
      final count = math.min(end - start, data.length - written);
      data.setRange(written, written + count, bytes, start);
      written += count;
    });
    final continuity = _Continuity();
    for (final packet in packets(frame.offset)) {
      if (packet.pid != videoId || !continuity.accept(packet)) continue;
      if (written == 0) {
        final start = packet.start + frame.offset - packet.position;
        if (start < packet.payload || start >= packet.end) {
          throw const FormatException('Invalid MPEG-TS access unit offset');
        }
        pes.resume(packet, start);
      } else {
        pes.add(packet);
      }
      if (written == data.length) return data;
    }
    throw const FormatException('Truncated MPEG-TS access unit');
  }
}

_Program? _programMap(Uint8List section) {
  final end = section.length - 4;
  if (end < 12) throw const FormatException('Truncated MPEG-TS program map');
  int? videoPid;
  String? codec;
  final audio = <int, int>{};
  var i = 12 + (_uint16(section, 10) & 4095);
  while (i + 5 <= end) {
    final type = section[i];
    final pid = _uint16(section, i + 1) & 8191;
    final videoCodec = _videoCodec(type);
    if (videoPid == null && videoCodec != null) {
      videoPid = pid;
      codec = videoCodec;
    }
    if (const {
      3,
      4,
      0x0f,
      0x11,
      0x80,
      0x81,
      0x82,
      0x83,
      0x84,
      0x85,
      0x86,
      0x87,
    }.contains(type)) {
      audio[pid] = type;
    }
    i += 5 + (_uint16(section, i + 3) & 4095);
  }
  if (i != end)
    throw const FormatException('Invalid MPEG-TS program descriptors');
  return videoPid == null
      ? null
      : (videoId: videoPid, codec: codec!, audio: audio);
}

final class _TransportPacket {
  _TransportPacket(this.bytes, this.start, this.position) {
    if (bytes[start] != 0x47) {
      throw const FormatException('Invalid MPEG-TS packet sync');
    }
  }

  final Uint8List bytes;
  final int start, position;
  int get end => start + _tsPacketSize;
  int get pid => _uint16(bytes, start + 1) & 8191;
  bool get begins => bytes[start + 1] & 0x40 != 0;
  int get counter => bytes[start + 3] & 15;
  bool get unusable =>
      bytes[start + 1] & 0x80 != 0 || bytes[start + 3] & 0xc0 != 0;
  bool get _adapted => bytes[start + 3] & 0x20 != 0;
  bool get discontinuity =>
      _adapted && bytes[start + 4] > 0 && bytes[start + 5] & 0x80 != 0;
  int get payload => bytes[start + 3] & 0x10 == 0
      ? end
      : start + 4 + (_adapted ? bytes[start + 4] + 1 : 0);
}

final class _Continuity {
  int? _counter;

  bool accept(_TransportPacket packet) {
    final payload = packet.payload;
    if (payload > packet.end || packet.unusable) {
      throw const FormatException('Damaged or scrambled MPEG-TS packet');
    }
    if (packet.discontinuity) _counter = null;
    if (payload == packet.end) return false;
    final previous = _counter;
    final current = packet.counter;
    if (current == previous) return false; // retransmitted payload
    if (previous != null && current != (previous + 1) & 15) {
      throw FormatException('MPEG-TS continuity error on PID ${packet.pid}');
    }
    _counter = current;
    return true;
  }
}

/// One PID's PSI sections. Pointer bytes can finish a previous section, and
/// more than one section can begin in the same transport packet.
final class _Sections {
  _Sections(this.tableId);

  final int tableId;
  final _buffer = Uint8List(1024);
  int _length = 0;
  int? _counter;

  Iterable<Uint8List> read(_TransportPacket packet) sync* {
    if (packet.unusable || packet.payload >= packet.end) return;
    final previous = _counter;
    final current = packet.counter;
    if (current == previous && !packet.discontinuity) return;
    if (packet.discontinuity ||
        (previous != null && current != (previous + 1) & 15)) {
      _length = 0;
    }
    _counter = current;
    var start = packet.payload;
    if (packet.begins) {
      final pointer = packet.bytes[start++];
      final next = start + pointer;
      if (next > packet.end) {
        _length = 0;
        return;
      }
      if (_length > 0) yield* _read(packet.bytes, start, next);
      _length = 0;
      start = next;
    } else if (_length == 0) {
      return;
    }
    yield* _read(packet.bytes, start, packet.end);
  }

  Iterable<Uint8List> _read(Uint8List bytes, int start, int end) sync* {
    while (start < end) {
      if (_length == 0 && bytes[start] == 0xff) return;
      if (_length < 3) {
        final count = math.min(3 - _length, end - start);
        _buffer.setRange(_length, _length + count, bytes, start);
        _length += count;
        start += count;
        if (_length < 3) return;
      }
      final size = 3 + (_uint16(_buffer, 1) & 4095);
      if (size < 12 || size > _buffer.length) {
        _length = 0;
        return;
      }
      final count = math.min(size - _length, end - start);
      _buffer.setRange(_length, _length + count, bytes, start);
      _length += count;
      start += count;
      if (_length != size) return;
      final section = Uint8List.sublistView(_buffer, 0, size);
      if (section[0] == tableId &&
          section[1] & 0x80 != 0 &&
          section[5] & 1 != 0 &&
          _crc(section) == 0) {
        yield section;
      }
      _length = 0;
    }
  }
}

int _crc(Uint8List section) {
  var crc = 0xffffffff;
  for (final byte in section) {
    crc ^= byte << 24;
    for (var bit = 0; bit < 8; bit++) {
      crc =
          ((crc << 1) ^ (crc & 0x80000000 != 0 ? 0x04c11db7 : 0)) & 0xffffffff;
    }
  }
  return crc;
}

typedef _Payload = void Function(Uint8List, int, int, int);

/// PES packets can start inside an adapted TS packet, and their optional
/// header can span transport packets. Emit only elementary-stream bytes.
final class _PesReader {
  _PesReader(this.onPayload, {this.onTime});

  final _Payload onPayload;
  final void Function(int pts, int dts)? onTime;
  final _header = Uint8List(9 + 255);
  var _headerBytes = 0, _headerSize = 9;
  var _reading = false, _inHeader = false;
  int? _remaining;
  bool get incomplete => _inHeader || (_remaining ?? 0) > 0;

  void resume(_TransportPacket packet, int start) {
    _reading = true;
    _emit(packet, start);
  }

  void add(_TransportPacket packet) {
    var start = packet.payload;
    if (packet.begins) {
      finish();
      _reading = _inHeader = true;
      _headerBytes = 0;
      _headerSize = 9;
      _remaining = null;
    }
    if (!_reading) return;
    while (_inHeader && start < packet.end) {
      final count = math.min(_headerSize - _headerBytes, packet.end - start);
      _header.setRange(_headerBytes, _headerBytes + count, packet.bytes, start);
      _headerBytes += count;
      start += count;
      if (_headerBytes < _headerSize) return;
      if (_headerSize == 9) {
        if (_header[0] != 0 ||
            _header[1] != 0 ||
            _header[2] != 1 ||
            _header[6] & 0xc0 != 0x80) {
          throw const FormatException('Invalid MPEG-TS PES header');
        }
        _headerSize = 9 + _header[8];
        if (_headerBytes < _headerSize) continue;
      }
      _endHeader();
    }
    if (!_inHeader) _emit(packet, start);
  }

  void _endHeader() {
    final length = _uint16(_header, 4);
    if (length != 0) {
      _remaining = length + 6 - _headerSize;
      if (_remaining! < 0)
        throw const FormatException('Invalid MPEG-TS PES length');
    }
    if (_mpeg2PesTime(_header, _headerSize) case final time?) {
      onTime?.call(time.$1, time.$2);
    }
    _inHeader = false;
  }

  void _emit(_TransportPacket packet, int start) {
    final available = packet.end - start;
    final remaining = _remaining;
    final count = remaining == null
        ? available
        : math.min(available, remaining);
    if (count == 0) return;
    onPayload(
      packet.bytes,
      start,
      start + count,
      packet.position + start - packet.start,
    );
    if (remaining != null) _remaining = remaining - count;
  }

  void finish() {
    if (incomplete) {
      throw const FormatException('Truncated MPEG-TS PES packet');
    }
  }
}

int _uint16(Uint8List bytes, int i) => (bytes[i] << 8) | bytes[i + 1];

final class _TransportAudio {
  _TransportAudio(this.type);

  final int type;
  final clock = _AudioClock();
  final _continuity = _Continuity();
  late final _PesReader _pes = _PesReader(
    _payload,
    onTime: (pts, _) {
      clock.timestamp(pts);
    },
  );

  void add(_TransportPacket packet) {
    if (_continuity.accept(packet)) _pes.add(packet);
  }

  void _payload(Uint8List bytes, int start, int end, int position) {
    if (type == 0x0f) clock.duration ??= _adtsDuration(bytes, start, end);
  }
}
