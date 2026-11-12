import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:image/image.dart' as image;
import 'package:vimg_dart/src/dds.dart';
import 'package:vimg_dart/src/preview_queue.dart';

import 'fixtures.dart';

void testQueue() {
  final queue = PreviewQueue();
  PreviewJob job(int i, {bool refresh = false}) =>
      PreviewJob('source $i', 'cache $i', refresh: refresh);

  for (var index = 0; index < 10; index++) {
    check(
      queue.submit(job(index)) == Admission.queued,
      'Initial queue entry $index',
    );
  }
  check(queue.submit(job(10)) == Admission.queued, 'Eviction at capacity');
  check(
    queue.waiting == 10 && queue.next()!.cache == 'cache 10',
    'Newest first',
  );
  while (queue.waiting > 0) {
    check(queue.next()!.cache != 'cache 0', 'Oldest queued job was evicted');
  }
  check(queue.submit(job(11)) == Admission.busy, 'Full active queue');

  final previews = PreviewQueue();
  previews.submit(job(1), recipient: '42', latest: true);
  previews.submit(job(1), recipient: '43', latest: true);
  previews.submit(job(2), recipient: '42', latest: true);
  previews.cancel('42', job(1).cache);
  check(
    previews.waiting == 2,
    'An old cancellation preserved the latest and shared requests',
  );
  previews.cancel('43', job(1).cache);
  check(previews.waiting == 1, 'Last viewer cancels the orphaned request');
  final active = previews.next()!;
  previews.submit(job(2), recipient: '44');
  check(
    previews.submit(job(2, refresh: true), recipient: '42', latest: true) ==
        Admission.shared,
    'Active refresh was coalesced',
  );
  check(
    previews.finish(active).isEmpty,
    'Superseded render did not notify viewers',
  );
  final refresh = previews.next()!;
  check(
    refresh.refresh && previews.finish(refresh).containsAll(['42', '44']),
    'Refresh notified both viewers',
  );

  final message = DdsMessage.parse('event,0,12,{"file":"a,b.mkv"}');
  check(
    message.sender == '12' && message.body['file'] == 'a,b.mkv',
    'DDS JSON can contain commas',
  );
}

Future<void> main(List<String> args) async {
  testQueue();
  check(
    args.length == 2,
    'Pass the compiled vimg and fake ya executable paths',
  );
  final temp = Directory.systemTemp.createTempSync('vimg-dart-service-test-');
  final input = File('${temp.path}/in.jsonl')..createSync();
  final output = File('${temp.path}/out.jsonl')..createSync();
  final environment = {
    'VIMG_TEST_DDS_INPUT': input.path,
    'VIMG_TEST_DDS_OUTPUT': output.path,
  };
  final video = matroskaFixture(temp);
  final cache = '${temp.path}/cache, animé.webp';
  final service = await Process.start(args[0], [
    'serve',
    '--ya',
    args[1],
    '-j2',
  ], environment: environment);
  final logs = <String>[];
  final out = service.stdout
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .listen(logs.add);
  final err = service.stderr
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .listen(logs.add);

  void request(String event, int sender, Map<String, Object?> body) {
    input.writeAsStringSync(
      '$event,0,$sender,${jsonEncode(body)}\n',
      mode: FileMode.append,
    );
  }

  Future<void> waitFor(bool Function() condition, String description) async {
    final timer = Stopwatch()..start();
    while (!condition()) {
      if (timer.elapsed > const Duration(seconds: 25)) {
        throw StateError('$description: ${logs.join('\n')}');
      }
      await Future<void>.delayed(const Duration(milliseconds: 30));
    }
  }

  Iterable<List> replies(String event, String recipient) => output
      .readAsLinesSync()
      .where((line) => line.endsWith(']'))
      .map((line) => jsonDecode(line) as List)
      .where((body) => body[0] == recipient && body[1] == event);

  try {
    request(pingEvent, 123, {'token': 37});
    await waitFor(
      () => replies(serviceReadyEvent, '123').isNotEmpty,
      'No readiness reply',
    );
    final ping = replies(serviceReadyEvent, '123').single[2] as Map;
    check(
      ping['token'] == 37 && (ping['formats'] as List).contains('webp'),
      'DDS readiness fields',
    );
    final duplicate = await Process.run(args[0], [
      'serve',
      '--ya',
      args[1],
    ], environment: environment).timeout(const Duration(seconds: 3));
    check(
      duplicate.exitCode == 0 &&
          '${duplicate.stdout}'.contains('already running'),
      'Duplicate service lock',
    );

    final body = {
      'file': video.path,
      'cache': cache,
      'source_size': video.lengthSync(),
    };
    request(requestEvent, 123, body);
    request(requestEvent, 456, body);
    await waitFor(
      () =>
          replies(readyEvent, '123').isNotEmpty &&
          replies(readyEvent, '456').isNotEmpty,
      'No ready replies from the worker',
    );
    final sheet = image.WebPDecoder().startDecode(
      File(cache).readAsBytesSync(),
    )!;
    check(
      sheet.width == 639 && sheet.height == 480 && sheet.numFrames == 30,
      'Service grid profile',
    );
    check(
      logs.any((line) => line.contains('shared')),
      'Service coalesced duplicate work',
    );

    request(requestEvent, 789, body);
    await waitFor(
      () => replies(readyEvent, '789').isNotEmpty,
      'No cache hit reply',
    );
    check(logs.any((line) => line.contains('Cache hit')), 'Cache reuse logged');

    request(requestEvent, 901, {...body, 'source_size': 1});
    await waitFor(
      () => replies(failedEvent, '901').isNotEmpty,
      'Stale source did not fail',
    );
    final error = replies(failedEvent, '901').single[2] as Map;
    check('${error['error']}'.contains('source changed'), 'Stale source error');

    final sent = await Process.run(args[0], [
      'send',
      '--ya',
      args[1],
      '--yazi-id',
      '123',
      video.path,
      cache,
    ], environment: environment);
    check(
      sent.exitCode == 0 &&
          replies(requestEvent, '0').single[2]['cache'] == cache,
      'send publishes the original cache path',
    );
  } finally {
    service.kill(
      Platform.isWindows ? ProcessSignal.sigint : ProcessSignal.sigterm,
    );
    try {
      await service.exitCode.timeout(const Duration(seconds: 5));
    } on TimeoutException {
      service.kill(ProcessSignal.sigkill);
      await service.exitCode;
    }
    await out.cancel();
    await err.cancel();
    temp.deleteSync(recursive: true);
  }
}
