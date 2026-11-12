import 'dart:typed_data';

import 'bitstream.dart';
import 'frame_header.dart';
import 'sequence_header.dart';
import 'tile_group.dart';

final class Av1CodedFrame {
  const Av1CodedFrame(
    this.sequence,
    this.syntax,
    this.tiles,
    this.temporalId,
    this.spatialId,
  );

  final Av1SequenceHeader sequence;
  final Av1Header syntax;
  final List<Av1Tile> tiles;
  final int temporalId, spatialId;

  Av1FrameHeader get header => syntax.frame;
  bool get shown => syntax.existingSlot != null || header.showFrame;
  int get refreshFlags => syntax.existingSlot == null
      ? header.refreshFlags
      : (header.type == Av1FrameType.key ? 255 : 0);
}

/// AV1 frames in decoding order. A temporal unit can contain several coded
/// frames before the one to display, including a display-only frame header.
final class Av1AccessUnits {
  Av1AccessUnits({this.operatingPoint = 0});

  final int operatingPoint;
  final _slots = List<Av1FrameHeader?>.filled(8, null);
  Av1SequenceHeader? _sequence;
  Av1FrameHeader? _shownKey;
  Uint8List? _sequencePayload;
  int _idc = 0;

  void configure(Uint8List config) {
    for (final obu in readAv1Obus(config)) {
      if (obu.type == 1) {
        _storeSequence(obu.payload);
      } else if (obu.type != 5 && obu.type != 15) {
        throw const FormatException('Invalid AV1 configuration OBU');
      }
    }
  }

  Iterable<Av1CodedFrame> readSample(Uint8List data) sync* {
    Av1Header? pending;
    Av1Obu? headerObu;
    var pendingTiles = <Av1Tile>[];
    for (final obu in readAv1Obus(data)) {
      if (obu.type == 1) {
        if (pending != null)
          throw const FormatException('New AV1 sequence during a frame');
        _storeSequence(obu.payload);
        continue;
      }
      if (obu.type == 2 && pending != null)
        throw const FormatException('AV1 temporal delimiter inside a frame');
      if (!av1OperatingLayer(_idc, obu.temporalId, obu.spatialId)) continue;
      switch (obu.type) {
        case 3 || 6 || 7:
          if (obu.type == 7 && pending != null) continue;
          if (pending != null)
            throw const FormatException(
              'Incomplete AV1 frame before next header',
            );
          final sequence = _sequence;
          if (sequence == null)
            throw const FormatException('Missing AV1 sequence header');
          final bits = Av1Bits(obu.payload);
          final header = readAv1FrameHeader(bits, sequence, _slots, obu);
          if (obu.type == 6) {
            if (header.existingSlot != null)
              throw const FormatException(
                'Unexpected AV1 tile data for an existing frame',
              );
            bits.align();
            final tiles = readAv1TileGroup(
              bits,
              header.frame.tiles,
              combined: true,
            );
            yield _complete(sequence, header, tiles, obu);
          } else {
            bits.trailing();
            if (header.existingSlot != null) {
              yield _complete(sequence, header, const [], obu);
            } else {
              pending = header;
              headerObu = obu;
            }
          }
        case 4:
          final header = pending;
          if (header == null ||
              headerObu!.temporalId != obu.temporalId ||
              headerObu.spatialId != obu.spatialId)
            throw const FormatException(
              'AV1 tile group has no matching frame header',
            );
          final layout = header.frame.tiles;
          final tiles = readAv1TileGroup(
            Av1Bits(obu.payload),
            layout,
            combined: false,
          );
          if (tiles.first.index != pendingTiles.length)
            throw const FormatException('Out-of-order AV1 tile group');
          pendingTiles.addAll(tiles);
          if (pendingTiles.length == layout.count) {
            yield _complete(_sequence!, header, pendingTiles, headerObu);
            pending = null;
            headerObu = null;
            pendingTiles = [];
          }
        case 8:
          throw UnsupportedError('AV1 tile-list OBUs are unavailable');
      }
    }
    if (pending != null)
      throw const FormatException('Incomplete AV1 frame at sample end');
  }

  Av1CodedFrame _complete(
    Av1SequenceHeader sequence,
    Av1Header syntax,
    List<Av1Tile> tiles,
    Av1Obu obu,
  ) {
    final frame = Av1CodedFrame(
      sequence,
      syntax,
      List.unmodifiable(tiles),
      obu.temporalId,
      obu.spatialId,
    );
    final header = frame.header;
    if (syntax.existingSlot != null && header.type == Av1FrameType.key) {
      if (identical(header, _shownKey))
        throw const FormatException('AV1 show-existing keyframe shown twice');
      _shownKey = header;
    }
    for (var slot = 0; slot < _slots.length; slot++) {
      final mask = 1 << slot;
      if (frame.refreshFlags & mask != 0) {
        _slots[slot] = header;
      } else if (syntax.existingSlot == null &&
          header.invalidatedSlots & mask != 0) {
        _slots[slot] = null;
      }
    }
    return frame;
  }

  void _storeSequence(Uint8List data) {
    final previous = _sequencePayload;
    if (previous != null && _equalBytes(previous, data)) return;
    final sequence = Av1SequenceHeader.read(data);
    if (operatingPoint < 0 || operatingPoint >= sequence.operatingPoints.length)
      throw const FormatException('Unknown AV1 operating point');
    final old = _sequence;
    if (old == null || !sequence.sameCodedSequence(old)) {
      _slots.fillRange(0, _slots.length, null);
      _shownKey = null;
    }
    _sequence = sequence;
    _sequencePayload = Uint8List.fromList(data);
    _idc = sequence.operatingPoints[operatingPoint].idc;
  }
}

bool _equalBytes(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
