import 'dart:math' as math;
import 'dart:typed_data';

import 'avi.dart';
import 'frame_packet.dart';
import 'h264/access_unit.dart';
import 'h264/picture_order.dart';
import 'hevc/access_unit.dart';
import 'hevc/picture_order.dart';
import 'nal_parameter_sets.dart';

typedef AviNalFrame = ({
  FramePacket packet,
  int? type,
  bool randomAccess,
  bool keyframe,
  bool shown,
  Uint8List? parameters,
});

typedef _PictureOrder = ({
  int type,
  int poc,
  bool reset,
  bool shown,
  bool randomAccess,
  H264FieldKey? field,
});

/// AVI supplies decode-order chunks and a stream clock. Reassign their
/// presentation slots by picture order without moving the coded payloads.
final class AviNal {
  AviNal(this.avi, this.codec);

  final Avi avi;
  final String codec;
  late final Uint8List _private = avi.videoPrivateData() ?? Uint8List(0);
  late final Uint8List? record = _private.firstOrNull == 1 ? _private : null;
  late final List<AviNalFrame> frames = _index();

  Uint8List read(FramePacket packet) {
    if (packet.size <= 0 || packet.size > 64 * 1024 * 1024) {
      throw const FormatException('Invalid AVI access unit size');
    }
    final bytes = avi.file.read(packet.offset, packet.size);
    return record == null ? annexBToLengthPrefixed(bytes) : bytes;
  }

  List<AviNalFrame> _index() {
    final initial = _private.isEmpty || record != null
        ? Uint8List(0)
        : annexBToLengthPrefixed(_private);
    final avc = codec != 'h264'
        ? null
        : AvcPictureOrder(
            record == null
                ? AvcConfiguration.inBand(initial)
                : AvcConfiguration(record!),
          );
    final hevc = codec != 'hevc'
        ? null
        : record == null
        ? HevcConfiguration.inBand(initial)
        : HevcConfiguration(record!);
    final parameters = NalParameterSets(
      lengthBytes: hevc?.lengthBytes ?? avc!.configuration.lengthBytes,
    );
    // Preserve format-header parameters for seeks after the first GOP.
    if (hevc != null) {
      for (final nal in hevc.nals(initial)) {
        final key = hevc.store(nal);
        if (key != null) parameters.update(key, nal.bytes);
      }
    } else {
      final configuration = avc!.configuration;
      for (final nal in configuration.nals(initial)) {
        final key = configuration.store(nal);
        if (key != null) parameters.update(key, nal);
      }
    }
    final hevcOrder = HevcPictureOrder();
    var startedHevc = false;
    _PictureOrder? inspect(Uint8List bytes) {
      if (hevc == null) {
        final order = avc!.observe(bytes, onParameterSet: parameters.update);
        return order == null
            ? null
            : (
                type: order.type,
                poc: order.poc,
                reset: order.reset,
                shown: true,
                randomAccess: order.randomAccess,
                field: order.field,
              );
      }
      if (!startedHevc &&
          !hevc
              .nals(bytes)
              .any((nal) => nal.header.layer == 0 && nal.header.randomAccess)) {
        for (final nal in hevc.nals(bytes)) {
          final key = hevc.store(nal);
          if (key != null) parameters.update(key, nal.bytes);
        }
        return null;
      }
      final first = hevc
          .slices(bytes, onParameterSet: parameters.update)
          .firstOrNull;
      if (first == null) return null;
      startedHevc = true;
      final order = hevcOrder.observe(first);
      return (
        type: first.nal.type,
        poc: order.poc,
        reset: order.reset,
        shown: order.output,
        randomAccess: first.nal.randomAccess,
        field: null,
      );
    }

    final result = <AviNalFrame>[];
    final display = <({int index, int epoch, int poc})>[];
    final slots = <FramePacket>[];
    ({H264FieldKey field, FramePacket packet, int poc, bool key})? pending;
    var epoch = 0;
    for (final packet in avi.packets()) {
      final before = parameters.snapshot();
      final order = inspect(read(packet));
      if (order?.reset == true) epoch++;
      final random = order?.randomAccess == true;
      var keyframe = random;
      if (order != null && order.shown) {
        final field = order.field;
        final previous = pending;
        if (field == null) {
          pending = null;
          display.add((index: result.length, epoch: epoch, poc: order.poc));
          slots.add(packet);
        } else if (previous != null &&
            complementaryH264Fields(previous.field, field)) {
          pending = null;
          keyframe |= previous.key;
          display.add((
            index: result.length,
            epoch: epoch,
            poc: math.min(previous.poc, order.poc),
          ));
          final first = previous.packet.timestamp!;
          slots.add(
            _withTime(previous.packet, (
              seconds: previous.packet.seconds,
              timestamp: frameTimestamp(
                first.pts,
                first.numerator,
                first.denominator,
                duration: packet.timestamp!.pts - first.pts + 1,
              ),
            )),
          );
        } else {
          pending = (field: field, packet: packet, poc: order.poc, key: random);
        }
      }
      result.add((
        packet: packet,
        type: order?.type,
        randomAccess: random,
        keyframe: keyframe,
        shown: false,
        parameters: random && record == null
            ? before ?? Uint8List(0)
            : random
            ? before
            : null,
      ));
    }
    display.sort((a, b) {
      final epoch = a.epoch.compareTo(b.epoch);
      if (epoch != 0) return epoch;
      final poc = a.poc.compareTo(b.poc);
      return poc == 0 ? a.index.compareTo(b.index) : poc;
    });
    for (final (i, item) in display.indexed) {
      final sample = result[item.index];
      final slot = slots[i];
      result[item.index] = (
        packet: _withTime(sample.packet, (
          seconds: slot.seconds,
          timestamp: slot.timestamp!,
        )),
        type: sample.type,
        randomAccess: sample.randomAccess,
        keyframe: sample.keyframe,
        shown: true,
        parameters: sample.parameters,
      );
    }
    return result;
  }
}

FramePacket _withTime(
  FramePacket sample,
  ({double seconds, FrameTimestamp timestamp}) time,
) => (
  offset: sample.offset,
  size: sample.size,
  seconds: time.seconds,
  timestamp: time.timestamp,
);
