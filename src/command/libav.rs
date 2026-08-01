//! Optional software libav Capture backend for the fixed Preview profile.

use crate::command::frame_schedule::SourceFrame;
use crate::command::{
    CaptureAttempt, CaptureAuthority, CaptureCompletion, CaptureDiagnostics, CaptureFrame,
    CaptureMetrics, CapturePlan, SourceSelection,
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
    path::PathBuf,
    sync::{
        Arc, Mutex,
        atomic::{AtomicBool, Ordering},
        mpsc::{Receiver, SyncSender, sync_channel},
    },
    thread::{self, JoinHandle},
    time::Instant,
};

const NONREF_RECOVERY_MARGIN_S: f64 = 0.125;

// ---------------------------------------------------------------------------
// Temporary prototype layer (hwaccel-dt branch): native parser + shared
// hardware device (D3D11VA / D3D12VA / CUDA) with counting probes, thread
// control and RGB/PTS dumps. Inert unless VIMG_PROTO_* env vars are set.
// ---------------------------------------------------------------------------

#[derive(Clone, Copy, Debug, PartialEq)]
enum ProtoHw {
    D3d11Va,
    D3d12Va,
    Cuda,
}

impl ProtoHw {
    const fn device_type(self) -> ffmpeg::ffi::AVHWDeviceType {
        match self {
            ProtoHw::D3d11Va => ffmpeg::ffi::AVHWDeviceType::AV_HWDEVICE_TYPE_D3D11VA,
            ProtoHw::D3d12Va => ffmpeg::ffi::AVHWDeviceType::AV_HWDEVICE_TYPE_D3D12VA,
            ProtoHw::Cuda => ffmpeg::ffi::AVHWDeviceType::AV_HWDEVICE_TYPE_CUDA,
        }
    }

    const fn pixel_format(self) -> i32 {
        match self {
            ProtoHw::D3d11Va => ffmpeg::ffi::AVPixelFormat::AV_PIX_FMT_D3D11 as i32,
            ProtoHw::D3d12Va => ffmpeg::ffi::AVPixelFormat::AV_PIX_FMT_D3D12 as i32,
            ProtoHw::Cuda => ffmpeg::ffi::AVPixelFormat::AV_PIX_FMT_CUDA as i32,
        }
    }

    const fn label(self) -> &'static str {
        match self {
            ProtoHw::D3d11Va => "d3d11va",
            ProtoHw::D3d12Va => "d3d12va",
            ProtoHw::Cuda => "cuda",
        }
    }
}

#[derive(Clone, Debug)]
struct ProtoConfig {
    hwaccel: Option<ProtoHw>,
    probe: bool,
    dump_dir: Option<PathBuf>,
}

impl Default for ProtoConfig {
    fn default() -> Self {
        Self {
            hwaccel: None,
            probe: false,
            dump_dir: None,
        }
    }
}

fn proto_config() -> ProtoConfig {
    let mut config = ProtoConfig::default();
    if let Ok(value) = std::env::var("VIMG_PROTO_HWACCEL") {
        config.hwaccel = Some(match value.to_ascii_lowercase().as_str() {
            "d3d11va" => ProtoHw::D3d11Va,
            "d3d12va" => ProtoHw::D3d12Va,
            "cuda" => ProtoHw::Cuda,
            other => panic!("VIMG_PROTO_HWACCEL must be d3d11va, d3d12va or cuda, got {other}"),
        });
    }
    config.probe = std::env::var("VIMG_PROTO_PROBE").is_ok_and(|value| value == "1");
    config.dump_dir = std::env::var_os("VIMG_PROTO_DUMP_DIR").map(PathBuf::from);
    if config.dump_dir.is_some() {
        config.probe = true;
    }
    config
}

/// Shared hardware device context; each worker takes its own `av_buffer_ref`.
struct ProtoHwDevice(*mut ffmpeg::ffi::AVBufferRef);

