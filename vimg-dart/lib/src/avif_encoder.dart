import 'dart:typed_data';

import 'package:image/image.dart' as image;

import 'av1/palette_encoder.dart';

/// Writes an AVIF primary image and, for multiple frames, a repeating
/// image sequence. Only the compressed AV1 samples are retained.
final class AvifEncoder {
  AvifEncoder(this.width, this.height, {this.fps})
    : _av1 = Av1PaletteEncoder(width, height, still: fps == null) {
    final rate = fps;
    if (rate != null && (!rate.isFinite || rate < 0.001 || rate > 1000)) {
      throw const FormatException('Invalid AVIF frame rate');
    }
  }

  final int width;
  final int height;
  final double? fps;
  final Av1PaletteEncoder _av1;
  final _samples = <Uint8List>[];
  var _sampleBytes = 0;

  void addFrame(image.Image pixels) {
    if (fps == null && _samples.isNotEmpty) {
      throw StateError('An AVIF still image can contain one frame');
    }
    final frame = _av1.frame(pixels);
    final sequence = _av1.sequence;
    final sample = Uint8List(sequence.length + frame.length)
      ..setAll(0, sequence)
      ..setAll(sequence.length, frame);
    _addSample(sample);
  }

  void repeatFrame() {
    if (fps == null || _samples.isEmpty) {
      throw StateError('No animated AVIF frame to repeat');
    }
    _addSample(_samples.last);
  }

  void _addSample(Uint8List sample) {
    _sampleBytes += sample.length;
    if (_sampleBytes > 512 * 1024 * 1024) {
      throw const FormatException('AVIF exceeds 512 MiB of compressed samples');
    }
    _samples.add(sample);
  }

  Uint8List finish() {
    if (_samples.isEmpty) throw StateError('No AVIF frames');
    final animated = fps != null;
    final fileType = _box('ftyp', (box) {
      box
        ..tag(animated ? 'avis' : 'avif')
        ..u32(0)
        ..tag('avif')
        ..tag('mif1')
        ..tag('miaf')
        ..tag('MA1A');
      if (animated) {
        box
          ..tag('avis')
          ..tag('avio')
          ..tag('msf1');
      }
    });
    // iloc and stco use fixed-width offsets, so a second pass preserves size.
    final metadataSize = _meta(0).length;
    final movieSize = animated ? _movie(0).length : 0;
    final sampleOffset = fileType.length + metadataSize + movieSize + 8;
    final bytes = _BoxWriter()
      ..bytes(fileType)
      ..bytes(_meta(sampleOffset));
    if (animated) bytes.bytes(_movie(sampleOffset));
    bytes
      ..u32(_sampleBytes + 8)
      ..tag('mdat');
    for (final sample in _samples) {
      bytes.bytes(sample);
    }
    return bytes.finish();
  }

  Uint8List _meta(int sampleOffset) => _fullBox('meta', 0, (box) {
    box
      ..bytes(_handler())
      ..bytes(_fullBox('pitm', 0, (box) => box.u16(1)))
      ..bytes(
        _fullBox('iloc', 0, (box) {
          box
            ..u8(0x44) // four-byte offset and length
            ..u8(0) // no base offset
            ..u16(1) // item count
            ..u16(1) // item ID
            ..u16(0) // in this file
            ..u16(1) // extent count
            ..u32(sampleOffset)
            ..u32(_samples.first.length);
        }),
      )
      ..bytes(
        _fullBox('iinf', 0, (box) {
          box
            ..u16(1)
            ..bytes(
              _fullBox('infe', 2 << 24, (box) {
                box
                  ..u16(1)
                  ..u16(0)
                  ..tag('av01')
                  ..string('Color');
              }),
            );
        }),
      )
      ..bytes(
        _box('iprp', (box) {
          box
            ..bytes(
              _box('ipco', (box) {
                box
                  ..bytes(
                    _fullBox('ispe', 0, (box) {
                      box
                        ..u32(width)
                        ..u32(height);
                    }),
                  )
                  ..bytes(_fullBox('pixi', 0, (box) => box.bytes([3, 8, 8, 8])))
                  ..bytes(_configuration())
                  ..bytes(_color());
              }),
            )
            ..bytes(
              _fullBox('ipma', 0, (box) {
                box
                  ..u32(1)
                  ..u16(1)
                  ..bytes([4, 1, 2, 0x83, 4]); // av1C is essential
              }),
            );
        }),
      );
  });

