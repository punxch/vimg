# Preserve FFmpeg CFR frame selection across Capture backends

The current production FFmpeg CFR output is the authority for the Frame selection contract. VideoToolbox and software libav Capture backends must reproduce its ordered source presentation timestamps, dimensions, and labels before they can participate in automatic Backend fallback; pixel differences are allowed only within the approved visual-golden tolerance. This favors stable user-visible output and cache behavior over adopting the prototype's different explicit-PTS selection merely because it is faster.
