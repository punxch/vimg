# 12 — Add feature-on CI and the opt-in rollout path

**What to build:** Make the optional accelerated build reproducible and reviewable across supported platforms while preserving default feature-off installation and providing a documented compatibility rollback.

**Blocked by:** 09 — Complete the macOS automatic fallback chain.

**Status:** ready-for-agent

- [ ] Existing default Linux and Windows CI remain feature-off and green.
- [ ] Linux CI builds and tests the software libav backend with the optional capability enabled.
- [ ] macOS CI builds the optional software and VideoToolbox adapters and exercises capability detection.
- [ ] The complete VideoToolbox contract corpus has a reproducible real-Apple-Silicon release-gate command and recorded result.
- [ ] Intel Mac coverage is added when a suitable runner is available or is explicitly recorded as pending.
- [ ] Installation documentation distinguishes the default FFmpeg executable requirement from feature-on libav development/runtime requirements.
- [ ] Backend-policy documentation explains `auto`, forced fail-fast policies, diagnostics, and `-T` behavior.
- [ ] The first rollout keeps `ffmpeg` as the default and requires explicit `auto` opt-in.
- [ ] Users can force `ffmpeg` as an immediate compatibility and rollback control.
- [ ] Disabling the optional capability removes both in-process adapters without changing the client protocol or cache format.
