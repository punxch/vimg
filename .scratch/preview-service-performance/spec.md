# Preview Service Performance and Cache Correctness

## Problem Statement

Vimg produces the required animated contact sheet quickly for one warmed video, but its current local preview service has no effective Service capacity control. Every connection can execute a Capture job immediately, duplicate requests repeat the same work, and a static preview waits synchronously for the animation. The VCS path also materializes all extracted and joined frames before encoding, inflating peak memory.

The current cache only checks that an AVIF file exists and is non-empty. It does not verify the source video identity and, when the temporary and cache directories are on different filesystems, can expose a partially copied AVIF. These behaviours can produce stale previews, wasted work, poor responsiveness during rapid browsing, and unbounded CPU or memory use.

## Solution

Provide a bounded local preview service that manages Capture jobs, publishes only validated preview caches, and supports Progressive preview. The existing Preview profile remains unchanged: a 3×3 grid, 160-pixel capture height, 30 frames, CRF 30, and the current AVIF encoder.

The service will execute one Capture job at a time and retain at most nine queued jobs. It will coalesce requests for the same cache, prioritize the newest preview request, remove Orphaned queued jobs, and reject new work at the Admission limit with `busy`. The client will immediately show its static preview and request the animated preview in the background.

Requests may carry a Media descriptor so the service can avoid redundant probing and validate the cache. An AVIF and its source-identity manifest will be published atomically as a Published preview cache. VCS will produce ordered grid frames through bounded buffering into the encoder rather than retain the complete animation in memory.

## User Stories

1. As a file-browser user, I want a static preview to appear immediately, so that moving through videos never waits for animated contact-sheet generation.
2. As a file-browser user, I want the preview to upgrade to the animated contact sheet when it is ready, so that I receive richer context without losing responsiveness.
3. As a file-browser user, I want a rapid move to a newer video to prioritize that video, so that the service does not spend time on previews I have already left.
4. As a file-browser user, I want repeated requests for the same video and cache to share one Capture job, so that duplicate work does not delay my preview.
5. As a file-browser user, I want a clear `busy` result when the service is full, so that the static preview remains usable instead of the browser appearing stalled.
6. As a file-browser user, I want unneeded queued previews to disappear when no requester remains, so that relevant work advances promptly.
7. As a file-browser user, I want an active Capture job to complete after my individual request ends, so that a nearly completed preview can still be reused from cache.
8. As a file-browser user, I want an existing animated cache to be reused only when it matches the current source video, so that I never see a preview from an earlier version of the file.
9. As a file-browser user, I want the client to ignore incomplete cache output, so that it never attempts to render a partial AVIF.
10. As a file-browser user, I want source-video changes at the same path to trigger a fresh animated preview, so that cache reuse remains correct.
11. As a preview-client maintainer, I want to send a Media descriptor when known while remaining compatible with older clients, so that redundant media probing can be avoided safely.
12. As a preview-client maintainer, I want the client-service exchange to report queued, shared, completed, busy, and failed outcomes, so that it can present the correct fallback behaviour.
13. As a local-service user, I want one executing Capture job and no more than nine queued Capture jobs, so that resource use remains predictable.
14. As a local-service user, I want the Latest-preview queue to replace the oldest unstarted job, so that interactive browsing is preferred over FIFO completion.
15. As a user on a CPU-only machine, I want the same Preview profile to remain available, so that NVIDIA hardware is never required.
16. As a user on a Windows machine with an NVIDIA GPU, I want CUDA to be used opportunistically with safe CPU fallback, so that supported hardware can reduce work without changing output semantics.
17. As a user, I want the existing 3×3, 160-pixel, 30-frame AVIF output preserved, so that performance work does not silently reduce preview fidelity.
18. As an operator, I want the service to keep an active Capture job within the agreed memory budget, so that it remains stable when the queue is occupied.
19. As an operator, I want observable progress and result states for Capture jobs, so that `busy`, failures, and successful cache publication can be diagnosed.
20. As a maintainer, I want grid production and encoding to overlap with bounded buffering, so that throughput improves without retaining an entire animation in memory.
21. As a maintainer, I want timestamp labels rendered without cloning each tile, so that label rendering does not dominate memory allocation or CPU copying.
22. As a maintainer, I want capture-process parallelism to be bounded and configurable, so that the service avoids overcommitting CPU through nested ffmpeg threading.
23. As a maintainer, I want performance measurements for cold cache, warm cache, and saturated service operation, so that regressions are visible on representative media.
24. As a maintainer, I want visual and structural regression tests for the Published preview cache, so that refactoring preserves externally visible output behaviour.

