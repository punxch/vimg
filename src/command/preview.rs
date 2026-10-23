use serde_json::{Value, json};
use std::{io::Write, path::PathBuf};

#[cfg(feature = "in-process-decode")]
mod hevc;

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
    target_pts: Option<i64>,
    seek_mode: &'static str,
    attempts: usize,
    pre_target_packets: usize,
    drain_kind: Option<&'static str>,
    decoder_threads: usize,
    skip_loop_filter: bool,
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
            target_pts: None,
            seek_mode: "none",
            attempts: 0,
            pre_target_packets: 0,
            drain_kind: None,
            decoder_threads: 0,
            skip_loop_filter: false,
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
                    "target_pts": self.target_pts, "seek_mode": self.seek_mode,
                    "attempts": self.attempts, "pre_target_packets": self.pre_target_packets,
                    "drain_kind": self.drain_kind,
                    "decoder_threads": self.decoder_threads,
                    "skip_loop_filter": self.skip_loop_filter,
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
        drop(videos);
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
        // Static previews favor a nearby indexed keyframe over an exact image.
        // Keep the same open/probed input for one bounded backward retry.
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
        timing.target_pts = Some(target_pts);
        if let Ok(jpeg) = attempt(input, index, target, Some(target_pts), options, timing) {
            return Ok(jpeg);
        }
        attempt(input, index, target, None, options, timing)
    }

    fn attempt(
        input: &mut format::context::Input,
        index: usize,
        target: i64,
        minimum_pts: Option<i64>,
        options: &Preview,
        timing: &mut PreviewTimings,
    ) -> anyhow::Result<Vec<u8>> {
        timing.attempts += 1;
        timing.early_drain = false;
        timing.drain_kind = None;
        timing.seek_mode = if minimum_pts.is_some() {
            "forward"
        } else {
            "backward"
        };
        if minimum_pts.is_some() {
            input.seek(target, target..)?;
        } else {
            input.seek(target, ..target)?;
        }
        timing.mark("seek");
        for mut stream in input.streams_mut() {
            if stream.index() != index {
                // The stream remains owned by input throughout this update.
                unsafe { (*stream.as_mut_ptr()).discard = ffmpeg::ffi::AVDiscard::AVDISCARD_ALL };
            }
        }
        // A fresh decoder also resets EOF, reference pictures and changed codec
        // configuration after an unsuccessful forward attempt.
        let parameters = input
            .stream(index)
            .context("missing preview stream")?
            .parameters();
        let codec_id = parameters.id();
        let raw = unsafe { &*parameters.as_ptr() };
        let extra = if raw.extradata_size > 0 && !raw.extradata.is_null() {
            // The stream owns this configuration until its parameters are copied below.
            unsafe { std::slice::from_raw_parts(raw.extradata, raw.extradata_size as usize) }
        } else {
            &[]
        };
        let mut framing = match codec_id {
            codec::Id::H264 => avc_length_size(extra),
            codec::Id::HEVC => hevc_length_size(extra),
            _ => None,
        };
        // Small previews do not recover even the pool setup cost. H.264 loop
        // filtering changes also lacked a stable cold-start benefit.
        let large_hevc = codec_id == codec::Id::HEVC
            && raw.width > 0
            && raw.height > 0
            && i64::from(raw.width) * i64::from(raw.height) >= 1920 * 1080;
        let fast_decode = large_hevc && super::hevc::has_wavefront(extra);
        let threads = if fast_decode { 4 } else { 1 };
        let mut context = codec::context::Context::from_parameters(parameters)?;
        context.set_threading(codec::threading::Config {
            kind: if threads > 1 {
                codec::threading::Type::Slice
            } else {
                codec::threading::Type::Frame
            },
            count: threads,
        });
        let mut decoder = context.decoder();
        // A disposable still-image decoder does not need filtered reference
        // pictures for later playback. Keep reconstruction/error checks intact;
        // only HEVC deblocking and SAO are skipped before downscaling the image.
        if fast_decode {
            decoder.skip_loop_filter(codec::discard::Discard::All);
        }
        decoder.check(
            codec::decoder::Check::BISTREAM
                | codec::decoder::Check::BUFFER
                | codec::decoder::Check::EXPLODE,
        );
        let mut decoder = decoder.video()?;
        decoder.skip_frame(codec::discard::Discard::NonKey);
        timing.decoder_threads = decoder.threading().count;
        timing.skip_loop_filter = fast_decode;
        timing.mark("decoder_init");
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
                    let (before_target, drain) =
                        packet_policy(&packet, minimum_pts, codec_id, &mut framing);
                    decoder.skip_frame(if before_target {
                        timing.pre_target_packets += 1;
                        codec::discard::Discard::All
                    } else {
                        codec::discard::Discard::NonKey
                    });
                    decoder.send_packet(&packet)?;
                    if let Some((pts, kind)) = drain {
                        // Consume any immediately available output before sending
                        // EOF; send_eof may otherwise return EAGAIN.
                        if let Some(jpeg) =
                            receive(&mut decoder, minimum_pts, options, timing, None)?
                        {
                            return Ok(jpeg);
                        }
                        // A complete random-access picture needs no later pictures. Draining
                        // releases the reorder queue instead of reading more GOPs
                        // solely to make the decoder return this one preview frame.
                        decoder.send_eof()?;
                        timing.early_drain = true;
                        timing.drain_kind = Some(kind);
                        return receive(&mut decoder, minimum_pts, options, timing, Some(pts))?
                            .context("no keyframe after early drain");
                    }
                }
                Err(ffmpeg::Error::Eof) => {
                    decoder.send_eof()?;
                    return receive(&mut decoder, minimum_pts, options, timing, None)?
                        .context("no keyframe after preview position");
                }
                Err(error) => return Err(error.into()),
            }
            if let Some(jpeg) = receive(&mut decoder, minimum_pts, options, timing, None)? {
                return Ok(jpeg);
            }
        }
    }

    fn packet_policy(
        packet: &ffmpeg::Packet,
        minimum_pts: Option<i64>,
        codec_id: codec::Id,
        framing: &mut Option<usize>,
    ) -> (bool, Option<(i64, &'static str)>) {
        if packet
            .side_data()
            .any(|side| side.kind() == codec::packet::side_data::Type::NewExtraData)
        {
            // Decoder configuration can change the NAL framing. Never drain
            // against the old configuration, even on a pre-target packet.
            *framing = None;
        }
        // Unknown timestamps never authorize dropping picture reconstruction.
        let before_target = minimum_pts
            .zip(packet.pts())
            .is_some_and(|(target, pts)| pts < target);
        let drain = if packet.is_key() && !before_target && packet.pts().is_some() {
            // Consider only the first eligible key packet; recovery/unknown
            // pictures retain normal decoder behavior throughout this attempt.
            framing.take().and_then(|size| {
                if unsafe { (*packet.as_ptr()).flags != ffmpeg::ffi::AV_PKT_FLAG_KEY } {
                    return None;
                }
                let data = packet.data()?;
                let kind = match codec_id {
                    codec::Id::H264 if avc_idr(data, size) => Some("h264_idr"),
                    codec::Id::HEVC => hevc_irap(data, size),
                    _ => None,
                }?;
                Some((packet.pts().unwrap(), kind))
            })
        } else {
            None
        };
        (before_target, drain)
    }

    fn receive(
        decoder: &mut ffmpeg::decoder::Video,
        minimum_pts: Option<i64>,
        options: &Preview,
        timing: &mut PreviewTimings,
        expected_key_pts: Option<i64>,
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
            if minimum_pts.is_some_and(|target| pts < target) {
                continue;
            }
            ensure!(
                frame.is_key() && !frame.is_corrupt(),
                "invalid preview keyframe uses FFmpeg"
            );
            if let Some(expected) = expected_key_pts {
                ensure!(
                    pts == expected,
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

    fn hevc_length_size(extra: &[u8]) -> Option<usize> {
        // hvcC has a 23-byte fixed header; Annex B and incomplete records must
        // not be mistaken for length-prefixed access units.
        if extra.len() < 23 || extra[0] != 1 {
            return None;
        }
        match (extra[21] & 3) + 1 {
            size @ (1 | 2 | 4) => Some(usize::from(size)),
            _ => None,
        }
    }

    fn hevc_irap(mut data: &[u8], length_size: usize) -> Option<&'static str> {
        if !matches!(length_size, 1 | 2 | 4) {
            return None;
        }
        let mut picture_type = None;
        while !data.is_empty() {
            let length = data.get(..length_size)?;
            let size = length
                .iter()
                .fold(0usize, |n, &b| (n << 8) | usize::from(b));
            data = &data[length_size..];
            let nal = data.get(..size).filter(|nal| nal.len() >= 3)?;
            // forbidden_zero_bit, nuh_layer_id and temporal_id_plus1. Only
            // single-layer, temporal-layer-zero random-access pictures qualify.
            if nal[0] & 0x81 != 0 || nal[1] != 1 {
                return None;
            }
            let kind = (nal[0] >> 1) & 0x3f;
            match kind {
                16..=21 => {
                    let first_slice = nal[2] & 0x80 != 0;
                    match picture_type {
                        None if first_slice => picture_type = Some(kind),
                        Some(previous) if previous == kind && !first_slice => {}
                        _ => return None, // no mixed pictures or missing first slice
                    }
                }
                32..=35 | 38..=40 => {} // VPS/SPS/PPS/AUD/filler/prefix and suffix SEI
                _ => return None,
            }
            data = &data[size..];
        }
        match picture_type? {
            16..=18 => Some("hevc_bla"),
            19..=20 => Some("hevc_idr"),
            21 => Some("hevc_cra"),
            _ => None,
        }
    }

    #[cfg(test)]
    mod tests {
        use super::{avc_idr, avc_length_size, hevc_irap, hevc_length_size, packet_policy};

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

        #[test]
        fn hevc_configuration_requires_a_complete_length_header() {
            let mut extra = [0; 23];
            extra[0] = 1;
            for size in [1, 2, 4] {
                extra[21] = size - 1;
                assert_eq!(hevc_length_size(&extra), Some(usize::from(size)));
            }
            assert_eq!(hevc_length_size(&extra[..22]), None);
            extra[21] = 2;
            assert_eq!(hevc_length_size(&extra), None);
            extra[0] = 0;
            assert_eq!(hevc_length_size(&extra), None);
        }

        #[test]
        fn hevc_idr_bla_cra_and_multiple_slices_can_drain() {
            for size in [1, 2, 4] {
                for kind in 16..=21 {
                    let data = packet(
                        size,
                        &[
                            &[64, 1, 0x80],
                            &[66, 1, 0x80],
                            &[68, 1, 0x80],
                            &[70, 1, 0x80],
                            &[78, 1, 0x80],
                            &[kind << 1, 1, 0x80],
                            &[kind << 1, 1, 0x40],
                            &[80, 1, 0x80],
                        ],
                    );
                    assert_eq!(
                        hevc_irap(&data, size),
                        Some(match kind {
                            16..=18 => "hevc_bla",
                            19..=20 => "hevc_idr",
                            _ => "hevc_cra",
                        })
                    );
                }
            }
        }

        #[test]
        fn hevc_rejects_mixed_pictures_layers_and_invalid_headers() {
            for nals in [
                vec![&[38, 1, 0x80][..], &[42, 1, 0x40]], // IDR then CRA slice
                vec![&[38, 1, 0x80][..], &[2, 1, 0x40]],  // non-IRAP VCL
                vec![&[38, 1, 0x80][..], &[38, 1, 0x80]], // two pictures
                vec![&[38, 1, 0x40][..]],                 // missing first slice
                vec![&[39, 1, 0x80][..]],                 // other layer
                vec![&[38, 9, 0x80][..]],                 // other layer
                vec![&[38, 0, 0x80][..]],                 // invalid temporal id
                vec![&[38, 2, 0x80][..]],                 // other temporal layer
                vec![&[166, 1, 0x80][..]],                // forbidden bit
                vec![&[64, 1, 0x80][..]],                 // parameters only
                vec![&[38, 1, 0x80][..], &[72, 1, 0x80]], // end of sequence
            ] {
                assert_eq!(hevc_irap(&packet(4, &nals), 4), None, "{nals:?}");
            }
        }

        #[test]
        fn hevc_rejects_truncated_nals_and_bad_length_prefixes() {
            let complete = packet(4, &[&[38, 1, 0x80]]);
            for n in 0..complete.len() {
                assert_eq!(hevc_irap(&complete[..n], 4), None);
            }
            for data in [
                &[0, 0, 0, 0][..],
                &[255, 255, 255, 255],
                &[0, 0, 0, 2, 38, 1],
            ] {
                assert_eq!(hevc_irap(data, 4), None);
            }
            assert_eq!(hevc_irap(&complete, 0), None);
            assert_eq!(hevc_irap(&complete, 3), None);
        }

        #[test]
        fn unknown_and_negative_timestamps_preserve_decoder_input_policy() {
            use ffmpeg_next::{Packet, codec};
            let mut key = Packet::copy(&packet(4, &[&[0x65, 1]]));
            key.set_flags(codec::packet::Flags::KEY);
            let mut framing = Some(4);
            assert_eq!(
                packet_policy(&key, Some(10), codec::Id::H264, &mut framing),
                (false, None)
            );
            assert_eq!(framing, Some(4));
            key.set_pts(Some(-1));
            assert_eq!(
                packet_policy(&key, Some(10), codec::Id::H264, &mut framing),
                (true, None)
            );
            // Backward retry explicitly allows the preceding keyframe.
            assert_eq!(
                packet_policy(&key, None, codec::Id::H264, &mut framing),
                (false, Some((-1, "h264_idr")))
            );
        }

        #[test]
        fn corrupt_key_packet_cannot_authorize_early_draining() {
            use ffmpeg_next::{Packet, codec};
            let mut key = Packet::copy(&packet(4, &[&[0x65, 1]]));
            key.set_pts(Some(10));
            key.set_flags(codec::packet::Flags::KEY | codec::packet::Flags::CORRUPT);
            let mut framing = Some(4);
            assert_eq!(
                packet_policy(&key, Some(10), codec::Id::H264, &mut framing),
                (false, None)
            );
            assert_eq!(framing, None);
        }

        #[test]
        fn a_configuration_change_disables_draining_for_the_attempt() {
            use ffmpeg_next::{Packet, codec, codec::packet::Mut as _};
            let mut changed = Packet::copy(&packet(4, &[&[0x65, 1]]));
            changed.set_pts(Some(0));
            changed.set_flags(codec::packet::Flags::KEY);
            let side = unsafe {
                ffmpeg_next::ffi::av_packet_new_side_data(
                    changed.as_mut_ptr(),
                    ffmpeg_next::ffi::AVPacketSideDataType::AV_PKT_DATA_NEW_EXTRADATA,
                    1,
                )
            };
            assert!(!side.is_null());
            unsafe { *side = 1 };
            let mut framing = Some(4);
            assert_eq!(
                packet_policy(&changed, Some(10), codec::Id::H264, &mut framing),
                (true, None)
            );
            let mut next = Packet::copy(&packet(4, &[&[0x65, 1]]));
            next.set_pts(Some(10));
            next.set_flags(codec::packet::Flags::KEY);
            assert_eq!(
                packet_policy(&next, Some(10), codec::Id::H264, &mut framing),
                (false, None)
            );
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
