import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'dds.dart';
import 'preview_queue.dart';
import 'service_cache.dart';
import 'video_commands.dart';

Future<void> serve(String ya, int workers) async {
  final lock = File(
    outputPath(Directory.systemTemp.path, 'vimg-dart-preview-service.lock'),
  ).openSync(mode: FileMode.append);
  try {
    try {
      lock.lockSync();
    } on FileSystemException catch (error) {
      // POSIX fcntl and Windows LockFileEx use different error codes for contention.
      final code = error.osError?.errorCode;
      final contended = Platform.isWindows
          ? code == 33
          : code == 13 || code == (Platform.isMacOS ? 35 : 11);
      if (!contended) rethrow;
      stdout.writeln('[serve] A Dart preview service is already running');
      return;
    }
    await _Service(ya, workers).run();
  } finally {
    lock.closeSync();
  }
}

final class _Service {
  _Service(this.ya, this.workers);

  final String ya;
  final int workers;
  final _queue = PreviewQueue();
  final _tasks = <Future<void>>{};
  final _stop = Completer<void>();
  Process? _child;

  Future<void> run() async {
    final signals = [
      ProcessSignal.sigint.watch().listen(_shutdown),
      if (!Platform.isWindows) ProcessSignal.sigterm.watch().listen(_shutdown),
    ];
    try {
      stdout.writeln(
        '[serve] $workers worker(s), capacity ${PreviewQueue.capacity}, waiting for Yazi DDS',
      );
      while (!_stop.isCompleted) {
        final child = await Process.start(ya, [
          'sub',
          '$requestEvent,$cancelEvent,$pingEvent',
        ]);
        _child = child;
        if (_stop.isCompleted) child.kill();
        unawaited(child.stdin.close());
        final errors = child.stderr
            .transform(const Utf8Decoder(allowMalformed: true))
            .transform(const LineSplitter())
            .listen(stderr.writeln);
        stdout.writeln('[serve] Subscribed to Yazi DDS');
        try {
          await for (final line
              in child.stdout
                  .transform(const Utf8Decoder(allowMalformed: true))
                  .transform(const LineSplitter())) {
            if (_stop.isCompleted) break;
            _receive(line);
          }
        } finally {
          if (_stop.isCompleted) child.kill();
          final code = await child.exitCode;
          await errors.cancel();
          _child = null;
          if (!_stop.isCompleted) {
            stderr.writeln('[serve] ya sub disconnected ($code); retrying');
          }
        }
        if (!_stop.isCompleted) {
          await Future.any([
            _stop.future,
            Future<void>.delayed(const Duration(seconds: 1)),
          ]);
        }
      }
    } finally {
      if (!_stop.isCompleted) _stop.complete();
      await Future.wait(_tasks);
      for (final signal in signals) {
        await signal.cancel();
      }
    }
  }

  void _shutdown(ProcessSignal _) {
    if (!_stop.isCompleted) _stop.complete();
    _child?.kill();
  }

  void _receive(String line) {
    try {
      final message = DdsMessage.parse(line);
      switch (message.event) {
        case pingEvent:
          final sender = message.requireSender();
          final token = message.body['token'];
          if (token is! int || token < 0)
            throw const FormatException('Invalid DDS probe token');
          _track(
            _publish(sender, serviceReadyEvent, {
              'token': token,
              'pid': pid,
              'formats': ['webp'],
            }),
          );
        case cancelEvent:
          final cache = message.body['cache'];
          if (cache is! String || cache.isEmpty)
            throw const FormatException('Missing DDS cache');
          _queue.cancel(message.requireSender(), cache);
          _status('cancelled');
        case requestEvent:
          final job = PreviewJob.fromDds(message.body);
          final latest = message.body['latest'] == true;
          final recipient = latest
              ? message.requireSender()
              : batchRecipient(message);
          final result = _queue.submit(
            job,
            recipient: recipient,
            latest: latest,
          );
          _status(result.name);
          _startJobs();
        default:
          throw FormatException('Unexpected DDS event ${message.event}');
      }
    } on FormatException catch (error) {
      stderr.writeln('[serve] ${error.message}');
    }
  }

  void _startJobs() {
    while (!_stop.isCompleted && _queue.running < workers) {
      final job = _queue.next();
      if (job == null) return;
      _track(_runJob(job));
    }
  }

  void _track(Future<void> task) {
    _tasks.add(task);
    unawaited(task.whenComplete(() => _tasks.remove(task)));
  }

  Future<void> _runJob(PreviewJob job) async {
    final watch = Stopwatch()..start();
    _status('Processing ${job.file} -> ${job.cache}');
    String? error;
    try {
      final reused = await renderPreview(job);
      _status(
        '${reused ? 'Cache hit' : 'Rendered'} ${job.cache} (${watch.elapsedMilliseconds} ms)',
      );
    } catch (failure) {
      error =
          switch (failure) {
            FormatException(:final message) => message,
            UnsupportedError(:final message) => message,
            _ => failure.toString(),
          } ??
          failure.toString();
      stderr.writeln('[serve] ${job.file}: $error');
    }
    final recipients = _queue.finish(job);
    _startJobs();
    final body = {
      'file': job.file,
      'cache': job.cache,
      if (error != null) 'error': error,
    };
    await Future.wait([
      for (final recipient in recipients)
        _publish(recipient, error == null ? readyEvent : failedEvent, body),
    ]);
  }

  Future<void> _publish(
    String recipient,
    String event,
    Map<String, Object?> body,
  ) async {
    try {
      await publishDds(ya, recipient, event, body);
    } on ProcessException catch (error) {
      stderr.writeln('[serve] Cannot publish $event: ${error.message}');
    }
  }

  void _status(String message) => stdout.writeln(
    '[serve] $message (${_queue.running} running, ${_queue.waiting} queued)',
  );
}
