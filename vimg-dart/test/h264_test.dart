import 'dart:convert';
import 'dart:io';

import 'package:image/image.dart' as image;
import 'package:vimg_dart/src/binary_file.dart';
import 'package:vimg_dart/src/h264/access_unit.dart';
import 'package:vimg_dart/src/video_configuration.dart';
import 'package:vimg_dart/src/h264/idr_picture.dart';
import 'package:vimg_dart/src/iso_media.dart';
import 'package:vimg_dart/src/matroska.dart';
import 'package:vimg_dart/src/matroska_frames.dart';

import 'fixtures.dart';

// Synthetic 78×50 YUV encoded with x264 High Profile, two IDR frames and two
// slices per frame. Checksums use FFmpeg's decoded, cropped YUV420p planes
// with deblocking enabled.
const _idrPlanes = [
  [0xbf89f3e5, 0xd17539ad, 0xe0ee3d2d],
  [0x1124f8a0, 0x4679dbc8, 0x248ac689],
];

// Twelve frames using multiple references, weighted prediction and two slices.
const _pPlanes = [
  [0xb31104a6, 0x487edb44, 0x8f405e49],
  [0x99d0f526, 0x3ee4a477, 0x5ca5f999],
  [0x0f705928, 0x2d9b6e65, 0xc9253506],
  [0xe80c67ac, 0x5033de0e, 0xb98831d7],
  [0x34dee6fe, 0xd5cc08a9, 0x3e4f59ee],
  [0xd6310950, 0x8d4c5161, 0xe1e92887],
  [0xa50e40d6, 0x7a7cc41f, 0xdd4742df],
  [0x5c14d537, 0x99a1e53e, 0x3e3fff1f],
  [0xfb7d5331, 0x4279441e, 0x8459ff13],
  [0x7b5bd543, 0x6862dd3a, 0xf1985475],
  [0xd7365a8e, 0xe93b2a4c, 0x63899bdd],
  [0x0b3a07f4, 0xa6299768, 0x6165d8b5],
];

// Reference B pictures, implicit weights, spatial direct motion and two slices.
const _spatialBPlanes = [
  [0xd8ba8846, 0xc4a51824, 0xca288f69],
  [0x061d47fb, 0x5d2c2283, 0x33c08b57],
  [0x0f091492, 0x7dbfe7aa, 0xf8049edd],
  [0x70f1a5c8, 0xc5ec89e7, 0x9f9322fe],
  [0x27ab7865, 0x2d903402, 0x82b865fe],
  [0x2dbe44f2, 0x69e8c53d, 0xfd2e6885],
  [0x1544cecd, 0xe529fd22, 0x13963487],
  [0xc9c5a734, 0x1860b8d7, 0xc46c30c2],
  [0xba0078c4, 0x914f7a67, 0x7da69ea3],
  [0x2766d6df, 0x8b921aad, 0xce465826],
  [0x45733304, 0x54f8da98, 0x2f34e70e],
  [0xb3b8513e, 0xa86e9702, 0xa54c3f9f],
  [0x00185cff, 0x3e50cf6c, 0x31a213ef],
  [0x5f06c145, 0xf74834c9, 0x17ae6d1a],
  [0x3003848c, 0x0e34ecf1, 0xefce8d51],
  [0x34b3f49e, 0x5b97073d, 0xaa428190],
  [0x574916d9, 0x6e270572, 0xf6bc19c4],
];

// Temporal direct motion with an MP4 composition offset table.
const _temporalBPlanes = [
  [0x8bc55aa5, 0x4ebf3135, 0x0c0fab46],
  [0xc7631710, 0xfa9391c2, 0x7b7dace2],
  [0xaa91f8fb, 0x46435fc4, 0x28e440d8],
  [0xf4c25807, 0xabb4f2e2, 0xdc11f2a3],
  [0x272e0991, 0x04b2b1ed, 0xc61b06c2],
  [0x9c049078, 0xb807ac9e, 0x7e0d361a],
  [0xbc877cfb, 0xd5ffdc1a, 0xd1722ed4],
  [0xbae53dd6, 0xb5564d84, 0xc2ee0270],
  [0x91bcf4a1, 0xc9de3887, 0xdb141798],
  [0x0608d54d, 0x191445ca, 0xcdbd321c],
  [0xbfb32b70, 0x73ce0c78, 0x17a3dec7],
  [0x103621eb, 0x845265ff, 0x45e24e89],
  [0x7fa43a3b, 0xbcdf2c56, 0x0c38d255],
  [0xc62c84fe, 0x61e19c3d, 0xf64d0b5c],
  [0x6edd3b94, 0xb2e34ec1, 0x20e9661a],
  [0x75fe7b7a, 0xdaaf4c68, 0x97a18080],
  [0xeff7cd2e, 0xc5d312c6, 0xc104e449],
];

