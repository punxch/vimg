Status: ready-for-agent

# Capture Backend Fallback

## Problem Statement

Vimg's current production VCS path starts one FFmpeg subprocess per sampling point. On the representative Preview profile it averages about 1.2 seconds and consumes roughly nine seconds of user CPU time. A validated in-process software libav prototype with Nonref preroll enters one second, while a VideoToolbox Nonref prototype reduces the same workload to about 0.74 seconds and roughly one second of user CPU.

The prototypes cannot yet replace production safely. Their explicit source-frame selection does not match the current FFmpeg CFR behavior, hardware support is platform and codec dependent, in-process libav changes build requirements, and a late backend failure may occur after frames have already entered the AVIF encoder. Without a deliberate Capture backend model, fallback could mix frames from different decoders, leak workers or temporary output, publish an incomplete cache, silently change user-visible frame selection, or make diagnostics claim that one backend ran when another was actually used.

Vimg needs a bounded, observable Capture backend fallback mechanism that preserves the current Preview profile and Frame selection contract while using VideoToolbox and software libav where they are proven safe.

## Solution

Introduce one deep Capture backend module that owns backend eligibility, preference ordering, whole-attempt fallback, ordered bounded frame streaming, cleanup, and diagnostic reporting.

The automatic preference order is VideoToolbox with a fixed 0.5-second Nonref preroll, software libav with the same Nonref strategy, then the existing FFmpeg subprocess. VideoToolbox is available only on macOS; software libav is cross-platform when the optional in-process decoding build capability is enabled. The first accelerated scope is the fixed Preview profile on H.264 and HEVC media without a custom video filter.

Every Capture attempt uses exactly one Capture backend. If that backend is unavailable or its attempt fails, Vimg completely stops and joins its workers, terminates the attempt encoder, removes unpublished temporary output, and restarts from animation frame zero with the next backend. Shared input, encoding, publication, disk, and cancellation failures terminate the Capture job instead of trying another decoder.

The current production FFmpeg CFR behavior remains authoritative. All backends must produce the same source presentation timestamps, ordering, dimensions, and labels. Visual differences caused by legitimate decoder rounding must remain within a per-frame SSIM threshold of 0.999. Production performs low-cost structural validation; exact timestamp and visual equivalence are enforced through corpus and CI testing rather than shadow-running FFmpeg.

The new backends initially remain opt-in. After correctness, resource, cross-media, and performance gates pass, the automatic policy becomes the shared default for direct VCS commands and the local preview service. Feature-off builds continue to use only the FFmpeg executable and retain the existing installation contract.

## User Stories

