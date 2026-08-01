//! In-process SVT-AV1 encoding + AVIF muxing for the fixed Preview profile.
//!
//! Replaces the external `ffmpeg` encoder subprocess: no process/DLL startup,
//! no raw-RGB pipe, and the flush tail shrinks to the SVT drain. The output is
//! byte-identical to the subprocess pipeline by construction:
//!
//! - the stream time base is set to the encoder time base (1/fps) before the
//!   header is written, so the avif (mov) muxer derives the same track
//!   timescale the CLI produces (20 → ×2 until ≥ 10000 → 10240);
//! - packets keep the encoder time base and are explicitly rescaled to the
//!   muxer's track time scale (1/10240), matching the CLI's ost rescale;
//! - RGB → yuv420p10le uses swscale bicubic, the same filter and flags the CLI
//!   auto-inserts (`auto_scale_0`, flags 0x4), producing tv-range frames;
//! - libsvtav1 receives identical options (`preset`, `crf`, `svtav1-params
//!   lp=2`) on an identically defaulted codec context.

use anyhow::{Context, ensure};
use ffmpeg::codec::threading;
use ffmpeg::util::frame::video::Video;
use ffmpeg_next as ffmpeg;
use image::RgbImage;
use std::{
    sync::mpsc::{Receiver, SyncSender, sync_channel},
    thread::{self, JoinHandle},
};

/// Streaming grid encoder: grids are converted and fed to SVT on a dedicated
/// thread so RGB→YUV conversion overlaps grid composition on the main thread.
#[derive(Debug)]
pub(crate) struct InProcessAvifEncoder {
    sender: Option<SyncSender<RgbImage>>,
    worker: Option<JoinHandle<anyhow::Result<()>>>,
}

impl InProcessAvifEncoder {
    pub(crate) fn start(
        path: &std::path::Path,
        width: u32,
        height: u32,
        fps: f32,
        crf: u8,
        preset: u8,
    ) -> anyhow::Result<Self> {
        ensure!(
            fps.is_finite() && fps > 0.0 && fps.fract() == 0.0,
            "in-process AVIF encoder requires an integer frame rate (found {fps})"
        );
        let state = EncoderState::new(path, width, height, fps as i32, crf, preset)?;
        let (sender, receiver) = sync_channel::<RgbImage>(2);
        let worker = thread::spawn(move || state.run(receiver));
        Ok(Self {
            sender: Some(sender),
            worker: Some(worker),
        })
    }

    pub(crate) fn write_grid(&self, grid: &RgbImage) -> anyhow::Result<()> {
        self.sender
            .as_ref()
            .context("in-process AVIF encoder has already been closed")?
            .send(grid.clone())
            .context("in-process AVIF encoder stopped")
    }

    pub(crate) fn finish(&mut self) -> anyhow::Result<()> {
        // Closing the channel makes the worker drain the encoder and write the
        // trailer before exiting.
        self.sender.take();
        self.worker
            .take()
            .context("in-process AVIF encoder has already been finished")?
            .join()
            .map_err(|_| anyhow::anyhow!("in-process AVIF encoder panicked"))?
    }
}

impl Drop for InProcessAvifEncoder {
    fn drop(&mut self) {
        self.sender.take();
        if let Some(worker) = self.worker.take() {
            let _ = worker.join();
        }
    }
}

struct EncoderState {
    encoder: ffmpeg::encoder::Video,
    output: ffmpeg::format::context::Output,
    converter: ffmpeg::software::scaling::Context,
    time_base: ffmpeg::Rational,
    width: u32,
    height: u32,
}

// The swscale context is a raw pointer and not auto-Send; every member is
// created on the calling thread and only ever used on the encoder worker.
unsafe impl Send for EncoderState {}