// Baseline I/P with two slices and multiple reference pictures.
const _cavlcBaselinePlanes = [
  [0x10cbd312, 0x50f12dd2, 0x807a7f4f],
  [0x4c03e113, 0x0eb332ae, 0x7c617f94],
  [0x47fbc934, 0x1a4987c0, 0xf5ee9455],
  [0xb1c64ee1, 0x047adb3b, 0x7fc2bf15],
  [0xc36ea976, 0xd030b7dc, 0x60685890],
  [0x5fa23879, 0x1a8c707d, 0x36801772],
  [0x8b844433, 0x23f965b3, 0x7962f9d4],
  [0xfc7c04a0, 0x7aa69598, 0xb0569c85],
  [0x5f9a7aba, 0x9396c075, 0xe68fc870],
  [0x7ca03dad, 0x0445eb52, 0xf1f81a92],
  [0xf7cb8561, 0x6d2021cf, 0x730fdc11],
  [0x317a9073, 0x4bc34d9c, 0xf0a33e51],
  [0x32921e1e, 0x292b9e13, 0xf390d681],
  [0xffdf8dc6, 0xbee2e104, 0x0ba8411d],
  [0x330e1594, 0x4a28b8e3, 0x60491e63],
  [0xa89c5b77, 0x4cbc38bc, 0x9940fa4c],
  [0x4120a30e, 0xe371215a, 0xaeed232b],
];

// High Profile I/P/B with 8×8 transforms, two slices and reference B pictures.
const _cavlcHighPlanes = [
  [0x19dadf59, 0x990a7386, 0xcc5fae9f],
  [0xf966bb60, 0x7d05e55b, 0x5f239a97],
  [0x3f4675cf, 0xc97ab978, 0xfcf81f21],
  [0xaafab400, 0xbfdbf354, 0xb67de6e7],
  [0x71b5e73a, 0x88ebd7c6, 0x2558bf67],
  [0xf4017d3f, 0xc780e07b, 0xa0e01471],
  [0xeabeff43, 0xd7f7c93e, 0x47e095a3],
  [0x7b6726fe, 0x1f367434, 0x7cb5c348],
  [0x6f699b21, 0x92955d69, 0xe83e60f8],
  [0x22ffcbd3, 0x137be89e, 0x29cbe22b],
  [0x61de7875, 0x321ba124, 0x36d05f58],
  [0x88888c0b, 0x6e46572b, 0x78e8b1af],
  [0x77a469b2, 0x97523f20, 0x3432c6d8],
  [0x0c91b004, 0xf6d91a23, 0xba3a5238],
  [0xfafcedd3, 0x9c11855a, 0x3d2490ba],
  [0x910dfcc7, 0x342e2d04, 0xb0d3b433],
  [0x2e581ec3, 0xa76e0486, 0xc17aa016],
];

// 10-bit ramps, motion and fades with I/P/B pictures, cropping and two slices.
// The CAVLC stream also exercises negative slice QP.
const _high10CabacPlanes = [
  [0x756f8f3a, 0x4b9da04c, 0xe1f970ce],
  [0xb40fd956, 0x38490590, 0xa237e644],
  [0xb46018f9, 0xbb254034, 0xddd5af28],
  [0x868a4dcf, 0xdcbf7c61, 0x8b30a5e4],
  [0x086f9872, 0x3920483b, 0xf189ac7e],
  [0x104ad48c, 0x124732f5, 0x0681c858],
  [0x3d261238, 0x2c827d95, 0x8ffe2994],
  [0x2bdf0f1a, 0x58d4936c, 0xcb11850b],
  [0x2a7b487a, 0x68e305e0, 0x99695540],
  [0x1df90ead, 0xe4752130, 0x1d4dee77],
  [0xad28cfcd, 0x9b769ee4, 0x812cef96],
  [0x74edc0a0, 0x5b421c15, 0x95028451],
  [0x591f50e3, 0xbb493c54, 0x704fe875],
  [0x9b8030c8, 0xa806497f, 0x9d260c1c],
  [0x84e200a8, 0x946b2f58, 0xc8b2e298],
  [0x5babd3fd, 0x8a7ee623, 0xb031b9ff],
];

