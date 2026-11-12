part of 'slice_data.dart';

extension PredictiveSlice on SliceData {
  Macroblock readP(
    Macroblock? left,
    Macroblock? top,
    MotionField motion,
    int mbX,
    int mbY,
    List<ReferencePicture?> references,
  ) {
    final owner = header.firstMb + 1;
    final x = mbX * 4, y = mbY * 4;
    final whole = (x: x, y: y, width: 4, height: 4);
    if (_skip(left, top)) {
      final block = Macroblock(header, -1)
        ..skipped = true
        ..qp = _qp;
      _previousQpDelta = false;
      final vector = motion.predictSkip(whole, owner);
      motion.setReference(
        whole,
        owner,
        0,
        getReference(references, 0).identity,
      );
      motion.setVector(whole, vector, zeroMotion);
      return block;
    }

    final type = _pType();
    if (type >= 5) {
      final block = readIntra(left, top, type - 5);
      motion.setUnused(whole, owner);
      return block;
    }
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
    final subTypes = type >= 3
        ? List.generate(4, (_) => _pSubType())
        : const <int>[];
    for (final partition in partitions) {
      final context = _pair(
        motion.referenceAt(partition.x - 1, partition.y, owner) > 0,
        motion.referenceAt(partition.x, partition.y - 1, owner) > 0,
      );
      final index = type == 4 ? 0 : _referenceIndex(context, header.activeL0);
      motion.setReference(
        partition,
        owner,
        index,
        getReference(references, index).identity,
      );
    }
    for (var i = 0; i < partitions.length; i++) {
      final partition = partitions[i];
      final ref = motion.referenceAt(partition.x, partition.y, owner);
      final sub = type >= 3 ? subTypes[i] : 0;
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
          _readVector(motion, part, owner, ref);
        }
      }
    }
    final block = Macroblock(header, -1);
    _interResiduals(block, left, top, subTypes.every((type) => type == 0));
    return block;
  }
}
