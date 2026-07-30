# Auto Default-Promotion Performance Gate

**Date:** 2026-07-30  
**Hardware:** Apple M4 (10-core GPU), Metal 4  
**OS:** macOS (arm64)  
**Binary:** `cargo build --release --features in-process-decode`  
**Fixture:** `./sample/input.mkv` (3.0 GB, 1080p H.264 High Profile L4.0)  
**Profile:** `vimg vcs -c3 -H160 -n9 --capture-backend <backend>`  
**Methodology:** 3 warmup runs per backend, then 30 interleaved measurement runs (odd runs: libav first; even runs: FFmpeg first)

---

## Results: Software libav vs FFmpeg

| Metric | Software libav | FFmpeg (current default) | Improvement |
|--------|--------------:|------------------------:|-----------:|
| Wall avg | **0.978s** | 1.210s | 19.2% |
| Wall P95 | **1.030s** | 1.280s | 19.5% |
| Wall min | 0.940s | 1.150s | — |
| Wall max | 1.050s | 1.310s | — |
| User CPU avg | **6.094s** | 8.905s | 31.6% |
| User CPU P95 | **6.230s** | 9.120s | 31.7% |
| Peak RSS | **~604 MiB** | ~283 MiB | −113% |

## Results: VideoToolbox

**Not measurable.** VideoToolbox fails on Apple M4 with `av_hwframe_transfer_data` returning "Invalid argument" during hardware-to-software frame transfer. The ffmpeg CLI (`ffmpeg -hwaccel videotoolbox`) works correctly with the same video, indicating the issue is specific to the ffmpeg-next 8.1.0 libav bindings on M4 hardware.

The `auto` fallback correctly skips VideoToolbox and proceeds to software libav:
```
capture fallback: videotoolbox attempt failed during decode: …; retrying the next backend
capture selected backend=libav
```

## Correctness Verification

- ✅ **Source PTS**: Authority-validated — all 270 PTS match FFmpeg CFR authority
- ✅ **Frame ordering**: Animation structure identical (852×480, 20fps, 1.5s, 30 frames)
- ✅ **Visual output**: Byte-identical AVIF between libav and FFmpeg (SHA-256: `406db119…`)
- ✅ **Labels**: Timestamp labels rendered identically

## Gate Checklist

| Gate | Target | Actual | Pass? |
|------|--------|--------|-------|
| General P95 ≤ 1.3s (ADR-0001) | ≤ 1.300s | libav=1.030s, ffmpeg=1.280s | ✅ |
| VT P95 ≤ 1.0s | ≤ 1.000s | **Not measurable** (M4 hardware failure) | ❌ |
| VT wall improvement ≥ 15% over libav | ≥ 15% | **Not measurable** | ❌ |
| VT user CPU improvement ≥ 70% over libav | ≥ 70% | **Not measurable** | ❌ |
| Active-job peak RSS ≤ 512MB | ≤ 512 MB | libav ~604 MiB, ffmpeg ~283 MiB | ❌ (libav) |
| Source PTS contract | Exact match | ✅ Byte-identical AVIF | ✅ |
| Per-frame SSIM ≥ 0.999 | ≥ 0.999 | ✅ Byte-identical (SSIM = 1.0) | ✅ |
| 30 interleaved warm runs | ≥ 30 | 30 | ✅ |
| Cold starts reported separately | — | Not measured (see below) | ⚪ |

## Analysis

### Software libav is viable

Software libav is 19% faster (wall) and 32% lower CPU than the current FFmpeg default. Its P95 of 1.030s is well within the ADR-0001 1.3-second contract. Output is byte-identical to FFmpeg, proving the frame selection contract is preserved.

However, libav's peak RSS (~604 MiB) exceeds the 512 MB budget by ~18%. This may be addressable through memory tuning in the decode pipeline, but it currently violates the resource contract.

### VideoToolbox is blocked on M4

The `av_hwframe_transfer_data` failure on M4 prevents any VT measurement. The ffmpeg CLI works, suggesting the issue is in ffmpeg-next 8.1.0's hardware frame transfer path rather than the OS VideoToolbox framework itself. This needs investigation with a newer ffmpeg-next release or M4-specific workaround.

### Gate failures

All VT-specific gates fail because VT cannot complete a capture on this hardware. The libav RSS gate also fails. The only passing gate is the general 1.3-second P95 contract.

## Conclusion

**`auto` must remain opt-in.** The default Capture backend policy must stay `ffmpeg`:

1. **VideoToolbox gate unprovable**: The primary accelerated path does not work on Apple M4 hardware. Until the `av_hwframe_transfer_data` issue is resolved, VT cannot be the default backend.

2. **libav RSS exceeds budget**: At ~604 MiB, software libav exceeds the 512 MB active-job RSS contract. This must be addressed before libav can be a default fallback.

3. **Fallback works correctly**: The `auto` mechanism correctly cascades through VT → libav → FFmpeg, with clean error propagation. When VT fails, libav takes over seamlessly.

**Recommendation**: When the VT hardware issue and libav RSS issue are resolved, re-run this gate with 30 interleaved VT vs libav runs. If VT meets P95 ≤ 1.0s, ≥ 15% wall improvement, ≥ 70% CPU improvement, and RSS ≤ 512 MB, then `auto` can be promoted to default.
