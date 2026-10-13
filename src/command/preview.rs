use serde_json::{Value, json};
use std::{io::Write, path::PathBuf};

/// Try a native static preview; print metadata and preview_written for fallback.
#[derive(clap::Parser, Debug)]
pub struct Preview {
    pub video: PathBuf,
    #[arg(long)]
    pub output: PathBuf,
    /// Yazi's preview offset, added to 5% (0% for attached pictures).
    #[arg(long, default_value_t = 0)]
    pub skip: u32,
    #[arg(long, default_value_t = 600, value_parser = clap::value_parser!(u32).range(1..=16384))]
    pub max_width: u32,
    #[arg(long, default_value_t = 900, value_parser = clap::value_parser!(u32).range(1..=16384))]
    pub max_height: u32,
    #[arg(long, default_value_t = 75, value_parser = clap::value_parser!(u8).range(0..=100))]
    pub quality: u8,
    /// Print native stage timings as JSON on stderr (stdout remains metadata).
    #[arg(long)]
    pub timings: bool,
}

#[cfg(feature = "in-process-decode")]
pub(super) struct PreviewTimings {
    clock: Option<(std::time::Instant, std::time::Instant)>,
    stages: Vec<(&'static str, f64)>,
    packets: usize,
    key_packets: usize,
    early_drain: bool,
    selected_pts: Option<i64>,
}

#[cfg(feature = "in-process-decode")]
impl PreviewTimings {
    fn new(enabled: bool) -> Self {
        Self {
            clock: enabled.then(|| {
                let now = std::time::Instant::now();
                (now, now)
            }),
            stages: Vec::new(),
            packets: 0,
            key_packets: 0,
            early_drain: false,
            selected_pts: None,
        }
    }

    pub(super) fn mark(&mut self, phase: &'static str) {
        if let Some((_, previous)) = &mut self.clock {
            let now = std::time::Instant::now();
            self.stages
                .push((phase, now.duration_since(*previous).as_secs_f64() * 1000.0));
            *previous = now;
        }
    }
}

#[cfg(feature = "in-process-decode")]
impl Drop for PreviewTimings {
    fn drop(&mut self) {
        if let Some((start, _)) = self.clock {
            let total_ms = start.elapsed().as_secs_f64() * 1000.0;
            eprintln!(
                "vimg-preview-timing {}",
                json!({
                    "total_ms": total_ms, "stages_ms": self.stages,
                    "packets": self.packets, "pid": std::process::id(),
                    "key_packets": self.key_packets, "early_drain": self.early_drain,
                    "selected_pts": self.selected_pts,
                })
            );
        }
    }
}

impl Preview {
    pub fn run(&self) -> anyhow::Result<()> {
        let metadata = self.prepare()?;
        let mut stdout = std::io::stdout().lock();
        serde_json::to_writer(&mut stdout, &metadata)?;
        writeln!(stdout)?;
        Ok(())
    }

    #[cfg(not(feature = "in-process-decode"))]
    fn prepare(&self) -> anyhow::Result<Value> {
        // A capability response avoids spawning ffprobe only to discover that
        // this build cannot also decode the frame. The plugin caches it.
        Ok(json!({"native_preview": false, "native_probe": false, "preview_written": false}))
    }

    #[cfg(feature = "in-process-decode")]
    fn prepare(&self) -> anyhow::Result<Value> {
        use anyhow::ensure;
        let mut timing = PreviewTimings::new(self.timings);
        let mut input = if self.timings {
            super::probe::open_input_observed(&self.video, &mut timing)?
        } else {
            super::probe::open_input(&self.video)?
        };
        let mut metadata = super::probe::metadata_from_input(&input)?;
        metadata["native_preview"] = json!(true);
        metadata["native_probe"] = json!(true);
        metadata["preview_written"] = json!(false);
        ensure!(
            std::fs::canonicalize(&self.output).ok().as_ref()
                != Some(&std::fs::canonicalize(&self.video)?),
            "preview output must differ from input"
        );
        let cover = metadata["streams"]
            .as_array()
            .unwrap()
            .iter()
            .any(|s| s["disposition"]["attached_pic"] == 1);
        let percent = u64::from(self.skip) + if cover { 0 } else { 5 };
        if percent > 95 {
            metadata["preview_upper_bound"] = json!(if cover { 95 } else { 90 });
            return Ok(metadata);
        }
        // Use precisely the same duration rounding as the Lua/ffprobe path.
        let duration: f64 = metadata["format"]["duration"].as_str().unwrap().parse()?;
        let seconds = (duration * percent as f64 / 100.0).floor();
        timing.mark("metadata");
        match native::jpeg(&mut input, seconds, self, &mut timing) {
            Ok(jpeg) => {
                timing.mark("decoder_release");
                native::publish(&self.output, &jpeg)?;
                timing.mark("publish");
                metadata["preview_written"] = json!(true);
            }
            Err(error) => {
                // Reuse the already-probed metadata with the plugin's FFmpeg
                // fallback. A per-file limitation is not a missing capability.
                metadata["preview_fallback"] = json!(error.to_string());
            }
        }
        drop(input);
        timing.mark("input_release");
        Ok(metadata)
    }
}

#[cfg(feature = "in-process-decode")]
mod native {
    use super::{Preview, PreviewTimings};
    use anyhow::{Context, ensure};
    use ffmpeg_next::{
        self as ffmpeg, codec, codec::packet::Ref as _, filter, format, frame::Video, media::Type,
    };
    use std::{io::Write, path::Path};

