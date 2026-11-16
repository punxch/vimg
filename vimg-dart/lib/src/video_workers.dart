part of 'video.dart';

/// Reuses a bounded set of decoder isolates for capture batches. Independent
/// decode runs can finish in any order and results identify their source packet.
final class VideoCaptureDecoder {
  VideoCaptureDecoder(
    this._video, {
    required int threads,
    YuvImageScaler? scaler,
    bool includeOriginal = false,
  }) : _limit = _workerLimit(threads),
       _scaler = scaler,
       _includeOriginal = includeOriginal;

  final Video _video;
  final int _limit;
  final YuvImageScaler? _scaler;
  final bool _includeOriginal;
  final _workers = <SendPort>[];
  final _isolates = <Isolate>[];
  ReceivePort? _events;
  StreamIterator<Object?>? _messages;
  var _busy = false, _closed = false;

  static int _workerLimit(int threads) {
    if (threads < 0) throw ArgumentError.value(threads, 'threads');
    final available = Platform.numberOfProcessors;
    return threads == 0 || threads > available ? available : threads;
  }

  Stream<_SelectedFrame> decode(Iterable<FramePacket> selected) =>
      _decode(selected, null);

  Stream<_SelectedFrame> decodeCaptures(
    Iterable<CaptureFrame> selected, {
    Map<FramePacket, int>? firstUse,
  }) {
    final captures = <FramePacket, Set<CaptureFrame>>{};
    var dynamicFilters = false, graph = false;
    for (final frame in selected) {
      captures.putIfAbsent(frame.packet, () => {}).add(frame);
      if (frame.positions.isNotEmpty) dynamicFilters = true;
      if (frame.picture != null) graph = true;
    }
    if (graph) {
      final composition = _FilterComposition(
        captures.values.expand((frames) => frames),
        _scaler!,
        _includeOriginal,
        firstUse,
      );
      return _decode(
        composition.uses.keys,
        null,
        firstUse: firstUse == null ? null : composition.priorities,
        composition: composition,
      );
    }
    return _decode(
      captures.keys,
      dynamicFilters ? captures : null,
      firstUse: firstUse,
    );
  }

  Stream<_SelectedFrame> _decode(
    Iterable<FramePacket> selected,
    Map<FramePacket, Set<CaptureFrame>>? captures, {
    Map<FramePacket, int>? firstUse,
    _FilterComposition? composition,
  }) async* {
    if (_closed || _busy) throw StateError('Capture decoder is unavailable');
    _busy = true;
    var finished = false;
    try {
      final runs = _video._decodeRuns(selected).toList();
      final active = _limit < runs.length ? _limit : runs.length;
      if (firstUse != null && runs.length > 1) {
        final priorities = <_DecodeRun, int>{};
        for (final run in runs) {
          var first = firstUse[run.packets[run.targets.first]]!;
          for (final target in run.targets) {
            final rank = firstUse[run.packets[target]]!;
            if (rank < first) first = rank;
          }
          priorities[run] = first;
        }
        // Prioritize the earliest grid. Among runs needed by the same grid,
        // give longer GOPs a head start to balance decoding work.
        runs.sort((a, b) {
          final order = priorities[a]!.compareTo(priorities[b]!);
          return order == 0
              ? b.packets.length.compareTo(a.packets.length)
              : order;
        });
      }
      if (active <= 1) {
        for (final run in runs) {
          if (composition != null) {
            for (final picture in _video._decodeNativeRun(run)) {
              for (final frame in composition.add(picture)) {
                yield frame;
              }
            }
            continue;
          }
          for (final frame in _video._decodeRun(
            run,
            _scaler,
            _includeOriginal,
            captures: captures,
          )) {
            yield frame;
          }
        }
      } else {
        await _startWorkers(active);
        if (firstUse == null) {
          // Start longer GOPs early when the consumer accepts any order.
          runs.sort((a, b) => b.packets.length.compareTo(a.packets.length));
        }
        void send(int worker, _DecodeRun run) {
          _workers[worker].send((
            run: run,
            native: composition != null,
            captures: captures == null
                ? null
                : {
                    for (final index in run.targets)
                      run.packets[index]: captures[run.packets[index]]!,
                  },
          ));
        }

        var next = 0;
        for (; next < active; next++) {
          send(next, runs[next]);
        }
        var working = active;
        while (working > 0) {
          switch (await _receive()) {
            case final _DecodedNativeFrame result:
              if (firstUse != null) _workers[result.worker].send(true);
              for (final frame in composition!.add(result.frame)) {
                yield frame;
              }
              if (firstUse == null) _workers[result.worker].send(true);
            case final _DecodedFrame result:
              final frame = _unpackImage(result.frame);
              final original = result.original;
              // Permit one frame of lookahead while the grid is encoded.
              if (firstUse != null) _workers[result.worker].send(true);
              yield (
                packet: result.capture.packet,
                capture: result.capture,
                frame: frame,
                original: original != null
                    ? _unpackImage(original)
                    : (_includeOriginal ? frame : null),
              );
              if (firstUse == null) _workers[result.worker].send(true);
            case final int worker:
              if (next < runs.length) {
                send(worker, runs[next++]);
              } else {
                working--;
              }
            default:
              throw const FormatException('Invalid capture worker response');
          }
        }
      }
      finished = true;
    } finally {
      _busy = false;
      if (!finished) await _close(abort: true);
    }
  }

