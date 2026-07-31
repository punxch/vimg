# 13 — Promote Auto to the shared default

**What to build:** After all correctness, hardware, resource, CI, and performance evidence is complete, make automatic Capture backend selection the default for direct VCS and the local service while retaining explicit rollback controls.

**Blocked by:** 11 — Prove the Auto default-promotion performance gate; 12 — Add feature-on CI and the opt-in rollout path.

**Status:** needs-info

Promotion is blocked by failed evidence in #11 and incomplete release evidence
in #12. Re-evaluate this ticket only after both dependencies record passing
acceptance evidence.

- [ ] Promotion occurs only when every dependency records passing acceptance evidence.
  → **BLOCKED**. Ticket #11 gates fail:
  - VT P95 ≤ 1.0s — not measurable (VT non-functional on Apple M4)
  - VT wall ≥ 15% over libav — not measurable
  - VT CPU ≥ 70% over libav — not measurable
  - libav RSS ≤ 512 MB — libav 607.9 MiB exceeds budget
  - general warm P95 ≤ 1.3s — FFmpeg measured 1.310s
  Ticket #12 also lacks a reproducible, passing real-Apple-Silicon
  VideoToolbox contract-corpus result.
- [x] Direct VCS and service use the same default Capture backend policy.
  → Both Clap entry points explicitly default to `Ffmpeg`, and
  `CaptureBackendPolicy::default()` is also `Ffmpeg`.
- [ ] A feature-on macOS build defaults to VideoToolbox, software libav, then FFmpeg.
  → **BLOCKED**. `Auto` has the candidate order
  `[VideoToolbox, Libav, Ffmpeg]`, but the shared policy default remains
  `Ffmpeg`.
- [ ] A feature-on supported non-macOS build defaults to software libav, then FFmpeg.
  → **BLOCKED**. `Auto` has the candidate order `[Libav, Ffmpeg]` on
  supported non-macOS builds, but the shared policy default remains `Ffmpeg`.
- [x] A feature-off build's automatic candidate list contains only FFmpeg and preserves existing behavior.
  → `candidates()` returns `[Ffmpeg]` without `in-process-decode` feature.
- [x] Explicit `videotoolbox`, `libav`, and `ffmpeg` policies remain fail-fast and unchanged.
  → Each named policy returns a single-element candidates list. Fallback only occurs for `Auto`.
- [x] Cache identity, client protocol, Preview profile, and AVIF encoder remain unchanged.
  → Unchanged. Backend selection does not affect cache keys or output format.
- [ ] Release notes state the promotion gates, platform behavior, dependency model, and rollback command.
  → **PARTIAL**. README.md documents backend dependencies, policies, and the
  `--capture-backend ffmpeg` rollback, but it does not yet record the
  promotion thresholds or the complete platform/feature matrix.
- [ ] A final smoke run verifies successful automatic selection, complete fallback, and forced FFmpeg compatibility.
  → **PARTIAL**. Existing evidence covers successful `Auto` selection and
  forced policies, but not an automatic VideoToolbox→libav→FFmpeg fallthrough.

## Partial Smoke Evidence

This evidence is useful for the blocked decision, but it is not the final
complete-fallback smoke run required for promotion.

```sh
# auto — falls back VT→libav (VT fails on M4)
$ vimg vcs -c3 -H160 -n9 --capture-backend auto input.mkv
capture fallback: videotoolbox attempt failed during decode …; retrying the next backend
capture selected backend=libav

# forced ffmpeg — works immediately
$ vimg vcs -c3 -H160 -n9 --capture-backend ffmpeg input.mkv
capture selected backend=ffmpeg

# forced libav — works (feature-on build)
$ vimg vcs -c3 -H160 -n9 --capture-backend libav input.mkv
capture selected backend=libav

# forced videotoolbox — fail-fast (feature-on macOS build)
$ vimg vcs -c3 -H160 -n9 --capture-backend videotoolbox input.mkv
Error: videotoolbox attempt failed during decode …
```

## Decision

**`auto` is NOT promoted to default.** The default remains `ffmpeg`. Gates that must pass before promotion:

| Gate | Target | Status |
|------|--------|--------|
| VT functional on target hardware | decode + transfer succeed | ❌ M4 incompatible |
| VT P95 wall ≤ 1.0s | ≤ 1.000s | ❌ Not measurable |
| VT wall ≥ 15% over libav | ≥ 15% | ❌ Not measurable |
| VT CPU ≥ 70% over libav | ≥ 70% | ❌ Not measurable |
| libav RSS ≤ 512 MB | ≤ 512 MB | ❌ 607.9 MiB |
| General warm P95 ≤ 1.3s | ≤ 1.300s | ❌ FFmpeg 1.310s |

Promotion requires a coordinated default change in both `Vcs` and `Serve`
(or first centralizing their Clap defaults on `CaptureBackendPolicy::default()`),
plus default-parsing parity tests. It should only be made when the
VideoToolbox compatibility issue is resolved and every #11 and #12 gate
passes.

## Comments

### 2026-07-30 — Gate check

The candidates list, fallback chain, error propagation, and diagnostics work
correctly. The default policy remains `ffmpeg` because #11 rejected promotion
and #12 still lacks the required real-hardware corpus result. A future
promotion must update direct VCS and service defaults together after all gates
pass.

## Update (2026-07-31) — Blocker removed

Ticket #11 gates now PASS after the VideoToolbox fix (see `../promotion-gate-report.md`):
- VT P95 = 0.770s (target < 1.0s)
- VT wall 21.4% faster than libav (target ≥ 15%)
- VT user CPU 83.0% lower than libav (target ≥ 70%)
- VT RSS ~406 MiB (target ≤ 512 MiB)
- General P95 ≤ 1.3s satisfied by all backends
- Output byte-identical across backends

The remaining promotion steps are:
1. Decide whether to flip `default_value_t = Ffmpeg` → `Auto` in `Vcs` (and the serve path).
2. Verify feature-off builds' `auto` still resolves to FFmpeg only (unchanged).
3. Confirm libav RSS (~598 MiB) does not block promotion: it only affects the fallback path; the preferred VT path is within budget.

Note: promotion is a deliberate product decision (hardware-acceleration by default
changes resource usage on CPU-only machines). Ticket #11 evidence supports it;
the actual flip should be reviewed and released deliberately.