    pub(super) fn jpeg(
        input: &mut format::context::Input,
        seconds: f64,
        options: &Preview,
        timing: &mut PreviewTimings,
    ) -> anyhow::Result<Vec<u8>> {
        // FFmpeg applies extra timestamp correction to discontinuous inputs
        // (for example MPEG-TS). Keep its seek/trim behavior on that path.
        let format_flags = unsafe { (*input.format().as_ptr()).flags };
        ensure!(
            format_flags & ffmpeg::ffi::AVFMT_TS_DISCONT == 0,
            "discontinuous timestamps use FFmpeg"
        );
        ensure!(
            input
                .format()
                .name()
                .split(',')
                .any(|name| matches!(name, "matroska" | "mov")),
            "container uses FFmpeg fallback"
        );
        let videos: Vec<_> = input
            .streams()
            .filter(|s| s.parameters().medium() == Type::Video)
            .collect();
        ensure!(
            videos.len() == 1,
            "multiple video streams or cover art use FFmpeg stream selection"
        );
        let stream = &videos[0];
        ensure!(
            !stream
                .disposition()
                .contains(format::stream::Disposition::ATTACHED_PIC),
            "attached picture uses FFmpeg"
        );
        ensure!(
            !stream
                .side_data()
                .any(|s| s.kind() == codec::packet::side_data::Type::DisplayMatrix),
            "display matrix uses FFmpeg autorotation"
        );
        let parameters = stream.parameters();
        ensure!(
            matches!(parameters.id(), codec::Id::H264 | codec::Id::HEVC),
            "codec uses FFmpeg fallback"
        );
        let index = stream.index();
        let time_base = stream.time_base();
        // Only length-prefixed H.264 IDRs are eligible for early draining.
        // Keep HEVC, recovery-point/open GOP and unknown framing on the normal path.
        let mut nal_length_size = if parameters.id() == codec::Id::H264 {
            // The parameters and extradata are borrowed from the live input stream.
            let raw = unsafe { &*parameters.as_ptr() };
            if raw.extradata_size >= 7 && !raw.extradata.is_null() {
                avc_length_size(unsafe { std::slice::from_raw_parts(raw.extradata, 7) })
            } else {
                None
            }
        } else {
            None
        };
        let mut context = codec::context::Context::from_parameters(parameters)?;
        context.set_threading(codec::threading::Config {
            kind: codec::threading::Type::Frame,
            count: 1,
        });
        let mut decoder = context.decoder().video()?;
        decoder.skip_frame(codec::discard::Discard::NonKey);
        drop(videos);
        timing.mark("decoder_init");
        // FFmpeg input-side -ss is relative to the container's start time.
        let origin = unsafe { (*input.as_ptr()).start_time };
        let origin = if origin == ffmpeg::ffi::AV_NOPTS_VALUE {
            0
        } else {
            origin
        };
        let target = (seconds * f64::from(ffmpeg::ffi::AV_TIME_BASE)) as i64;
        let target = target
            .checked_add(origin)
            .context("seek timestamp overflow")?;
        input.seek(target, ..target)?;
        timing.mark("seek");
        for mut stream in input.streams_mut() {
            if stream.index() != index {
                // The stream remains owned by input throughout this update.
                unsafe { (*stream.as_mut_ptr()).discard = ffmpeg::ffi::AVDiscard::AVDISCARD_ALL };
            }
        }
        let target_pts = unsafe {
            ffmpeg::ffi::av_rescale_q_rnd(
                target,
                ffmpeg::ffi::AVRational {
                    num: 1,
                    den: ffmpeg::ffi::AV_TIME_BASE,
                },
                time_base.into(),
                ffmpeg::ffi::AVRounding::AV_ROUND_UP,
            )
        };
        loop {
            // Drop/unref each packet before reading the next one.
            let mut packet = ffmpeg::Packet::empty();
            match packet.read(input) {
                Ok(()) => {
                    timing.packets += 1;
                    if packet.stream() != index {
                        continue;
                    }
                    timing.key_packets += usize::from(packet.is_key());
                    if packet
                        .side_data()
                        .any(|side| side.kind() == codec::packet::side_data::Type::NewExtraData)
                    {
                        // A new AVC configuration may change the NAL length size.
                        nal_length_size = None;
                    }
                    let drain_pts = if packet.is_key()
                        && packet.pts().is_some_and(|pts| pts >= target_pts)
                    {
                        // Consider only the first key packet at/after the target.
                        // Do not drain past an earlier recovery-point picture.
                        nal_length_size.take().and_then(|size| {
                            (unsafe { (*packet.as_ptr()).flags == ffmpeg::ffi::AV_PKT_FLAG_KEY }
                                && packet.data().is_some_and(|data| avc_idr(data, size)))
                            .then(|| packet.pts().unwrap())
                        })
                    } else {
                        None
                    };
                    decoder.send_packet(&packet)?;
                    if let Some(pts) = drain_pts {
                        // Consume any immediately available output before sending
                        // EOF; send_eof may otherwise return EAGAIN.
                        if let Some(jpeg) =
                            receive(&mut decoder, target_pts, options, timing, None)?
                        {
                            return Ok(jpeg);
                        }
                        // A complete IDR is independent of later pictures. Draining
                        // releases the reorder queue instead of reading more GOPs
                        // solely to make the decoder return this one preview frame.
                        decoder.send_eof()?;
                        timing.early_drain = true;
                        return receive(&mut decoder, target_pts, options, timing, Some(pts))?
                            .context("no keyframe after early drain");
                    }
                }
                Err(ffmpeg::Error::Eof) => {
                    decoder.send_eof()?;
                    return receive(&mut decoder, target_pts, options, timing, None)?
                        .context("no keyframe after preview position");
                }
                Err(error) => return Err(error.into()),
            }
            if let Some(jpeg) = receive(&mut decoder, target_pts, options, timing, None)? {
                return Ok(jpeg);
            }
        }
    }

