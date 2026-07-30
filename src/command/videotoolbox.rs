//! macOS VideoToolbox Capture backend for the fixed Preview profile.
//!
//! Each capture owns its demuxer and decoder context, while all contexts retain
//! a reference to one process-wide VideoToolbox device. Decoded frames remain
//! on the hardware surface until the shared schedule selects them.

use crate::command::frame_schedule::SourceFrame;
use crate::command::{
    CaptureAttempt, CaptureAuthority, CaptureBackendPolicy, CaptureCompletion, CaptureDiagnostics,
    CaptureFrame, CapturePlan, SourceSelection,
};
use anyhow::{Context, ensure};
use ffmpeg::codec::{discard::Discard, threading};
use ffmpeg::format::Pixel;
use ffmpeg::media::Type as MediaType;
use ffmpeg::software::scaling::{context::Context as ScalingContext, flag::Flags};
use ffmpeg::util::frame::video::Video;
use ffmpeg_next as ffmpeg;
use image::RgbImage;
use std::{
    collections::HashMap,
    ptr,
    sync::{
        Arc, Mutex, OnceLock,
        atomic::{AtomicBool, Ordering},
        mpsc::{Receiver, SyncSender, sync_channel},
    },
    thread::{self, JoinHandle},
};

const NONREF_RECOVERY_MARGIN_S: f64 = 0.5;
const DECODER_THREADS: usize = 1;
type AuthorityRecords = Arc<Mutex<Vec<Option<Vec<SourceSelection>>>>>;

pub(super) fn availability(plan: &CapturePlan) -> anyhow::Result<()> {
    plan.ensure_in_process_preview_profile(CaptureBackendPolicy::VideoToolbox)?;
    ffmpeg::init().context("initializing VideoToolbox libav support")?;
    let codec = decoder_for_media_codec(&plan.media().codec)?;
    ensure_videotoolbox_support(codec)
}

pub(super) fn start(
    plan: &CapturePlan,
    authority: bool,
) -> anyhow::Result<Box<dyn CaptureAttempt>> {
    ffmpeg::init().context("initializing VideoToolbox libav support")?;
    let device = shared_device()?;

    let mut receivers = Vec::with_capacity(plan.capture_count());
    let mut workers = Vec::with_capacity(plan.capture_count());
    let cancelled = Arc::new(AtomicBool::new(false));
    let records = authority.then(|| Arc::new(Mutex::new(vec![None; plan.capture_count()])));
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
        let device = Arc::clone(&device);
        workers.push(thread::spawn(move || {
            let result = decode_capture(DecodeRequest {
                video: &video,
                capture_index: window.capture_index(),
                start_s: window.start_s(),
                dimensions,
                schedule,
                sender: &sender,
                records,
                cancelled: &cancelled,
                device: &device,
            });
            if let Err(error) = &result {
                let _ = sender.send(Err(anyhow::anyhow!(
                    "videotoolbox capture failed: {error:#}"
                )));
            }
            result
        }));
    }
    Ok(Box::new(VideoToolboxCaptureAttempt {
        receivers: Mutex::new(receivers),
        next: Mutex::new(0),
        capture_count: plan.capture_count(),
        workers,
        records,
        cancelled,
    }))
}

struct VideoToolboxCaptureAttempt {
    receivers: Mutex<Vec<Receiver<anyhow::Result<CaptureFrame>>>>,
    next: Mutex<usize>,
    capture_count: usize,
    workers: Vec<JoinHandle<anyhow::Result<()>>>,
    records: Option<AuthorityRecords>,
    cancelled: Arc<AtomicBool>,
}

impl CaptureAttempt for VideoToolboxCaptureAttempt {
    fn recv(&self) -> anyhow::Result<CaptureFrame> {
        let capture_index = {
            let mut next = self.next.lock().unwrap();
            let capture_index = *next % self.capture_count;
            *next += 1;
            capture_index
        };
        self.receivers.lock().unwrap()[capture_index]
            .recv()
            .context("videotoolbox capture stream ended before all frames were produced")?
    }

    fn finish(mut self: Box<Self>) -> anyhow::Result<CaptureCompletion> {
        self.receivers.get_mut().unwrap().clear();
        let workers = std::mem::take(&mut self.workers);
        let records = self.records.take();
        let mut worker_error = None;
        for worker in workers {
            let result = worker
                .join()
                .map_err(|_| anyhow::anyhow!("videotoolbox decoder worker panicked"))
                .and_then(|result| result);
            if worker_error.is_none() {
                worker_error = result.err();
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
                            "videotoolbox decoder records remained shared after worker completion"
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
                                .context("videotoolbox decoder produced no source PTS record")?,
                        })
                    })
                    .collect::<anyhow::Result<Vec<_>>>()
            })
            .transpose()?
            .unwrap_or_default();
        Ok(CaptureCompletion {
            authority,
            diagnostics: CaptureDiagnostics {
                backend: "videotoolbox",
            },
        })
    }
}

