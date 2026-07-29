# Stream contact-sheet frames with bounded buffering

VCS will preserve the existing preview profile while producing ordered grid frames through a bounded pipeline into the encoder instead of materializing all extracted and joined frames before encoding. Bounded buffering keeps an active Capture job within its resource budget and overlaps grid assembly with encoding; the implementation must preserve frame order and propagate producer or encoder failures to every waiting requester.
