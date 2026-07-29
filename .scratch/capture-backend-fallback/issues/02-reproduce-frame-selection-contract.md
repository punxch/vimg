# 02 — Reproduce the FFmpeg Frame selection contract

**What to build:** Turn the observed production FFmpeg CFR behavior into one deterministic Frame selection contract that can be reused by every Capture backend without shadow-running FFmpeg in production.

**Blocked by:** 01 — Establish the production FFmpeg authority.

**Status:** resolved

- [x] The shared frame schedule reproduces all 270 authority PTS on the representative input.
- [x] The schedule reproduces the authority PTS on the existing 11 H.264/HEVC GOP, B-frame, VFR, short-duration, and tail fixtures.
- [x] Duplicate and drop behavior at capture-window boundaries is covered explicitly.
- [x] The schedule carries enough information for a Capture plan to drive FFmpeg, software libav, and VideoToolbox adapters.
- [x] Production use of the schedule does not require a second FFmpeg process or shadow decode.
- [x] A mismatch reports the capture point, animation index, expected PTS, and observed PTS.
- [x] If the authority cannot be expressed deterministically, the result documents the blocker and stops dependent implementation in accordance with ADR-0003.

## Answer

Implemented a backend-independent `CaptureWindow` and `FrameSchedule` that reproduce FFmpeg's CFR frame-selection behavior, including boundary duplicates, accumulated drops, time-base conversion, and FFmpeg-compatible frame-rate rationalization. The production FFmpeg path now consumes the same canonical capture-window frame rate without a second process or shadow decode.

Verification:

- Representative authority: 270/270 source PTS, from `183100@1/1000` through `3113736@1/1000`.
- Generated corpus: 11/11 H.264/HEVC GOP, B-frame, VFR, short-duration, and tail cases reproduce all 270 PTS.
- Authority visual comparison: 30/30 decoded animation frames, minimum SSIM `1.000000`.
- Production output SHA-256 remains `406db119839f6307cf56b5907966f525f36f18a21093f439926835918ab2c68f`.
- Full test suite, Clippy with warnings denied, release build, and both Standards and Spec reviews pass.