impl EncoderState {
    fn new(
        path: &std::path::Path,
        width: u32,
        height: u32,
        fps: i32,
        crf: u8,
        preset: u8,
    ) -> anyhow::Result<Self> {
        ffmpeg::init().context("initializing software libav")?;
        let codec =
            ffmpeg::encoder::find_by_name("libsvtav1").context("libsvtav1 encoder is unavailable")?;
        let mut output = ffmpeg::format::output_as(path, "avif")
            .with_context(|| format!("opening AVIF output {}", path.display()))?;
        // The CLI sets GLOBAL_HEADER whenever the muxer requests it (mov/avif
        // does): libsvtav1 then puts the sequence header in extradata (the
        // 4-byte av1C payload) instead of repeating it in every packet.
        let global_header = output
            .format()
            .flags()
            .contains(ffmpeg::format::Flags::GLOBAL_HEADER);
        let mut stream = output.add_stream(codec)?;
        let time_base = ffmpeg::Rational(1, fps);
        // The muxer derives the track timescale from the stream time base and
        // rewrites the stream time base to match it during header writing.
        stream.set_time_base(time_base);
        // The mov muxer writes the stream's "encoder" metadata as the av01
        // compressor name; the ffmpeg CLI tags it with the lavc ident + codec.
        let version = ffmpeg::codec::version();
        let mut metadata = ffmpeg::Dictionary::new();
        metadata.set(
            "encoder",
            &format!(
                "Lavc{}.{}.{} {}",
                (version >> 16) & 0xff,
                (version >> 8) & 0xff,
                version & 0xff,
                codec.name()
            ),
        );
        stream.set_metadata(metadata);
        let mut context = ffmpeg::codec::context::Context::new_with_codec(codec);
        // Auto thread count, matching the ffmpeg CLI default.
        context.set_threading(threading::Config {
            kind: threading::Type::Frame,
            count: 0,
        });
        if global_header {
            context.set_flags(ffmpeg::codec::Flags::GLOBAL_HEADER);
        }
        let mut encoder = context
            .encoder()
            .video()
            .context("libsvtav1 video encoder is unsupported")?;
        encoder.set_width(width);
        encoder.set_height(height);
        encoder.set_format(ffmpeg::format::Pixel::YUV420P10LE);
        encoder.set_time_base(time_base);
        encoder.set_frame_rate(Some(ffmpeg::Rational(fps, 1)));
        // The CLI's codecpar carries field_order=PROGRESSIVE (from the filter
        // chain), which makes the mov muxer emit the av01 'fiel' box.
        unsafe {
            (*encoder.as_mut_ptr()).field_order = ffmpeg::ffi::AVFieldOrder::AV_FIELD_PROGRESSIVE;
        }
        let mut options = ffmpeg::Dictionary::new();
        options.set("preset", &preset.to_string());
        options.set("crf", &crf.to_string());
        // SVT-AV1 lp (Level of Parallelism) 2 instead of the subprocess
        // pipeline's 4: lp does not change the bitstream (verified byte-
        // identical) but cuts the in-process encoder's peak working set by
        // ~100MB (PPCS 59 -> 42), which matters now that SVT shares vimg's
        // process and the 512MB ADR budget.
        options.set("svtav1-params", "lp=2");
        let encoder: ffmpeg::encoder::Video = encoder
            .open_with(options)
            .context("opening libsvtav1 encoder")?;
        stream.set_parameters(&encoder);
        output.write_header().context("writing AVIF header")?;
        // Same conversion the CLI auto-inserts: swscale bicubic, rgb24(gbr,pc)
        // → yuv420p10le(tv).
        let converter = ffmpeg::software::scaling::Context::get(
            ffmpeg::format::Pixel::RGB24,
            width,
            height,
            ffmpeg::format::Pixel::YUV420P10LE,
            width,
            height,
            ffmpeg::software::scaling::Flags::BICUBIC,
        )
        .context("creating the RGB→YUV converter")?;
        Ok(Self {
            encoder,
            output,
            converter,
            time_base,
            width,
            height,
        })
    }

    fn run(mut self, receiver: Receiver<RgbImage>) -> anyhow::Result<()> {
        for (pts, grid) in receiver.iter().enumerate() {
            self.feed(&grid, pts as i64)?;
        }
        self.encoder.send_eof()?;
        // The muxer rewrote the stream time base to its track timescale
        // (1/10240) during header writing. Rescale packets from the encoder
        // time base (1/fps) into the stream time base exactly like the ffmpeg
        // CLI does, instead of relying on muxer-side rescale behavior.
        let stream_time_base = self
            .output
            .stream(0)
            .context("AVIF output has no stream")?
            .time_base();
        let mut packet = ffmpeg::Packet::empty();
        while self.encoder.receive_packet(&mut packet).is_ok() {
            packet.set_stream(0);
            // The encoder leaves packet duration zero; the ffmpeg CLI patches
            // it from the frame duration (one tick per CFR frame). Do the same
            // so the track duration covers all 30 frames.
            packet.set_duration(1);
            packet.rescale_ts(self.time_base, stream_time_base);
            packet.set_time_base(stream_time_base);
            packet
                .write_interleaved(&mut self.output)
                .context("writing AVIF packet")?;
        }
        self.output.write_trailer().context("writing AVIF trailer")?;
        Ok(())
    }

