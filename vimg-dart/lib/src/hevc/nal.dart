import 'dart:typed_data';

import '../rbsp.dart';

/// H.265 §7.3.1.2. Access-unit boundaries are supplied by the container.
final class HevcNal {
  HevcNal(this.bytes)
    : header = readHevcNalHeader(
        bytes.length >= 2 ? (bytes[0] << 8) | bytes[1] : -1,
      );

  final Uint8List bytes;
  final HevcNalHeader header;

  Rbsp rbsp() => Rbsp.fromNal(
    bytes,
    headerBytes: 2,
    codec: 'HEVC',
    trackPrevention: header.vcl,
  );
}

final class HevcNalHeader {
  const HevcNalHeader(this.type, this.layer, this.temporalId);

  final int type, layer, temporalId;

  bool get vcl => type < 32;
  bool get codedSlice => type <= 9 || randomAccess;
  bool get idr => type == 19 || type == 20;
  bool get irap => type >= 16 && type <= 23;
  bool get randomAccess => type >= 16 && type <= 21;
  bool get rasl => type == 8 || type == 9;
  bool get radl => type == 6 || type == 7;
}

HevcNalHeader readHevcNalHeader(int word) {
  final temporalId = (word & 7) - 1;
  if (word < 0 || word & 0x8000 != 0 || temporalId < 0) {
    throw const FormatException('Invalid HEVC NAL header');
  }
  return HevcNalHeader((word >> 9) & 63, (word >> 3) & 63, temporalId);
}