    fn receive(
        decoder: &mut ffmpeg::decoder::Video,
        target: i64,
        options: &Preview,
        timing: &mut PreviewTimings,
        expected_idr_pts: Option<i64>,
    ) -> anyhow::Result<Option<Vec<u8>>> {
        let mut frame = Video::empty();
        loop {
            match decoder.receive_frame(&mut frame) {
                Ok(()) => {}
                Err(ffmpeg::Error::Other {
                    errno: ffmpeg::util::error::EAGAIN,
                })
                | Err(ffmpeg::Error::Eof) => return Ok(None),
                Err(error) => return Err(error.into()),
            }
            let pts = frame
                .timestamp()
                .or_else(|| frame.pts())
                .context("frame has no timestamp")?;
            if pts < target {
                continue;
            }
            if let Some(expected) = expected_idr_pts {
                ensure!(
                    frame.is_key() && pts == expected && !frame.is_corrupt(),
                    "early-drained frame requires FFmpeg validation"
                );
            }
            ensure!(!frame.is_interlaced(), "interlaced frame uses FFmpeg");
            ensure!(
                frame
                    .side_data(ffmpeg::frame::side_data::Type::DisplayMatrix)
                    .is_none(),
                "frame rotation uses FFmpeg"
            );
            ensure!(
                matches!(
                    frame.format(),
                    format::Pixel::YUV420P | format::Pixel::YUVJ420P
                ),
                "pixel format uses FFmpeg"
            );
            timing.selected_pts = Some(pts);
            timing.mark("read_decode");
            return Ok(Some(encode(&frame, options, timing)?));
        }
    }