unsafe impl Send for ProtoHwDevice {}
unsafe impl Sync for ProtoHwDevice {}

impl Drop for ProtoHwDevice {
    fn drop(&mut self) {
        unsafe { ffmpeg::ffi::av_buffer_unref(&mut self.0) };
    }
}

fn create_hw_device(backend: ProtoHw) -> anyhow::Result<Arc<ProtoHwDevice>> {
    let mut device: *mut ffmpeg::ffi::AVBufferRef = std::ptr::null_mut();
    let name = match backend {
        ProtoHw::Cuda => c"0".as_ptr(),
        ProtoHw::D3d11Va | ProtoHw::D3d12Va => std::ptr::null(),
    };
    let result = unsafe {
        ffmpeg::ffi::av_hwdevice_ctx_create(
            &mut device,
            backend.device_type(),
            name,
            std::ptr::null_mut(),
            0,
        )
    };
    if result < 0 || device.is_null() {
        anyhow::bail!(
            "proto hwaccel {} device creation failed: {}",
            backend.label(),
            ffmpeg::Error::from(result)
        );
    }
    Ok(Arc::new(ProtoHwDevice(device)))
}

thread_local! {
    static PROTO_HW_FORMAT: std::cell::Cell<i32> = const { std::cell::Cell::new(-1) };
}

/// Decoder `get_format` callback: demand the configured hardware pixel format.
/// Returning `AV_PIX_FMT_NONE` (instead of falling back to software) makes the
/// decoder open fail loudly when the hardware path is unavailable.
unsafe extern "C" fn proto_get_format(
    _context: *mut ffmpeg::ffi::AVCodecContext,
    pix_fmts: *const ffmpeg::ffi::AVPixelFormat,
) -> ffmpeg::ffi::AVPixelFormat {
    unsafe {
        let wanted = PROTO_HW_FORMAT.with(std::cell::Cell::get);
        if wanted >= 0 && !pix_fmts.is_null() {
            let mut cursor = pix_fmts;
            while *cursor != ffmpeg::ffi::AVPixelFormat::AV_PIX_FMT_NONE {
                if *cursor as i32 == wanted {
                    return *cursor;
                }
                cursor = cursor.add(1);
            }
        }
        ffmpeg::ffi::AVPixelFormat::AV_PIX_FMT_NONE
    }
}

#[derive(Default)]
struct ProtoCounters {
    packets: usize,
    hw_decoded: usize,
    transfers: usize,
    send_s: f64,
    receive_s: f64,
    emit_s: f64,
}

fn pix_fmt_name(format: ffmpeg::ffi::AVPixelFormat) -> String {
    unsafe {
        let descriptor = ffmpeg::ffi::av_pix_fmt_desc_get(format);
        if descriptor.is_null() {
            return format!("pixfmt:{}", format as i32);
        }
        let name = (*descriptor).name;
        if name.is_null() {
            return format!("pixfmt:{}", format as i32);
        }
        std::ffi::CStr::from_ptr(name).to_string_lossy().into_owned()
    }
}

fn device_type_name(kind: ffmpeg::ffi::AVHWDeviceType) -> String {
    unsafe {
        let name = ffmpeg::ffi::av_hwdevice_get_type_name(kind);
        if name.is_null() {
            "unknown".to_owned()
        } else {
            std::ffi::CStr::from_ptr(name).to_string_lossy().into_owned()
        }
    }
}

/// Pixel format of the software frames produced by `av_hwframe_transfer_data`
/// for this decoder (its hw frames context sw_format).
fn proto_sw_format(decoder: &ffmpeg::decoder::Video) -> Option<String> {
    unsafe {
        let frames = (*decoder.as_ptr()).hw_frames_ctx;
        if frames.is_null() {
            return None;
        }
        let hw_frames = (*frames).data as *mut ffmpeg::ffi::AVHWFramesContext;
        if hw_frames.is_null() {
            return None;
        }
        Some(pix_fmt_name((*hw_frames).sw_format))
    }
}

