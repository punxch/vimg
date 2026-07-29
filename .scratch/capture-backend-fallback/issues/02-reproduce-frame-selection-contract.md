# 02 — Reproduce the FFmpeg Frame selection contract

**What to build:** Turn the observed production FFmpeg CFR behavior into one deterministic Frame selection contract that can be reused by every Capture backend without shadow-running FFmpeg in production.

**Blocked by:** 01 — Establish the production FFmpeg authority.

**Status:** ready-for-agent

- [ ] The shared frame schedule reproduces all 270 authority PTS on the representative input.
- [ ] The schedule reproduces the authority PTS on the existing 11 H.264/HEVC GOP, B-frame, VFR, short-duration, and tail fixtures.
- [ ] Duplicate and drop behavior at capture-window boundaries is covered explicitly.
- [ ] The schedule carries enough information for a Capture plan to drive FFmpeg, software libav, and VideoToolbox adapters.
- [ ] Production use of the schedule does not require a second FFmpeg process or shadow decode.
- [ ] A mismatch reports the capture point, animation index, expected PTS, and observed PTS.
- [ ] If the authority cannot be expressed deterministically, the result documents the blocker and stops dependent implementation in accordance with ADR-0003.