const _high10CavlcPlanes = [
  [0x33f100d9, 0x0ab8775f, 0x817d1ec6],
  [0xeec2729c, 0xa6032d3e, 0x226ed26b],
  [0x1309362c, 0x837dcddf, 0x676e72b2],
  [0xa1e0667f, 0x10d70287, 0xcc469c44],
  [0xa1534b6c, 0x94f87484, 0x652a2997],
  [0x8e4ec8d0, 0xc3a9a11c, 0x2c8d8694],
  [0x612801b6, 0x22c07c7f, 0x59ced4fc],
  [0x76cd3f18, 0x9893e6cb, 0xe4998b10],
  [0x21b6dc9e, 0xc4995c55, 0xfe851dd8],
  [0x048add8a, 0x4e4db0d7, 0x4beef889],
  [0x3c4955b1, 0x220058d4, 0xd7f64246],
  [0x8c57d7be, 0xadd7df31, 0x54291ca8],
  [0x69a3ebda, 0xf94ec89c, 0x42a8f9fa],
  [0xbba32d5a, 0x5f4bb4b6, 0x6bf252c9],
  [0xb429479a, 0xd5623563, 0xd921cd13],
  [0x058ec3fd, 0xe34f9946, 0x08a60635],
];

// High 10 monochrome with intra and inter prediction.
const _high10MonochromePlanes = [
  [0xe21637d1],
  [0x99197636],
  [0xe68843f7],
  [0x49c02a90],
  [0x1eb66953],
  [0x4788d1fc],
];

// One 9-bit picture with two I_PCM macroblocks.
const _high10Pcm9Planes = [
  [0x10b95145, 0x21b90145, 0x2ec7f3c5],
];

// Checksums of the original raw input to x264 --qp 0. Both streams use
// 4×4, 8×8 and 16×16 intra prediction and 4×4 and 8×8 inter residuals.
const _losslessCabacPlanes = [
  [0xf5f6873b, 0xf07bfb90, 0xc6bc45bc],
  [0x1aeed8cb, 0xc0f291ba, 0xe5b25de4],
  [0x99626e4b, 0xb5bc6f38, 0x1a385298],
  [0xab95326f, 0x32c9ce02, 0xe6a21398],
  [0x9cf2e71b, 0x8cae6a00, 0x74087f7c],
  [0x0008e3d7, 0xf16df162, 0x19f2e51c],
  [0x00e5516b, 0x0d366060, 0xbab05eb0],
];

const _losslessCavlcPlanes = [
  [0x33544995, 0xf5a3bdb0, 0xe921d259],
  [0x1cb2e1dd, 0x2dcb4c1b, 0x5a1a93d0],
  [0xd28fda1d, 0x2337e4e2, 0xf16e6c33],
  [0xd82b624d, 0xe7490309, 0x31024d5a],
  [0x622ad135, 0x50108408, 0xe76d4f39],
  [0x447c691d, 0xd1d6d28b, 0x3fee51e8],
  [0x1c614efd, 0xf29e0aaa, 0x96f3f7f3],
];

// 4:2:2 reference samples from FFmpeg, with cropped width and odd height.
const _chroma422CabacPlanes = [
  [0x514d97c2, 0xdeac7d20, 0x9e72a38e],
  [0xef8c2db6, 0x5e292029, 0xed7768b8],
  [0x04466c16, 0x82574464, 0x7009ec3c],
  [0x0dc22885, 0xefc412d7, 0x0e748903],
  [0x1fa2d4b7, 0xc6a270c7, 0xc03cc327],
  [0xa10a8808, 0xa2d849fe, 0x9533ad92],
  [0xc4030c2c, 0xcda95ef9, 0x8b081391],
  [0x59b1311f, 0x0677dd08, 0x14b4d82e],
  [0xa0d3175e, 0x32ea2580, 0xc23920ab],
  [0xbf62df3d, 0xbbb0a337, 0x688a8d4e],
  [0xaeb126c6, 0xa2b7d3c7, 0xf3c3852e],
  [0x74b07a40, 0x696a4f40, 0x922c6936],
];

