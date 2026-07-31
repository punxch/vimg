//! Optional software libav Capture backend for the fixed Preview profile.

use crate::command::frame_schedule::SourceFrame;
use crate::command::{
    CaptureAttempt, CaptureAuthority, CaptureCompletion, CaptureDiagnostics, CaptureFrame,
    CaptureMetrics, CapturePlan, SourceSelection, extract::Semaphore,
};
use anyhow::{Context, ensure};
use ffmpeg::codec::{discard::Discard, threading};
use ffmpeg::filter;
use ffmpeg::media::Type as MediaType;
use ffmpeg::util::frame::video::Video;
use ffmpeg_next as ffmpeg;
use image::RgbImage;
use std::{
    collections::HashMap,
    sync::{
        Arc, Mutex,
        atomic::{AtomicBool, Ordering},
        mpsc::{Receiver, SyncSender, sync_channel},
    },
    thread::{self, JoinHandle},
};

const NONREF_RECOVERY_MARGIN_S: f64 = 0.25;
const DECODER_THREADS: usize = 3;
type AuthorityRecords = Arc<Mutex<Vec<Option<Vec<SourceSelection>>>>>;

pub(super) fn start(
    plan: &CapturePlan,
    authority: bool,
) -> anyhow::Result<Box<dyn CaptureAttempt>> {
    ffmpeg::init().context("initializing software libav")?;

    // NOTE: Capture-point concurrency limiting for in-process backends requires
    // per-frame semaphore gating inside `emit_scheduled_frames`. The plan-level
    // `concurrency` value is stored but not yet enforced here; all capture
    // workers run concurrently.
    let _ = plan.concurrency();

    // Limit the number of concurrently decoding capture workers to the
    // effective capture-point concurrency (-T). 9 workers × 3 decoder threads
    // saturates the CPU; gating keeps per-worker decode throughput high.
    // `recv` polls every channel so waiting workers cannot deadlock behind
    // full bounded channels (each worker releases its permit once its frames
    // have been drained).
    let mut receivers = Vec::with_capacity(plan.capture_count());
    let mut workers = Vec::with_capacity(plan.capture_count());
    let cancelled = Arc::new(AtomicBool::new(false));
    let records = authority.then(|| Arc::new(Mutex::new(vec![None; plan.capture_count()])));
    let semaphore = Arc::new(Semaphore::new(plan.concurrency().max(1)));
    for (window, schedule) in plan
        .windows()
        .iter()
        .copied()
        .zip(plan.schedules().iter().cloned())
    {
        let (sender, receiver) = sync_channel(2);
        receivers.push(receiver);
        let video = plan.video().to_owned();
        let dimensions = plan.frame_dimensions();
        let records = records.clone();
        let cancelled = Arc::clone(&cancelled);
        let semaphore = Arc::clone(&semaphore);
        workers.push(thread::spawn(move || {
            let _permit = semaphore.acquire();
            let result = decode_capture(DecodeRequest {
                video: &video,
                capture_index: window.capture_index(),
                start_s: window.start_s(),
                dimensions,
                schedule,
                sender: &sender,
                records,
                cancelled: &cancelled,
            });
            if let Err(error) = &result {
                let _ = sender.send(Err(anyhow::anyhow!("libav capture failed: {error:#}")));
            }
            result
        }));
    }
    Ok(Box::new(LibavCaptureAttempt {
        receivers: Mutex::new(receivers),
        next: Mutex::new(0),
        capture_count: plan.capture_count(),
        workers,
        records,
        cancelled,
    }))
}

pub(super) fn availability(plan: &CapturePlan) -> anyhow::Result<()> {
    plan.ensure_in_process_preview_profile(crate::command::CaptureBackendPolicy::Libav)
}

struct LibavCaptureAttempt {
    receivers: Mutex<Vec<Receiver<anyhow::Result<CaptureFrame>>>>,
    next: Mutex<usize>,
    capture_count: usize,
    workers: Vec<JoinHandle<anyhow::Result<CaptureMetrics>>>,
    records: Option<AuthorityRecords>,
    cancelled: Arc<AtomicBool>,
}

