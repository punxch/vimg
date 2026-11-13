import 'package:image/image.dart' as image;

void setRgb555(image.Pixel pixel, int word) {
  int expand(int value) => (value << 3) | (value >> 2);
  pixel.setRgb(
    expand((word >> 10) & 31),
    expand((word >> 5) & 31),
    expand(word & 31),
  );
}