const _chroma422CavlcPlanes = [
  [0x25eb233f, 0x35c55ccd, 0xcc7a7b6b],
  [0xf519725e, 0xb25cda70, 0x47024a4a],
  [0x7d80a2ea, 0x22c2c50d, 0xe08bc2b7],
  [0xa10c8318, 0x327ee366, 0xc07aa4ef],
  [0xcf70f115, 0x6bb4a61e, 0x96de6840],
  [0xc58aa377, 0x91032f29, 0xf099c707],
  [0xc28ef710, 0x3def49e7, 0x0658ee47],
  [0x05d87ed6, 0x0dbe2203, 0xd3c0a7a6],
  [0x86dade2b, 0xa85d2ca1, 0x92469cbc],
  [0x7aaa412f, 0xa687b8f8, 0x38ea0afd],
  [0x0aabe469, 0x05cd5ce6, 0x38565102],
  [0x0e327c1c, 0x9522f81f, 0xcc55d83b],
];

const _chroma422LosslessPlanes = [
  [0x0b2b17a0, 0xc92199d1, 0x1452819c],
  [0xfb86c588, 0x976a7430, 0x56094913],
  [0x256e274c, 0xb405bd49, 0x59b93d80],
  [0x8ef07420, 0x10c9ebd4, 0xf18bf5df],
];

// 4:4:4 reference samples from FFmpeg. The 8-bit CABAC sample uses
// JVT scaling matrices and mixed 4×4 and 8×8 transforms.
const _chroma444CabacPlanes = [
  [0x1fcb8fed, 0x804f51bd, 0xe1062284],
  [0x79fd4704, 0xde1b3ba4, 0x4836a45f],
  [0x5aa819d9, 0xfd47d34f, 0x7012c000],
  [0x1759a417, 0x3c7da023, 0xd48f3b43],
  [0x45883462, 0x44b1b2ef, 0x623ff135],
  [0xbd0bf559, 0x8aaba7e4, 0x9b01362c],
  [0xd2fed06c, 0x804aaf27, 0xe34ebe05],
  [0x36a6eb6e, 0xcb84fec3, 0x025d53be],
  [0xf7fb1294, 0x770d7fef, 0x8f453fbb],
  [0xe7deafc6, 0x59001e14, 0x589b8683],
  [0xd6969de8, 0xc1acf672, 0xc7b8103b],
  [0x19729f14, 0x659db31e, 0x94a339de],
];

const _chroma444CavlcPlanes = [
  [0x6e0ec64a, 0xe2115618, 0x9b8b5df6],
  [0x18b20ac5, 0x36077362, 0x285493ae],
  [0x0abd1f80, 0x9a44bd54, 0xb9afcbd4],
  [0x749db0d3, 0x9db16c4e, 0xad78fb03],
  [0x95669da0, 0x4e18a926, 0x8dca2a96],
  [0xdaee01ab, 0x31708a79, 0xfa06d839],
  [0x353a5387, 0x137a92fd, 0x5ac551bd],
  [0x169b7df7, 0x54fad8e4, 0x7f8bb979],
  [0x8faa0a1a, 0x61755e9f, 0x9f15a484],
  [0x5933332f, 0xccdafc6f, 0x0ecade3d],
  [0x11804a0e, 0x6eb3cbf1, 0x1e4e37f5],
  [0xb5034d08, 0x665b3533, 0x325d78b6],
];

// libx264rgb lossless; these reference planes also match the original GBR.
const _chroma444LosslessRgbPlanes = [
  [0xfc568344, 0x1b54dffb, 0x02f092e2],
  [0x3d7de7a6, 0x7ec5489b, 0x49979094],
  [0xe1e4d4a8, 0xd1554cc1, 0x93f927aa],
  [0x576d91de, 0x34b646d9, 0xcef205bc],
  [0x84aa0a24, 0xcb89a901, 0x67815f0a],
];

// Synthetic 64×48 samples encoded with JM 19.0. These hashes are from
// reconstructed native samples before RGB conversion.
const _depth12CabacPlanes = [
  [0x486a4649, 0x8c125446, 0xbe4a8cb4],
  [0x606a4cdd, 0x040f0bdb, 0x47ac88cd],
  [0x8802ce7c, 0x5b27ca0e, 0x1daf3446],
  [0xbc789a48, 0x739a4725, 0x79d347b4],
  [0xb484debb, 0xc3a0d831, 0xf6b394fd],
  [0xb80d9b0d, 0x054d1044, 0x53f4f038],
  [0xed540e43, 0xd51d31c9, 0x1ea40aa0],
];

const _depth12CavlcPlanes = [
  [0x6c54df38, 0x5b93c0fc, 0xbb45443c],
  [0x91154a36, 0xa4e88f13, 0x032c4106],
  [0x6d6ed47e, 0x2a18d458, 0x4fc8cf85],
  [0xe70f3297, 0x13eb569a, 0xb53a28f3],
  [0xf4ee7d8e, 0x75221c3c, 0x39299f78],
  [0xe25e95df, 0xce0a267e, 0xe2edd504],
  [0xc992d857, 0x2779564d, 0x15bab000],
];

