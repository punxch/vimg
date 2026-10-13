# ADR-0008: Release obsolete Yazi preview interest

Date: 2026-10-13
Status: Accepted

## Context

The latest-preview queue prioritizes the newest job but still generates old
queued previews after it completes. DDS has no per-request socket disconnect,
so the service cannot infer when an individual preview is abandoned. This
wastes CPU during rapid browsing and can leave the next preview waiting behind
an obsolete job that has just started.

## Decision

An interactive request opts in with `latest: true`, keyed by its DDS sender.
Each sender has one current preview interest. Replacing that interest removes
the sender from the previous job; if no interactive or batch requester remains,
an unstarted job is removed. An already queued shared preview is moved to the
newest position when selected again.

The plugin also sends `vimg-gridthumb-cancel` with its previous cache on hover
or tab changes. This covers navigation to a cached preview, non-video file or
empty directory. Cancellation must match both DDS sender and current cache.
The synchronous publication seam checks the current hovered file so a late
asynchronous preload cannot requeue an abandoned preview.

Ready notifications force a peek of the currently hovered source without
resetting its preview position. Yazi otherwise reuses the unchanged source's
existing preview and does not display the newly published animated cache.

Keep legacy/batch subscriptions separate from interactive interest, including
anonymous batch requests. A shared job survives while any requester remains.
Executing jobs complete and publish their cache, even after losing all preview
interest. No per-job capture cancellation or image/encoder changes are needed.

## Consequences

The service performs less unnecessary work after rapid navigation, without
changing the ten-job admission limit or the configurable executing-job limit.
It still waits for the residual runtime of an already executing job. Clients
that omit `latest` keep the existing behavior. Abrupt client termination is not
detected by this protocol; no inactivity timeout is inferred from silence.

Regression tests exercise the DDS parsing and scheduler seam, mixed interactive
and batch requests, shared jobs, cancellation and stale asynchronous plugin
completion. The performance report compares real Yazi DDS requests and ready
callbacks using identical native rendering and byte-identical AVIF output.
