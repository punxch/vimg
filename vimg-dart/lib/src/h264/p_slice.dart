part of 'cabac_slice.dart';

extension PredictiveCabacSlice on CabacSlice {
  Macroblock readP(
    Macroblock? left,
    Macroblock? top,
    MotionField motion,
    int mbX,
    int mbY,
    List<int?> referenceIdentities,
  ) {
    final owner = header.firstMb + 1;
    final x = mbX * 4, y = mbY * 4;
    final whole = (x: x, y: y, width: 4, height: 4);
    final skipContext = _count(
      left != null && !left.skipped,
      top != null && !top.skipped,
    );
    if (_cabac.decision(11 + skipContext) != 0) {
      final block = Macroblock(header, -1)
        ..skipped = true
        ..qp = _qp;
      _previousQpDelta = false;
      final vector = motion.predictSkip(whole, owner);
      motion.setReference(
        whole,
        owner,
        0,
        _referenceIdentity(referenceIdentities, 0),
      );
      motion.setVector(whole, vector, zeroMotion);
      return block;
    }

    if (_cabac.decision(14) != 0) {
      final block = readIntra(left, top);
      motion.setIntra(whole, owner);
      return block;
    }
    final type = _cabac.decision(15) == 0
        ? 3 * _cabac.decision(16)
        : 2 - _cabac.decision(17);
    final partitions = switch (type) {
      0 => [whole],
      1 => [
        (x: x, y: y, width: 4, height: 2),
        (x: x, y: y + 2, width: 4, height: 2),
      ],
      2 => [
        (x: x, y: y, width: 2, height: 4),
        (x: x + 2, y: y, width: 2, height: 4),
      ],
      _ => [
        for (var i = 0; i < 4; i++)
          (x: x + (i & 1) * 2, y: y + (i >> 1) * 2, width: 2, height: 2),
      ],
    };
    final subTypes = type == 3
        ? List.generate(4, (_) => _subType())
        : const <int>[];
    final references = <int>[];
    for (final partition in partitions) {
      final context = _pair(
        motion.referenceAt(partition.x - 1, partition.y, owner) > 0,
        motion.referenceAt(partition.x, partition.y - 1, owner) > 0,
      );
      final index = header.activeL0 == 1 ? 0 : _referenceIndex(context);
      references.add(index);
      motion.setReference(
        partition,
        owner,
        index,
        _referenceIdentity(referenceIdentities, index),
      );
    }
    for (var i = 0; i < partitions.length; i++) {
      final partition = partitions[i];
      final sub = type == 3 ? subTypes[i] : 0;
      final width = sub == 2 || sub == 3 ? 1 : partition.width;
      final height = sub == 1 || sub == 3 ? 1 : partition.height;
      for (var row = 0; row < partition.height; row += height) {
        for (var col = 0; col < partition.width; col += width) {
          final part = (
            x: partition.x + col,
            y: partition.y + row,
            width: width,
            height: height,
          );
          _readVector(motion, part, owner, references[i]);
        }
      }
    }
    final block = Macroblock(header, -1);
    _patterns(block, left, top);
    if (header.pps.transform8x8 &&
        block.lumaPattern != 0 &&
        subTypes.every((type) => type == 0)) {
      final context = _count(
        left?.transform8x8 == true,
        top?.transform8x8 == true,
      );
      block.transform8x8 = _cabac.decision(399 + context) != 0;
    }
    _readQuantizerAndResiduals(block, left, top);
    return block;
  }

  int _subType() {
    if (_cabac.decision(21) != 0) return 0;
    if (_cabac.decision(22) == 0) return 1;
    return _cabac.decision(23) != 0 ? 2 : 3;
  }

  int _referenceIndex(int context) {
    var index = 0;
    while (_cabac.decision(54 + context) != 0) {
      if (++index >= header.activeL0) {
        throw const FormatException('H.264 reference index is out of range');
      }
      context = (context >> 2) + 4;
    }
    return index;
  }

  void _readVector(
    MotionField field,
    MotionPartition part,
    int owner,
    int ref,
  ) {
    final left = field.differenceAt(part.x - 1, part.y, owner);
    final top = field.differenceAt(part.x, part.y - 1, owner);
    final dx = _motionDifference(40, left.x.abs() + top.x.abs());
    final dy = _motionDifference(47, left.y.abs() + top.y.abs());
    final predicted = field.predict(part, owner, ref);
    final vector = (
      x: _signed16(predicted.x + dx),
      y: _signed16(predicted.y + dy),
    );
    field.setVector(part, vector, (x: dx, y: dy));
  }

  int _motionDifference(int base, int difference) {
    final context = difference > 32 ? 2 : (difference > 2 ? 1 : 0);
    if (_cabac.decision(base + context) == 0) return 0;
    var magnitude = 1;
    while (magnitude < 9 &&
        _cabac.decision(base + 3 + math.min(3, magnitude - 1)) != 0) {
      magnitude++;
    }
    if (magnitude == 9) {
      var bits = 3;
      while (_cabac.bypass() != 0) {
        magnitude += 1 << bits++;
        if (bits >= 16)
          throw const FormatException(
            'Oversized H.264 motion vector difference',
          );
      }
      for (var i = bits - 1; i >= 0; i--) {
        magnitude += _cabac.bypass() << i;
      }
    }
    if (magnitude > 32767)
      throw const FormatException('H.264 motion vector is out of range');
    return _cabac.bypass() == 0 ? magnitude : -magnitude;
  }
}

int _signed16(int value) => ((value + 32768) & 65535) - 32768;

int _referenceIdentity(List<int?> references, int index) =>
    references[index] ??
    (throw const FormatException('H.264 reference picture is unavailable'));