  Future<void> _startWorkers(int count) async {
    final events = _events ??= ReceivePort();
    _messages ??= StreamIterator<Object?>(events);
    while (_workers.length < count) {
      final index = _workers.length;
      final port = events.sendPort;
      _isolates.add(
        await Isolate.spawn(
          _decodeWorker,
          (
            path: File(_video.path).absolute.path,
            width: _scaler?.width,
            height: _scaler?.height,
            enlarge: _scaler?.enlarge ?? true,
            filters: _scaler?.filters?.source,
            original: _includeOriginal,
            index: index,
            events: port,
          ),
          onError: port,
          onExit: port,
          debugName: 'vimg-capture-$index',
        ),
      );
      final response = await _receive();
      if (response is! SendPort) {
        throw const FormatException('Capture worker failed to start');
      }
      _workers.add(response);
    }
  }

  Future<Object> _receive() async {
    final messages = _messages!;
    if (!await messages.moveNext()) {
      throw const FormatException('Capture workers stopped');
    }
    switch (messages.current) {
      case final _DecodeFailure failure:
        Error.throwWithStackTrace(
          failure.error,
          StackTrace.fromString(failure.stack),
        );
      case final List<dynamic> failure:
        throw FormatException('Capture worker failed: ${failure.first}');
      case null:
        throw const FormatException('Capture worker exited unexpectedly');
      case final Object response:
        return response;
    }
  }

  Future<void> close() => _close(abort: _busy);

  Future<void> _close({required bool abort}) async {
    if (_closed) return;
    _closed = true;
    try {
      if (!abort && _workers.isNotEmpty) {
        for (final worker in _workers) {
          worker.send(null);
        }
        // Wait for onExit after each idle worker has closed its source file.
        var remaining = _workers.length;
        while (remaining > 0 && await _messages!.moveNext()) {
          if (_messages!.current == null) remaining--;
        }
      }
    } finally {
      for (final isolate in _isolates) {
        isolate.kill(priority: Isolate.immediate);
      }
      _events?.close();
      await _messages?.cancel();
    }
  }
}

final class _FilterComposition {
  _FilterComposition(
    Iterable<CaptureFrame> captures,
    this.scaler,
    this.includeOriginal,
    Map<FramePacket, int>? firstUse,
  ) {
    for (final frame in captures) {
      final picture = frame.picture ?? FilterInputPicture(frame.packet);
      final packets = picture.sourcePackets();
      _pending[frame] = packets.length;
      for (final packet in packets) {
        uses.putIfAbsent(packet, () => []).add(frame);
        if (firstUse != null) {
          final rank = firstUse[frame.packet]!;
          final prior = priorities[packet];
          if (prior == null || rank < prior) priorities[packet] = rank;
        }
      }
    }
    for (final entry in uses.entries) {
      _references[entry.key] = entry.value.length;
    }
  }

