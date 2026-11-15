import 'dart:math' as math;

import 'picture.dart';
import 'slice_header.dart';

final class ReferencePicture {
  ReferencePicture(
    this._decodedPicture,
    this.frameIdentity,
    this.frameNum,
    this.poc, {
    this.longIndex,
    this.bottomField,
    this.fields,
  });

  final H264Picture? _decodedPicture;
  final int frameIdentity, frameNum, poc;
  final bool? bottomField;
  final int? longIndex;
  // Present for a frame reference made of two separately coded fields.
  final ({ReferencePicture top, ReferencePicture bottom})? fields;

  int get identity => _pictureIdentity(frameIdentity, bottomField);

  late final H264Picture? picture = _decodedPicture ?? _assembleFields();

  H264Picture? _assembleFields() {
    final pair = fields;
    final top = pair?.top._decodedPicture,
        bottom = pair?.bottom._decodedPicture;
    return top != null && bottom != null
        ? top.referenceFrameWith(bottom)
        : null;
  }

  ReferencePicture asLongTerm(int index) => ReferencePicture(
    _decodedPicture,
    frameIdentity,
    frameNum,
    poc,
    longIndex: index,
    bottomField: bottomField,
  );
}

// Give the frame and each of its two reference fields distinct identities,
// even when they share sample storage or their long-term marking changes.
int _pictureIdentity(int frame, bool? bottomField) =>
    frame * 3 + (bottomField == null ? 0 : (bottomField ? 2 : 1));