    fn avc_length_size(extra: &[u8]) -> Option<usize> {
        if extra.len() < 7 || extra[0] != 1 || extra[4] & 0xfc != 0xfc {
            return None;
        }
        match (extra[4] & 3) + 1 {
            size @ (1 | 2 | 4) => Some(usize::from(size)),
            _ => None,
        }
    }

    // Validate every NAL boundary, not just the first slice. The demuxer supplies
    // a complete AVC access unit; allow IDR slices plus ordinary parameter/SEI
    // data, but reject mixed VCL, extensions, unknown types and malformed framing.
    fn avc_idr(mut data: &[u8], length_size: usize) -> bool {
        if !matches!(length_size, 1 | 2 | 4) {
            return false;
        }
        let mut idr = false;
        while !data.is_empty() {
            let Some(length) = data.get(..length_size) else {
                return false;
            };
            let size = length
                .iter()
                .fold(0usize, |n, &b| (n << 8) | usize::from(b));
            data = &data[length_size..];
            let Some(nal) = data.get(..size).filter(|nal| !nal.is_empty()) else {
                return false;
            };
            if nal[0] & 0x80 != 0 {
                return false;
            }
            match nal[0] & 0x1f {
                5 if nal[0] & 0x60 != 0 && nal.len() > 1 => idr = true,
                6..=9 | 12 => {}
                _ => return false,
            }
            data = &data[size..];
        }
        idr
    }

    #[cfg(test)]
    mod tests {
        use super::{avc_idr, avc_length_size};

        fn packet(size: usize, nals: &[&[u8]]) -> Vec<u8> {
            let mut packet = Vec::new();
            for nal in nals {
                packet.extend_from_slice(&(nal.len() as u32).to_be_bytes()[4 - size..]);
                packet.extend_from_slice(nal);
            }
            packet
        }

        #[test]
        fn avc_configuration_requires_known_length_framing() {
            for size in [1, 2, 4] {
                assert_eq!(
                    avc_length_size(&[1, 100, 0, 40, 0xfc | (size - 1), 0xe1, 0]),
                    Some(usize::from(size))
                );
            }
            for extra in [
                &[][..],
                &[1, 100, 0, 40],
                &[0, 0, 0, 1, 0x67, 0, 0],
                &[1, 100, 0, 40, 0xfe, 0, 0],
                &[1, 100, 0, 40, 3, 0, 0],
            ] {
                assert_eq!(avc_length_size(extra), None);
            }
        }

        #[test]
        fn complete_multislice_idr_allows_parameter_and_sei_nals() {
            for size in [1, 2, 4] {
                assert!(avc_idr(
                    &packet(
                        size,
                        &[
                            &[0x09, 0xf0],
                            &[0x67, 1],
                            &[0x68, 1],
                            &[0x06, 1],
                            &[0x65, 1],
                            &[0x65, 2],
                            &[0x0c, 0x80]
                        ]
                    ),
                    size
                ));
            }
        }

        #[test]
        fn recovery_points_mixed_slices_and_extensions_do_not_drain() {
            for nals in [
                vec![&[0x06, 1][..], &[0x41, 1]],
                vec![&[0x65, 1][..], &[0x41, 1]],
                vec![&[0x65, 1][..], &[0x74, 1]],
                vec![&[0x65, 1][..], &[0x0b, 1]],
                vec![&[0x05, 1][..]],
                vec![&[0xe5, 1][..]],
                vec![&[0x67, 1][..]],
            ] {
                assert!(!avc_idr(&packet(4, &nals), 4));
            }
        }

        #[test]
        fn incomplete_or_malformed_access_units_do_not_drain() {
            let complete = packet(4, &[&[0x65, 1], &[0x65, 2]]);
            for n in [0, 1, 2, 3, 4, 5, 7, 8, 9, 10, 11] {
                assert!(!avc_idr(&complete[..n], 4), "truncated at {n}");
            }
            for data in [
                &[0, 0, 0, 0][..],
                &[255, 255, 255, 255, 0x65],
                &[0, 0, 0, 1, 0x65],
            ] {
                assert!(!avc_idr(data, 4));
            }
            assert!(!avc_idr(&complete, 0));
            assert!(!avc_idr(&complete, 3));
        }
    }

