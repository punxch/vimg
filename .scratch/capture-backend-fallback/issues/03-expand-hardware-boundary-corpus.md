# 03 — Expand the hardware-boundary media corpus

**What to build:** Extend the repeatable media corpus so VideoToolbox eligibility, decoder color behavior, damaged-input handling, and compatibility fallback are tested against production FFmpeg authority output rather than assumptions.

**Blocked by:** 01 — Establish the production FFmpeg authority.

**Status:** resolved

- [x] The corpus includes H.264 and HEVC 8-bit and 10-bit fixtures.
- [x] The corpus covers limited/full range and BT.601, BT.709, and BT.2020 metadata.
- [x] Rotation metadata, non-square SAR, and interlaced input are represented.
- [x] Unsupported hardware chroma cases include 4:2:2 and 4:4:4 input.
- [x] Corrupt and truncated inputs exercise explicit failure rather than silent incomplete output.
- [x] Every valid fixture has an authority PTS record, structural record, and visual reference.
- [x] Each fixture declares whether VideoToolbox support or Backend fallback is expected.
- [x] Corpus generation and validation are reproducible and clean up their generated temporary artifacts.

## Answer

Extended the repeatable corpus generator with nine valid hardware-boundary fixtures and two invalid-media fixtures. The declarations record codec, pixel format, color metadata, rotation/SAR/interlacing where applicable, and the expected VideoToolbox outcome (`supported`, `backend-fallback`, or `failure`).

Every valid fixture is processed by `vimg authority record`; validation requires 270 selected source PTS, a complete animation structural record, and 30 pre-encoder plus 30 decoded visual references. Corrupt and truncated inputs must leave a non-empty failure log without publishing an AVIF or authority manifest. The script uses a dedicated `mktemp` directory and removes it on exit.

Verification: the final corpus run generated and validated all nine authority records, preserved the existing 11-case 270/270 frame-selection corpus, rejected both damaged fixtures as required, and removed its generated temporary directory. Full tests, shell syntax and ShellCheck, Clippy with warnings denied, release build, and Standards/Spec reviews pass.
