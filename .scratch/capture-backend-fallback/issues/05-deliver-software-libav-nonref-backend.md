# 05 — Deliver the explicit software libav Nonref backend

**What to build:** Allow a feature-on build to run the fixed Preview profile through software libav with the validated 0.5-second Nonref preroll, while keeping feature-off installation and unsupported-input behavior unchanged.

**Blocked by:** 04 — Prefactor FFmpeg behind the Capture backend module.

**Status:** ready-for-agent

- [ ] The optional in-process decoding capability does not add libav linkage requirements to feature-off builds.
- [ ] An explicit `libav` Capture backend policy runs one fail-fast software attempt and never silently uses FFmpeg.
- [ ] Initial eligibility is limited to the fixed Preview profile, H.264/HEVC, bicubic scaling, and no custom video filter.
- [ ] Unsupported build, profile, codec, timestamp, or decoder conditions return a clear unavailable/unsupported result.
- [ ] The Nonref recovery margin is fixed internally at 0.5 seconds and is not exposed as a public tuning option.
- [ ] Frame production remains ordered and bounded with no materialization of all 270 tiles.
- [ ] All 270 source PTS exactly match the Frame selection contract on the existing corpus.
- [ ] Pre-encoder grids and decoded AVIF frames meet the per-frame SSIM 0.999 contract.
- [ ] Linux and macOS feature-on builds pass while existing feature-off Linux and Windows behavior remains green.
