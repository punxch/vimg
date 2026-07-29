# Performance Optimization Report

## Test Command
```
vimg vcs -c3 -H160 -n9 .\sample\input.mkv --output output.avif
```

## Baseline (original vimg.exe)
| Run | Time |
|-----|------|
| 1 | 2.957s |
| 2 | 2.888s |
| 3 | 2.721s |
| 4 | 2.712s |
| 5 | 2.697s |
| **Average** | **~2.80s** |

## Optimized (current build)
| Run | Time |
|-----|------|
| 1 | 2.153s |
| 2 | 2.097s |
| 3 | 2.082s |
| 4 | 2.061s |
| 5 | 2.078s |
| **Average** | **~2.09s** |

## Results
- **~26% faster** (2.80s → 2.09s, saved ~0.71s)
- Output file size unchanged (79KB AVIF)
- FFmpeg output suppressed

## Key Optimizations

### 1. Disabled CUDA Decoding
CUDA (`-hwaccel cuda`) was **adding overhead** for short captures:
- Single capture: 0.51s (CUDA) vs 0.28s (CPU)
- Reason: CUDA initialization overhead outweighs benefits for 30-frame captures
- Disabled by default; can be re-enabled if needed

### 2. SVT-AV1 Preset 6 → 8
- Faster encoding with negligible quality loss for contact sheets
- ~0.2s improvement per run

### 3. Thread Count 3 → 8
- Better utilization of 24-core system
- Each ffmpeg process uses ~1-2 cores internally
- 8 parallel ffmpeg calls = ~16 cores utilized

## Phase Breakdown
| Phase | Baseline | Optimized |
|-------|----------|-----------|
| Extraction | ~1.8s | ~1.5s |
| Join | ~0.3s | ~0.2s |
| Encoding | ~0.5s | ~0.3s |
| **Total** | **~2.8s** | **~2.1s** |

## Files Modified
- `src/command/extract.rs` - Disabled CUDA by default, thread count 3→8
- `src/command/vcs.rs` - SVT-AV1 preset 6→8, stderr suppression
- `src/command/join.rs` - Direct buffer copy optimization
- `src/command/join/label.rs` - Direct buffer access for label drawing

## Ordered Streaming Pipeline Verification (2026-07-30, macOS)

The release build was warmed once, then measured five times with the representative fixture:

```sh
./target/release/vimg vcs -c3 -H160 -n9 ./sample/input.mkv --output /tmp/vimg-final-benchmark.avif
```

| Warm run | Wall time |
|---|---:|
| 1 | 1.18s |
| 2 | 1.28s |
| 3 | 1.26s |
| 4 | 1.18s |
| 5 | 1.17s |
| **Average** | **1.214s** |

Profiling is available without changing the output profile:

```sh
./target/release/vimg vcs -c3 -H160 -n9 ./sample/input.mkv \
  --output /tmp/vimg-profile.avif --profile
```

Representative phase timing:

| Phase | Time |
|---|---:|
| Probe and pipeline setup | 0.021s |
| First complete grid available | 0.981s |
| Grid composition | 0.026s |
| Encoder input backpressure | 0.162s |
| Encoder tail | 0.088s |
| **Total** | **1.280s** |

The original bounded channel allowed each sampling process to enqueue its full 30-frame capture. The encoder therefore received 241 frames before it could assemble frame zero. A cancellable frame barrier now keeps all nine sampling processes on the same frame index: only nine frames are received before the first grid, and the channel remains bounded to two frames per sampling point.

Each sampling process uses three ffmpeg threads. One thread produced approximately 1.60–1.66s totals and two threads approximately 1.25–1.29s; three threads produced a warmed 1.16–1.28s range on this host.

`/usr/bin/time -lp` reported a maximum resident set size of approximately 298 MB. Summing the resident sets of the vimg process and all direct ffmpeg children peaked near 879 MiB, but that value double-counts shared mappings. Both figures are recorded because the ADR's memory accounting boundary needs to be made explicit before treating 512 MB as a hard process-tree gate.

The generated AVIF retains its animation stream: AV1, 852×480, 20 fps, 1.5 seconds, and 30 frames.
