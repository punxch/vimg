# Auto Default-Promotion Performance Gate

**Date:** 2026-07-30 14:51 UTC
**Hardware:** Apple M4
**OS:** macOS 26.4.1
**FFmpeg:** 8.1.2
**Binary:** `cargo build --release --features in-process-decode`
**Fixture:** `./sample/input.mkv`
**Profile:** `vimg vcs -c3 -H160 -n9 --capture-backend <backend>`
**Methodology:** 3 warmups, then 30 rotated/interleaved warm pairs

Raw observations: `.scratch/capture-backend-fallback/promotion-gate-results.tsv`

## Promotion decision

**Do not promote `auto`; keep `ffmpeg` as the default.**

The VideoToolbox candidate cannot complete the representative Preview profile
(forced-backend exit status 1), so its latency and CPU gates
are not measurable. Thresholds are not weakened or substituted with libav results.

## Warm results

| Metric | Software libav | FFmpeg | libav improvement |
|---|---:|---:|---:|
| Wall average | 0.988s | 1.231s | 19.7% |
| Wall P95 | 1.040s | 1.310s | — |
| User CPU average | 6.116s | 8.924s | 31.5% |
| User CPU P95 | 6.250s | 9.140s | — |
| Peak RSS | 607.9 MiB | 294.3 MiB | — |

## VideoToolbox failure boundary

The forced VideoToolbox attempt failed before producing a hardware frame.
The full diagnostic is in `/tmp/vimg-promotion-gate/time-videotoolbox-probe-1-videotoolbox.txt`.
This benchmark treats software pixel-format fallback as failure, so a successful
software decode cannot be misreported as VideoToolbox performance.

Independent probes reproduced the same VideoToolbox session-initialization
failure with FFmpeg 8.1.2's own CLI and its installed official
`hw_decode.c` example, including on a newly generated two-second 1080p
H.264 fixture. That falsifies a Vimg transfer-path or Rust-binding-specific
cause: the failure occurs below Vimg before any hardware frame is returned.

## First-process observations

These are fresh-process observations made before benchmark warmups. They are not
filesystem-cache-cold claims; reproducible cache eviction requires privileged OS
control and is deliberately kept separate from the warm promotion result.

| Policy | Wall time |
|---|---:|
| libav | 2.030s |
| ffmpeg | 1.330s |
| auto (early VideoToolbox failure, then libav) | 1.210s |

## Fallback latency

Real early fallback was measured in 5 rotated/interleaved pairs:
`auto` averaged 1.228s versus 0.972s for direct
libav, an observed overhead of 0.256s.

Late injected fallback is a correctness/stress scenario, not a sub-second SLA.
It must be reported independently if a lifecycle fault-injection benchmark is
added; it is not mixed into the warm promotion distribution here.

## Correctness

- Latest libav and FFmpeg AVIF outputs byte-identical: **yes**
- libav SHA-256: `406db119839f6307cf56b5907966f525f36f18a21093f439926835918ab2c68f`
- FFmpeg SHA-256: `406db119839f6307cf56b5907966f525f36f18a21093f439926835918ab2c68f`

## Gate checklist

| Gate | Target | Result |
|---|---:|---|
| General warm P95 | ≤ 1.300s | fail (1.040s libav, 1.310s FFmpeg) |
| VideoToolbox warm P95 | < 1.000s | fail: not measurable |
| VideoToolbox wall improvement over libav | ≥ 15% | fail: not measurable |
| VideoToolbox user CPU improvement over libav | ≥ 70% | fail: not measurable |
| Active-job peak RSS | ≤ 512 MiB | fail (libav 607.9 MiB) |
| Frame-selection/output contract | exact/approved tolerance | byte-identical=yes |
| Rotated, interleaved warm runs | ≥ 30 | 30 pairs |
| First-process and fallback observations separate | required | yes |

## Reproduction

```bash
cargo build --release --features in-process-decode
bash src/bin/bench_promotion_gate.sh
ffmpeg -hide_banner -loglevel debug -hwaccel videotoolbox \
  -i ./sample/input.mkv -frames:v 1 -f null -
```