    fn encode(
        frame: &Video,
        options: &Preview,
        timing: &mut PreviewTimings,
    ) -> anyhow::Result<Vec<u8>> {
        let mut graph = filter::Graph::new();
        // The graph is owned locally; one filter worker matches the plugin.
        unsafe { (*graph.as_mut_ptr()).nb_threads = 1 };
        let aspect = frame.aspect_ratio();
        let aspect = if aspect.numerator() > 0 && aspect.denominator() > 0 {
            aspect
        } else {
            ffmpeg::Rational(1, 1)
        };
        let (space, range) = unsafe {
            (
                (*frame.as_ptr()).colorspace as i32,
                (*frame.as_ptr()).color_range as i32,
            )
        };
        graph.add(
            &filter::find("buffer").context("buffer filter unavailable")?,
            "in",
            &format!(
                "video_size={}x{}:pix_fmt={}:time_base=1/1:pixel_aspect={}:colorspace={}:range={}",
                frame.width(),
                frame.height(),
                frame
                    .format()
                    .descriptor()
                    .context("unknown pixel format")?
                    .name(),
                aspect,
                space,
                range
            ),
        )?;
        graph.add(
            &filter::find("buffersink").context("buffersink unavailable")?,
            "out",
            "",
        )?;
        graph.output("in", 0)?.input("out", 0)?.parse(&format!(
            "scale='min({},iw)':'min({},ih)':force_original_aspect_ratio=decrease:flags=fast_bilinear:out_range=pc,format=yuv420p",
            options.max_width, options.max_height
        ))?;
        graph.validate()?;
        timing.mark("filter_setup");
        graph.get("in").unwrap().source().add(frame)?;
        let mut scaled = Video::empty();
        graph.get("out").unwrap().sink().frame(&mut scaled)?;
        timing.mark("scale");
        // Degenerate output dimensions can make the scaled SAR invalid for
        // the encoder (for example 1x1 at 16:9). FFmpeg's CLI rewrites those
        // image headers; leave that case to the compatibility path.
        ensure!(
            unsafe {
                ffmpeg::ffi::av_image_check_sar(
                    scaled.width(),
                    scaled.height(),
                    scaled.aspect_ratio().into(),
                )
            } >= 0,
            "invalid scaled aspect ratio uses FFmpeg"
        );
        let codec = ffmpeg::encoder::find(codec::Id::MJPEG).context("MJPEG encoder unavailable")?;
        let mut context = codec::context::Context::new_with_codec(codec);
        context.set_threading(codec::threading::Config {
            kind: codec::threading::Type::Slice,
            count: 1,
        });
        context.set_flags(codec::Flags::QSCALE);
        let mut encoder = context.encoder().video()?;
        encoder.set_width(scaled.width());
        encoder.set_height(scaled.height());
        encoder.set_format(scaled.format());
        encoder.set_aspect_ratio(scaled.aspect_ratio());
        encoder.set_time_base((1, 25));
        let quality = (31 - i32::from(options.quality) * 3 / 10) * ffmpeg::ffi::FF_QP2LAMBDA;
        encoder.set_global_quality(quality);
        // These fields belong to live local frames/contexts. FFmpeg's CLI
        // applies qscale to both the codec context and each submitted frame.
        unsafe {
            (*encoder.as_mut_ptr()).color_range = ffmpeg::ffi::AVColorRange::AVCOL_RANGE_JPEG;
            (*encoder.as_mut_ptr()).colorspace = (*scaled.as_ptr()).colorspace;
            (*scaled.as_mut_ptr()).quality = quality;
        }
        scaled.set_pts(Some(0));
        let mut encoder = encoder.open()?;
        timing.mark("jpeg_setup");
        encoder.send_frame(&scaled)?;
        encoder.send_eof()?;
        let mut packet = ffmpeg::Packet::empty();
        encoder.receive_packet(&mut packet)?;
        timing.mark("jpeg_encode");
        Ok(packet.data().context("empty JPEG packet")?.to_vec())
    }

    pub(super) fn publish(path: &Path, jpeg: &[u8]) -> anyhow::Result<()> {
        let temporary = path.with_file_name(format!(
            ".vimg-preview-{}-{:016x}.tmp",
            std::process::id(),
            fastrand::u64(..)
        ));
        let mut file = std::fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&temporary)?;
        let result = (|| {
            file.write_all(jpeg)?;
            drop(file);
            std::fs::rename(&temporary, path)
        })();
        if result.is_err() {
            let _ = std::fs::remove_file(&temporary);
        }
        result.context("publishing static preview")
    }
}
