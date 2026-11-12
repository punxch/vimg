part of 'cabac_slice.dart';

// Prediction-list bit masks for the partition pairs in H.264 Table 7-14.
const _pairLists = [
  (1, 1),
  (2, 2),
  (1, 2),
  (2, 1),
  (1, 3),
  (2, 3),
  (3, 1),
  (3, 2),
  (3, 3),
];

// B_8×8 submacroblock list masks in H.264 Table 7-17.
const _subLists = [0, 1, 2, 3, 1, 1, 2, 2, 3, 3, 1, 2, 3];

extension BidirectionalCabacSlice on CabacSlice {
  Macroblock readB(
    Macroblock? left,
    Macroblock? top,
    BDirect motion,
    int mbX,
    int mbY,
  ) {
    final owner = header.firstMb + 1;
    final x = mbX * 4, y = mbY * 4;
    final whole = (x: x, y: y, width: 4, height: 4);
    final skipContext = _count(
      left != null && !left.skipped,
      top != null && !top.skipped,
    );
    final block = Macroblock(header, -1);
    if (_cabac.decision(24 + skipContext) != 0) {
      motion.derive(whole, [whole], owner);
      _previousQpDelta = false;
      return block
        ..skipped = true
        ..direct = true
        ..qp = _qp;
    }

    final type = _bType(
      _count(left != null && !left.direct, top != null && !top.direct),
    );
    if (type == 23) {
      final intra = readIntra(left, top);
      motion.l0.setUnused(whole, owner);
      motion.l1.setUnused(whole, owner);
      return intra;
    }
    if (type == 0) {
      motion.derive(whole, [whole], owner);
      block.direct = true;
      _interResiduals(block, left, top, header.pps.sps.direct8x8);
      return block;
    }

    final List<MotionPartition> parts;
    final List<int> lists;
    final List<int> subTypes;
    if (type == 22) {
      subTypes = [for (var i = 0; i < 4; i++) _bSubType()];
      parts = [
        for (var i = 0; i < 4; i++)
          (x: x + (i & 1) * 2, y: y + (i >> 1) * 2, width: 2, height: 2),
      ];
      lists = [for (final sub in subTypes) _subLists[sub]];
      final directParts = [
        for (var i = 0; i < 4; i++)
          if (lists[i] == 0) parts[i],
      ];
      if (directParts.isNotEmpty) motion.derive(whole, directParts, owner);
    } else {
      subTypes = const [];
      if (type < 4) {
        parts = [whole];
        lists = [type];
      } else {
        final (first, second) = _pairLists[(type - 4) ~/ 2];
        lists = [first, second];
        parts = type.isEven
            ? [
                (x: x, y: y, width: 4, height: 2),
                (x: x, y: y + 2, width: 4, height: 2),
              ]
            : [
                (x: x, y: y, width: 2, height: 4),
                (x: x + 2, y: y, width: 2, height: 4),
              ];
      }
    }

    final fields = [motion.l0, motion.l1];
    final refs = [motion.refs.l0, motion.refs.l1];
    for (var list = 0; list < 2; list++) {
      final field = fields[list];
      for (var i = 0; i < parts.length; i++) {
        if (lists[i] == 0) continue;
        final part = parts[i];
        if ((lists[i] & (1 << list)) == 0) {
          field.setUnused(part, owner);
          continue;
        }
        bool positiveRef(int x, int y) =>
            field.referenceAt(x, y, owner) > 0 &&
            !motion.l0.directAt(x, y, owner);
        final context = _pair(
          positiveRef(part.x - 1, part.y),
          positiveRef(part.x, part.y - 1),
        );
        final index = _referenceIndex(context, refs[list].length);
        field.setReference(
          part,
          owner,
          index,
          getReference(refs[list], index).identity,
        );
      }
    }
    for (var list = 0; list < 2; list++) {
      final field = fields[list];
      for (var i = 0; i < parts.length; i++) {
        if ((lists[i] & (1 << list)) == 0) continue;
        final part = parts[i];
        final ref = field.referenceAt(part.x, part.y, owner);
        final sub = type == 22 ? subTypes[i] : 0;
        final width = sub == 5 || sub == 7 || sub == 9 || sub >= 10
            ? 1
            : part.width;
        final height = sub == 4 || sub == 6 || sub == 8 || sub >= 10
            ? 1
            : part.height;
        for (var dy = 0; dy < part.height; dy += height) {
          for (var dx = 0; dx < part.width; dx += width) {
            _readVector(
              field,
              (x: part.x + dx, y: part.y + dy, width: width, height: height),
              owner,
              ref,
            );
          }
        }
      }
    }
    final allow8x8 = subTypes.every(
      (type) => type == 0 ? header.pps.sps.direct8x8 : type < 4,
    );
    _interResiduals(block, left, top, allow8x8);
    return block;
  }

  int _bType(int context) {
    if (_cabac.decision(27 + context) == 0) return 0;
    if (_cabac.decision(30) == 0) return 1 + _cabac.decision(32);
    var prefix = _cabac.decision(31);
    for (var i = 0; i < 3; i++) {
      prefix = (prefix << 1) | _cabac.decision(32);
    }
    return switch (prefix) {
      < 8 => prefix + 3,
      13 => 23,
      14 => 11,
      15 => 22,
      _ => (prefix << 1) + _cabac.decision(32) - 4,
    };
  }

  int _bSubType() {
    if (_cabac.decision(36) == 0) return 0;
    if (_cabac.decision(37) == 0) return 1 + _cabac.decision(39);
    var offset = 3;
    if (_cabac.decision(38) != 0) {
      if (_cabac.decision(39) != 0) return 11 + _cabac.decision(39);
      offset = 7;
    }
    return offset + 2 * _cabac.decision(39) + _cabac.decision(39);
  }
}