impl CaptureAttempt for LibavCaptureAttempt {
    fn recv(&self) -> anyhow::Result<CaptureFrame> {
        let mut next = self.next.lock().unwrap();
        loop {
            let mut any_connected = false;
            {
                let receivers = self.receivers.lock().unwrap();
                for offset in 0..self.capture_count {
                    let capture_index = (*next + offset) % self.capture_count;
                    match receivers[capture_index].try_recv() {
                        Ok(frame) => {
                            *next += 1;
                            return frame;
                        }
                        Err(std::sync::mpsc::TryRecvError::Empty) => {
                            any_connected = true;
                        }
                        // A worker that has produced all its frames drops its
                        // sender; skip it and keep polling the others.
                        Err(std::sync::mpsc::TryRecvError::Disconnected) => {}
                    }
                }
            }
            if !any_connected {
                return Err(anyhow::anyhow!(
                    "libav capture stream ended before all frames were produced"
                ));
            }
            // Some channels are empty (workers gated on the concurrency
            // semaphore or still decoding). Yield and retry.
            std::thread::yield_now();
        }
    }

    fn finish(mut self: Box<Self>) -> anyhow::Result<CaptureCompletion> {
        self.receivers.get_mut().unwrap().clear();
        let workers = std::mem::take(&mut self.workers);
        let records = self.records.take();
        let mut worker_error = None;
        let mut metrics = CaptureMetrics::default();
        for worker in workers {
            let result = worker
                .join()
                .map_err(|_| anyhow::anyhow!("libav decoder worker panicked"))
                .and_then(|result| result);
            match result {
                Ok(worker_metrics) => metrics.include_worker(worker_metrics),
                Err(error) if worker_error.is_none() => worker_error = Some(error),
                Err(_) => {}
            }
        }
        if let Some(error) = worker_error {
            return Err(error);
        }
        let authority = records
            .map(|records| {
                Arc::try_unwrap(records)
                    .map_err(|_| {
                        anyhow::anyhow!(
                            "libav decoder records remained shared after worker completion"
                        )
                    })?
                    .into_inner()
                    .unwrap()
                    .into_iter()
                    .enumerate()
                    .map(|(capture_index, frames)| {
                        Ok(CaptureAuthority {
                            capture_index,
                            frames: frames
                                .context("libav decoder produced no source PTS record")?,
                        })
                    })
                    .collect::<anyhow::Result<Vec<_>>>()
            })
            .transpose()?
            .unwrap_or_default();
        Ok(CaptureCompletion {
            authority,
            diagnostics: CaptureDiagnostics {
                backend: "libav",
                availability: std::time::Duration::ZERO,
                setup: std::time::Duration::ZERO,
                metrics,
            },
        })
    }
}

impl Drop for LibavCaptureAttempt {
    fn drop(&mut self) {
        self.cancelled.store(true, Ordering::Release);
        self.receivers.get_mut().unwrap().clear();
        for worker in self.workers.drain(..) {
            let _ = worker.join();
        }
    }
}

struct DecodeRequest<'a> {
    video: &'a std::path::Path,
    capture_index: usize,
    start_s: f32,
    dimensions: (u32, u32),
    schedule: crate::command::frame_schedule::FrameSchedule,
    sender: &'a SyncSender<anyhow::Result<CaptureFrame>>,
    records: Option<AuthorityRecords>,
    cancelled: &'a AtomicBool,
}