  Uint8List _movie(int sampleOffset) {
    final rate = (fps! * 1000).round();
    final divisor = rate.gcd(1000);
    final scale = rate ~/ divisor;
    final delta = 1000 ~/ divisor;
    final duration = _samples.length * delta;
    return _box('moov', (box) {
      box
        ..bytes(
          _fullBox('mvhd', 0, (box) {
            box
              ..zeroes(8)
              ..u32(scale)
              ..u32(duration)
              ..u32(0x00010000) // rate 1
              ..u16(0x0100) // volume 1
              ..zeroes(10)
              ..matrix()
              ..zeroes(24)
              ..u32(2); // next track ID
          }),
        )
        ..bytes(
          _box('trak', (box) {
            box
              ..bytes(
                _fullBox('tkhd', (1 << 24) | 3, (box) {
                  box
                    ..zeroes(16) // creation and modification
                    ..u32(1) // track ID
                    ..u32(0)
                    ..u32(0xffffffff) // indefinitely repeating
                    ..u32(0xffffffff)
                    ..zeroes(16)
                    ..matrix()
                    ..u32(width << 16)
                    ..u32(height << 16);
                }),
              )
              ..bytes(
                _box('edts', (box) {
                  box.bytes(
                    _fullBox('elst', 1, (box) {
                      box
                        ..u32(1)
                        ..u32(duration)
                        ..u32(0)
                        ..u32(0x00010000);
                    }),
                  );
                }),
              )
              ..bytes(
                _box('mdia', (box) {
                  box
                    ..bytes(
                      _fullBox('mdhd', 0, (box) {
                        box
                          ..zeroes(8)
                          ..u32(scale)
                          ..u32(duration)
                          ..u16(0x55c4) // und
                          ..u16(0);
                      }),
                    )
                    ..bytes(_handler())
                    ..bytes(
                      _box('minf', (box) {
                        box
                          ..bytes(_fullBox('vmhd', 1, (box) => box.zeroes(8)))
                          ..bytes(_dataInformation())
                          ..bytes(_sampleTable(sampleOffset, delta));
                      }),
                    );
                }),
              );
          }),
        );
    });
  }

  Uint8List _sampleTable(int sampleOffset, int delta) => _box('stbl', (box) {
    // Every sample is a self-contained keyframe, so an stss box is unnecessary.
    box
      ..bytes(
        _fullBox('stsd', 0, (box) {
          box
            ..u32(1)
            ..bytes(
              _box('av01', (box) {
                box
                  ..zeroes(6)
                  ..u16(1) // data reference
                  ..zeroes(16)
                  ..u16(width)
                  ..u16(height)
                  ..u32(72 << 16)
                  ..u32(72 << 16)
                  ..u32(0)
                  ..u16(1) // frame count
                  ..zeroes(32) // compressor name
                  ..u16(24)
                  ..u16(0xffff)
                  ..bytes(_configuration())
                  ..bytes(_color())
                  ..bytes(_fullBox('ccst', 0, (box) => box.u32(0xc0000000)));
              }),
            );
        }),
      )
      ..bytes(
        _fullBox('stts', 0, (box) {
          box
            ..u32(1)
            ..u32(_samples.length)
            ..u32(delta);
        }),
      )
      ..bytes(
        _fullBox('stsc', 0, (box) {
          box
            ..u32(1)
            ..u32(1)
            ..u32(_samples.length)
            ..u32(1);
        }),
      )
      ..bytes(
        _fullBox('stsz', 0, (box) {
          box
            ..u32(0)
            ..u32(_samples.length);
          for (final sample in _samples) {
            box.u32(sample.length);
          }
        }),
      )
      ..bytes(
        _fullBox('stco', 0, (box) {
          box
            ..u32(1)
            ..u32(sampleOffset);
        }),
      );
  });

  Uint8List _configuration() => _box('av1C', (box) {
    box.bytes([
      0x81, // marker and version
      (Av1PaletteEncoder.profile << 5) | Av1PaletteEncoder.level,
      0, // 8-bit, 4:4:4, main tier
      0, // no initial presentation delay
    ]);
  });

  Uint8List _color() => _box('colr', (box) {
    box
      ..tag('nclx')
      ..u16(1) // primaries
      ..u16(13) // transfer
      ..u16(0) // identity matrix
      ..u8(0x80); // full range
  });
}

Uint8List _handler() => _fullBox('hdlr', 0, (box) {
  box
    ..u32(0)
    ..tag('pict')
    ..zeroes(12)
    ..string('PictureHandler');
});

Uint8List _dataInformation() => _box('dinf', (box) {
  box.bytes(
    _fullBox('dref', 0, (box) {
      box
        ..u32(1)
        ..bytes(_fullBox('url ', 1, (_) {}));
    }),
  );
});

Uint8List _fullBox(
  String tag,
  int versionAndFlags,
  void Function(_BoxWriter) write,
) => _box(tag, (box) {
  box.u32(versionAndFlags);
  write(box);
});

Uint8List _box(String tag, void Function(_BoxWriter) write) {
  final body = _BoxWriter();
  write(body);
  final data = body.finish();
  return (_BoxWriter()
        ..u32(data.length + 8)
        ..tag(tag)
        ..bytes(data))
      .finish();
}

final class _BoxWriter {
  final _buffer = BytesBuilder(copy: false);

  void bytes(List<int> data) => _buffer.add(data);
  void zeroes(int count) => bytes(Uint8List(count));
  void tag(String value) => bytes(value.codeUnits);
  void string(String value) {
    tag(value);
    u8(0);
  }

  void u8(int value) => _buffer.addByte(value & 255);
  void u16(int value) {
    u8(value >> 8);
    u8(value);
  }

  void u32(int value) {
    u16(value >> 16);
    u16(value);
  }

  void matrix() {
    for (final value in [0x10000, 0, 0, 0, 0x10000, 0, 0, 0, 0x40000000]) {
      u32(value);
    }
  }

  Uint8List finish() => _buffer.takeBytes();
}
