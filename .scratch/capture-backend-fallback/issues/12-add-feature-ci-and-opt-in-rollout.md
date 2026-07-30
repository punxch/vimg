# 12 — Add feature-on CI and the opt-in rollout path

**What to build:** Make the optional accelerated build reproducible and reviewable across supported platforms while preserving default feature-off installation and providing a documented compatibility rollback.

**Blocked by:** 09 — Complete the macOS automatic fallback chain.

**Status:** in-progress

- [x] Existing default Linux and Windows CI remain feature-off and green.  
  → Linux feature-off job preserved. Windows release build unchanged.
- [x] Linux CI builds and tests the software libav backend with the optional capability enabled.  
  → `test-linux-feature-on` job added: installs libav dev libs, runs `cargo test --features in-process-decode --locked`.
- [x] macOS CI builds the optional software and VideoToolbox adapters and exercises capability detection.  
  → `test-macos` (feature-off) and `test-macos-feature-on` (feature-on) jobs added. VT availability test `deterministic_device_failure_is_cached_for_later_capture_jobs` runs in CI.
- [ ] The complete VideoToolbox contract corpus has a reproducible real-Apple-Silicon release-gate command and recorded result.  
  → **Deferred**: VideoToolbox is non-functional on Apple M4 (see ticket #11 and `../promotion-gate-report.md`). The `h264_videotoolbox` decoder is not available in Homebrew FFmpeg and manual `AVHWFramesContext` allocation segfaults. The contract corpus cannot run until the upstream ffmpeg-next / FFmpeg 7.x compatibility issue is resolved. The CI exercises VT availability detection (codec lookup, device creation) but not full decode.
- [x] Intel Mac coverage is added when a suitable runner is available or is explicitly recorded as pending.  
  → GitHub Actions `macos-latest` currently provides Apple Silicon (M1). Intel Mac coverage is recorded as pending — no x86_64 macOS runner is available in the free GitHub Actions tier.
- [x] Installation documentation distinguishes the default FFmpeg executable requirement from feature-on libav development/runtime requirements.  
  → Added "Optional: in-process decoding" section to README.md listing build-time libav dependencies for Debian/Ubuntu and macOS.
- [x] Backend-policy documentation explains `auto`, forced fail-fast policies, diagnostics, and `-T` behavior.  
  → Added "Capture Backends" and "Capture Concurrency" sections to README.md with policy table, `--capture-backend` examples, and `-T` flag documentation.
- [x] The first rollout keeps `ffmpeg` as the default and requires explicit `auto` opt-in.  
  → `CaptureBackendPolicy::default()` is `Ffmpeg`. Users must explicitly pass `--capture-backend auto` to enable fallback. README documents this.
- [x] Users can force `ffmpeg` as an immediate compatibility and rollback control.  
  → `--capture-backend ffmpeg` is always available regardless of build features. Documented in README.
- [x] Disabling the optional capability removes both in-process adapters without changing the client protocol or cache format.  
  → Verified: feature-off builds compile without libav or videotoolbox modules. Cache identity, TCP protocol, and AVIF format are unaffected by backend selection.

## Comments

### 2026-07-30 — Implementation

Added multi-platform CI:
- **Linux**: feature-off (`test-linux`) + feature-on (`test-linux-feature-on`, installs libav dev packages)
- **macOS**: feature-off (`test-macos`) + feature-on (`test-macos-feature-on`, `brew install ffmpeg`)
- **Windows**: unchanged (release binary stays feature-off)
- **rustfmt**: unchanged

Updated README.md:
- "Optional: in-process decoding" section with build-time deps
- "Capture Backends" section with policy table and examples
- "Capture Concurrency" section with `-T` flag docs

VT contract corpus deferred (M4 incompatibility). Intel Mac coverage noted as pending.

### Outstanding

The VT contract corpus gate remains open. This requires either:
1. A newer ffmpeg-next release that fixes `hw_frames_ctx` creation on FFmpeg 7.x / Apple Silicon
2. Switching to the filter-graph approach for hardware acceleration (software decode → hwupload → hwdownload)
3. An Intel Mac runner for testing the existing VT path (may work on Intel + older FFmpeg)

See `../promotion-gate-report.md` for the full VT root cause analysis.