const _depth14LosslessPlanes = [
  [0x4afa56c5, 0x442fefc5, 0x40cc98d2],
  [0xf2cc75c5, 0x9f268245, 0x0bcbc95b],
  [0x8b6a08c5, 0x2c2157c5, 0xa317203d],
  [0x6c759dc5, 0xae176f45, 0x968b9c39],
  [0xd88fddc5, 0x226b0ac5, 0x265ed9da],
  [0x02dee0c5, 0xa7f06e45, 0xa188964b],
  [0xa24d0dc5, 0x20961dc5, 0x12d7f0f0],
];

// JM decoder output reordered from RGB to GBR. The IDR carries CABAC padding.
const _mixedDepthGbrPlanes = [
  [0x98bb73df, 0xe40d4c25, 0x6fe85c80],
  [0xa47226e8, 0x1d667af5, 0xcb8bf060],
  [0x82300eba, 0x9a3446ed, 0x8449a947],
  [0x6c76a9be, 0x73fe76ef, 0x1e0c09bb],
  [0x55c5eb8b, 0x7d269570, 0x0ff5e2e8],
  [0xf550d459, 0x2d026c21, 0x2fd4b218],
  [0x065f4596, 0x14b407b3, 0xbb5b5f5e],
];

// Independent color planes encoded with JM 19.0, three slices per plane.
// The CABAC sample interleaves slices and uses distinct scaling lists.
const _separateCabacPlanes = [
  [0xf66e8a3d, 0x4a1ce7f8, 0x0159661b],
  [0x0e3e219b, 0x36da164f, 0x249e1e13],
  [0x80d2bc3c, 0xb6fdf9e6, 0xe985f30e],
  [0xb179477b, 0xcf9bc2e3, 0x762419b6],
  [0xe71ab2c5, 0x62b03238, 0x1f76dc44],
  [0x04019efd, 0x3137043e, 0x911ddd75],
  [0x2de8a775, 0xb957296c, 0xba1de31f],
];

const _separateCavlcPlanes = [
  [0xcb50aa57, 0xf0bffb7c, 0x07ecd914],
  [0xd77d811e, 0x7bfdb9e9, 0xc1b863b5],
  [0x6485cf49, 0x0124f273, 0x37415590],
  [0xf3a3ae87, 0x2fb9c561, 0x5191e779],
  [0x42d62b31, 0xdf90b961, 0xccbc6d2f],
  [0x02f3b3f2, 0x990dfe7c, 0x1c822015],
  [0x4d243da3, 0xfed8f83e, 0x75a0e61d],
];

const _separateLosslessPlanes = [
  [0x64e69285, 0x5b4933b5, 0x4fb88c92],
  [0xd098f1c5, 0xbe564a65, 0xd7602cff],
  [0xbe182c05, 0xa3c888f5, 0x51e73fe5],
  [0x345c3685, 0x527ed935, 0x14811cd5],
  [0x649c8705, 0x32eaad65, 0x5f79a9e6],
  [0xc04dfe45, 0xf05e8f45, 0xe35dfb1b],
  [0x23353905, 0x1a39a085, 0x4d29cc64],
];

