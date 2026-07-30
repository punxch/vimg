# 05 — Deliver the explicit software libav Nonref backend

**What to build:** Allow a feature-on build to run the fixed Preview profile through software libav with the validated 0.5-second Nonref preroll, while keeping feature-off installation and unsupported-input behavior unchanged.

**Blocked by:** 04 — Prefactor FFmpeg behind the Capture backend module.

**Status:** claimed

- [x] The optional in-process decoding capability does not add libav linkage requirements to feature-off builds.
- [x] An explicit `libav` Capture backend policy runs one fail-fast software attempt and never silently uses FFmpeg.
- [x] Initial eligibility is limited to the fixed Preview profile, H.264/HEVC, bicubic scaling, and no custom video filter.
- [x] Unsupported build, profile, codec, timestamp, or decoder conditions return a clear unavailable/unsupported result.
- [x] The Nonref recovery margin is fixed internally at 0.5 seconds and is not exposed as a public tuning option.
- [x] Frame production remains ordered and bounded with no materialization of all 270 tiles.
- [x] All 270 source PTS exactly match the Frame selection contract on the existing representative corpus.
- [x] Pre-encoder grids and decoded AVIF frames meet the per-frame SSIM 0.999 contract on the representative corpus.
- [ ] Linux and macOS feature-on builds pass while existing feature-off Linux and Windows behavior remains green.

## Progress

The optional `in-process-decode` feature adds an explicit, fail-fast `--capture-backend libav` path without changing feature-off linkage. It opens one software libav decoder per capture point, uses a private 0.5-second `AVDISCARD_NONREF` recovery margin, feeds the shared `FrameSchedule` with demux packet durations, and uses an in-process libavfilter `scale=-1:160:flags=bicubic,format=rgb24` graph. Each decoder owns a capacity-two channel; the attempt forwards root worker failures and joins every worker on completion or drop.

The policy is restricted at the VCS boundary to the complete fixed Preview profile and validates H.264/HEVC plus usable timestamps at decoder setup. The representative release authority run produced all 270 expected `(capture, animation, PTS, time base)` values; all 30 pre-encoder grids were byte-identical and the decoded AVIF verification minimum SSIM was `1.000000`.

Feature-off and macOS feature-on test/Clippy builds pass locally. Cross-platform feature-on Linux and feature-off Windows CI evidence remains for Ticket 12, so the final platform checkbox stays open.