  final YuvImageScaler scaler;
  final bool includeOriginal;
  final uses = <FramePacket, List<CaptureFrame>>{};
  final priorities = <FramePacket, int>{};
  final _pending = <CaptureFrame, int>{};
  final _references = <FramePacket, int>{};
  final _pictures = <FramePacket, VideoFilterPicture>{};

  Iterable<_SelectedFrame> add(_NativeCaptureFrame source) sync* {
    _pictures[source.packet] = source.picture;
    for (final capture in uses.remove(source.packet)!) {
      final remaining = _pending[capture]! - 1;
      if (remaining != 0) {
        _pending[capture] = remaining;
        continue;
      }
      _pending.remove(capture);
      final picture = capture.picture ?? FilterInputPicture(capture.packet);
      VideoFilterPicture sourceFor(FramePacket packet) => _pictures[packet]!;
      final render = scaler.renderFilterPicture(picture, sourceFor);
      final unscaled = scaler.unscaled;
      final original = !includeOriginal
          ? null
          : identical(unscaled, scaler)
          ? render
          : unscaled!.renderFilterPicture(picture, sourceFor);
      for (final packet in picture.sourcePackets()) {
        final count = _references[packet]! - 1;
        if (count == 0) {
          _references.remove(packet);
          _pictures.remove(packet);
        } else {
          _references[packet] = count;
        }
      }
      yield (
        packet: capture.packet,
        capture: capture,
        frame: render,
        original: original,
      );
    }
  }
}

typedef _WorkerInput = ({
  String path,
  int? width,
  int? height,
  bool enlarge,
  String? filters,
  bool original,
  int index,
  SendPort events,
});
typedef _PackedImage = ({
  int width,
  int height,
  int channels,
  TransferableTypedData pixels,
});
typedef _DecodedFrame = ({
  int worker,
  CaptureFrame capture,
  _PackedImage frame,
  _PackedImage? original,
});
typedef _DecodedNativeFrame = ({int worker, _NativeCaptureFrame frame});
typedef _DecodeJob = ({
  _DecodeRun run,
  bool native,
  Map<FramePacket, Set<CaptureFrame>>? captures,
});
typedef _DecodeFailure = ({Object error, String stack});

Future<void> _decodeWorker(_WorkerInput input) async {
  final commands = ReceivePort();
  Video? video;
  try {
    video = Video(input.path);
    final filters = input.filters;
    final scaler =
        input.width == null && input.height == null && filters == null
        ? null
        : YuvImageScaler(
            width: input.width,
            height: input.height,
            enlarge: input.enlarge,
            filters: filters == null ? null : VideoFilterChain.parse(filters),
          );
    input.events.send(commands.sendPort);
    Iterator<Object>? cursor;
    await for (final command in commands) {
      if (command == null) break;
      if (command is _DecodeJob) {
        cursor = command.native
            ? video._decodeNativeRun(command.run).iterator
            : video
                  ._decodeRun(
                    command.run,
                    scaler,
                    input.original,
                    captures: command.captures,
                  )
                  .iterator;
      }
      if (cursor!.moveNext()) {
        final item = cursor.current;
        if (item is _NativeCaptureFrame) {
          input.events.send((worker: input.index, frame: item));
          continue;
        }
        final result = item as _SelectedFrame;
        final original = result.original;
        input.events.send((
          worker: input.index,
          capture: result.capture,
          frame: _packImage(result.frame),
          original: original == null || identical(original, result.frame)
              ? null
              : _packImage(original),
        ));
      } else {
        cursor = null;
        input.events.send(input.index);
      }
    }
  } catch (error, stack) {
    input.events.send((error: error, stack: stack.toString()));
  } finally {
    commands.close();
    video?.close();
  }
}

_PackedImage _packImage(image.Image frame) {
  final alpha = frame.numChannels == 4;
  return (
    width: frame.width,
    height: frame.height,
    channels: alpha ? 4 : 3,
    pixels: TransferableTypedData.fromList([
      frame.getBytes(
        order: alpha ? image.ChannelOrder.rgba : image.ChannelOrder.rgb,
      ),
    ]),
  );
}

image.Image _unpackImage(_PackedImage frame) => image.Image.fromBytes(
  width: frame.width,
  height: frame.height,
  bytes: frame.pixels.materialize(),
  numChannels: frame.channels,
);