fn decode_capture(request: DecodeRequest<'_>) -> anyhow::Result<CaptureMetrics> {
    let started = std::time::Instant::now();
    let DecodeRequest {
        video,
        capture_index,
        start_s,
        dimensions,
        mut schedule,
        sender,
        records,
        cancelled,
    } = request;
    let mut input = ffmpeg::format::input(video)
        .with_context(|| format!("opening input {}", video.display()))?;
    let stream = input
        .streams()
        .best(MediaType::Video)
        .context("libav capture is unavailable: input has no video stream")?;
    let codec_id = stream.parameters().id();
    ensure!(
        matches!(codec_id, ffmpeg::codec::Id::H264 | ffmpeg::codec::Id::HEVC),
        "libav capture is unavailable: only H.264 and HEVC are supported"
    );
    let stream_index = stream.index();
    let time_base = stream.time_base();
    let source_time_base = crate::command::frame_schedule::Rational::new(
        time_base.numerator(),
        time_base.denominator(),
    );
    ensure!(
        source_time_base == schedule.source_time_base(),
        "libav capture is unavailable: planned and decoded source time bases differ"
    );
    let parameters = stream.parameters();
    let mut context = ffmpeg::codec::context::Context::from_parameters(parameters)?;
    context.set_threading(threading::Config {
        kind: threading::Type::Frame,
        count: DECODER_THREADS,
    });
    let mut decoder = context
        .decoder()
        .video()
        .context("libav capture is unavailable: video decoder is unsupported")?;
    let mut scaler = production_scale_filter(&decoder, dimensions, time_base)?;
    decoder.skip_frame(Discard::NonReference);
    let target = (f64::from(start_s) * ffmpeg::ffi::AV_TIME_BASE as f64).round() as i64;
    input
        .seek(target, ..target)
        .context("libav capture seek failed")?;
    decoder.flush();

    let mut decoded = Video::empty();
    let mut rgb = Video::empty();
    let mut input_frame_index = 0_i64;
    let mut previous_decoded = None;
    let mut pending_decoded = None;
    let mut last_duration = None;
    let mut packet_durations = HashMap::new();
    let mut nonref = true;
    let mut selected = Vec::new();
    let mut metrics = CaptureMetrics::default();
    for (packet_stream, packet) in input.packets() {
        ensure!(
            !cancelled.load(Ordering::Acquire),
            "libav capture cancelled"
        );
        if packet_stream.index() != stream_index {
            continue;
        }
        if let Some(pts) = packet.pts()
            && packet.duration() > 0
        {
            packet_durations.insert(pts, packet.duration());
        }
        if nonref
            && packet.dts().or_else(|| packet.pts()).is_some_and(|pts| {
                pts as f64 * f64::from(time_base) >= f64::from(start_s) - NONREF_RECOVERY_MARGIN_S
            })
        {
            decoder.skip_frame(Discard::Default);
            nonref = false;
        }
        decoder.send_packet(&packet)?;
        receive_frames(
            &mut decoder,
            &mut scaler,
            &mut decoded,
            &mut rgb,
            &mut schedule,
            source_time_base,
            sender,
            &mut input_frame_index,
            &mut previous_decoded,
            &mut pending_decoded,
            &mut last_duration,
            &packet_durations,
            &mut selected,
            &mut metrics,
        )?;
        if schedule.is_complete() {
            break;
        }
    }
    if !schedule.is_complete() {
        decoder.send_eof()?;
        receive_frames(
            &mut decoder,
            &mut scaler,
            &mut decoded,
            &mut rgb,
            &mut schedule,
            source_time_base,
            sender,
            &mut input_frame_index,
            &mut previous_decoded,
            &mut pending_decoded,
            &mut last_duration,
            &packet_durations,
            &mut selected,
            &mut metrics,
        )?;
    }
    if !schedule.is_complete() {
        let pending =
            pending_decoded.context("libav decoder produced no timestamped source frame")?;
        let duration = last_duration.context("libav decoder produced no source-frame duration")?;
        emit_scheduled_frames(
            pending,
            duration,
            &mut scaler,
            &mut rgb,
            &mut schedule,
            source_time_base,
            sender,
            &mut previous_decoded,
            &mut selected,
        )?;
    }
    ensure!(
        schedule.is_complete(),
        "libav capture ended before its 30 planned frames"
    );
    if let Some(records) = records {
        ensure!(
            !selected.is_empty(),
            "libav decoder produced no selected frames"
        );
        records.lock().unwrap()[capture_index] = Some(selected);
    }
    metrics.decode = started.elapsed();
    Ok(metrics)
}

#[allow(clippy::too_many_arguments)]
fn receive_frames(
    decoder: &mut ffmpeg::decoder::Video,
    scaler: &mut filter::Graph,
    decoded: &mut Video,
    rgb: &mut Video,
    schedule: &mut crate::command::frame_schedule::FrameSchedule,
    source_time_base: crate::command::frame_schedule::Rational,
    sender: &SyncSender<anyhow::Result<CaptureFrame>>,
    input_frame_index: &mut i64,
    previous_decoded: &mut Option<Video>,
    pending_decoded: &mut Option<PendingDecoded>,
    last_duration: &mut Option<i64>,
    packet_durations: &HashMap<i64, i64>,
    selected: &mut Vec<SourceSelection>,
    metrics: &mut CaptureMetrics,
) -> anyhow::Result<()> {
    while decoder.receive_frame(decoded).is_ok() {
        metrics.decoded_frames += 1;
        let pts = decoded
            .timestamp()
            .or_else(|| decoded.pts())
            .context("libav capture is unavailable: decoded frame has no timestamp")?;
        let current = PendingDecoded {
            image: decoded.clone(),
            pts,
            input_frame_index: *input_frame_index,
            duration: packet_durations.get(&pts).copied(),
        };
        *input_frame_index += 1;
        // FFmpeg's input-side `-ss` begins the CFR filter at the first decoded
        // source timestamp at or after the planned start. libav seeking may expose
        // a few earlier display frames, which must remain preroll only.
        if current.pts < schedule.source_pts_offset() {
            metrics.preroll_frames += 1;
            continue;
        }
        if let Some(pending) = pending_decoded.take() {
            let duration = pending.duration.unwrap_or(current.pts - pending.pts);
            ensure!(
                duration > 0,
                "libav decoder produced non-monotonic source timestamps"
            );
            *last_duration = Some(duration);
            emit_scheduled_frames(
                pending,
                duration,
                scaler,
                rgb,
                schedule,
                source_time_base,
                sender,
                previous_decoded,
                selected,
            )?;
        }
        *pending_decoded = Some(current);
    }
    Ok(())
}

