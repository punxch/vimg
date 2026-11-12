import 'dart:convert';
import 'dart:io';

const serviceReadyEvent = 'gridthumb-service-ready';

enum DdsEvent { request, cancel, ping }

enum GridFormat {
  avif(''),
  webp('webp-');

  const GridFormat(this._namespace);

  final String _namespace;

  String topic(DdsEvent kind) => 'vimg-gridthumb-$_namespace${kind.name}';

  String resultTopic({required bool success}) =>
      'gridthumb-$name-${success ? 'ready' : 'failed'}';

  bool matchesCache(String path) => path.toLowerCase().endsWith('.$name');

  static GridFormat fromCache(String path) =>
      values.where((format) => format.matchesCache(path)).firstOrNull ??
      (throw const FormatException(
        'Preview cache requires an .avif or .webp extension',
      ));
}

final class DdsMessage {
  const DdsMessage(this.format, this.kind, this.sender, this.body);

  static final _topics = {
    for (final format in GridFormat.values)
      for (final kind in DdsEvent.values)
        format.topic(kind): (format: format, kind: kind),
  };

  static Iterable<String> get topics => _topics.keys;

  factory DdsMessage.parse(String line) {
    var start = 0;
    final fields = <String>[];
    for (var field = 0; field < 3; field++) {
      final end = line.indexOf(',', start);
      if (end < 0) throw const FormatException('Incomplete DDS message');
      fields.add(line.substring(start, end));
      start = end + 1;
    }
    final body = jsonDecode(line.substring(start));
    if (body is! Map<String, Object?> || !validYaziId(fields[2])) {
      throw const FormatException('Invalid DDS message body or sender');
    }
    final topic = _topics[fields[0]];
    if (topic == null)
      throw FormatException('Unexpected DDS event ${fields[0]}');
    return DdsMessage(topic.format, topic.kind, fields[2], body);
  }

  final GridFormat format;
  final DdsEvent kind;
  final String sender;
  final Map<String, Object?> body;

  String requireSender() {
    if (sender == '0') throw const FormatException('DDS sender is required');
    return sender;
  }
}

bool validYaziId(String id) => RegExp(r'^(?:0|[1-9][0-9]{0,19})$').hasMatch(id);

Future<void> publishDds(
  String ya,
  String recipient,
  String event,
  Map<String, Object?> body,
) async {
  final result = await Process.run(ya, [
    'pub-to',
    recipient,
    event,
    '--json',
    jsonEncode(body),
  ]);
  if (result.exitCode != 0) {
    throw ProcessException(
      ya,
      ['pub-to', recipient, event],
      '${result.stderr}'.trim(),
      result.exitCode,
    );
  }
}
