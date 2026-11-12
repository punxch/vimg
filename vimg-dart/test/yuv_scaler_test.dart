import 'dart:convert';
import 'dart:typed_data';

import 'package:image/image.dart' as image;
import 'package:vimg_dart/src/yuv_image.dart';

import 'fixtures.dart';

// FFmpeg 8.1.2 RGB24 output from the planar fixture below, using bicubic scale.
const _evenReference =
    'TFNKaXBnpo+SqZKWe5i+dpO6jWd2gVppiHt9gXR2aYo/WXovk3Ctp4TBYqJta6t1umZZzXpt'
    'qKlkhohCc4oeYHcLM3Q3UJFUSHisZZbJjHiNhXGG3oG56IvDsnBes3FfdWKTc2CRmY2Tg3d9'
    'WHNdbIZwgX9GjYxTd6B+W4RimIlJhnc3pIuKmoKBe1SMfFaNYGVIdnteeJhSXXw2b2dzbGRv'
    'in+MnZKfbrKdW5+Kq2yZhEVzjXBvl3p4Ym51V2JpmGhCm2xFrYZfrIVeS3hNfqyBhq6acZmF'
    'WoKoL1d9hFZ8lGaMvFSbz2euaGdXe3ppSZNWTZhapnx6pnx6dHGQi4mniZFscHhTfXFYfnNZ'
    'l2aommmsbX6Kd4mURZCCX6mbsJdotZttlHSIkG+DOER7c361YZLuRXbSLISXN5CiP5eXZr29'
    'yHNtvWhicWA/f25Nf5qEepR+T29tRWZkrWGhsmamkIKlbmCDYmx9kputeqCTc5mMbX6mUmSL'
    'LoZUSKBubX4he4wvd010e1F3dXOldXOlfKuZaZiGbqyGca+KhmVziWd1XWxgU2JXcXZMbnNJ'
    'e2dSgm5ZhohaiYpdkpv1cHrTTJSnOoKUP2hvdZ6la3doZXFie3iIfHqJs4RnvI1wdXV6fn6D'
    'iIvIkZTRr4aJpn1/bnRGZ20/e4RahY9lbV2Le2uZQYtZYKt4oYW6rJDEb3AqfX44iaEugZkm'
    'SaSNIn1nNFubUXi5hW+NoIqo6G+hvEN1yYNP0IpWr31zqXdt';
const _oddReference =
    'UV9NmXp4t5GWZayGiHbAfWdadHZ1i3CmX5khbWxrt37QkpCFbLBnqGqT231Jf5SGcIQUa34k'
    'RI4zbYB5SY7MloNhqXKYvpa27lxvgnF1Pm2AinOEeIt7XHpJd2KrkHlbn6l/WZ6Ck4k9lVdn'
    'hJR3fWqIXWCOi2hfsnkVj49sXXkye5SPhaSygJx1LnzCemGKuEyKuV2rn2xGW2x4RJZbeotY'
    'w3iFgHZ8fpardZCAiHc0YXBzq1qYgnigcoSllnR2OLCcoJqCsI5lf3OQVFWBhXe0RYr/X3KC'
    'JpOtT52jc7eXvGmGrl4yUX1pZaN9hX1HP1l2mV+utW19kYeqcHJmeaairYZ4Yo+0RmiaZWpD'
    'I6V0aHcylnI3h21Ib4DjaIC7Qqy9WYx7XqeteXRegGdeXIFusWBok4Q/h2qSdIl6lI7RqZmw'
    'rnWIaneRUXsAg4mSd2WhZX1hQZmUnI1/sZfIfWlJbJ8hl5ZMaJtrLX96NGa3f3pvmYGjvHS4'
    '10Zhsphaqo5atHOa';

Uint8List _plane(int width, int height, int kind) {
  const padding = 4;
  final stride = width + padding;
  final crop = kind == 0 ? 2 : 1;
  final data = Uint8List(stride * (height + padding));
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      data[(y + crop) * stride + x + crop] = kind == 0
          ? 16 + (5 * x + 11 * y + 78 * ((x ^ y) & 1) + 19 * (x * y % 7)) % 220
          : 16 +
                (7 * x +
                        13 * y +
                        59 * ((x + y + kind) % 3) +
                        31 * (x * y % 5) +
                        kind * 23) %
                    225;
    }
  }
  return data;
}

void main() {
  final luma = _plane(64, 48, 0);
  final cb = _plane(32, 24, 1);
  final cr = _plane(32, 24, 2);
  image.Image scale(YuvImageScaler scaler) => yuvImage(
    y: luma,
    cb: cb,
    cr: cr,
    stride: 68,
    chromaStride: 36,
    width: 64,
    height: 48,
    cropLeft: 2,
    cropTop: 2,
    matrix: 2,
    fullRange: false,
    scaler: scaler,
  );

  final even = YuvImageScaler(width: 16);
  for (final (scaled, width, height, reference, maxDelta) in [
    (scale(even), 16, 12, _evenReference, 0),
    (scale(YuvImageScaler(width: 13)), 13, 10, _oddReference, 1),
    (scale(even), 16, 12, _evenReference, 0),
  ]) {
    check(scaled.width == width && scaled.height == height, 'Scaled geometry');
    final actual = scaled.getBytes(order: image.ChannelOrder.rgb);
    final expected = base64Decode(reference);
    check(actual.length == expected.length, 'RGB24 reference size');
    for (var i = 0; i < actual.length; i++) {
      check((actual[i] - expected[i]).abs() <= maxDelta, 'RGB24 channel $i');
    }
  }

  final gray = yuvImage(
    y: Uint16List.fromList([512, 512, 512]),
    cb: const [],
    cr: const [],
    stride: 1,
    chromaStride: 0,
    width: 1,
    height: 3,
    cropLeft: 0,
    cropTop: 0,
    matrix: 2,
    fullRange: true,
    lumaDepth: 10,
    scaler: even,
  );
  check(gray.width == 16 && gray.height == 48, 'One-pixel source axis');
  check(
    gray.getBytes(order: image.ChannelOrder.rgb).every((value) => value == 128),
    'Deep monochrome stays neutral after enlarging with a reused scaler',
  );
}
