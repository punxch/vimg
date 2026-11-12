import 'dart:math' as math;

import 'picture.dart';
import 'slice_header.dart';

final class ReferencePicture {
  const ReferencePicture(
    this.picture,
    this.identity,
    this.frameNum,
    this.poc, {
    this.longIndex,
  });

  final H264Picture? picture;
  final int identity, frameNum, poc;
  final int? longIndex;

  ReferencePicture asLongTerm(int index) =>
      ReferencePicture(picture, identity, frameNum, poc, longIndex: index);
}

typedef _History = ({int frame, int wrap, int msb, int lsb});
typedef _Order = ({int top, int bottom, _History next});
typedef ReferenceLists = ({
  List<ReferencePicture?> l0,
  List<ReferencePicture?> l1,
});
const _initialHistory = (frame: 0, wrap: 0, msb: 0, lsb: 0);

ReferencePicture getReference(List<ReferencePicture?> references, int index) {
  final ref = index >= 0 && index < references.length
      ? references[index]
      : null;
  if (ref?.picture == null) {
    throw const FormatException('H.264 reference picture is unavailable');
  }
  return ref!;
}

/// A staged picture shares the decoded reference store across its slices.
/// Each slice independently builds its active reference lists.
final class PendingPicture {
  const PendingPicture(this.header, this._store, this.identity, this._order);

  final SliceHeader header;
  final List<ReferencePicture> _store;
  final int identity;
  final _Order _order;

  int get poc => math.min(_order.top, _order.bottom);

  List<ReferencePicture?> pList(SliceHeader slice) {
    final short = _store.where((ref) => ref.longIndex == null).toList();
    final max = 1 << slice.pps.sps.frameNumBits;
    short.sort(
      (a, b) => _shortNumber(
        b,
        slice.frameNum,
        max,
      ).compareTo(_shortNumber(a, slice.frameNum, max)),
    );
    return _modified(
      [...short, ..._longReferences()],
      slice,
      slice.activeL0,
      slice.list0,
    );
  }

  ReferenceLists bLists(SliceHeader slice) {
    final past = <ReferencePicture>[];
    final future = <ReferencePicture>[];
    for (final ref in _store.where((ref) => ref.longIndex == null)) {
      (ref.poc < poc ? past : future).add(ref);
    }
    past.sort((a, b) => b.poc.compareTo(a.poc));
    future.sort((a, b) => a.poc.compareTo(b.poc));
    final long = _longReferences();
    final initial0 = [...past, ...future, ...long];
    final initial1 = [...future, ...past, ...long];
    if (initial1.length > 1 &&
        Iterable<int>.generate(
          initial1.length,
        ).every((i) => initial0[i] == initial1[i])) {
      final first = initial1[0];
      initial1[0] = initial1[1];
      initial1[1] = first;
    }
    return (
      l0: _modified(initial0, slice, slice.activeL0, slice.list0),
      l1: _modified(initial1, slice, slice.activeL1, slice.list1),
    );
  }

  List<ReferencePicture> _longReferences() =>
      _store.where((ref) => ref.longIndex != null).toList()
        ..sort((a, b) => a.longIndex!.compareTo(b.longIndex!));

  List<ReferencePicture?> _modified(
    List<ReferencePicture> initial,
    SliceHeader slice,
    int count,
    List<ReferenceModification> modifications,
  ) {
    final list = List<ReferencePicture?>.generate(
      count,
      (i) => i < initial.length ? initial[i] : null,
    );
    final maximum = 1 << slice.pps.sps.frameNumBits;
    var predicted = slice.frameNum;
    for (var i = 0; i < modifications.length; i++) {
      final operation = modifications[i];
      final ReferencePicture? selected;
      if (operation.op == 2) {
        selected = _store
            .where((ref) => ref.longIndex == operation.value)
            .firstOrNull;
      } else {
        final difference = operation.value + 1;
        predicted =
            (predicted + (operation.op == 0 ? -difference : difference)) %
            maximum;
        selected = _store
            .where((ref) => ref.longIndex == null && ref.frameNum == predicted)
            .firstOrNull;
      }
      if (selected == null)
        throw const FormatException(
          'H.264 reference list points to a missing picture',
        );
      final suffix = list.skip(i).where((entry) => entry != selected).toList();
      list[i] = selected;
      for (var j = i + 1; j < count; j++) {
        final source = j - i - 1;
        list[j] = source < suffix.length ? suffix[source] : null;
      }
    }
    return list;
  }
}

final class ReferenceState {
  List<ReferencePicture> _references = [];
  _History _history = _initialHistory;
  int? _previousReference;
  var _longMaximum = -1;
  var _identity = 0;

  PendingPicture begin(SliceHeader header) {
    final sps = header.pps.sps;
    final store = header.idr ? <ReferencePicture>[] : [..._references];
    var history = header.idr ? _initialHistory : _history;
    final previous = _previousReference;
    if (!header.idr && previous == null) {
      throw const FormatException(
        'H.264 decoding must start at an IDR picture',
      );
    }
    if (!header.idr && previous != header.frameNum) {
      final maximum = 1 << sps.frameNumBits;
      var gap = (previous! + 1) % maximum;
      while (gap != header.frameNum) {
        if (!sps.allowGaps)
          throw const FormatException('Unexpected H.264 frame number gap');
        final order = _order(header, history, missingFrame: gap);
        history = order.next;
        if (sps.maxReferences > 0) {
          _evictOldest(store, sps.maxReferences, gap, maximum);
          store.add(
            ReferencePicture(null, -1, gap, math.min(order.top, order.bottom)),
          );
        }
        gap = (gap + 1) % maximum;
      }
    }
    return PendingPicture(header, store, _identity, _order(header, history));
  }