1. As a macOS preview user, I want VideoToolbox used for supported previews, so that animated contact sheets appear substantially faster.
2. As a laptop user, I want hardware decoding to reduce user CPU time, so that preview generation uses less power and interferes less with foreground work.
3. As a preview user, I want software libav used when VideoToolbox cannot complete the job, so that a hardware-specific failure does not lose my preview.
4. As a preview user, I want the existing FFmpeg path retained as the final fallback, so that unsupported or unusual media still produces a preview.
5. As a preview user, I want every backend to select the same source moments, so that hardware availability does not change what the contact sheet shows.
6. As a preview user, I want the existing 3×3, 160-pixel, 30-frame AVIF profile preserved, so that performance work does not reduce preview fidelity.
7. As a preview user, I want timestamp labels to remain stable across backends, so that the contact sheet continues to communicate source positions accurately.
8. As a preview user, I want a failed backend attempt discarded completely, so that one animation never combines frames from different decoding strategies.
9. As a preview user, I want only a complete successful animation published, so that I never render a partial fallback result.
10. As a preview user, I want a late hardware failure to restart safely with software, so that correctness does not depend on when the failure occurs.
11. As a CPU-only user, I want the FFmpeg compatibility path to remain available, so that accelerated decoding is never required.
12. As a Linux user who enables in-process decoding, I want software libav Nonref available without macOS code, so that I can use the cross-platform acceleration independently.
13. As a Windows user of the prebuilt binary, I want the existing feature-off build to remain unchanged, so that new libav development libraries are not required.
14. As a user installing with Cargo, I want default builds to retain the FFmpeg executable-only requirement, so that installation does not unexpectedly fail on missing headers or shared libraries.
15. As a user with unsupported media, I want `auto` to skip ineligible backends cleanly, so that unsupported codecs are handled by FFmpeg without noisy failed attempts.
16. As a user with a custom VCS profile or video filter, I want the compatibility backend selected automatically, so that initial acceleration scope does not alter existing flexible commands.
17. As a user forcing VideoToolbox, I want failure reported instead of silently falling back, so that benchmarks and diagnostics are truthful.
18. As a user forcing software libav, I want failure reported instead of silently running FFmpeg, so that I can reproduce backend-specific behavior.
19. As a user forcing FFmpeg, I want the current production path used directly, so that I have an immediate compatibility and rollback control.
20. As a service operator, I want one Capture backend policy fixed at service startup, so that all Capture jobs in the process have predictable behavior.
21. As a service operator, I want fallback to remain transparent to preview clients, so that the existing request protocol does not need a decoder-specific state model.
22. As a service operator, I want backend choice excluded from cache identity, so that equivalent results do not create duplicate caches.
23. As a service operator, I want fallback attempts to keep active-job RSS below 512MB, so that the service retains its resource-stability contract.
24. As a service operator, I want the previous attempt fully cleaned before the next starts, so that decoder contexts from multiple backends never overlap.
25. As a service operator, I want deterministic process-level hardware unavailability cached, so that every Capture job does not repeat a known-impossible device initialization.
26. As a service operator, I want media-specific runtime failures isolated to the current job, so that one problematic video does not permanently disable hardware acceleration.
27. As an operator, I want fallback diagnostics to name the backend, phase, failure class, and lost time, so that degraded performance can be explained.
28. As an operator, I want detailed per-attempt profiling on demand, so that decode, transfer, composition, encoding, and cleanup regressions can be localized.
29. As a maintainer, I want one Capture backend module interface, so that fallback behavior is implemented and tested in one place.
30. As a maintainer, I want FFmpeg, software libav, VideoToolbox, and fault-injection fakes behind one internal seam, so that adapters can vary without spreading policy logic through callers.
31. As a maintainer, I want media properties and the canonical frame schedule computed once per Capture job, so that fallback does not repeat shared planning and probe work.
32. As a maintainer, I want backend failures classified as unavailable, attempt failed, or fatal, so that only errors helped by another decoder trigger fallback.
33. As a maintainer, I want encoder and publication failures to remain fatal, so that switching decoders does not repeat work that cannot solve the actual problem.
34. As a maintainer, I want cooperative cancellation at packet and frame boundaries, so that explicit failures clean up promptly without pretending blocked FFI threads can be killed safely.
35. As a maintainer, I want the Nonref recovery margin fixed at the validated 0.5 seconds, so that users cannot trade correctness for a hidden timing tweak.
36. As a maintainer, I want in-process backends limited initially to H.264 and HEVC, so that Nonref assumptions are not extrapolated to unvalidated reference-frame models.
37. As a maintainer, I want source PTS and frame order compared exactly in offline tests, so that visual similarity cannot conceal a different frame schedule.
38. As a maintainer, I want every grid and decoded AVIF frame checked against a 0.999 SSIM threshold, so that backend-specific color differences remain imperceptible.
39. As a maintainer, I want a deterministic label-rendering golden test, so that whole-frame SSIM cannot hide a local timestamp-label regression.
40. As a maintainer, I want hardware boundary fixtures for bit depth, color metadata, chroma, rotation, SAR, and interlacing, so that VideoToolbox eligibility and output are proven deliberately.
41. As a maintainer, I want corrupt and truncated fixtures, so that cleanup and failure classification are verified against damaged input.
42. As a maintainer, I want unsupported 4:2:2 and 4:4:4 hardware cases to reach the next backend, so that capability detection is tested as behavior rather than assumed.
43. As a performance maintainer, I want capture-point concurrency measured at 3, 4, 6, and 9, so that production uses the lowest concurrency that meets latency and memory targets.
44. As a user on a constrained machine, I want an explicit concurrency cap, so that I can trade latency for lower resource use without changing output semantics.
45. As a performance maintainer, I want at least 30 rotated, interleaved warm runs before default promotion, so that dynamic loading and run-order noise do not create a false win.
46. As a performance maintainer, I want cold starts and injected fallback paths reported separately, so that the sub-second gate remains interpretable.
47. As a release maintainer, I want feature-off Linux and Windows builds preserved in CI, so that optional acceleration cannot break the default product.
48. As a release maintainer, I want feature-on software libav tests on Linux, so that the cross-platform adapter does not become macOS-only accidentally.
49. As a release maintainer, I want feature-on macOS builds and real Apple Silicon corpus evidence, so that VideoToolbox is validated on actual hardware before becoming default.
50. As a release maintainer, I want automatic selection shipped as opt-in before promotion, so that fallback behavior can be observed without immediately changing every invocation.
51. As a release maintainer, I want default promotion isolated from backend implementation, so that rollback to FFmpeg is a small reversible change.
52. As a maintainer, I want the implementation to stop if current FFmpeg CFR behavior cannot be reproduced without shadow decoding, so that ADR-defined compatibility is not silently weakened.

