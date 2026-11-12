part of 'grid_label.dart';

final _lineBreak = Uint8List.fromList(
  gzip.decode(base64Decode(labelLineBreakData)),
);

// Consecutive arrays from xi-unicode's Unicode 10.0 line break data.
const _bmpRoot = 2048;
const _bmpPages = _bmpRoot + 1024;
const _astralRoot = _bmpPages + 11712;
const _astralBlocks = _astralRoot + 272;
const _astralPages = _astralBlocks + 960;
const _breakTransitions = _astralPages + 9408;
const _breakCategories = 43;

int _breakProperty(int rune) {
  if (rune < 0x800) return _lineBreak[rune];
  final int page;
  final int pages;
  if (rune < 0x10000) {
    page = _lineBreak[_bmpRoot + (rune >> 6)];
    pages = _bmpPages;
  } else {
    final block = _lineBreak[_astralRoot + (rune >> 12)];
    page = _lineBreak[_astralBlocks + block * 64 + ((rune >> 6) & 63)];
    pages = _astralPages;
  }
  return _lineBreak[pages + page * 64 + (rune & 63)];
}

int _transition(int state, int property) =>
    _lineBreak[_breakTransitions + state * _breakCategories + property];

Iterable<({int end, bool hard})> _lineBreaks(List<int> runes) sync* {
  if (runes.isEmpty) return;
  var state = _breakProperty(runes.first);
  for (var i = 1; i < runes.length; i++) {
    final next = _transition(state, _breakProperty(runes[i]));
    if (next >= 0x80) {
      yield (end: i, hard: next >= 0xc0);
      state = next & 0x3f;
    } else {
      state = next;
    }
  }
  // At end of text, the Rust layout keeps trailing whitespace only when the
  // final ASCII character creates a break inside a line (such as a space).
  final last = runes.last;
  final property = _breakProperty(last);
  final keepTrailing =
      last < 0x80 &&
      (_transition(property, _breakProperty(32)) >= 0x80 ||
          _transition(property, _breakProperty(97)) >= 0x80);
  yield (end: runes.length, hard: keepTrailing);
}
