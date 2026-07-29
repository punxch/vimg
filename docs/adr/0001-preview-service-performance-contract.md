# Preserve the preview profile within a bounded service budget

The local preview service keeps the 3×3, 160-pixel, 30-frame, CRF 30 AVIF preview profile. For the representative input, a warm-cache capture job must meet a 1.3-second P95 interactive-latency target and a 512 MB peak-RSS limit; the one-active-job, nine-queued-job service capacity must not permit resource growth beyond that active-job budget. This preserves visual fidelity while making interactive responsiveness and resource stability explicit.