## Implementation Decisions

- ADR-0001 remains the general performance and resource contract: the fixed Preview profile, warm P95 no greater than 1.3 seconds on the representative input, and active-job peak RSS no greater than 512MB.
- ADR-0002 remains the dataflow contract: grid frames are produced in order through bounded buffering and overlap with encoding rather than retaining the full animation.
- ADR-0003 makes current production FFmpeg CFR behavior authoritative for the Frame selection contract. New backends adapt to that behavior rather than adopting the prototype's different explicit-PTS selection.
- ADR-0004 requires whole-Capture-attempt fallback. Frames from different backends are never mixed, and the selected backend does not become part of cache identity.
- One deep Capture backend module owns normalized media/profile planning, backend policy, candidate selection, attempt lifecycle, ordered frame validation, cleanup, fallback, and diagnostics.
- The module presents one external interface to VCS orchestration. FFmpeg, software libav, VideoToolbox, and test fakes are internal adapters at one real seam.
- A Capture plan is computed once per Capture job and reused across attempts. It contains the selected video stream, duration, dimensions, codec, time base, nine capture windows, canonical frame schedule, output dimensions, and labels.
- A Capture stream emits capture index, animation frame index, source PTS, and RGB image through bounded ordering while hiding decoder contexts, child processes, worker threads, and channels.
- Capture backend policy has four values: `auto`, `videotoolbox`, `libav`, and `ffmpeg`.
- Only `auto` permits fallback. A named backend performs exactly one fail-fast Capture attempt.
- During development, `ffmpeg` remains the default policy. `auto` becomes the shared VCS and service default only after every promotion gate passes.
- The local service fixes its Capture backend policy at process startup. Backend selection does not change the existing TCP request protocol or lifecycle results.
- On macOS with in-process decoding enabled, `auto` tries VideoToolbox Nonref, software libav Nonref, then FFmpeg.
- On another supported platform with in-process decoding enabled, `auto` tries software libav Nonref, then FFmpeg.
- Without in-process decoding, `auto` contains only the FFmpeg adapter.
- In-process decoding is an optional build capability and must not add libav development or runtime linkage requirements to default feature-off builds.
- Software libav is cross-platform when the optional capability is enabled. VideoToolbox code and dependencies are macOS-only.
- Initial in-process eligibility is restricted to the fixed Preview profile, H.264 or HEVC, bicubic scaling, and no custom video filter.
- Media outside that eligibility reports the in-process adapter as unavailable under `auto`; forced in-process policies return a clear unsupported error.
- Both in-process adapters use a fixed internal 0.5-second full-decode recovery margin after Nonref preroll. It is test-injectable but not a public performance option.
- VideoToolbox creates one device per process and shares references across the capture contexts. A deterministic device-creation failure is cached for that process.
- Codec and media capability failures are scoped to the current media. A runtime seek, decode, transfer, timestamp, or ordering failure does not permanently disable the backend.
- `Unavailable` means an adapter cannot start for the current build, platform, media, or profile and allows `auto` to continue without a Capture attempt.
- `AttemptFailed` means an adapter started but failed during backend-owned setup, seek, decode, hardware transfer, frame validation, or completion and allows `auto` to restart with the next candidate.
- `Fatal` means the shared input preflight, encoder, disk, publication, or cancellation failed and terminates the Capture job.
- Every Capture attempt owns all adapter workers or child processes, bounded channels, cancellation state, encoder process, and one unique unpublished temporary output.
- Before fallback, Vimg signals cooperative cancellation, terminates owned child processes, joins every worker, closes the encoder, removes temporary output, and confirms the previous attempt no longer owns resources.
- The next adapter always starts at animation frame zero and receives the same Capture plan.
- Production structural validation requires exactly 270 indexed images, no missing or duplicate index pairs, ordered in-window PTS, correct dimensions and RGB layout, and successful completion of all workers.
- Production does not shadow-run FFmpeg or decode every output for visual comparison.
- The selected backend, attempted backends, failure classes, phases, and timings are diagnostic results only. They do not alter the cache key, cache manifest contract, or client protocol.
- Normal fallback emits one concise diagnostic. Profiling emits detailed availability, setup, first-frame/grid, decode/preroll, hardware-transfer, wait, composition, encoder, cleanup, and total timings.
- Capacity-two channels per capture point and lockstep grid production remain the starting buffering model.
- VideoToolbox starts from one codec thread per capture context; software libav starts from three.
- Capture-point concurrency is benchmarked at 3, 4, 6, and 9. Automatic concurrency selects the lowest value satisfying the backend's latency and resource gate.
- `-T 0` requests the selected automatic capture-point concurrency. An explicit `-T` caps capture-point concurrency for diagnostics and constrained machines.
- An explicit backend failure can trigger cooperative cancellation only at safe packet/frame boundaries. The first implementation does not turn timeouts into fallback while an in-process FFI thread may remain blocked.
- The current AVIF encoder and its settings remain unchanged.
- Default promotion is a separate, reversible rollout decision. Users can always force FFmpeg, and feature-off builds remove both in-process adapters.