  void commit(PendingPicture pending, H264Picture picture) {
    final header = pending.header;
    final sps = header.pps.sps;
    final next = [...pending._store];
    var longMaximum = header.idr ? (header.longTermIdr ? 0 : -1) : _longMaximum;
    var longIndex = header.longTermIdr ? 0 : null;
    var clearNumber = false;
    final maximum = 1 << sps.frameNumBits;
    if (header.reference && !header.idr) {
      final marking = header.marking;
      if (marking == null) {
        if (sps.maxReferences > 0)
          _evictOldest(next, sps.maxReferences, header.frameNum, maximum);
      } else {
        for (final operation in marking) {
          switch (operation.op) {
            case 1 || 3:
              final target = header.frameNum - operation.first - 1;
              final entry = next.indexWhere(
                (ref) =>
                    ref.longIndex == null &&
                    _shortNumber(ref, header.frameNum, maximum) == target,
              );
              if (entry < 0)
                throw const FormatException(
                  'H.264 marking references a missing short-term picture',
                );
              final ref = next.removeAt(entry);
              if (operation.op == 3) {
                if (operation.second > longMaximum)
                  throw const FormatException(
                    'Invalid H.264 long-term reference index',
                  );
                next.removeWhere((ref) => ref.longIndex == operation.second);
                next.add(ref.asLongTerm(operation.second));
              }
            case 2:
              next.removeWhere((ref) => ref.longIndex == operation.first);
            case 4:
              longMaximum = operation.first - 1;
              next.removeWhere(
                (ref) => ref.longIndex != null && ref.longIndex! > longMaximum,
              );
            case 5:
              next.clear();
              longMaximum = -1;
              clearNumber = true;
            case 6:
              if (operation.first > longMaximum)
                throw const FormatException(
                  'Invalid H.264 long-term reference index',
                );
              next.removeWhere((ref) => ref.longIndex == operation.first);
              longIndex = operation.first;
          }
        }
      }
    }
    if (header.reference && sps.maxReferences > 0) {
      if (next.length >= sps.maxReferences)
        throw const FormatException('H.264 decoded picture buffer is full');
      next.add(
        ReferencePicture(
          picture,
          pending.identity,
          clearNumber ? 0 : header.frameNum,
          clearNumber ? 0 : pending.poc,
          longIndex: longIndex,
        ),
      );
    }
    _references = next;
    _longMaximum = longMaximum;
    _identity++;
    _history = clearNumber
        ? (frame: 0, wrap: 0, msb: 0, lsb: pending._order.top - pending.poc)
        : pending._order.next;
    if (header.reference)
      _previousReference = clearNumber ? 0 : header.frameNum;
  }
}

int _shortNumber(ReferencePicture ref, int current, int maximum) =>
    ref.frameNum > current ? ref.frameNum - maximum : ref.frameNum;

void _evictOldest(
  List<ReferencePicture> store,
  int capacity,
  int current,
  int maximum,
) {
  if (store.length < capacity) return;
  ReferencePicture? oldest;
  var minimum = maximum;
  for (final ref in store) {
    if (ref.longIndex != null) continue;
    final number = _shortNumber(ref, current, maximum);
    if (number < minimum) {
      minimum = number;
      oldest = ref;
    }
  }
  if (oldest == null)
    throw const FormatException(
      'H.264 reference buffer has no short-term slot',
    );
  store.remove(oldest);
}

_Order _order(SliceHeader header, _History previous, {int? missingFrame}) {
  final sps = header.pps.sps;
  final frame = missingFrame ?? header.frameNum;
  final reference = missingFrame != null || header.reference;
  final wrap =
      previous.wrap + (frame < previous.frame ? 1 << sps.frameNumBits : 0);
  var msb = previous.msb, lsb = previous.lsb;
  int top, bottom;
  switch (sps.pocType) {
    case 0:
      if (missingFrame != null) {
        top = 0;
        bottom = 0;
      } else {
        final value = header.pocLsb;
        final maximum = 1 << sps.pocLsbBits;
        var upper = msb;
        if (value < lsb && lsb - value >= maximum ~/ 2) {
          upper += maximum;
        } else if (value > lsb && value - lsb > maximum ~/ 2) {
          upper -= maximum;
        }
        top = upper + value;
        bottom = top + header.deltaBottom;
        if (reference) {
          msb = upper;
          lsb = value;
        }
      }
    case 1:
      final cycle = sps.pocCycle;
      var absolute = cycle.isEmpty ? 0 : wrap + frame;
      if (!reference && absolute > 0) absolute--;
      var expected = 0;
      if (absolute > 0) {
        final index = absolute - 1;
        expected =
            (index ~/ cycle.length) * cycle.fold(0, (sum, step) => sum + step);
        for (var i = 0; i <= index % cycle.length; i++) {
          expected += cycle[i];
        }
      }
      if (!reference) expected += sps.nonReferenceOffset;
      top = expected + (missingFrame == null ? header.delta0 : 0);
      bottom =
          top + sps.bottomOffset + (missingFrame == null ? header.delta1 : 0);
    default:
      top = header.idr ? 0 : 2 * (wrap + frame) - (reference ? 0 : 1);
      bottom = top;
  }
  if (top < -0x80000000 ||
      top > 0x7fffffff ||
      bottom < -0x80000000 ||
      bottom > 0x7fffffff) {
    throw const FormatException('H.264 picture order is out of range');
  }
  return (
    top: top,
    bottom: bottom,
    next: (frame: frame, wrap: wrap, msb: msb, lsb: lsb),
  );
}