/// Software frame matching a hardware frame's hw frames context
/// (sw_format/size), pre-allocated for `av_hwframe_transfer_data`. D3D11VA
/// pools are 16-line aligned (1088 for 1080p): allocate at the coded size so
/// the transfer crops the padding rows.
fn hw_sw_frame(hw_frame: &Video) -> Option<Video> {
    unsafe {
        let frames = (*hw_frame.as_ptr()).hw_frames_ctx;
        if frames.is_null() {
            return None;
        }
        let hw_frames = (*frames).data as *mut ffmpeg::ffi::AVHWFramesContext;
        if hw_frames.is_null() {
            return None;
        }
        let format = ffmpeg::format::Pixel::from((*hw_frames).sw_format);
        Some(Video::new(format, hw_frame.width(), hw_frame.height()))
    }
}

const DECODER_THREADS: usize = 2;
/// Capture windows with a longer preroll (distance from the seek-landing
/// keyframe to the window start) are the makespan-gating slow workers. Giving
/// only those decoders a third frame thread recovers most of the all-DT3
/// makespan (~0.2s) while adding only a few decoder buffer pools to RSS
/// (~8MB/worker over DT2), keeping the 512MB budget.
const PREROLL_DT3_THRESHOLD_S: f64 = 1.5;
const DECODER_THREADS_LONG_PREROLL: usize = 3;
type AuthorityRecords = Arc<Mutex<Vec<Option<Vec<SourceSelection>>>>>;