void _checkPlanes(
  String input,
  List<List<int>> expected, {
  bool inter = false,
  bool cabac = true,
  int profile = 100,
  int depth = 8,
  int? chromaDepth,
  int chromaFormat = 1,
  bool lossless = false,
  bool separate = false,
  bool rgb = false,
  (int, int) dimensions = (78, 50),
}) {
  final handle = File(input).openSync();
  try {
    final file = BinaryFile(handle);
    final isMatroska = input.endsWith('.mkv');
    final matroska = isMatroska ? Matroska(file) : null;
    final iso = isMatroska ? null : IsoMedia(file);
    final config = matroska == null
        ? isoVideoConfiguration(iso!, 'h264')
        : matroskaVideoConfiguration(matroska, 'h264');
    final packets =
        (matroska == null ? isoFrames(iso!) : matroskaFrames(matroska))
            .toList();
    final display = [...packets]
      ..sort((a, b) => a.seconds.compareTo(b.seconds));
    final indexes = {for (var i = 0; i < display.length; i++) display[i]: i};
    check(indexes.length == expected.length, 'H.264 fixture frame count');
    final avc = AvcConfiguration(config!);
    check(
      avc.pictures.values.every((pps) => pps.cabac == cabac),
      'H.264 fixture entropy mode',
    );
    final decode = inter
        ? H264StreamDecoder(avc).decode
        : H264IdrDecoder(avc).decode;
    for (final packet in packets) {
      final frame = indexes[packet]!;
      final picture = decode(file.read(packet.offset, packet.size))!;
      final sps = picture.sps;
      if (rgb) {
        final converted = picture.rgb();
        check(
          sps.color.matrix == 0 && sps.color.fullRange,
          'Expected full-range GBR',
        );
        int toRgb(int sample, int bits) {
          final max = (1 << bits) - 1;
          return (sample * 255 + max ~/ 2) ~/ max;
        }

        for (final (x, y) in [(25, 13), (7, 9), (45, 17)]) {
          final pixel = converted.getPixel(x, y);
          final i = (y + sps.cropTop) * picture.stride + x + sps.cropLeft;
          check(
            (pixel.r - toRgb(picture.cr[i], sps.chromaDepth)).abs() <= 1 &&
                (pixel.g - toRgb(picture.y[i], sps.lumaDepth)).abs() <= 1 &&
                (pixel.b - toRgb(picture.cb[i], sps.chromaDepth)).abs() <= 1,
            'Expected identity GBR conversion in $input at $x,$y',
          );
        }
      }
      check(
        sps.profile == profile &&
            sps.lumaDepth == depth &&
            sps.chromaDepth == (chromaDepth ?? depth) &&
            sps.chromaFormat == chromaFormat &&
            sps.separateColorPlane == separate &&
            sps.transformBypass == lossless &&
            (sps.width, sps.height) == dimensions,
        'H.264 dimensions, bit depth and profile',
      );
      for (final (index, plane) in [
        (0, picture.y),
        if (chromaFormat != 0) ...[(1, picture.cb), (2, picture.cr)],
      ]) {
        final shiftX = index == 0 || chromaFormat == 3 ? 0 : 1;
        final shiftY = index != 0 && chromaFormat == 1 ? 1 : 0;
        final stride = picture.stride >> shiftX;
        final hash = _checksum(
          plane,
          stride,
          ((sps.cropTop >> shiftY) * stride) + (sps.cropLeft >> shiftX),
          sps.width >> shiftX,
          sps.height >> shiftY,
        );
        check(
          hash == expected[frame][index],
          'H.264 $input frame $frame plane $index differs from reference: ${hash.toRadixString(16)}',
        );
      }
    }
  } finally {
    handle.closeSync();
  }
}

int _checksum(List<int> plane, int stride, int offset, int width, int height) {
  var hash = 0x811c9dc5;
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      hash =
          ((hash ^ plane[offset + y * stride + x]) * 0x01000193) & 0xffffffff;
    }
  }
  return hash;
}

