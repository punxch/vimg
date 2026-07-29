# Capture Backend Fallback Implementation Plan

Status: accepted plan; implementation not started

Date: 2026-07-30

## Goal

Productize the validated in-process decoding work behind one bounded Capture backend module and support the preference order:

1. VideoToolbox with 0.5-second Nonref preroll;
2. software libav with 0.5-second Nonref preroll;
3. the existing FFmpeg subprocess.

The first production scope is the fixed Preview profile on H.264 and HEVC media. The module must preserve the current FFmpeg CFR Frame selection contract, restart whole Capture attempts when fallback is allowed, keep an active job below the existing 512MB RSS budget, and retain the current FFmpeg path for compatibility.

## Measured Baseline

The strict like-for-like comparison on `sample/input.mkv` is:

| Path | Wall average | First grid | User CPU | Peak RSS |
|---|---:|---:|---:|---:|
| software libav Nonref | 0.932s | 0.549s | 5.798s | 450.1MB |
| VideoToolbox Nonref | 0.743s | 0.417s | 1.073s | 376.3MB |
| Change | -20.2% | -24.1% | -81.5% | -16.4% |

Both paths selected the same 270 source PTS and produced byte-identical RGB tiles and AVIF output. The existing FFmpeg subprocess averaged 1.207s in a separate paired run, but its current CFR selection differs from the prototype's explicit-PTS selection; its 38.1% apparent wall-time gap is not an acceptance baseline until Stage 0 aligns selection semantics.

## Accepted Constraints

- Backend fallback is atomic at the Capture attempt level. A failed attempt contributes no frames or output to the next attempt.
- Only `Unavailable` and `AttemptFailed` outcomes permit trying the next backend. Shared input, encoder, publication, disk, and cancellation failures are `Fatal`.
- The current production FFmpeg CFR behavior is the authority for the Frame selection contract.
- Source PTS, animation/capture order, dimensions, and labels must match exactly across backends. RGB and decoded AVIF frames must each meet SSIM ≥ 0.999.
- Production performs structural validation only. Exact PTS comparison and visual equivalence are offline corpus and CI gates; production never shadow-runs FFmpeg.
- In-process decoding is behind an optional `in-process-decode` Cargo feature. Default builds retain the existing FFmpeg executable-only installation contract.
- Software libav is cross-platform when the feature is enabled. VideoToolbox is compiled only on macOS.
- Initial acceleration applies only to the fixed Preview profile and H.264/HEVC. Other VCS configurations or codecs use FFmpeg under `auto`.
- The Nonref full-decode recovery margin is an internal fixed 0.5 seconds, not a user-facing tuning option.
- Backend choice does not affect cache identity or the client protocol.
- Only deterministic process-level unavailability is cached. A media-specific runtime failure does not permanently disable a backend.
- The first implementation handles explicit failures and cooperative cancellation; it does not pretend that a blocked in-process FFI thread can be safely killed and retried.
- One service Capture job remains active at a time. A previous attempt must be fully joined before the next attempt starts.

## Runtime Policy

Expose the same Capture backend policy to direct VCS commands and the local service:

| Policy | Behavior |
|---|---|
| `auto` | Try the available backend sequence in preference order and permit whole-attempt fallback |
| `videotoolbox` | Run exactly one VideoToolbox attempt; fail fast if unavailable or failed |
| `libav` | Run exactly one software libav attempt; fail fast if unavailable or failed |
| `ffmpeg` | Run exactly the existing FFmpeg subprocess path |

Add `--capture-backend` to both `vcs` and `serve`. `serve` fixes the policy at process startup and passes it to every Capture job; the request protocol remains unchanged.

Rollout has two defaults:

1. During development and validation, `ffmpeg` remains the default and `auto` is explicit opt-in.
2. After every correctness, resource, and performance gate passes, `auto` becomes the shared `vcs` and `serve` default. In a build without `in-process-decode`, its candidate list naturally contains only FFmpeg.

On macOS with the feature, `auto` resolves to VideoToolbox → software libav → FFmpeg. On another supported platform with the feature, it resolves to software libav → FFmpeg.

## Target Module Shape

Create one deep Capture backend module. Its external interface should let `Vcs` provide a normalized capture request and receive either a completed attempt report or a typed failure. Backend selection, attempt sequencing, bounded frame ordering, cleanup, and diagnostic aggregation belong inside the module rather than being repeated in `Vcs`, `serve`, or each adapter.

The module owns these concepts:

- `CapturePlan`: a single normalized media/profile plan containing duration, dimensions, selected video stream, codec, time base, nine capture windows, the canonical frame schedule, output dimensions, and labels. It is computed once and reused by every attempt.
- `CaptureBackendPolicy`: `auto`, `videotoolbox`, `libav`, or `ffmpeg`.
- `CaptureFailure`: `Unavailable`, `AttemptFailed`, or `Fatal`, with backend, phase, and source error attached for diagnostics.
- `CaptureReport`: selected backend, attempted backends, fallback reasons, frame counts, phase timings, and resource-relevant counters.
- An internal Capture backend seam with three production adapters and a fake adapter used by module-level tests.
- A bounded `CaptureStream` that yields capture index, animation frame index, source PTS, and RGB image while hiding decoder, demuxer, worker, and channel implementation details.

Keep the adapter interface small: identify the backend and start one stream from a `CapturePlan`. Capability detection, device management, seek, Nonref switching, scaling, fallback-frame handling, worker joining, and adapter-specific statistics remain implementation details.

The seam is real because FFmpeg, software libav, VideoToolbox, and test fakes all vary behind it. Tests should exercise fallback and cleanup through the Capture module's external interface rather than assert private channel or decoder state.

## Data Flow and Attempt Ownership

```text
shared input preflight
        │
        ▼
   CapturePlan ───────► policy candidate list
                             │
                    ┌────────▼────────┐
                    │ Capture attempt │
                    │ one backend     │
                    └────────┬────────┘
                             │ bounded ordered RGB frames
                             ▼
                    grid + labels + encoder
                             │
                             ▼
                    attempt-local temp output
                             │
             ┌───────────────┴────────────────┐
             │                                │
       complete success               backend-local failure
             │                                │
             ▼                                ▼
      publish atomically        join/terminate/delete, then next
```

Every attempt owns:

- all decoder/demuxer contexts and worker threads or child processes;
- its bounded frame channels and cancellation state;
- one encoder child process;
- one unique temporary output.

On `AttemptFailed`, cleanup order is:

1. signal cooperative cancellation and close receivers;
2. terminate child processes owned by the adapter;
3. join every adapter worker;
4. close or terminate the encoder;
5. remove the attempt-local temporary output;
6. confirm no worker or child remains;
7. start the next attempt from animation frame zero.

Encoder, output-directory, disk, publication, and user-cancellation failures are `Fatal`; they clean the current attempt but do not try another decoder.

## Backend Eligibility

### VideoToolbox Nonref

Available only when:

- `in-process-decode` is compiled;
- the target is macOS;
- the Preview profile is requested without a custom video filter;
- the selected codec is H.264 or HEVC;
- libav exposes a VideoToolbox hardware configuration;
- the shared VideoToolbox device can be created.

Create the device once per process and share references across the nine capture contexts. Cache only a deterministic device-creation failure for the process lifetime. Runtime seek, decode, transfer, or contract failure affects the current media only.

### Software libav Nonref

Available when:

- `in-process-decode` is compiled;
- the fixed Preview profile is requested without a custom video filter;
- the selected codec is H.264 or HEVC;
- required timestamps and decoder support exist.

Do not silently change to full software preroll. If the validated Nonref strategy is unavailable or fails, continue to FFmpeg under `auto`.

### FFmpeg Subprocess

Retain the current subprocess adapter for:

- default builds without in-process decoding;
- non-H.264/HEVC media;
- custom VCS configurations and filters;
- in-process backend fallback;
- explicit compatibility and diagnostic runs.

The FFmpeg adapter must implement the same CaptureStream invariants as the in-process adapters without changing existing VCS output.

## Frame Selection and Validation

Stage 0 must turn current FFmpeg CFR behavior into an executable reference before new adapters are integrated:

1. instrument the current nine FFmpeg captures to record each selected source PTS without changing RGB output;
2. derive and document the exact CFR duplicate/drop rule at capture-window boundaries;
3. represent that rule in the shared `CapturePlan`;
4. prove the reference implementation reproduces current FFmpeg PTS on the complete corpus;
5. make both in-process adapters consume the same schedule.

Production structural validation checks:

- exactly 30 animation positions × 9 capture points;
- no missing or duplicate `(frame_index, capture_index)` pair;
- source PTS are ordered and fall within the planned capture window;
- every image has the planned dimensions and RGB layout;
- every worker exits successfully before an attempt completes.

Offline contract validation checks:

- all 270 source PTS and their order are exact matches to the FFmpeg authority;
- every pre-encoder RGB grid has SSIM ≥ 0.999;
- label rendering passes a deterministic golden test;
- the final AVIF is 852×480, 20fps, 1.5 seconds, and 30 frames;
- every decoded final frame has SSIM ≥ 0.999.

The current prototype mismatch at SSIM 0.9685 and the rejected bilinear result at 0.9951 must both fail the gate.

## Concurrency and Resource Model

Preserve capacity-2 channels per capture point and the lockstep ordered consumer. Start tuning from the validated codec-thread values:

- VideoToolbox: one codec thread per capture context;
- software libav: three codec threads per capture context.

Do not hard-code nine simultaneous contexts as the production answer. Benchmark capture-point concurrency at 3, 4, 6, and 9:

- choose the lowest VideoToolbox concurrency that meets the accelerated P95 gate;
- choose the lowest software concurrency that meets the general 1.3-second contract and 512MB limit on both 1080p and 4K fixtures;
- use `-T 0` for the selected automatic value;
- use an explicit `-T` as a maximum capture-point concurrency for diagnostics and constrained machines.

No decoder, child process, channel, or frame buffer from one attempt may overlap the next attempt.

## Implementation Stages

### Stage 0 — Establish the FFmpeg authority

Tasks:

- add test-only PTS instrumentation to the current FFmpeg path;
- make the existing 11-case corpus reproducible from the production tree;
- add 8/10-bit, limited/full range, BT.601/709/2020, rotation, non-square SAR, interlaced, 4:2:2/4:4:4, corrupt, and truncated fixtures;
- capture structural output and visual goldens from the current production command;
- implement and verify the canonical frame-selection schedule.

Exit criteria:

- the schedule reproduces every FFmpeg-selected PTS;
- the current production AVIF remains unchanged;
- the visual checker rejects the known 0.9685 and 0.9951 mismatches.

Stop condition: if current CFR behavior cannot be expressed reliably without running a shadow FFmpeg pipeline, pause and revisit ADR-0003 before proceeding.

### Stage 1 — Introduce the Capture backend module

Tasks:

- move shared media/profile planning out of the FFmpeg adapter;
- introduce the policy, report, and typed failure model;
- wrap the current subprocess implementation as the first adapter;
- keep general VCS/JPG/WebP/custom-filter behavior on its existing compatibility path;
- expose one module interface to `Vcs`.

Exit criteria:

- default command output and timings remain within noise;
- existing FFmpeg failures retain actionable messages;
- tests use the module interface, not adapter internals.

### Stage 2 — Make Capture attempts restartable

Tasks:

- give every attempt a fresh encoder and unique temp path;
- centralize cancellation, process termination, worker joining, and temp cleanup;
- add internal fake adapters that fail before the first frame, after the first grid, and on the last frame;
- aggregate attempted backend names and reasons in the final error.

Exit criteria:

- no partial file can be published;
- the next adapter always starts at frame zero;
- thread/process/resource counters return to baseline before fallback;
- `Fatal` failures never start another adapter.

### Stage 3 — Productize software libav Nonref

Tasks:

- add optional `ffmpeg-next`/libav dependencies under `in-process-decode`;
- move shared demux, frame scheduling, scaling, bounded streaming, and 0.5-second Nonref logic out of the prototype;
- isolate unsafe FFI and decoder lifetime management inside the adapter;
- support only the accepted Preview profile and H.264/HEVC whitelist;
- implement explicit `libav` fail-fast policy;
- add Linux and macOS feature builds.

Exit criteria:

- exact PTS and SSIM contracts pass on the expanded corpus;
- unsupported codecs and profiles report `Unavailable`;
- the backend remains within the 512MB active-job budget;
- the default feature-off build remains unchanged.

### Stage 4 — Productize VideoToolbox Nonref

Tasks:

- add a macOS-only adapter over the shared libav frame-selection machinery;
- create and cache the process-level hardware device;
- negotiate the VideoToolbox pixel format and transfer only selected frames;
- preserve one codec thread per capture context and fixed 0.5-second Nonref recovery;
- implement explicit `videotoolbox` fail-fast policy.

Exit criteria:

- all selected frames are hardware frames before transfer and software fallback count is zero;
- exact PTS and SSIM contracts pass on supported expanded fixtures;
- unsupported hardware formats reliably report `Unavailable`;
- runtime failures remain media-scoped rather than permanently disabling the backend.

### Stage 5 — Enable automatic fallback

Tasks:

- add `--capture-backend` to `vcs` and `serve`;
- assemble platform/feature-specific candidate lists;
- implement whole-attempt fallback and final diagnostic aggregation;
- keep backend metadata out of cache identity and the request protocol;
- emit one concise fallback diagnostic normally and detailed per-attempt timings under `--profile`.

Exit criteria:

- VideoToolbox → libav, VideoToolbox → libav → FFmpeg, and direct skip-to-FFmpeg paths are covered;
- forced policies never fall back;
- encoder, publication, cancellation, and disk failures are terminal;
- service coalescing produces one published result regardless of attempts.

### Stage 6 — Tune concurrency and measure

Tasks:

- run 3/4/6/9 capture-point sweeps for both in-process adapters;
- run at least 30 rotated/interleaved warm measurements against software Nonref and FFmpeg;
- record cold start separately;
- record wall time, first grid, user/system CPU, RSS, decoded/preroll/downloaded frames, and fallback cleanup time;
- run 1080p and 4K resource tests;
- measure injected early and late fallback latency without treating it as a sub-second SLA.

Exit criteria for VideoToolbox:

- warm P95 < 1.0 second on the representative input;
- wall time improves at least 15% over software Nonref;
- user CPU improves at least 70% over software Nonref;
- peak RSS remains ≤ 512MB;
- all visual and fallback correctness gates remain green.

The general ADR-0001 contract remains warm P95 ≤ 1.3 seconds and RSS ≤ 512MB. Failure paths and cold starts are reported but are not required to stay below one second.

### Stage 7 — CI, rollout, and default promotion

Tasks:

- keep the existing default Ubuntu and Windows jobs feature-off;
- add a Linux feature-on job for software libav contract tests;
- add a macOS feature-on build and capability test;
- run the full VideoToolbox corpus on real Apple Silicon as a release gate, and add Intel Mac coverage when a runner is available;
- document libav development/runtime requirements and forced backend diagnostics;
- ship `auto` as opt-in for one validation period;
- promote `auto` to the shared default only after all gates pass.

Rollback:

- users can force `--capture-backend ffmpeg`;
- disabling `in-process-decode` removes both in-process adapters;
- default promotion is a separate, reversible change from adapter implementation.

## Failure Test Matrix

| Scenario | Expected result |
|---|---|
| Feature absent or non-macOS VideoToolbox | `Unavailable`; choose next candidate |
| Unsupported codec/profile/filter | `Unavailable`; choose next candidate |
| VideoToolbox device creation deterministically fails | Cache process-level unavailability; choose next candidate |
| Seek/decode/transfer fails before first frame | Clean attempt; restart next backend at frame zero |
| Backend fails after one or 29 grids | Terminate encoder, delete temp, join workers, restart from frame zero |
| Frame index, PTS, dimensions, or count invalid | `AttemptFailed`; clean and fall back |
| Software libav also fails | Clean and run FFmpeg |
| Forced backend fails | Return failure without fallback |
| Encoder write or exit fails | `Fatal`; no fallback |
| Output directory, disk, or atomic publication fails | `Fatal`; no fallback |
| User cancellation | Clean current attempt and terminate job |
| Every eligible backend fails | Return one error containing every attempted backend and reason |

## Observability

Normal fallback emits one concise diagnostic containing:

- Capture job/cache identity suitable for local diagnosis;
- attempted and selected backend;
- failure class and phase;
- elapsed time lost before fallback.

`--profile` additionally reports per attempt:

- availability/setup time;
- first frame and first complete grid;
- decoded and preroll frames;
- hardware transfers and software fallback frames;
- receive wait, grid composition, encoder write/tail, cleanup, and total;
- selected concurrency and codec-thread count.

No new lifecycle state is added to the TCP request protocol, and Ya/DDS work remains deferred.

## Known Risks and Explicit Non-goals

- Aligning the prototypes to current FFmpeg CFR selection may reduce the measured 0.743-second result; the default gate must use the aligned implementation.
- Dynamic libav linkage changes build requirements for feature-on builds; vendoring or distributing FFmpeg libraries is not part of this plan.
- Hosted macOS CI may not expose representative VideoToolbox hardware; real-hardware release evidence remains necessary.
- A blocked FFI call cannot be safely killed in-process. Hard timeout fallback requires a future process-isolation design.
- First-stage acceleration excludes non-H.264/HEVC media, arbitrary VCS profiles, custom filters, and user-adjustable Nonref margins.
- This plan does not change the AVIF encoder, cache key, client protocol, Ya/DDS integration, or service capacity.