## Testing Decisions

- The highest user-visible seam is the direct VCS invocation: select a Capture backend policy, run the fixed Preview profile, and assert the final animation structure, diagnostics, and failure result.
- The primary deterministic fallback seam is the Capture backend module's external interface. Internal fake adapters inject unavailability and early, middle, late, and fatal failures without exposing private channels or decoder state.
- The local-service seam receives a smaller set of integration tests proving startup policy propagation, coalesced Capture job behavior, one Published preview cache, and unchanged client protocol semantics.
- Tests assert observable frames, selected timestamps, final output, published cache state, reported failure class, and absence of leaked attempt output. They do not assert private worker counts, channel operations, decoder context layout, or adapter call sequences except where resource cleanup is itself observable.
- The current FFmpeg path first gains test-only source-PTS instrumentation and becomes the authority fixture.
- A shared frame-schedule implementation must reproduce every FFmpeg-selected source PTS before either in-process adapter is accepted.
- Offline backend contract tests require exact equality of all 270 source PTS, capture/animation ordering, dimensions, and label text.
- Every pre-encoder RGB grid must have per-frame SSIM of at least 0.999 against the FFmpeg authority.
- Timestamp labels have a separate deterministic golden test so a local regression cannot hide inside a whole-grid similarity score.
- Final AVIF tests require 852×480 dimensions, 20fps, 1.5-second duration, 30 frames, and per-frame decoded SSIM of at least 0.999.
- The visual checker must reject the known formal-versus-prototype mismatch at SSIM 0.9685 and the rejected bilinear result at 0.9951.
- The existing 11-case H.264/HEVC corpus remains prior art for long/short GOP, B-frame, VFR, short-duration, and single-keyframe-tail behavior.
- The corpus expands to H.264/HEVC 8-bit and 10-bit, limited and full range, BT.601/709/2020, rotation metadata, non-square SAR, interlacing, unsupported 4:2:2/4:4:4, corruption, and truncation.
- Supported fixtures must satisfy the Frame selection contract and visual threshold. Unsupported hardware fixtures must deterministically select the next adapter.
- Fault tests cover adapter unavailability, failure before the first frame, failure after the first complete grid, failure on the last animation frame, invalid index, duplicate frame, missing frame, invalid PTS, wrong dimensions, and worker completion failure.
- Every fallback fault test verifies that the encoder and attempt-local temporary output are discarded and the next backend starts from frame zero.
- Fatal tests cover encoder input/write/exit failure, output-directory failure, disk failure, atomic publication failure, and cancellation; none may start another decoder.
- Forced policy tests verify that named backends never fall back.
- Full-chain tests cover VideoToolbox to software libav, VideoToolbox through software libav to FFmpeg, direct capability skip to FFmpeg, and all-backends-failed diagnostic aggregation.
- Process-level availability tests verify that deterministic VideoToolbox device failure is cached while media-specific failures do not poison later media.
- Cache tests verify that backend choice does not create a second identity and that only one complete successful attempt becomes a Published preview cache.
- Resource tests verify that decoder, worker, process, channel, and temporary-output ownership returns to baseline before another attempt starts.
- Concurrency tests compare 3, 4, 6, and 9 capture contexts on representative 1080p and 4K fixtures.
- Promotion performance tests use at least 30 rotated, interleaved warm runs. VideoToolbox must achieve P95 below 1.0 second, at least 15% wall-time improvement and 70% user-CPU improvement over aligned software Nonref, and peak RSS no greater than 512MB.
- Cold starts and injected fallback paths are measured and reported separately rather than included in the sub-second gate.
- Default feature-off tests continue on Linux and Windows. Feature-on software libav contract tests run on Linux and macOS. VideoToolbox builds on macOS and the complete corpus runs on real Apple Silicon before release.
- Existing bounded-streaming, cache-publication, service-capacity, prototype corpus, and performance scripts are the relevant prior art. The new Capture module interface becomes the stable test surface for fallback behavior.