    fn feed(&mut self, grid: &RgbImage, pts: i64) -> anyhow::Result<()> {
        ensure!(
            grid.width() == self.width && grid.height() == self.height,
            "in-process AVIF encoder received a {}x{} grid, expected {}x{}",
            grid.width(),
            grid.height(),
            self.width,
            self.height
        );
        let mut rgb = Video::new(ffmpeg::format::Pixel::RGB24, self.width, self.height);
        let row = self.width as usize * 3;
        let stride = rgb.stride(0);
        let raw = grid.as_raw();
        for y in 0..self.height as usize {
            rgb.data_mut(0)[y * stride..y * stride + row]
                .copy_from_slice(&raw[y * row..(y + 1) * row]);
        }
        let mut yuv = Video::new(ffmpeg::format::Pixel::YUV420P10LE, self.width, self.height);
        // The CLI's auto_scale_0 emits tv-range frames into libsvtav1.
        yuv.set_color_range(ffmpeg::color::Range::MPEG);
        self.converter.run(&rgb, &mut yuv)?;
        yuv.set_pts(Some(pts));
        // One tick per frame in the encoder time base, like the CLI filter
        // chain emits; the encoder propagates it to the packet duration.
        unsafe { (*yuv.as_mut_ptr()).duration = 1 };
        self.encoder.send_frame(&yuv)?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;

    fn grid(frame: u32) -> RgbImage {
        RgbImage::from_fn(64, 64, |x, y| {
            let v = ((x + y + frame * 7) % 256) as u8;
            image::Rgb([v, v.wrapping_mul(2), v.wrapping_mul(3)])
        })
    }

    fn temp_output(name: &str) -> PathBuf {
        std::env::temp_dir().join(format!(
            "vimg-encode-test-{name}-{}.avif",
            std::process::id()
        ))
    }

    #[test]
    fn rejects_a_non_integer_frame_rate() {
        let path = temp_output("fps");
        let error = InProcessAvifEncoder::start(&path, 64, 64, 23.976, 30, 8)
            .unwrap_err()
            .to_string();
        assert!(
            error.contains("integer frame rate"),
            "unexpected error: {error}"
        );
        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn round_trip_writes_a_30_frame_avif_with_the_preview_timeline() {
        let path = temp_output("roundtrip");
        let mut encoder = InProcessAvifEncoder::start(&path, 64, 64, 20.0, 30, 8).unwrap();
        for frame in 0..30 {
            encoder.write_grid(&grid(frame)).unwrap();
        }
        encoder.finish().unwrap();

        let mut input = ffmpeg::format::input(&path).expect("reopening the encoded AVIF");
        let stream = input.streams().next().expect("one video stream");
        assert_eq!(stream.parameters().medium(), ffmpeg::media::Type::Video);
        assert_eq!(stream.parameters().id(), ffmpeg::codec::Id::AV1);
        let (width, height) = unsafe {
            let parameters = stream.parameters().as_ptr();
            ((*parameters).width, (*parameters).height)
        };
        assert_eq!((width, height), (64, 64));
        // 30 frames at 20fps = 1.5s in the demuxer's time base.
        assert_eq!(input.duration(), 1_500_000);

        // The AVIF demuxer reports its own stream time base (1/1) and image-
        // sequence frame counts, so verify the muxer recipe against the
        // container boxes directly: mdhd timescale 10240 (20 doubled until
        // >= 10000, matching the CLI) and stsz entry count 30.
        let bytes = std::fs::read(&path).expect("reading the encoded AVIF");
        let mdhd = bytes
            .windows(4)
            .position(|window| window == b"mdhd")
            .expect("mdhd box");
        // version/flags (4) + creation/modification (8 for v0, 16 for v1) +
        // timescale (4).
        let version = bytes[mdhd + 4];
        let timescale_offset = mdhd + 4 + 4 + if version == 1 { 16 } else { 8 };
        let timescale = u32::from_be_bytes(
            bytes[timescale_offset..timescale_offset + 4]
                .try_into()
                .expect("timescale bytes"),
        );
        assert_eq!(timescale, 10_240);
        let stsz = bytes
            .windows(4)
            .position(|window| window == b"stsz")
            .expect("stsz box");
        // version/flags (4) + sample_size (4) + sample_count (4).
        let sample_count = u32::from_be_bytes(
            bytes[stsz + 12..stsz + 16]
                .try_into()
                .expect("sample count bytes"),
        );
        assert_eq!(sample_count, 30);

        let _ = std::fs::remove_file(&path);
    }
}