## Implementation Decisions

- The Preview profile is fixed by ADR-0001: 3×3, 160-pixel capture height, 30 frames, CRF 30, and the current AVIF encoder. Performance work must preserve it.
- The local service owns Capture job admission, execution, coalescing, lifecycle, and requester notification.
- Service capacity is exactly one executing Capture job plus at most nine queued Capture jobs.
- The Admission limit returns `busy` for a new non-coalesced request when capacity is full.
- A Coalesced capture job is keyed by its output cache identity and has one shared result for all requesters.
- The Latest-preview queue retains the executing job and replaces the oldest unstarted job when a newer request is admitted.
- An Orphaned queued job is removed when its last requester disconnects. An executing job is allowed to finish and populate its cache.
- The preview client must use Progressive preview: show the existing static preview immediately, request animation asynchronously, then refresh on successful Published preview cache availability.
- The request protocol gains optional Media descriptor fields for duration, dimensions, and source identity. The service must accept legacy requests without those fields and probe media itself.
- A Validated preview cache requires a source identity that matches the requested Media descriptor. A Published preview cache requires both its AVIF and identity manifest to be atomically published in the cache directory.
- The client must require a matching manifest before rendering an animated cache. Cache publication must avoid exposing an incomplete AVIF, including when staging and cache locations use different filesystems.
- VCS must use a bounded, ordered producer-to-encoder pipeline as required by ADR-0002. It may retain only a small bounded number of grid frames awaiting encoding and must propagate extraction, composition, encoder, and publication errors to every requester.
- The current FFmpeg CFR output is the authority for the Frame selection contract. Every Capture backend must preserve exact source PTS, frame/capture order, dimensions, and labels; pixel differences must remain within the accepted visual-golden tolerance.
- Backend fallback is atomic at the Capture attempt level. A failed attempt is fully cleaned and restarted from frame zero with the next backend; frames from different backends are never mixed.
- Capture backend failures are classified as `Unavailable`, `AttemptFailed`, or `Fatal`. Only the first two allow automatic fallback; shared input, encoder, publication, disk, and cancellation failures terminate the Capture job.
- The automatic macOS preference order is VideoToolbox Nonref, software libav Nonref, then the existing FFmpeg subprocess. A named-backend policy is fail-fast and never silently falls back.
- In-process decoding is an optional build capability. Software libav is cross-platform when enabled; VideoToolbox is macOS-only. Default builds continue to require only the FFmpeg executable.
- Initial in-process eligibility is limited to the fixed Preview profile, H.264/HEVC, bicubic scaling, and no custom video filter. The Nonref recovery margin is a fixed internal 0.5 seconds.
- Backend choice is diagnostic information, not part of cache identity or the client protocol.
- Capture-point concurrency is bounded and configurable. `-T 0` selects a per-backend automatic value after 3/4/6/9-way measurement; an explicit `-T` caps capture-point concurrency. Decoder-internal thread counts are controlled and benchmarked separately.
- The CPU path is mandatory. CUDA is optional on supported Windows/NVIDIA systems and must fall back safely to CPU with output-equivalent results.
- Timestamp labels are drawn into the destination grid region and reuse parsed font state rather than cloning and converting whole capture tiles.
- The service continues to report progress in a form suitable for local diagnostics.

