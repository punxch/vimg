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

  Stream<_SelectedFrame> decodeCaptures(Iterable<CaptureFrame> selected) {
    final captures = <FramePacket, Set<CaptureFrame>>{};
    var dynamicFilters = false;
    for (final frame in selected) {
      captures.putIfAbsent(frame.packet, () => {}).add(frame);
      if (frame.positions.isNotEmpty) dynamicFilters = true;
    }
    return _decode(captures.keys, dynamicFilters ? captures : null);
  }

  Stream<_SelectedFrame> _decode(
    Iterable<FramePacket> selected,
    Map<FramePacket, Set<CaptureFrame>>? captures,
  ) async* {
    if (_closed || _busy) throw StateError('Capture decoder is unavailable');
    _busy = true;
    var finished = false;
    try {
      final runs = _video._decodeRuns(selected).toList();
      final active = _limit < runs.length ? _limit : runs.length;
      if (active <= 1) {
        for (final run in runs) {
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
        // Start longer GOPs early and let workers take the next available run.
        runs.sort((a, b) => b.packets.length.compareTo(a.packets.length));
        void send(int worker, _DecodeRun run) {
          _workers[worker].send((
            run: run,
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
            case final _DecodedFrame result:
              final frame = _unpackImage(result.frame);
              final original = result.original;
              yield (
                packet: result.capture.packet,
                capture: result.capture,
                frame: frame,
                original: original != null
                    ? _unpackImage(original)
                    : (_includeOriginal ? frame : null),
              );
              // A worker keeps at most one frame waiting in the mailbox.
              _workers[result.worker].send(true);
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

typedef _WorkerInput = ({
  String path,
  int? width,
  int? height,
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
typedef _DecodeJob = ({
  _DecodeRun run,
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
            filters: filters == null ? null : VideoFilterChain.parse(filters),
          );
    input.events.send(commands.sendPort);
    Iterator<_SelectedFrame>? cursor;
    await for (final command in commands) {
      if (command == null) break;
      if (command is _DecodeJob) {
        cursor = video
            ._decodeRun(
              command.run,
              scaler,
              input.original,
              captures: command.captures,
            )
            .iterator;
      }
      if (cursor!.moveNext()) {
        final result = cursor.current;
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