impl Drop for VideoToolboxCaptureAttempt {
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
    device: &'a VideoToolboxDevice,
}

fn decode_capture(request: DecodeRequest<'_>) -> anyhow::Result<()> {
    let DecodeRequest {
        video,
        capture_index,
        start_s,
        dimensions,
        mut schedule,
        sender,
        records,
        cancelled,
        device,
    } = request;
    let mut input = ffmpeg::format::input(video)
        .with_context(|| format!("videotoolbox opening input {}", video.display()))?;
    let stream = input
        .streams()
        .best(MediaType::Video)
        .context("videotoolbox decode unavailable: input has no video stream")?;
    let codec_id = stream.parameters().id();
    ensure!(
        matches!(codec_id, ffmpeg::codec::Id::H264 | ffmpeg::codec::Id::HEVC),
        "videotoolbox decode unavailable: only H.264 and HEVC are supported"
    );
    let stream_index = stream.index();
    let time_base = stream.time_base();
    let source_time_base = crate::command::frame_schedule::Rational::new(
        time_base.numerator(),
        time_base.denominator(),
    );
    ensure!(
        source_time_base == schedule.source_time_base(),
        "videotoolbox decode unavailable: planned and decoded source time bases differ"
    );
    let parameters = stream.parameters();
    let mut context = ffmpeg::codec::context::Context::from_parameters(parameters)?;
    context.set_threading(threading::Config {
        kind: threading::Type::Frame,
        count: DECODER_THREADS,
    });
    let codec = ffmpeg::decoder::find(context.id())
        .context("videotoolbox setup unavailable: video decoder is unsupported")?;
    ensure_videotoolbox_support(codec)?;
    unsafe {
        let context = context.as_mut_ptr();
        (*context).get_format = Some(select_videotoolbox_format);
        (*context).hw_device_ctx = device.new_reference()?;
    }
    let mut decoder = context
        .decoder()
        .open_as(codec)
        .context("videotoolbox setup failed while opening hardware decoder")?
        .video()
        .context("videotoolbox setup unavailable: hardware decoder is not video")?;
    decoder.skip_frame(Discard::NonReference);
    let target = (f64::from(start_s) * ffmpeg::ffi::AV_TIME_BASE as f64).round() as i64;
    input
        .seek(target, ..target)
        .context("videotoolbox seek failed")?;
    decoder.flush();

    let mut decoded = Video::empty();
    let mut scaler = None;
    let mut software = Video::empty();
    let mut rgb = Video::empty();
    let mut input_frame_index = 0_i64;
    let mut previous_decoded = None;
    let mut pending_decoded = None;
    let mut last_duration = None;
    let mut packet_durations = HashMap::new();
    let mut nonref = true;
    let mut selected = Vec::new();
    for (packet_stream, packet) in input.packets() {
        ensure!(
            !cancelled.load(Ordering::Acquire),
            "videotoolbox capture cancelled"
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
        decoder
            .send_packet(&packet)
            .context("videotoolbox decode failed while submitting packet")?;
        receive_frames(
            &mut decoder,
            &mut decoded,
            &mut scaler,
            &mut software,
            &mut rgb,
            dimensions,
            &mut schedule,
            source_time_base,
            sender,
            &mut input_frame_index,
            &mut previous_decoded,
            &mut pending_decoded,
            &mut last_duration,
            &packet_durations,
            &mut selected,
        )?;
        if schedule.is_complete() {
            break;
        }
    }
    if !schedule.is_complete() {
        decoder
            .send_eof()
            .context("videotoolbox decode failed while flushing")?;
        receive_frames(
            &mut decoder,
            &mut decoded,
            &mut scaler,
            &mut software,
            &mut rgb,
            dimensions,
            &mut schedule,
            source_time_base,
            sender,
            &mut input_frame_index,
            &mut previous_decoded,
            &mut pending_decoded,
            &mut last_duration,
            &packet_durations,
            &mut selected,
        )?;
    }
    if !schedule.is_complete() {
        let pending =
            pending_decoded.context("videotoolbox decoder produced no timestamped source frame")?;
        let duration =
            last_duration.context("videotoolbox decoder produced no source-frame duration")?;
        emit_scheduled_frames(
            pending,
            duration,
            &mut scaler,
            &mut software,
            &mut rgb,
            dimensions,
            &mut schedule,
            source_time_base,
            sender,
            &mut previous_decoded,
            &mut selected,
        )?;
    }
    ensure!(
        schedule.is_complete(),
        "videotoolbox decode ended before its 30 planned frames"
    );
    if let Some(records) = records {
        ensure!(
            !selected.is_empty(),
            "videotoolbox decoder produced no selected frames"
        );
        records.lock().unwrap()[capture_index] = Some(selected);
    }
    Ok(())
}

#[allow(clippy::too_many_arguments)]
fn receive_frames(
    decoder: &mut ffmpeg::decoder::Video,
    decoded: &mut Video,
    scaler: &mut Option<ScalingContext>,
    software: &mut Video,
    rgb: &mut Video,
    dimensions: (u32, u32),
    schedule: &mut crate::command::frame_schedule::FrameSchedule,
    source_time_base: crate::command::frame_schedule::Rational,
    sender: &SyncSender<anyhow::Result<CaptureFrame>>,
    input_frame_index: &mut i64,
    previous_decoded: &mut Option<Video>,
    pending_decoded: &mut Option<PendingDecoded>,
    last_duration: &mut Option<i64>,
    packet_durations: &HashMap<i64, i64>,
    selected: &mut Vec<SourceSelection>,
) -> anyhow::Result<()> {
    while decoder.receive_frame(decoded).is_ok() {
        ensure!(
            decoded.format() == Pixel::VIDEOTOOLBOX,
            "videotoolbox decode fell back to software pixel format {:?}",
            decoded.format()
        );
        let pts = decoded
            .timestamp()
            .or_else(|| decoded.pts())
            .context("videotoolbox decode unavailable: decoded frame has no timestamp")?;
        let current = PendingDecoded {
            image: decoded.clone(),
            pts,
            input_frame_index: *input_frame_index,
            duration: packet_durations.get(&pts).copied(),
        };
        *input_frame_index += 1;
        if current.pts < schedule.source_pts_offset() {
            continue;
        }
        if let Some(pending) = pending_decoded.take() {
            let duration = pending.duration.unwrap_or(current.pts - pending.pts);
            ensure!(
                duration > 0,
                "videotoolbox decoder produced non-monotonic source timestamps"
            );
            *last_duration = Some(duration);
            emit_scheduled_frames(
                pending,
                duration,
                scaler,
                software,
                rgb,
                dimensions,
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
    scaler: &mut Option<ScalingContext>,
    software: &mut Video,
    rgb: &mut Video,
    dimensions: (u32, u32),
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
                "videotoolbox frame schedule selected a previous source frame that was not retained",
            )?
        };
        let image = transfer_and_scale(source, scaler, software, rgb, dimensions)?;
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
            .context("videotoolbox frame consumer stopped")?;
    }
    *previous_decoded = Some(current.image);
    Ok(())
}

fn transfer_and_scale(
    source: &Video,
    scaler: &mut Option<ScalingContext>,
    software: &mut Video,
    rgb: &mut Video,
    dimensions: (u32, u32),
) -> anyhow::Result<RgbImage> {
    ensure!(
        source.format() == Pixel::VIDEOTOOLBOX,
        "videotoolbox transfer received a non-hardware source frame"
    );
    unsafe {
        ffmpeg::ffi::av_frame_unref(software.as_mut_ptr());
    }
    let result =
        unsafe { ffmpeg::ffi::av_hwframe_transfer_data(software.as_mut_ptr(), source.as_ptr(), 0) };
    ensure!(
        result >= 0,
        "videotoolbox transfer failed: {}",
        ffmpeg::Error::from(result)
    );
    if scaler.is_none() {
        *scaler = Some(
            ScalingContext::get(
                software.format(),
                software.width(),
                software.height(),
                Pixel::RGB24,
                dimensions.0,
                dimensions.1,
                Flags::BICUBIC,
            )
            .context("videotoolbox transfer failed while creating RGB scaler")?,
        );
    }
    scaler
        .as_mut()
        .expect("scaler was initialized above")
        .run(software, rgb)
        .context("videotoolbox transfer failed while scaling RGB frame")?;
    copy_rgb(rgb)
}

fn copy_rgb(frame: &Video) -> anyhow::Result<RgbImage> {
    let width = frame.width() as usize;
    let height = frame.height() as usize;
    let row = width * 3;
    let stride = frame.stride(0);
    ensure!(
        stride >= row,
        "videotoolbox transfer emitted an invalid RGB stride"
    );
    let mut raw = vec![0; row * height];
    for index in 0..height {
        raw[index * row..(index + 1) * row]
            .copy_from_slice(&frame.data(0)[index * stride..index * stride + row]);
    }
    RgbImage::from_raw(width as u32, height as u32, raw)
        .context("videotoolbox transfer emitted an invalid RGB frame")
}

fn decoder_for_media_codec(codec: &str) -> anyhow::Result<ffmpeg::Codec> {
    let id = match codec {
        "h264" => ffmpeg::codec::Id::H264,
        "hevc" => ffmpeg::codec::Id::HEVC,
        _ => anyhow::bail!(
            "Capture backend videotoolbox is unavailable: only H.264 and HEVC are supported (found {codec})"
        ),
    };
    ffmpeg::decoder::find(id)
        .with_context(|| format!("VideoToolbox decoder for {codec} is unavailable"))
}

fn ensure_videotoolbox_support(codec: ffmpeg::Codec) -> anyhow::Result<()> {
    for index in 0.. {
        let config = unsafe { ffmpeg::ffi::avcodec_get_hw_config(codec.as_ptr(), index) };
        if config.is_null() {
            break;
        }
        let config = unsafe { &*config };
        if config.device_type == ffmpeg::ffi::AVHWDeviceType::AV_HWDEVICE_TYPE_VIDEOTOOLBOX
            && config.methods & ffmpeg::ffi::AV_CODEC_HW_CONFIG_METHOD_HW_DEVICE_CTX as i32 != 0
            && config.pix_fmt == ffmpeg::ffi::AVPixelFormat::AV_PIX_FMT_VIDEOTOOLBOX
        {
            return Ok(());
        }
    }
    anyhow::bail!(
        "VideoToolbox decoder {} does not expose hardware device support",
        codec.name()
    )
}

unsafe extern "C" fn select_videotoolbox_format(
    _context: *mut ffmpeg::ffi::AVCodecContext,
    formats: *const ffmpeg::ffi::AVPixelFormat,
) -> ffmpeg::ffi::AVPixelFormat {
    if formats.is_null() {
        return ffmpeg::ffi::AVPixelFormat::AV_PIX_FMT_NONE;
    }
    let mut format = formats;
    loop {
        let value = unsafe { *format };
        if value == ffmpeg::ffi::AVPixelFormat::AV_PIX_FMT_VIDEOTOOLBOX {
            return value;
        }
        if value == ffmpeg::ffi::AVPixelFormat::AV_PIX_FMT_NONE {
            return value;
        }
        format = unsafe { format.add(1) };
    }
}

struct VideoToolboxDevice {
    reference: *mut ffmpeg::ffi::AVBufferRef,
}

unsafe impl Send for VideoToolboxDevice {}
unsafe impl Sync for VideoToolboxDevice {}

impl VideoToolboxDevice {
    fn new() -> anyhow::Result<Self> {
        let mut reference = ptr::null_mut();
        let result = unsafe {
            ffmpeg::ffi::av_hwdevice_ctx_create(
                &mut reference,
                ffmpeg::ffi::AVHWDeviceType::AV_HWDEVICE_TYPE_VIDEOTOOLBOX,
                ptr::null(),
                ptr::null_mut(),
                0,
            )
        };
        ensure!(
            result >= 0 && !reference.is_null(),
            "creating VideoToolbox device failed: {}",
            ffmpeg::Error::from(result)
        );
        Ok(Self { reference })
    }

    fn new_reference(&self) -> anyhow::Result<*mut ffmpeg::ffi::AVBufferRef> {
        let reference = unsafe { ffmpeg::ffi::av_buffer_ref(self.reference) };
        ensure!(
            !reference.is_null(),
            "referencing VideoToolbox device failed"
        );
        Ok(reference)
    }
}

impl Drop for VideoToolboxDevice {
    fn drop(&mut self) {
        unsafe {
            ffmpeg::ffi::av_buffer_unref(&mut self.reference);
        }
    }
}

fn shared_device() -> anyhow::Result<Arc<VideoToolboxDevice>> {
    static DEVICE: OnceLock<Result<Arc<VideoToolboxDevice>, String>> = OnceLock::new();
    match DEVICE.get_or_init(|| {
        VideoToolboxDevice::new()
            .map(Arc::new)
            .map_err(|error| format!("{error:#}"))
    }) {
        Ok(device) => Ok(Arc::clone(device)),
        Err(error) => anyhow::bail!("creating shared VideoToolbox device failed: {error}"),
    }
}
