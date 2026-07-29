# Vimg

Vimg generates visual contact sheets from video and can run as a local service for preview clients.

## Language

**Capture job**:
A request to generate one visual contact sheet from one video for a preview client.
_Avoid_: task, conversion

**Coalesced capture job**:
A capture job shared by requests for the same output cache, producing one result for all requesters.
_Avoid_: duplicate request, retry

**Orphaned queued job**:
An unstarted capture job with no remaining waiting requester; it is removed from the queue.
_Avoid_: abandoned task, cancelled conversion

**Media descriptor**:
Optional source-video duration, dimensions, and modification identity carried with a capture request.
_Avoid_: ffprobe output, video metadata blob

**Service capacity**:
The configured limit of one executing capture job and up to nine queued capture jobs while the local service remains stable.
_Avoid_: thread count, ffmpeg count

**Admission limit**:
The service-capacity boundary after which a new capture job receives `busy` instead of being queued.
_Avoid_: backpressure, overload

**Latest-preview queue**:
An admission order that keeps the executing capture job and replaces the oldest unstarted job with a newer preview request.
_Avoid_: FIFO queue, fair queue

**Interactive latency**:
The elapsed time from accepting a capture job until its output is ready for the preview client.
_Avoid_: processing speed, response time

**Preview profile**:
The fixed contact-sheet output of a 3×3 grid, 160-pixel capture height, 30 frames, CRF 30, and the current AVIF encoder.
_Avoid_: quality setting, thumbnail configuration

**Progressive preview**:
A preview that shows a static image immediately and replaces it with the completed animated contact sheet when available.
_Avoid_: blocking preview, two-stage conversion

**Validated preview cache**:
A cached animated contact sheet whose source identity matches the media descriptor of the requested video.
_Avoid_: existing file, stale thumbnail

**Published preview cache**:
A validated preview cache whose AVIF and source-identity manifest have been atomically published in the cache directory.
_Avoid_: output file, partial cache

**Resource stability**:
The service's ability to keep memory and CPU use bounded while operating at its configured service capacity.
_Avoid_: performance, efficiency
