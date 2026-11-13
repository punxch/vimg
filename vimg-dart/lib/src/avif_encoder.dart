import 'dart:typed_data';

import 'package:image/image.dart' as image;

import 'av1/dct_encoder.dart';
import 'av1/palette_encoder.dart';

export 'av1/dct_encoder.dart' show defaultAvifPreset, maxAvifPreset;

/// Writes an AVIF primary image and, for multiple frames, a repeating
/// image sequence. The transform encoder also retains its last reference.
final class AvifEncoder {
  AvifEncoder(
    this.width,
    this.height, {
    this.fps,
    int? qIndex,
    int preset = defaultAvifPreset,
  }) : _palette = qIndex == null
           ? Av1PaletteEncoder(width, height, still: fps == null)
           : null,
       _dct = qIndex == null
           ? null
           : Av1DctEncoder(
               width,
               height,
               still: fps == null,
               qIndex: qIndex,
               preset: preset,
             ) {
    final rate = fps;
    if (rate != null && (!rate.isFinite || rate < 0.001 || rate > 1000)) {
      throw const FormatException('Invalid AVIF frame rate');
    }
  }

  final int width;
  final int height;
  final double? fps;
  final Av1DctEncoder? _dct;
  final Av1PaletteEncoder? _palette;
  final _samples = <Uint8List>[];
  final _syncSamples = <int>[];
  var _sampleBytes = 0;
  bool get _inter => _syncSamples.length != _samples.length;
  int get _depth => _dct == null ? 8 : Av1DctEncoder.depth;

  void addFrame(image.Image pixels) {
    if (fps == null && _samples.isNotEmpty) {
      throw StateError('An AVIF still image can contain one frame');
    }
    final dct = _dct;
    final keyframe = dct?.nextIsKeyframe ?? true;
    final frame = dct == null ? _palette!.frame(pixels) : dct.frame(pixels);
    if (!keyframe) {
      _addSample(frame, sync: false);
      return;
    }
    final sequence = dct == null ? _palette!.sequence : dct.sequence;
    final sample = Uint8List(sequence.length + frame.length)
      ..setAll(0, sequence)
      ..setAll(sequence.length, frame);
    _addSample(sample, sync: true);
  }

  void repeatFrame() {
    if (fps == null || _samples.isEmpty) {
      throw StateError('No animated AVIF frame to repeat');
    }
    final dct = _dct;
    _addSample(dct == null ? _samples.last : dct.repeat(), sync: dct == null);
  }

  void _addSample(Uint8List sample, {required bool sync}) {
    _sampleBytes += sample.length;
    if (_sampleBytes > 512 * 1024 * 1024) {
      throw const FormatException('AVIF exceeds 512 MiB of compressed samples');
    }
    _samples.add(sample);
    if (sync) _syncSamples.add(_samples.length);
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
        ..tag(_dct == null ? 'MA1A' : 'MA1B');
      if (animated) {
        box.tag('avis');
        if (!_inter) box.tag('avio');
        box.tag('msf1');
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
                  ..bytes(
                    _fullBox(
                      'pixi',
                      0,
                      (box) => box.bytes([3, _depth, _depth, _depth]),
                    ),
                  )
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
                  ..bytes(
                    _fullBox(
                      'ccst',
                      0,
                      (box) => box.u32(_inter ? 0x44000000 : 0xc0000000),
                    ),
                  );
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
    if (_inter) {
      box.bytes(
        _fullBox('stss', 0, (box) {
          box.u32(_syncSamples.length);
          for (final index in _syncSamples) {
            box.u32(index);
          }
        }),
      );
    }
  });

  Uint8List _configuration() => _box('av1C', (box) {
    box.bytes([
      0x81, // marker and version
      _dct == null
          ? (Av1PaletteEncoder.profile << 5) | Av1PaletteEncoder.level
          : (Av1DctEncoder.profile << 5) | Av1DctEncoder.level,
      _dct == null ? 0 : 0x4c, // high bit depth, 4:2:0, main tier
      0, // no initial presentation delay
    ]);
  });

  Uint8List _color() => _box('colr', (box) {
    box
      ..tag('nclx')
      ..u16(_dct == null ? 1 : 2) // primaries
      ..u16(_dct == null ? 13 : 2) // transfer
      ..u16(_dct == null ? 0 : Av1DctEncoder.matrix)
      ..u8(_dct == null ? 0x80 : 0); // full-range flag
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