struct PendingDecoded {
    image: Video,
    pts: i64,
    input_frame_index: i64,
    duration: Option<i64>,
}

#[allow(clippy::too_many_arguments)]
fn emit_scheduled_frames(
    current: PendingDecoded,
    duration: i64,
    scaler: &mut filter::Graph,
    rgb: &mut Video,
    schedule: &mut crate::command::frame_schedule::FrameSchedule,
    source_time_base: crate::command::frame_schedule::Rational,
    sender: &SyncSender<anyhow::Result<CaptureFrame>>,
    previous_decoded: &mut Option<Video>,
    selected: &mut Vec<SourceSelection>,
) -> anyhow::Result<()> {
    let scheduled = schedule.push(SourceFrame {
        input_frame_index: current.input_frame_index,
        pts: current.pts,
        duration,
    })?;
    for frame in scheduled {
        let source = if frame.input_frame_index == current.input_frame_index {
            &current.image
        } else {
            previous_decoded.as_ref().context(
                "libav frame schedule selected a previous source frame that was not retained",
            )?
        };
        scaler
            .get("in")
            .context("libav scale filter has no input")?
            .source()
            // av_buffersrc_add_frame may take ownership of the supplied frame;
            // retain our decoded reference because CFR can select it again.
            .add(&source.clone())?;
        scaler
            .get("out")
            .context("libav scale filter has no output")?
            .sink()
            .frame(rgb)?;
        let image = copy_rgb(rgb)?;
        selected.push(SourceSelection {
            source_pts: frame.source_pts,
            source_time_base: format!(
                "{}/{}",
                source_time_base.numerator, source_time_base.denominator
            ),
            input_frame_index: frame.input_frame_index,
        });
        sender
            .send(Ok(CaptureFrame {
                capture_index: frame.capture_index,
                animation_index: frame.animation_index,
                image,
            }))
            .context("libav frame consumer stopped")?;
    }
    *previous_decoded = Some(current.image);
    Ok(())
}

fn production_scale_filter(
    decoder: &ffmpeg::decoder::Video,
    dimensions: (u32, u32),
    time_base: ffmpeg::Rational,
) -> anyhow::Result<filter::Graph> {
    let mut graph = filter::Graph::new();
    let args = format!(
        "video_size={}x{}:pix_fmt={}:time_base={}:pixel_aspect=1/1",
        decoder.width(),
        decoder.height(),
        decoder
            .format()
            .descriptor()
            .context("libav capture is unavailable: decoder pixel format is unsupported")?
            .name(),
        time_base,
    );
    graph.add(
        &filter::find("buffer").context("libav scale filter is unavailable")?,
        "in",
        &args,
    )?;
    graph.add(
        &filter::find("buffersink").context("libav scale filter is unavailable")?,
        "out",
        "",
    )?;
    graph.output("in", 0)?.input("out", 0)?.parse(&format!(
        "scale=-1:{}:flags=bicubic,format=rgb24",
        dimensions.1
    ))?;
    graph.validate()?;
    Ok(graph)
}

fn copy_rgb(frame: &Video) -> anyhow::Result<RgbImage> {
    let width = frame.width() as usize;
    let height = frame.height() as usize;
    let row = width * 3;
    let stride = frame.stride(0);
    ensure!(stride >= row, "libav capture emitted an invalid RGB stride");
    let mut raw = vec![0; row * height];
    for index in 0..height {
        raw[index * row..(index + 1) * row]
            .copy_from_slice(&frame.data(0)[index * stride..index * stride + row]);
    }
    RgbImage::from_raw(width as u32, height as u32, raw)
        .context("libav capture emitted an invalid RGB frame")
}
