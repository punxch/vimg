# 03 — Expand the hardware-boundary media corpus

**What to build:** Extend the repeatable media corpus so VideoToolbox eligibility, decoder color behavior, damaged-input handling, and compatibility fallback are tested against production FFmpeg authority output rather than assumptions.

**Blocked by:** 01 — Establish the production FFmpeg authority.

**Status:** ready-for-agent

- [ ] The corpus includes H.264 and HEVC 8-bit and 10-bit fixtures.
- [ ] The corpus covers limited/full range and BT.601, BT.709, and BT.2020 metadata.
- [ ] Rotation metadata, non-square SAR, and interlaced input are represented.
- [ ] Unsupported hardware chroma cases include 4:2:2 and 4:4:4 input.
- [ ] Corrupt and truncated inputs exercise explicit failure rather than silent incomplete output.
- [ ] Every valid fixture has an authority PTS record, structural record, and visual reference.
- [ ] Each fixture declares whether VideoToolbox support or Backend fallback is expected.
- [ ] Corpus generation and validation are reproducible and clean up their generated temporary artifacts.
