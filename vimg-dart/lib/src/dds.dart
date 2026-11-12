import 'dart:convert';
import 'dart:io';

const requestEvent = 'vimg-gridthumb-webp-request';
const avifRequestEvent = 'vimg-gridthumb-request';
const cancelEvent = 'vimg-gridthumb-webp-cancel';
const pingEvent = 'vimg-gridthumb-webp-ping';
const readyEvent = 'gridthumb-webp-ready';
const failedEvent = 'gridthumb-webp-failed';
const serviceReadyEvent = 'gridthumb-service-ready';

final class DdsMessage {
  const DdsMessage(this.event, this.sender, this.body);

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
    return DdsMessage(fields[0], fields[2], body);
  }

  final String event;
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