int referenceIdentityWithParity(int identity, bool? bottomField) =>
    _pictureIdentity(identity ~/ 3, bottomField);

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
  PendingPicture(
    this.header,
    this._store,
    this._order,
    this.frameIdentity,
    this.idrStart,
  );

  final SliceHeader header;
  final List<ReferencePicture> _store;
  final int frameIdentity;
  final bool idrStart;
  final _Order _order;

  int get poc => math.min(_order.top, _order.bottom);

  late final List<ReferencePicture> _available =
      header.field || header.pps.sps.frameOnly
      ? _store
      : _frameReferences(_store);

  List<ReferencePicture?> pList(SliceHeader slice) {
    final short = _available.where((ref) => ref.longIndex == null).toList();
    final max = 1 << slice.pps.sps.frameNumBits;
    short.sort(
      (a, b) => _shortNumber(
        b,
        slice.frameNum,
        max,
      ).compareTo(_shortNumber(a, slice.frameNum, max)),
    );
    return _modified(
      [..._fieldOrder(short, slice), ..._fieldOrder(_longReferences(), slice)],
      slice,
      slice.activeL0,
      slice.list0,
    );
  }

  ReferenceLists bLists(SliceHeader slice) {
    final past = <ReferencePicture>[];
    final future = <ReferencePicture>[];
    final frameOrders = <int, int>{};
    if (slice.field) {
      for (final ref in _available) {
        frameOrders.update(
          ref.frameIdentity,
          (old) => math.min(old, ref.poc),
          ifAbsent: () => ref.poc,
        );
      }
    }
    int order(ReferencePicture ref) =>
        frameOrders[ref.frameIdentity] ?? ref.poc;
    for (final ref in _available.where((ref) => ref.longIndex == null)) {
      (order(ref) < poc ? past : future).add(ref);
    }
    past.sort((a, b) => order(b).compareTo(order(a)));
    future.sort((a, b) => order(a).compareTo(order(b)));
    final long = _fieldOrder(_longReferences(), slice);
    final initial0 = [
      ..._fieldOrder([...past, ...future], slice),
      ...long,
    ];
    final initial1 = [
      ..._fieldOrder([...future, ...past], slice),
      ...long,
    ];
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
      _available.where((ref) => ref.longIndex != null).toList()
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
    final maximum = slice.maxPicNum;
    var predicted = slice.currPicNum;
    for (var i = 0; i < modifications.length; i++) {
      final operation = modifications[i];
      final ReferencePicture? selected;
      if (operation.op == 2) {
        selected = _available
            .where((ref) => _longPicNum(ref, slice) == operation.value)
            .firstOrNull;
      } else {
        final difference = operation.value + 1;
        predicted =
            (predicted + (operation.op == 0 ? -difference : difference)) %
            maximum;
        final target = predicted > slice.currPicNum
            ? predicted - maximum
            : predicted;
        selected = _available
            .where(
              (ref) =>
                  ref.longIndex == null && _shortPicNum(ref, slice) == target,
            )
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
  ({SliceHeader header, int frameIdentity})? _previousPicture;

  PendingPicture begin(SliceHeader header) {
    final sps = header.pps.sps;
    final last = _previousPicture;
    final paired = last != null && header.complements(last.header);
    final idrStart = header.idr && !paired;
    final store = idrStart ? <ReferencePicture>[] : [..._references];
    var history = idrStart ? _initialHistory : _history;
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
          _storePicture(
            store,
            null,
            sps.frameOnly,
            null,
            -2 - gap,
            gap,
            order,
            null,
          );
        }
        gap = (gap + 1) % maximum;
      }
    }
    return PendingPicture(
      header,
      store,
      _order(header, history),
      paired ? last.frameIdentity : _identity,
      idrStart,
    );
  }

  void commit(PendingPicture pending, H264Picture picture) {
    final header = pending.header;
    final sps = header.pps.sps;
    final next = [...pending._store];
    var longMaximum = pending.idrStart
        ? (header.longTermIdr ? 0 : -1)
        : _longMaximum;
    var longIndex = header.longTermIdr ? 0 : null;
    var clearNumber = false;
    final maximum = 1 << sps.frameNumBits;
    if (header.reference && !header.idr) {
      final marking = header.marking;
      if (marking == null) {
        if (sps.maxReferences > 0 &&
            !next.any(
              (ref) =>
                  ref.frameIdentity == pending.frameIdentity &&
                  ref.longIndex == null,
            )) {
          _evictOldest(next, sps.maxReferences, header.frameNum, maximum);
        }
      } else {
        for (final operation in marking) {
          switch (operation.op) {
            case 1 || 3:
              final target = header.currPicNum - operation.first - 1;
              final matches = next
                  .where(
                    (ref) =>
                        ref.longIndex == null &&
                        _shortPicNum(ref, header) == target,
                  )
                  .toList();
              if (matches.isEmpty) {
                throw const FormatException(
                  'H.264 marking references a missing short-term picture',
                );
              }
              for (final ref in matches) {
                next.remove(ref);
                if (operation.op == 3) {
                  if (operation.second > longMaximum) {
                    throw const FormatException(
                      'Invalid H.264 long-term reference index',
                    );
                  }
                  next.removeWhere(
                    (other) =>
                        other.longIndex == operation.second &&
                        other.frameIdentity != ref.frameIdentity,
                  );
                  next.add(ref.asLongTerm(operation.second));
                }
              }
            case 2:
              next.removeWhere(
                (ref) => _longPicNum(ref, header) == operation.first,
              );
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
              next.removeWhere(
                (ref) =>
                    ref.longIndex == operation.first &&
                    ref.frameIdentity != pending.frameIdentity,
              );
              longIndex = operation.first;
          }
        }
      }
    }
    if (header.reference && sps.maxReferences > 0) {
      final order = pending._order;
      _storePicture(
        next,
        picture,
        sps.frameOnly,
        header.bottomField,
        pending.frameIdentity,
        clearNumber ? 0 : header.frameNum,
        clearNumber
            ? (
                top: order.top - pending.poc,
                bottom: order.bottom - pending.poc,
                next: order.next,
              )
            : order,
        longIndex,
      );
      if (_referenceCount(next) > sps.maxReferences) {
        throw const FormatException('H.264 decoded picture buffer is full');
      }
    }
    _references = next;
    _longMaximum = longMaximum;
    _identity++;
    _previousPicture = header.field
        ? (header: header, frameIdentity: pending.frameIdentity)
        : null;
    _history = clearNumber
        ? (frame: 0, wrap: 0, msb: 0, lsb: pending._order.top - pending.poc)
        : pending._order.next;
    if (header.reference)
      _previousReference = clearNumber ? 0 : header.frameNum;
  }
}

