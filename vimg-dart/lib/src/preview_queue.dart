import 'dds.dart';

final class PreviewJob {
  const PreviewJob(
    this.file,
    this.cache, {
    this.sourceSize,
    this.sourceModified,
    this.refresh = false,
  });

  factory PreviewJob.fromDds(Map<String, Object?> body) {
    final file = body['file'];
    final cache = body['cache'];
    if (file is! String ||
        file.isEmpty ||
        cache is! String ||
        cache.isEmpty ||
        file.contains('\x00') ||
        cache.contains('\x00')) {
      throw const FormatException(
        'A DDS request requires file and cache paths',
      );
    }
    final size = body['source_size'];
    final modified = body['source_modified_s'];
    return PreviewJob(
      file,
      cache,
      sourceSize: size is int && size >= 0 ? size : null,
      sourceModified: modified is int && modified >= 0 ? modified : null,
      refresh: body['refresh'] == true,
    );
  }

  final String file;
  final String cache;
  final int? sourceSize;
  final int? sourceModified;
  final bool refresh;
}

enum Admission { queued, shared, busy }

/// Owns queued and active jobs on the DDS isolate.
final class PreviewQueue {
  static const capacity = 10;

  final _pending = <String, PreviewJob>{};
  final _active = <String>{};
  final _batch = <String, Set<String>>{};
  final _latest = <String, String>{};
  final _refreshes = <String, PreviewJob>{};

  int get running => _active.length;
  int get waiting => _pending.length;

  Admission submit(PreviewJob job, {String? recipient, bool latest = false}) {
    if (latest) {
      if (recipient == null)
        throw const FormatException('Latest request requires a DDS sender');
      final previous = _latest[recipient];
      if (previous != null && previous != job.cache)
        cancel(recipient, previous);
    }
    final active = _active.contains(job.cache);
    final queued = _pending[job.cache];
    if (active || queued != null) {
      _subscribe(job.cache, recipient, latest);
      if (active && job.refresh) _refreshes[job.cache] = job;
      if (queued != null && (latest || job.refresh)) {
        if (latest) _pending.remove(job.cache);
        _pending[job.cache] = job.refresh ? job : queued;
      }
      return Admission.shared;
    }
    if (running + waiting == capacity) {
      if (_pending.isEmpty) return Admission.busy;
      final oldest = _pending.keys.first;
      _pending.remove(oldest);
      _takeSubscribers(oldest);
    }
    _subscribe(job.cache, recipient, latest);
    _pending[job.cache] = job;
    return Admission.queued;
  }

  void _subscribe(String cache, String? recipient, bool latest) {
    if (latest) {
      _latest[recipient!] = cache;
    } else {
      final recipients = _batch.putIfAbsent(cache, () => <String>{});
      if (recipient != null) recipients.add(recipient);
    }
  }

  void cancel(String sender, String cache) {
    if (_latest[sender] != cache) return;
    _latest.remove(sender);
    if (_batch.containsKey(cache) || _latest.containsValue(cache)) return;
    _pending.remove(cache);
    _refreshes.remove(cache);
  }

  PreviewJob? next() {
    if (_pending.isEmpty) return null;
    final job = _pending.remove(_pending.keys.last)!;
    _active.add(job.cache);
    return job;
  }

  Set<String> finish(PreviewJob job) {
    _active.remove(job.cache);
    final refresh = _refreshes.remove(job.cache);
    if (refresh != null) {
      _pending[job.cache] = refresh;
      return {};
    }
    return _takeSubscribers(job.cache);
  }

  Set<String> _takeSubscribers(String cache) {
    final recipients = _batch.remove(cache) ?? <String>{};
    _latest.removeWhere((id, current) {
      if (current != cache) return false;
      recipients.add(id);
      return true;
    });
    return recipients;
  }
}

String? batchRecipient(DdsMessage message) {
  final id = message.body['yazi_id'];
  if (id is String && id != '0' && validYaziId(id)) return id;
  return message.sender == '0' ? null : message.sender;
}