## Testing Decisions

- The primary seam is the externally visible local-service request: submit a Capture job and assert the response state plus the resulting Published preview cache. Tests must not assert private queue, thread, channel, or buffer implementation details.
- Service integration tests cover completion, duplicate-request coalescing, Admission limit `busy`, Latest-preview queue replacement, orphaned queued-job removal, and executing-job completion after requester departure.
- Compatibility tests submit both legacy requests and requests containing a Media descriptor.
- Cache tests verify that a matching manifest permits rendering, a changed source identity invalidates the cache, and no partial or unmatched AVIF is considered published.
- VCS integration tests verify ordered animated output, the fixed Preview profile, successful failure propagation, and stable timestamp-label appearance through structural and visual golden comparisons.
- Capture backend contract tests require exact source PTS/order and per-frame SSIM of at least 0.999 before and after AVIF encoding. Production performs structural checks only and never shadow-runs FFmpeg.
- Fallback tests inject unavailable, early, mid-stream, and late backend failures and verify complete worker/encoder/temp cleanup before the next attempt starts at frame zero. Encoder, publication, disk, and cancellation failures must remain terminal.
- The media corpus covers H.264/HEVC GOP/B-frame/VFR/short/tail cases plus 8/10-bit, color range and matrix, rotation, SAR, interlacing, unsupported chroma formats, corruption, and truncation.
- CPU-only and CUDA-capable configurations are tested for the same externally visible output semantics; CUDA failures must exercise CPU fallback.
- Performance benchmarks record cold-cache and warm-cache interactive latency, active-job peak RSS, and the one-executing-plus-nine-queued service scenario. A benchmark report, rather than a single timing-sensitive unit test, is the regression signal.
- Promoting `auto` to the default requires at least 30 interleaved warm runs with VideoToolbox P95 below 1.0 second, at least 15% wall-time improvement and 70% user-CPU improvement over software Nonref, and peak RSS no greater than 512MB. ADR-0001's general 1.3-second P95 contract remains unchanged.
- The representative `input.mkv` command is the initial benchmark fixture. Existing test coverage is effectively absent, so this feature establishes the first relevant integration and golden-test prior art.

## Out of Scope

- Changing the Preview profile, reducing frame count, lowering resolution, changing CRF, or switching the current AVIF encoder solely to improve timing.
- More than one simultaneously executing Capture job.
- Cancelling an already executing ffmpeg pipeline when requesters disconnect.
- Replacing per-sampling-point extraction with a single monolithic ffmpeg seek pipeline.
- Accelerating arbitrary VCS profiles, custom video filters, or codecs other than H.264/HEVC in the first in-process release.
- Making libav development libraries a dependency of the default feature-off build.
- Mixing frames from multiple Capture backends in one animation, adding backend identity to the cache key, or exposing backend fallback through the client protocol.
- Treating a timeout as a safe in-process fallback while an FFI decoder thread may still be blocked.
- Requiring NVIDIA hardware, removing CPU fallback, or adding GPU-specific output semantics.
- Remote, distributed, or multi-host preview services.
- A general cache-eviction policy unrelated to validating and publishing the current source video.
- Migrating the existing local TCP request transport to `ya` / DDS, including DDS lifecycle
  responses and requester-disconnect orphan handling. This is tracked as deferred in
  `issues/01-implement-preview-service-performance.md` and must not block the current
  runtime-efficiency work.

## Further Notes

- On the representative warmed input, measured wall time was approximately 1.21 seconds with four extraction workers and approximately 1.27 seconds with the previous eight-worker default. The initial cold run was much slower because of source-file cache warm-up.
- Current service and client behaviour is synchronous and lacks job admission or in-flight deduplication; the specification deliberately changes those externally visible lifecycle semantics.
- ADR-0001 defines the performance and fidelity contract. ADR-0002 defines bounded streaming as the dataflow strategy.