Future<void> main(List<String> arguments) async {
  const mkv = 'test/fixtures/cabac-idr.mkv';
  const mp4 = 'test/fixtures/cabac-idr.mp4';
  const interMkv = 'test/fixtures/cabac-p.mkv';
  const interMp4 = 'test/fixtures/cabac-p.mp4';
  const spatial = 'test/fixtures/cabac-b-spatial.mkv';
  const temporal = 'test/fixtures/cabac-b-temporal.mp4';
  const cavlcBaseline = 'test/fixtures/cavlc-baseline.mp4';
  const cavlcHigh = 'test/fixtures/cavlc-high.mkv';
  const high10Cabac = 'test/fixtures/high10-cabac.mkv';
  const high10Cavlc = 'test/fixtures/high10-cavlc.mp4';
  const high10Monochrome = 'test/fixtures/high10-mono.mkv';
  const losslessCabac = 'test/fixtures/lossless-avc-cabac.mkv';
  const losslessCavlc = 'test/fixtures/lossless-avc-cavlc.mp4';
  const cabac422 = 'test/fixtures/avc-422-cabac.mkv';
  const cavlc422 = 'test/fixtures/avc-422-cavlc.mp4';
  const lossless422 = 'test/fixtures/avc-422-lossless.mkv';
  const cabac444 = 'test/fixtures/avc-444-cabac.mkv';
  const cavlc444 = 'test/fixtures/avc-444-cavlc.mp4';
  const losslessRgb = 'test/fixtures/avc-444-lossless-rgb.mkv';
  const cabac12 = 'test/fixtures/avc-12-b.mkv';
  const cavlc12 = 'test/fixtures/avc-12-cavlc.mp4';
  const lossless14 = 'test/fixtures/avc-14-lossless.mkv';
  const mixedGbr = 'test/fixtures/avc-mixed-gbr.mkv';
  const separateCabac = 'test/fixtures/avc-separate-cabac.mkv';
  const separateCavlc = 'test/fixtures/avc-separate-cavlc.mkv';
  const separateLossless = 'test/fixtures/avc-separate-lossless.mkv';
  _checkPlanes(mkv, _idrPlanes);
  _checkPlanes(mp4, _idrPlanes);
  _checkPlanes(interMkv, _pPlanes, inter: true);
  _checkPlanes(interMp4, _pPlanes, inter: true);
  _checkPlanes(spatial, _spatialBPlanes, inter: true, dimensions: (166, 110));
  _checkPlanes(temporal, _temporalBPlanes, inter: true, dimensions: (166, 110));
  _checkPlanes(
    cavlcBaseline,
    _cavlcBaselinePlanes,
    inter: true,
    cabac: false,
    profile: 66,
    dimensions: (166, 110),
  );
  _checkPlanes(
    cavlcHigh,
    _cavlcHighPlanes,
    inter: true,
    cabac: false,
    dimensions: (166, 110),
  );

  _checkPlanes(
    high10Cabac,
    _high10CabacPlanes,
    inter: true,
    profile: 110,
    depth: 10,
    dimensions: (94, 62),
  );
  _checkPlanes(
    high10Cavlc,
    _high10CavlcPlanes,
    inter: true,
    cabac: false,
    profile: 110,
    depth: 10,
    dimensions: (94, 62),
  );

  _checkPlanes(
    high10Monochrome,
    _high10MonochromePlanes,
    inter: true,
    profile: 110,
    depth: 10,
    chromaFormat: 0,
    dimensions: (94, 62),
  );
  _checkPlanes(
    'test/fixtures/high10-pcm9.mp4',
    _high10Pcm9Planes,
    cabac: false,
    profile: 110,
    depth: 9,
    dimensions: (32, 16),
  );

  _checkPlanes(
    losslessCabac,
    _losslessCabacPlanes,
    inter: true,
    lossless: true,
    profile: 244,
    dimensions: (94, 62),
  );
  _checkPlanes(
    losslessCavlc,
    _losslessCavlcPlanes,
    inter: true,
    cabac: false,
    lossless: true,
    profile: 244,
    depth: 10,
    dimensions: (94, 62),
  );

  _checkPlanes(
    cabac422,
    _chroma422CabacPlanes,
    inter: true,
    profile: 122,
    chromaFormat: 2,
    dimensions: (94, 61),
  );
  _checkPlanes(
    cavlc422,
    _chroma422CavlcPlanes,
    inter: true,
    cabac: false,
    profile: 122,
    depth: 10,
    chromaFormat: 2,
    dimensions: (94, 61),
  );
  _checkPlanes(
    lossless422,
    _chroma422LosslessPlanes,
    inter: true,
    profile: 244,
    depth: 10,
    lossless: true,
    chromaFormat: 2,
    dimensions: (94, 61),
  );

  _checkPlanes(
    cabac444,
    _chroma444CabacPlanes,
    inter: true,
    profile: 244,
    chromaFormat: 3,
    dimensions: (93, 61),
  );
  _checkPlanes(
    cavlc444,
    _chroma444CavlcPlanes,
    inter: true,
    cabac: false,
    profile: 244,
    depth: 10,
    chromaFormat: 3,
    dimensions: (93, 61),
  );
  _checkPlanes(
    losslessRgb,
    _chroma444LosslessRgbPlanes,
    inter: true,
    profile: 244,
    chromaFormat: 3,
    lossless: true,
    rgb: true,
    dimensions: (93, 61),
  );

  _checkPlanes(
    cabac12,
    _depth12CabacPlanes,
    inter: true,
    profile: 244,
    depth: 12,
    chromaFormat: 3,
    dimensions: (64, 48),
  );
  _checkPlanes(
    cavlc12,
    _depth12CavlcPlanes,
    inter: true,
    cabac: false,
    profile: 244,
    depth: 12,
    dimensions: (64, 48),
  );
  _checkPlanes(
    lossless14,
    _depth14LosslessPlanes,
    inter: true,
    cabac: false,
    profile: 244,
    depth: 14,
    chromaFormat: 3,
    lossless: true,
    dimensions: (64, 48),
  );
  _checkPlanes(
    mixedGbr,
    _mixedDepthGbrPlanes,
    inter: true,
    profile: 244,
    chromaDepth: 14,
    chromaFormat: 3,
    rgb: true,
    dimensions: (64, 48),
  );

  _checkPlanes(
    separateCabac,
    _separateCabacPlanes,
    inter: true,
    profile: 244,
    chromaFormat: 3,
    separate: true,
    dimensions: (64, 48),
  );
  _checkPlanes(
    separateCavlc,
    _separateCavlcPlanes,
    inter: true,
    cabac: false,
    profile: 244,
    depth: 10,
    chromaFormat: 3,
    separate: true,
    dimensions: (64, 48),
  );
  _checkPlanes(
    separateLossless,
    _separateLosslessPlanes,
    inter: true,
    cabac: false,
    profile: 244,
    depth: 10,
    chromaFormat: 3,
    separate: true,
    lossless: true,
    rgb: true,
    dimensions: (64, 48),
  );

  final directory = Directory.systemTemp.createTempSync('vimg-h264-test-');
  Future<String> run(List<String> args) async {
    final result = await Process.run(
      arguments.firstOrNull ?? Platform.resolvedExecutable,
      [if (arguments.isEmpty) 'bin/vimg.dart', ...args],
    );
    check(result.exitCode == 0, 'H.264 CLI failed: ${result.stderr}');
    return result.stdout as String;
  }

  try {
    final jpeg = File('${directory.path}/preview.jpg');
    for (final (input, width, height) in [
      (mkv, 39, 25),
      (mp4, 39, 25),
      (high10Cabac, 47, 31),
      (high10Monochrome, 47, 31),
      (losslessCabac, 47, 31),
      (cabac422, 47, 31),
      (cabac444, 47, 31),
      (mixedGbr, 32, 24),
      (separateLossless, 32, 24),
      (cavlcBaseline, 83, 55),
    ]) {
      final response =
          jsonDecode(
                await run([
                  'preview',
                  '--output',
                  jpeg.path,
                  '--max-width',
                  '$width',
                  input,
                ]),
              )
              as Map;
      check(
        response['preview_written'] == true,
        'H.264 preview response: $response',
      );
      final decoded = image.decodeJpg(jpeg.readAsBytesSync())!;
      check(
        decoded.width == width && decoded.height == height,
        'H.264 JPEG preview dimensions',
      );
    }

    for (final (input, width, height) in [
      (interMkv, 78, 50),
      (high10Cavlc, 94, 62),
      (losslessCavlc, 94, 62),
      (cavlc422, 94, 61),
      (cavlc444, 93, 61),
      (cavlc12, 64, 48),
      (separateCavlc, 64, 48),
      (cavlcBaseline, 166, 110),
    ]) {
      final name = input.split('/').last;
      final output = '${directory.path}/frames-$name';
      await run(['extract', '-n1', '-t500ms', '--output-dir', output, input]);
      final bmp = Directory(output).listSync().single as File;
      final frame = image.decodeBmp(bmp.readAsBytesSync())!;
      check(
        frame.width == width && frame.height == height,
        'H.264 extracted BMP',
      );
    }

    for (final (mode, input, width, height) in [
      ('cabac', temporal, 166, 110),
      ('cavlc', cavlcHigh, 166, 110),
      ('high10', high10Cabac, 94, 62),
      ('lossless', losslessCavlc, 94, 62),
      ('422', cavlc422, 94, 61),
      ('444-rgb', losslessRgb, 93, 61),
      ('12-bit', cabac12, 64, 48),
      ('separate-planes', separateCabac, 64, 48),
    ]) {
      final avif = File('${directory.path}/grid-$mode.avif');
      final kept = '${directory.path}/kept-$mode';
      await run([
        'vcs',
        '-c2',
        '-n2',
        '-H24',
        '-f3',
        '-t500ms',
        '--keep',
        '--output-dir',
        kept,
        '-o',
        avif.path,
        input,
      ]);
      check(
        ascii.decode(avif.readAsBytesSync().sublist(4, 12)) == 'ftypavis',
        'H.264 animated contact sheet',
      );
      final captures = Directory(kept).listSync().cast<File>();
      check(captures.length == 6, 'H.264 kept B-frame captures');
      for (final capture in captures) {
        final frame = image.decodeBmp(capture.readAsBytesSync())!;
        check(
          frame.width == width && frame.height == height,
          'H.264 --keep retains the original capture dimensions',
        );
      }
    }
  } finally {
    directory.deleteSync(recursive: true);
  }
}