// Interlaced sequences mark fields separately, even for a decoded frame.
// A frame reference is available only when both its fields have the same
// short-term or long-term marking.
void _storePicture(
  List<ReferencePicture> store,
  H264Picture? picture,
  bool frameOnly,
  bool? bottomField,
  int frameIdentity,
  int frameNum,
  _Order order,
  int? longIndex,
) {
  void add(bool? bottom, int poc) => store.add(
    ReferencePicture(
      picture,
      frameIdentity,
      frameNum,
      poc,
      longIndex: longIndex,
      bottomField: bottom,
    ),
  );
  if (bottomField != null) {
    add(bottomField, bottomField ? order.bottom : order.top);
  } else if (frameOnly) {
    add(null, math.min(order.top, order.bottom));
  } else {
    add(false, order.top);
    add(true, order.bottom);
  }
}

List<ReferencePicture> _frameReferences(List<ReferencePicture> store) {
  final bottoms = {
    for (final ref in store)
      if (ref.bottomField == true) ref.frameIdentity: ref,
  };
  final frames = <ReferencePicture>[];
  for (final top in store) {
    if (top.bottomField != false) continue;
    final bottom = bottoms[top.frameIdentity];
    if (bottom == null ||
        bottom.longIndex != top.longIndex ||
        bottom.frameNum != top.frameNum) {
      continue;
    }
    final samePicture = top._decodedPicture == bottom._decodedPicture;
    frames.add(
      ReferencePicture(
        samePicture ? top._decodedPicture : null,
        top.frameIdentity,
        top.frameNum,
        math.min(top.poc, bottom.poc),
        longIndex: top.longIndex,
        fields: samePicture ? null : (top: top, bottom: bottom),
      ),
    );
  }
  return frames;
}

// Each parity advances independently through the ordered frame list (§8.2.4.2.5).
List<ReferencePicture> _fieldOrder(
  List<ReferencePicture> list,
  SliceHeader slice,
) {
  if (!slice.field) return list;
  final same = <ReferencePicture>[], opposite = <ReferencePicture>[];
  for (final ref in list) {
    (ref.bottomField == slice.bottomField ? same : opposite).add(ref);
  }
  return [
    for (var i = 0; i < math.max(same.length, opposite.length); i++) ...[
      if (i < same.length) same[i],
      if (i < opposite.length) opposite[i],
    ],
  ];
}

int _shortPicNum(ReferencePicture ref, SliceHeader slice) {
  final number = _shortNumber(
    ref,
    slice.frameNum,
    1 << slice.pps.sps.frameNumBits,
  );
  return slice.field
      ? 2 * number + (ref.bottomField == slice.bottomField ? 1 : 0)
      : number;
}

int? _longPicNum(ReferencePicture ref, SliceHeader slice) {
  final number = ref.longIndex;
  if (number == null || !slice.field) return number;
  return 2 * number + (ref.bottomField == slice.bottomField ? 1 : 0);
}

int _referenceCount(List<ReferencePicture> store) =>
    store.isEmpty || store.first.bottomField == null
    ? store.length
    : {
        for (final ref in store) (ref.frameIdentity, ref.longIndex != null),
      }.length;

int _shortNumber(ReferencePicture ref, int current, int maximum) =>
    ref.frameNum > current ? ref.frameNum - maximum : ref.frameNum;

void _evictOldest(
  List<ReferencePicture> store,
  int capacity,
  int current,
  int maximum,
) {
  if (_referenceCount(store) < capacity) return;
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
  store.removeWhere(
    (ref) =>
        ref.longIndex == null && ref.frameIdentity == oldest!.frameIdentity,
  );
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
      if (missingFrame == null && header.bottomField == true) top = bottom;
    default:
      top = header.idr ? 0 : 2 * (wrap + frame) - (reference ? 0 : 1);
      bottom = top;
  }
  if (header.field && missingFrame == null) bottom = top;
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
