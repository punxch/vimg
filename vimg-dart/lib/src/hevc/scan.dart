/// HEVC §6.5. Scan positions are stored as row-major indices.
enum HevcScan { diagonal, horizontal, vertical }

final hevcScans = [
  for (final scan in HevcScan.values)
    [for (var size = 1; size <= 8; size <<= 1) _scan(size, scan)],
];

List<int> _scan(int size, HevcScan scan) => switch (scan) {
  HevcScan.diagonal => [
    for (var sum = 0; sum < 2 * size - 1; sum++)
      for (var x = 0; x < size; x++)
        if (sum - x >= 0 && sum - x < size) (sum - x) * size + x,
  ],
  HevcScan.horizontal => List.generate(size * size, (i) => i),
  HevcScan.vertical => List.generate(
    size * size,
    (i) => i ~/ size + (i % size) * size,
  ),
};