pub(super) fn start(
    plan: &CapturePlan,
    authority: bool,
) -> anyhow::Result<Box<dyn CaptureAttempt>> {
    ffmpeg::init().context("initializing software libav")?;
    let proto = proto_config();
    let hw_device = match proto.hwaccel {
        Some(backend) => Some(create_hw_device(backend)?),
        None => None,
    };

    // NOTE: Capture-point concurrency limiting for in-process backends requires
    // per-frame semaphore gating inside `emit_scheduled_frames`. The plan-level
    // `concurrency` value is stored but not yet enforced here; all capture
    // workers run concurrently.
    let _ = plan.concurrency();

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
        let proto_for_worker = proto.clone();
        let hw_device_for_worker = hw_device.clone();
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
                proto: proto_for_worker,
                hw_device: hw_device_for_worker,
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
    proto: ProtoConfig,
    hw_device: Option<Arc<ProtoHwDevice>>,
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
        proto,
        hw_device,
    } = request;
    let mut counters = ProtoCounters::default();
    let open_started = Instant::now();
    let mut input = ffmpeg::format::input(video)
        .with_context(|| format!("opening input {}", video.display()))?;
    let open_s = open_started.elapsed().as_secs_f64();
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
    // Demux only the selected video stream: non-video packets (this input can
    // carry dozens of subtitle tracks) are dropped inside av_read_frame
    // instead of being allocated, delivered, and skipped per packet.
    for mut other in input.streams_mut() {
        if other.index() != stream_index {
            unsafe { (*other.as_mut_ptr()).discard = ffmpeg::ffi::AVDiscard::AVDISCARD_ALL };
        }
    }
    let target = (f64::from(start_s) * ffmpeg::ffi::AV_TIME_BASE as f64).round() as i64;
    let seek_started = Instant::now();
    input
        .seek(target, ..target)
        .context("libav capture seek failed")?;
    let seek_s = seek_started.elapsed().as_secs_f64();
    // The decoder opens lazily on the first video packet after the seek: its
    // pts exposes the preroll length, which selects the frame-thread count.
    // The scaler is created together with the decoder and always lives as
    // long as it does.
    let mut decode_pipeline: Option<(ffmpeg::decoder::Video, filter::Graph)> = None;

    let mut decoded = Video::empty();
    let mut rgb = Video::empty();
    let mut input_frame_index = 0_i64;
    let mut previous_rgb: Option<RgbImage> = None;
    let mut pending_decoded = None;
    let mut last_duration = None;
    let mut packet_durations = HashMap::new();
    let mut decoder_threads_used = 0;
    let mut selected = Vec::new();
    let mut metrics = CaptureMetrics::default();
    let mut setup_s = 0.0;
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
        if decode_pipeline.is_none() {
            // First video packet of the seek: its pts is the preroll start, so
            // the preroll length is known before any decoding happens.
            let preroll_s = packet
                .pts()
                .map(|pts| (f64::from(start_s) - pts as f64 * f64::from(time_base)).max(0.0))
                .unwrap_or(0.0);
            let threads = if preroll_s > PREROLL_DT3_THRESHOLD_S {
                DECODER_THREADS_LONG_PREROLL
            } else {
                DECODER_THREADS
            };
            // Prototype knob: force decoder thread count (VIMG_PROTO_DT).
            let threads = std::env::var("VIMG_PROTO_DT")
                .ok()
                .and_then(|value| value.parse::<usize>().ok())
                .unwrap_or(threads);
            decoder_threads_used = threads;
            let setup_started = Instant::now();
            let mut opened = open_proto_decoder(
                &parameters,
                codec_id,
                threads,
                &proto,
                hw_device.as_ref(),
            )?;
            opened.skip_frame(Discard::NonReference);
            let graph_pix_fmt = if proto.hwaccel.is_some() {
                proto_sw_format(&opened).unwrap_or_else(|| "nv12".to_owned())
            } else {
                opened
                    .format()
                    .descriptor()
                    .context("libav capture is unavailable: decoder pixel format is unsupported")?
                    .name()
                    .to_owned()
            };
            let opened_scaler = production_scale_filter(
                &opened,
                dimensions,
                time_base,
                &graph_pix_fmt,
            )?;
            setup_s = setup_started.elapsed().as_secs_f64();
            decode_pipeline = Some((opened, opened_scaler));
        }
        let (active_decoder, active_scaler) = decode_pipeline
            .as_mut()
            .expect("decoder opened above");
        if let Some(pts) = packet.dts().or_else(|| packet.pts()) {
            let seconds = pts as f64 * f64::from(time_base);
            if seconds >= f64::from(start_s) - NONREF_RECOVERY_MARGIN_S {
                active_decoder.skip_frame(Discard::Default);
            }
        }
        if proto.probe {
            counters.packets += 1;
        }
        let send_started = Instant::now();
        active_decoder.send_packet(&packet)?;
        counters.send_s += send_started.elapsed().as_secs_f64();
        receive_frames(
            active_decoder,
            active_scaler,
            &mut decoded,
            &mut rgb,
            &mut schedule,
            source_time_base,
            sender,
            &mut input_frame_index,
            &mut previous_rgb,
            &mut pending_decoded,
            &mut last_duration,
            &packet_durations,
            &mut selected,
            &mut metrics,
            &proto,
            &mut counters,
        )?;
        if schedule.is_complete() {
            break;
        }
    }
    // The packet loop ended: if the schedule still isn't full, drain the
    // decoder (EOF) and emit any pending source frame. No video packets at
    // all is an error.
    let (mut active_decoder, mut active_scaler) =
        decode_pipeline.context("libav capture received no video packets")?;
    if !schedule.is_complete() {
        active_decoder.send_eof()?;
        receive_frames(
            &mut active_decoder,
            &mut active_scaler,
            &mut decoded,
            &mut rgb,
            &mut schedule,
            source_time_base,
            sender,
            &mut input_frame_index,
            &mut previous_rgb,
            &mut pending_decoded,
            &mut last_duration,
            &packet_durations,
            &mut selected,
            &mut metrics,
            &proto,
            &mut counters,
        )?;
    }
    if !schedule.is_complete() {
        let pending =
            pending_decoded.context("libav decoder produced no timestamped source frame")?;
        let duration = last_duration.context("libav decoder produced no source-frame duration")?;
        emit_scheduled_frames(
            pending,
            duration,
            &mut active_scaler,
            &mut rgb,
            &mut schedule,
            source_time_base,
            sender,
            &mut previous_rgb,
            &mut selected,
            &proto,
            &mut counters,
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
    if proto.probe {
        eprintln!(
            "[proto] cap={capture_index} start_s={start_s:.3} hw={} dt={} open={open_s:.4} seek={seek_s:.4} setup={setup_s:.4} send={:.4} receive={:.4} emit={:.4} total={:.4} packets={} decoded={} preroll={} hw_decoded={} transfers={}",
            proto
                .hwaccel
                .map(ProtoHw::label)
                .unwrap_or("sw"),
            decoder_threads_used,
            counters.send_s,
            counters.receive_s,
            counters.emit_s,
            metrics.decode.as_secs_f64(),
            counters.packets,
            metrics.decoded_frames,
            metrics.preroll_frames,
            counters.hw_decoded,
            counters.transfers,
        );
    }
    Ok(metrics)
}

/// Open the native codec decoder, optionally with a shared hardware device.
/// Frame threading is tried first; if the hardware backend rejects it the open
/// is retried single-threaded (the prototype records the fallback).
fn open_proto_decoder(
    parameters: &ffmpeg::codec::Parameters,
    codec_id: ffmpeg::codec::Id,
    threads: usize,
    proto: &ProtoConfig,
    hw_device: Option<&Arc<ProtoHwDevice>>,
) -> anyhow::Result<ffmpeg::decoder::Video> {
    let codec = ffmpeg::codec::decoder::find(codec_id)
        .context("libav capture is unavailable: video decoder is unsupported")?;
    if proto.probe {
        eprintln!("[proto] codec={codec_id:?} native={}", codec.name());
        for index in 0.. {
            unsafe {
                let config = ffmpeg::ffi::avcodec_get_hw_config(codec.as_ptr(), index);
                if config.is_null() {
                    break;
                }
                eprintln!(
                    "[proto]   hw_config[{index}] device={} pix_fmt={} methods=0x{:x}",
                    device_type_name((*config).device_type),
                    pix_fmt_name((*config).pix_fmt),
                    (*config).methods,
                );
            }
        }
    }
    let attempt = |kind: threading::Type, count: usize| -> Result<ffmpeg::decoder::Video, ffmpeg::Error> {
        let mut context = ffmpeg::codec::context::Context::from_parameters(parameters.clone())?;
        if kind != threading::Type::None {
            context.set_threading(threading::Config { kind, count });
        }
        if let (Some(device), Some(hw)) = (hw_device, proto.hwaccel) {
            unsafe {
                let context_ptr = context.as_mut_ptr();
                (*context_ptr).hw_device_ctx = ffmpeg::ffi::av_buffer_ref(device.0);
                PROTO_HW_FORMAT.with(|cell| cell.set(hw.pixel_format()));
                (*context_ptr).get_format = Some(proto_get_format);
            }
        }
        Ok(context.decoder().open_as(codec)?.video()?)
    };
    // Prototype knob: VIMG_PROTO_THREAD_KIND=frame|slice|none overrides the
    // frame-threading default (slice threading + hwaccel compatibility check).
    let thread_kind = std::env::var("VIMG_PROTO_THREAD_KIND").ok();
    let (kind, count) = match thread_kind.as_deref() {
        Some("none") => (threading::Type::None, 0),
        Some("slice") => (threading::Type::Slice, threads.max(2)),
        _ => (threading::Type::Frame, threads),
    };
    match attempt(kind, count) {
        Ok(video) => Ok(video),
        Err(error) if hw_device.is_some() => {
            eprintln!(
                "[proto] frame-threaded hw open failed ({error}); retrying single-threaded"
            );
            attempt(threading::Type::None, 0).map_err(|error| {
                anyhow::anyhow!("libav capture is unavailable: hw decoder open failed: {error}")
            })
        }
        Err(error) => Err(anyhow::anyhow!(
            "libav capture is unavailable: video decoder open failed: {error}"
        )),
    }
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
    previous_rgb: &mut Option<RgbImage>,
    pending_decoded: &mut Option<PendingDecoded>,
    last_duration: &mut Option<i64>,
    packet_durations: &HashMap<i64, i64>,
    selected: &mut Vec<SourceSelection>,
    metrics: &mut CaptureMetrics,
    proto: &ProtoConfig,
    counters: &mut ProtoCounters,
) -> anyhow::Result<()> {
    let receive_started = Instant::now();
    let emit_before = counters.emit_s;
    let mut receive_error: Option<ffmpeg::Error> = None;
    loop {
        match decoder.receive_frame(decoded) {
            Ok(()) => {}
            Err(ffmpeg::Error::Other {
                errno: ffmpeg::util::error::EAGAIN,
            })
            | Err(ffmpeg::Error::Eof) => break,
            Err(error) => {
                receive_error = Some(error);
                break;
            }
        }
        metrics.decoded_frames += 1;
        let is_hw = proto
            .hwaccel
            .is_some_and(|hw| unsafe { (*decoded.as_ptr()).format == hw.pixel_format() });
        if is_hw {
            counters.hw_decoded += 1;
        }
        let pts = decoded
            .timestamp()
            .or_else(|| decoded.pts())
            .context("libav capture is unavailable: decoded frame has no timestamp")?;
        *input_frame_index += 1;
        // FFmpeg's input-side `-ss` begins the CFR filter at the first decoded
        // source timestamp at or after the planned start. libav seeking may expose
        // a few earlier display frames, which must remain preroll only. Skip them
        // before cloning: 272 preroll frames at ~3MB each is ~800MB of wasted
        // allocation + memcpy per run.
        if pts < schedule.source_pts_offset() {
            metrics.preroll_frames += 1;
            continue;
        }
        let current = PendingDecoded {
            // ffmpeg-next's Video::clone is av_frame_copy + copy_props, which
            // mis-copies hardware frames (texture handle bytes, no
            // hw_frames_ctx); hardware frames need a real av_frame_ref.
            image: if is_hw {
                let mut cloned = Video::empty();
                let result = unsafe {
                    ffmpeg::ffi::av_frame_ref(cloned.as_mut_ptr(), decoded.as_ptr())
                };
                ensure!(result >= 0, "proto hw frame ref failed: {}", result);
                cloned
            } else {
                decoded.clone()
            },
            pts,
            input_frame_index: *input_frame_index,
            duration: packet_durations.get(&pts).copied(),
        };
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
                previous_rgb,
                selected,
                proto,
                counters,
            )?;
        }
        *pending_decoded = Some(current);
    }
    if let Some(error) = receive_error {
        eprintln!("[proto]   cap={} receive_frame error: {error}", schedule.capture_index());
    }
    // receive_s excludes the emit work measured inside emit_scheduled_frames.
    counters.receive_s +=
        receive_started.elapsed().as_secs_f64() - (counters.emit_s - emit_before);
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
    previous_rgb: &mut Option<RgbImage>,
    selected: &mut Vec<SourceSelection>,
    proto: &ProtoConfig,
    counters: &mut ProtoCounters,
) -> anyhow::Result<()> {
    let emit_started = Instant::now();
    let scheduled = schedule.push(SourceFrame {
        input_frame_index: current.input_frame_index,
        pts: current.pts,
        duration,
    })?;
    // Hardware frames are downloaded (av_hwframe_transfer_data) only when the
    // frame actually needs to be scaled; preroll frames never reach this path.
    let is_hw = proto
        .hwaccel
        .is_some_and(|hw| unsafe { (*current.image.as_ptr()).format == hw.pixel_format() });
    let cpu_frame = if is_hw {
        // D3D11VA's transfer requires a destination pre-allocated in the hw
        // frames context sw_format (e.g. NV12); CUDA would allocate it itself.
        let mut cpu = hw_sw_frame(&current.image)
            .context("proto hw frame has no hw frames context")?;
        let result = unsafe {
            ffmpeg::ffi::av_hwframe_transfer_data(cpu.as_mut_ptr(), current.image.as_ptr(), 0)
        };
        ensure!(
            result >= 0,
            "proto hw transfer failed: {}",
            ffmpeg::Error::from(result)
        );
        counters.transfers += 1;
        cpu
    } else {
        current.image.clone()
    };
    // Scale the current source frame once. The small RGB is retained as the
    // previous frame for CFR re-selection instead of the full-resolution YUV,
    // saving ~3MB resident per worker (9 workers ≈ 27MB).
    scaler
        .get("in")
        .context("libav scale filter has no input")?
        .source()
        // av_buffersrc_add_frame may take ownership of the supplied frame;
        // feed a clone and drop the full-resolution reference afterwards.
        .add(&cpu_frame)?;
    scaler
        .get("out")
        .context("libav scale filter has no output")?
        .sink()
        .frame(rgb)?;
    let current_rgb = copy_rgb(rgb)?;
    for frame in scheduled {
        let image = if frame.input_frame_index == current.input_frame_index {
            current_rgb.clone()
        } else {
            previous_rgb.as_ref().context(
                "libav frame schedule selected a previous source frame that was not retained",
            )?
            .clone()
        };
        selected.push(SourceSelection {
            source_pts: frame.source_pts,
            source_time_base: format!(
                "{}/{}",
                source_time_base.numerator, source_time_base.denominator
            ),
            input_frame_index: frame.input_frame_index,
        });
        if let Some(dump_dir) = &proto.dump_dir {
            let dump_image = if frame.input_frame_index == current.input_frame_index {
                &current_rgb
            } else {
                previous_rgb.as_ref().context(
                    "libav frame schedule selected a previous source frame that was not retained",
                )?
            };
            dump_scheduled(dump_dir, frame, dump_image)?;
        }
        sender
            .send(Ok(CaptureFrame {
                capture_index: frame.capture_index,
                animation_index: frame.animation_index,
                image,
            }))
            .context("libav frame consumer stopped")?;
    }
    *previous_rgb = Some(current_rgb);
    counters.emit_s += emit_started.elapsed().as_secs_f64();
    Ok(())
}

fn dump_scheduled(
    dump_dir: &std::path::Path,
    frame: crate::command::frame_schedule::ScheduledFrame,
    image: &RgbImage,
) -> anyhow::Result<()> {
    use std::io::Write;
    std::fs::write(
        dump_dir.join(format!(
            "cap{:02}_anim{:02}.rgb",
            frame.capture_index, frame.animation_index
        )),
        image.as_raw(),
    )?;
    let mut pts_file = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(dump_dir.join(format!("pts_cap{:02}.txt", frame.capture_index)))?;
    writeln!(
        pts_file,
        "anim{:02} pts={}",
        frame.animation_index, frame.source_pts
    )?;
    Ok(())
}

fn production_scale_filter(
    decoder: &ffmpeg::decoder::Video,
    dimensions: (u32, u32),
    time_base: ffmpeg::Rational,
    graph_pix_fmt: &str,
) -> anyhow::Result<filter::Graph> {
    let mut graph = filter::Graph::new();
    let args = format!(
        "video_size={}x{}:pix_fmt={}:time_base={}:pixel_aspect=1/1",
        decoder.width(),
        decoder.height(),
        graph_pix_fmt,
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