## Out of Scope

- Changing the Preview profile, capture count, grid dimensions, capture height, frame count, duration, output framerate, CRF, or AVIF encoder to meet the performance target.
- Accelerating arbitrary VCS profiles, JPG/WebP output, custom video filters, or non-H.264/HEVC codecs in the first release.
- Adopting the prototype's explicit-PTS frame selection instead of preserving current FFmpeg CFR behavior.
- Replacing the per-sampling-point model with one monolithic FFmpeg seek pipeline.
- Full software preroll as a hidden fourth automatic backend.
- Making the 0.5-second Nonref margin user configurable.
- Requiring in-process libav libraries in default feature-off builds.
- Vendoring, statically distributing, or otherwise solving general FFmpeg/libav packaging.
- Enabling in-process decoding in the existing Windows prebuilt release.
- Adding backend name to cache identity or requiring clients to understand fallback attempts.
- Changing the local TCP request protocol or implementing the deferred Ya/DDS migration.
- Increasing local-service capacity beyond one executing Capture job.
- Shadow-running FFmpeg in production to validate accelerated output.
- Treating a timeout as safe fallback while an in-process FFI thread may still own resources.
- Guaranteeing sub-second cold starts or sub-second injected failure paths.
- Permanently disabling a backend after one media-specific runtime failure.
- Promoting `auto` to default before all correctness, hardware-corpus, resource, and performance gates pass.

## Further Notes

- The exact like-for-like prototype comparison is software libav Nonref at 0.932 seconds versus VideoToolbox Nonref at 0.743 seconds, a 20.2% wall-time improvement. User CPU falls from 5.798 seconds to 1.073 seconds.
- The current FFmpeg subprocess averages 1.207 seconds in a separate paired run, but that comparison is not semantically exact because current CFR output and prototype explicit-PTS output differ at SSIM 0.9685.
- VideoToolbox full preroll alone averages 1.158 seconds and is slower than software Nonref. The acceleration depends on combining hardware decoding with Nonref preroll.
- The VideoToolbox Nonref prototype is preserved in the `prototype-videotoolbox-nonref` Jujutsu bookmark at commit `210fcda9`.
- The software Nonref strategy has passed the existing 11-case corpus. The hardware combination has exact validation on the representative input but must pass the expanded corpus before default promotion.
- The general ADR-0001 contract remains warm P95 no greater than 1.3 seconds and peak RSS no greater than 512MB. The sub-second requirement is a stronger default-promotion gate for the accelerated path, not a universal hardware-independent SLA.
- If Stage 0 cannot express current FFmpeg CFR selection as a shared deterministic schedule without shadow decoding, implementation must stop and revisit the accepted frame-selection decision rather than weaken compatibility implicitly.
