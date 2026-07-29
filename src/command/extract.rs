use crate::{
    command::{
        DurationOrPercent, HumanDuration, SourceSelection, label, parse_source_frames, sh_escape,
    },
    process::CommandExt,
};
use anyhow::{Context, ensure};
use image::RgbImage;
use rayon::prelude::*;
use std::{
    fmt, fs,
    io::{BufReader, ErrorKind, Read},
    path::{Path, PathBuf},
    process::Command,
    sync::{
        Arc, Condvar, Mutex,
        atomic::{AtomicBool, Ordering},
        mpsc::{Receiver, SyncSender, sync_channel},
    },
    thread::{self, JoinHandle},
};

/// Generate capture bmp images from a video using ffmpeg.
#[derive(clap::Parser, Debug, Clone)]
#[group(skip)]
pub struct Extract {
    /// Number of equidistant points in the video to capture.
    #[arg(long, short)]
    pub number: u32,

    /// Time or percentage at the start to ignore when calculating capture points.
    #[arg(long = "ignore-start", default_value = "0s")]
    pub ignore_start: DurationOrPercent,

    /// Time or percentage at the end to ignore when calculating capture points.
    #[arg(long = "ignore-end", default_value = "0s")]
    pub ignore_end: DurationOrPercent,

    /// Number of frames to output for each capture (greater than 1 for animated captures).
    ///
    /// Defaults to 1 (extract), 30 (vcs).
    #[arg(long, short = 'f')]
    pub capture_frames: Option<u32>,

    /// Duration per capture for multi-frame captures.
    #[arg(long, short = 't', default_value = "1500ms")]
    pub capture_time: HumanDuration,

    /// Ffmpeg vfilter.
    #[arg(long)]
    pub vfilter: Option<String>,

    /// Number of threads / concurrent ffmpeg calls. 0=auto.
    #[arg(long, short = 'T', default_value_t = 4)]
    pub threads: usize,

    /// Directory to write capture images into. Defaults to the current directory.
    #[arg(long)]
    pub output_dir: Option<PathBuf>,

    /// Video file input.
    #[arg(required = true)]
    pub video: PathBuf,

    /// Media properties supplied by a caller that has already probed the video.
    #[arg(skip)]
    pub media: Option<MediaDescriptor>,
}

/// Optional media properties used to avoid repeating ffprobe work in preview services.
#[derive(Clone, Debug, Default)]
pub struct MediaDescriptor {
    pub duration_s: Option<f32>,
    pub width: Option<u32>,
    pub height: Option<u32>,
}

impl Extract {
    pub fn run(&self) -> anyhow::Result<ExtractData> {
        let Self {
            number,
            ignore_start,
            ignore_end,
            threads,
            video,
            output_dir,
            ..
        } = self;

        let video_duration_s = ffprobe::ffprobe(video)?
            .format
            .duration
            .context("invalid video duration")?
            .parse::<f32>()
            .context("invalid video duration")?;

        let duration_s = video_duration_s
            - ignore_start.to_secs(video_duration_s)
            - ignore_end.to_secs(video_duration_s);

        ensure!(
            duration_s > 0.0,
            "invalid negative video duration minus offsets"
        );

        let out_dir = match output_dir {
            Some(dir) => {
                fs::create_dir_all(dir)?;
                dir.clone()
            }
            None => PathBuf::from("."),
        };

        rayon::ThreadPoolBuilder::new()
            .num_threads(*threads)
            .build()?
            .install(|| {
                let out_templates = (0..*number)
                    .into_par_iter()
                    .map(|n| {
                        let interval = duration_s / *number as f32;
                        let start_s = ignore_start.to_secs(video_duration_s)
                            + interval * 0.5
                            + interval * n as f32;
                        let start_s = start_s.min(video_duration_s - self.capture_time.seconds);
                        let out_template = self.out_template(start_s, duration_s);
                        self.capture(start_s, &out_template)?;
                        Ok(out_template)
                    })
                    .collect::<anyhow::Result<Vec<_>>>()?;

                let warnings = self.fix_missing(&out_templates, &out_dir)?;

                Ok(ExtractData { warnings })
            })
    }

    pub fn capture_frames(&self) -> u32 {
        self.capture_frames.unwrap_or(1)
    }

    fn out_template(&self, start_s: f32, duration_s: f32) -> OutTemplate {
        let prefix = self.video.with_extension("");
        let prefix = prefix.file_name().unwrap_or_default().to_string_lossy();

        OutTemplate::new(prefix, start_s as _, duration_s as _, self.capture_frames())
    }

    fn capture(&self, start_s: f32, out_template: &OutTemplate) -> anyhow::Result<()> {
        let Self {
            capture_time,
            vfilter,
            output_dir,
            video,
            ..
        } = self;
        let capture_frames = self.capture_frames();
        ensure!(
            capture_frames > 0,
            "invalid capture-frames must be non-zero"
        );
        ensure!(
            capture_time.seconds > 0.0,
            "invalid capture-time must be non-zero"
        );

        let mut out = match output_dir {
            Some(dir) => dir.clone(),
            None => PathBuf::from("."),
        };
        out.push(out_template.to_string());

        let out = Command::new("ffmpeg")
            .arg2("-ss", start_s)
            .arg2("-t", capture_time.seconds)
            .arg2("-i", video)
            .arg2("-r", format!("{capture_frames}/{}", capture_time.seconds))
            .arg2("-fps_mode", "cfr")
            .arg2_opt("-vf", vfilter.as_ref())
            .arg2("-vframes", capture_frames)
            .arg("-y")
            .arg(&out)
            .output()?;

        ensure!(
            out.status.success(),
            "ffmpeg capture failed\n---stderr---\n{}\n------",
            String::from_utf8_lossy(&out.stderr).trim(),
        );

        Ok(())
    }

    /// Check extractions and fix missing. Returns a list of warnings.
    ///
    /// In fairly rare cases ffmpeg can fail to extract the expected number of frames.
    /// Auto fixing will simply cover these missing frames with duplicates of the previous frame.
    fn fix_missing(
        &self,
        extracts: &[OutTemplate],
        temp_dir: &Path,
    ) -> anyhow::Result<Vec<String>> {
        let mut warnings = Vec::new();

        // ensure all captures exist
        for tmpl in extracts {
            let mut first = temp_dir.to_path_buf();
            first.push(tmpl.with_frame(1));
            ensure!(first.is_file(), "Failed to extract: {}", sh_escape(&first));

            let mut prev = first;
            let mut fixes = 0;
            for f in 2..=self.capture_frames() {
                let mut next = temp_dir.to_path_buf();
                next.push(tmpl.with_frame(f));
                if !next.is_file() {
                    fs::hard_link(&prev, &next).or_else(|_| fs::copy(&prev, &next).map(|_| ()))?;
                    fixes += 1;
                }
                prev = next;
            }
            if fixes != 0 {
                warnings.push(format!(
                    "Duplicated {fixes} captures to cover missing {tmpl} frames"
                ));
            }
        }

        Ok(warnings)
    }

    pub fn stream_pipe(
        &self,
        capture_height: Option<u32>,
        capture_width: Option<u32>,
        authority: bool,
    ) -> anyhow::Result<PipeExtractStream> {
        let Self {
            number,
            ignore_start,
            ignore_end,
            ..
        } = self;

        let (video_duration_s, orig_w, orig_h) = self.pipe_media()?;
        let (frame_w, frame_h) = scaled_dimensions(orig_w, orig_h, capture_height, capture_width);

        let duration_s = video_duration_s
            - ignore_start.to_secs(video_duration_s)
            - ignore_end.to_secs(video_duration_s);

        ensure!(
            duration_s > 0.0,
            "invalid negative video duration minus offsets"
        );

        let starts: Vec<_> = (0..*number)
            .map(|capture_index| {
                let interval = duration_s / *number as f32;
                let start_s = ignore_start.to_secs(video_duration_s)
                    + interval * 0.5
                    + interval * capture_index as f32;
                (
                    capture_index as usize,
                    start_s.min(video_duration_s - self.capture_time.seconds),
                )
            })
            .collect();
        // Every grid frame needs one image from each sampling point. Start one
        // single-threaded process per point and synchronize after each frame so a
        // fast producer cannot fill the bounded channel with future frames.
        let process_count = starts.len().max(1);
        let (sender, receiver) = sync_channel((process_count * 2).max(1));
        let frame_barrier = Arc::new(FrameBarrier::new(process_count));
        let authority_records = authority.then(|| Arc::new(Mutex::new(vec![None; process_count])));
        let mut workers = Vec::with_capacity(process_count);
        for (capture_index, start_s) in starts {
            let extract = self.clone();
            let sender = sender.clone();
            let frame_barrier = Arc::clone(&frame_barrier);
            let authority_records = authority_records.clone();
            workers.push(thread::spawn(move || {
                if let Err(error) = extract.capture_pipe_stream(
                    PipeCapture {
                        capture_index,
                        start_s,
                        width: frame_w,
                        height: frame_h,
                        authority_records,
                    },
                    &sender,
                    &frame_barrier,
                ) {
                    frame_barrier.cancel();
                    let _ = sender.send(Err(error));
                }
            }));
        }
        drop(sender);

        Ok(PipeExtractStream {
            receiver: Some(receiver),
            workers,
            authority_records,
            capture_count: *number as usize,
            capture_frames: self.capture_frames() as usize,
            frame_width: frame_w,
            frame_height: frame_h,
            labels: (0..*number)
                .map(|capture_index| {
                    label::seconds_text(
                        (ignore_start.to_secs(video_duration_s)
                            + duration_s / *number as f32 * (0.5 + capture_index as f32))
                            .min(video_duration_s - self.capture_time.seconds)
                            as u32,
                    )
                })
                .collect(),
        })
    }

    fn pipe_media(&self) -> anyhow::Result<(f32, u32, u32)> {
        let descriptor = self.media.as_ref();
        let needs_probe = descriptor.is_none_or(|media| {
            media.duration_s.is_none() || media.width.is_none() || media.height.is_none()
        });
        let probe = needs_probe
            .then(|| ffprobe::ffprobe(&self.video))
            .transpose()?;
        let duration_s = descriptor
            .and_then(|media| media.duration_s)
            .or_else(|| {
                probe
                    .as_ref()?
                    .format
                    .duration
                    .as_ref()?
                    .parse::<f32>()
                    .ok()
            })
            .context("invalid video duration")?;
        let stream = || {
            probe
                .as_ref()?
                .streams
                .iter()
                .find(|stream| stream.codec_type.as_deref() == Some("video"))
        };
        let width = descriptor
            .and_then(|media| media.width)
            .or_else(|| stream().and_then(|stream| stream.width.map(|width| width as u32)))
            .context("no width")?;
        let height = descriptor
            .and_then(|media| media.height)
            .or_else(|| stream().and_then(|stream| stream.height.map(|height| height as u32)))
            .context("no height")?;
        Ok((duration_s, width, height))
    }

    fn capture_pipe_stream(
        &self,
        capture: PipeCapture,
        sender: &SyncSender<anyhow::Result<PipeFrame>>,
        frame_barrier: &FrameBarrier,
    ) -> anyhow::Result<()> {
        let PipeCapture {
            capture_index,
            start_s,
            width,
            height,
            authority_records,
        } = capture;
        let authority = authority_records.is_some();
        let Self {
            capture_time,
            vfilter,
            video,
            ..
        } = self;
        let capture_frames = self.capture_frames();
        let frame_size = (width * height * 3) as usize;

        let run_ffmpeg = |use_cuda: bool| -> anyhow::Result<()> {
            let mut cmd = Command::new("ffmpeg");
            if authority {
                cmd.arg("-copyts");
            }
            if use_cuda {
                cmd.arg2("-hwaccel", "cuda");
            }
            let authority_filter = authority.then(|| match vfilter {
                Some(vfilter) => format!("setpts=PTS-round({start_s}/TB),{vfilter}"),
                None => format!("setpts=PTS-round({start_s}/TB)"),
            });
            cmd.arg2("-v", "error")
                .arg2("-threads", FFMPEG_THREADS_PER_CAPTURE)
                .arg2("-ss", start_s)
                .arg2("-t", capture_time.seconds)
                .arg2("-i", video)
                .arg2("-r", format!("{capture_frames}/{}", capture_time.seconds))
                .arg2("-fps_mode", "cfr")
                .arg2_opt("-vf", authority_filter.as_ref().or(vfilter.as_ref()))
                .arg2("-vframes", capture_frames)
                .arg2("-f", "rawvideo")
                .arg2("-pix_fmt", "rgb24");
            if authority {
                cmd.arg2("-stats_enc_pre", "pipe:2")
                    .arg2("-stats_enc_pre_fmt", "{n} {ni} {ptsi} {tbi}");
            }
            let mut child = cmd
                .arg("-y")
                .arg("pipe:1")
                .stdout(std::process::Stdio::piped())
                .stderr(std::process::Stdio::piped())
                .spawn()
                .with_context(|| {
                    if authority {
                        "decoding failed: could not start instrumented FFmpeg capture"
                    } else {
                        "could not start FFmpeg capture"
                    }
                })?;

            let stdout = child.stdout.take().context(if authority {
                "decoding failed: FFmpeg stdout was not piped"
            } else {
                "FFmpeg stdout was not piped"
            })?;
            let mut stderr_worker = if authority {
                let child_stderr = child
                    .stderr
                    .take()
                    .context("PTS extraction failed: FFmpeg stderr was not piped")?;
                Some(thread::spawn(move || {
                    let mut bytes = Vec::new();
                    BufReader::new(child_stderr)
                        .read_to_end(&mut bytes)
                        .map(|_| bytes)
                }))
            } else {
                None
            };
            let mut reader = BufReader::new(stdout);
            let mut last_frame = None;
            for frame_index in 0..capture_frames as usize {
                let mut raw = vec![0; frame_size];
                let image = match reader.read_exact(&mut raw) {
                    Ok(()) => RgbImage::from_raw(width, height, raw).context(if authority {
                        "decoding failed: FFmpeg emitted an invalid raw RGB frame"
                    } else {
                        "FFmpeg emitted an invalid raw RGB frame"
                    })?,
                    Err(error) if error.kind() == ErrorKind::UnexpectedEof => {
                        last_frame.clone().context(if authority {
                            "decoding failed: FFmpeg produced 0 frames for capture"
                        } else {
                            "FFmpeg produced 0 frames for capture"
                        })?
                    }
                    Err(error) => {
                        return Err(error).context(if authority {
                            "decoding failed: could not read FFmpeg RGB output"
                        } else {
                            "could not read FFmpeg RGB output"
                        });
                    }
                };
                last_frame = Some(image.clone());
                if !send_pipe_frame(
                    sender,
                    frame_barrier,
                    PipeFrame {
                        capture_index,
                        frame_index,
                        image,
                    },
                ) {
                    frame_barrier.cancel();
                    let _ = child.kill();
                    let _ = child.wait();
                    if let Some(stderr_worker) = stderr_worker.take() {
                        let _ = stderr_worker.join();
                    }
                    return Ok(());
                }
            }
            let (status, stderr) = if let Some(stderr_worker) = stderr_worker {
                let status = child
                    .wait()
                    .context("decoding failed: could not wait for FFmpeg capture")?;
                let stderr = stderr_worker
                    .join()
                    .map_err(|_| anyhow::anyhow!("PTS extraction failed: stderr reader panicked"))?
                    .context("PTS extraction failed: could not read FFmpeg encoder stats")?;
                (status, stderr)
            } else {
                let output = child.wait_with_output()?;
                (output.status, output.stderr)
            };
            if authority {
                ensure!(
                    status.success(),
                    "decoding failed: FFmpeg capture exited {:?} (cuda={use_cuda}, ss={start_s}, t={})\nvideo: {}\nstderr: {}",
                    status.code(),
                    capture_time.seconds,
                    video.display(),
                    String::from_utf8_lossy(&stderr).trim(),
                );
            } else {
                ensure!(
                    status.success(),
                    "ffmpeg capture failed (exit {:?}, cuda={use_cuda}, ss={start_s}, t={})\nvideo: {}\nstderr: {}",
                    status.code(),
                    capture_time.seconds,
                    video.display(),
                    String::from_utf8_lossy(&stderr).trim(),
                );
            }
            if let Some(authority_records) = &authority_records {
                let selected = parse_source_frames(
                    &String::from_utf8_lossy(&stderr),
                    capture_frames as usize,
                )?;
                let mut records = authority_records
                    .lock()
                    .map_err(|_| anyhow::anyhow!("PTS extraction failed: record lock poisoned"))?;
                ensure!(
                    records[capture_index].is_none(),
                    "PTS extraction failed: duplicate capture record {capture_index}"
                );
                records[capture_index] = Some(selected);
            }
            Ok(())
        };

        let use_cuda = CUDA_AVAILABLE.load(Ordering::Relaxed);
        if use_cuda {
            match run_ffmpeg(true) {
                Ok(()) => Ok(()),
                Err(_) => {
                    CUDA_AVAILABLE.store(false, Ordering::Relaxed);
                    run_ffmpeg(false)
                }
            }
        } else {
            run_ffmpeg(false)
        }
    }
}

pub struct ExtractData {
    pub warnings: Vec<String>,
}

/// "prefix-Ss-F.bmp" template.
///
/// S = seconds. Constant for a given template.
/// F = frames using a ffmpeg/printf `%0nd` style.
#[derive(Debug, Clone, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct OutTemplate {
    pub prefix: String,
    pub seconds: u32,
    second_w: usize,
    frame_w: usize,
}

impl OutTemplate {
    fn new(prefix: impl Into<String>, seconds: u32, max_seconds: u32, max_frames: u32) -> Self {
        let second_w = max_seconds.to_string().len();
        let frame_w = max_frames.to_string().len();
        let mut prefix = prefix.into();
        // try to avoid breaking the ffmpeg output template
        if prefix.contains('%') {
            prefix = prefix.replace('%', "");
        }
        Self {
            prefix,
            seconds,
            second_w,
            frame_w,
        }
    }

    /// Return a string capture file name with the given frame number.
    pub fn with_frame(&self, f: u32) -> String {
        let Self {
            prefix,
            seconds,
            second_w,
            frame_w,
        } = self;
        format!("{prefix}-{seconds:0second_w$}s-{f:0frame_w$}.bmp")
    }
}

impl fmt::Display for OutTemplate {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let Self {
            prefix,
            seconds,
            second_w,
            frame_w,
        } = self;
        write!(f, "{prefix}-{seconds:0second_w$}s-%0{frame_w}d.bmp")
    }
}

// --- Bounded pipe-based extraction ---

static CUDA_AVAILABLE: AtomicBool = AtomicBool::new(false);
const FFMPEG_THREADS_PER_CAPTURE: u8 = 3;
type AuthorityRecords = Arc<Mutex<Vec<Option<Vec<SourceSelection>>>>>;

#[derive(Clone)]
struct PipeCapture {
    capture_index: usize,
    start_s: f32,
    width: u32,
    height: u32,
    authority_records: Option<AuthorityRecords>,
}

pub struct PipeFrame {
    pub capture_index: usize,
    pub frame_index: usize,
    pub image: RgbImage,
}

pub struct CaptureAuthority {
    pub capture_index: usize,
    pub frames: Vec<SourceSelection>,
}

pub struct PipeExtractStream {
    receiver: Option<Receiver<anyhow::Result<PipeFrame>>>,
    workers: Vec<JoinHandle<()>>,
    authority_records: Option<AuthorityRecords>,
    pub capture_count: usize,
    pub capture_frames: usize,
    pub frame_width: u32,
    pub frame_height: u32,
    pub labels: Vec<String>,
}

struct FrameBarrier {
    parties: usize,
    state: Mutex<FrameBarrierState>,
    ready: Condvar,
}

#[derive(Default)]
struct FrameBarrierState {
    arrived: usize,
    generation: usize,
    cancelled: bool,
}

impl FrameBarrier {
    fn new(parties: usize) -> Self {
        Self {
            parties,
            state: Mutex::new(FrameBarrierState::default()),
            ready: Condvar::new(),
        }
    }

    fn wait(&self) -> bool {
        let mut state = self.state.lock().unwrap();
        if state.cancelled {
            return false;
        }
        let generation = state.generation;
        state.arrived += 1;
        if state.arrived == self.parties {
            state.arrived = 0;
            state.generation += 1;
            self.ready.notify_all();
            return true;
        }
        while !state.cancelled && state.generation == generation {
            state = self.ready.wait(state).unwrap();
        }
        !state.cancelled
    }

    fn cancel(&self) {
        let mut state = self.state.lock().unwrap();
        state.cancelled = true;
        self.ready.notify_all();
    }
}

impl PipeExtractStream {
    pub fn recv(&self) -> anyhow::Result<PipeFrame> {
        self.receiver
            .as_ref()
            .context("extraction stream has already been closed")?
            .recv()
            .context("extraction stream ended before all frames were produced")?
    }

    pub fn finish(mut self) -> anyhow::Result<Vec<CaptureAuthority>> {
        self.receiver.take();
        for worker in self.workers.drain(..) {
            worker
                .join()
                .map_err(|_| anyhow::anyhow!("extraction worker panicked"))?;
        }
        let Some(authority_records) = self.authority_records.take() else {
            return Ok(Vec::new());
        };
        let mut records = authority_records
            .lock()
            .map_err(|_| anyhow::anyhow!("PTS extraction failed: record lock poisoned"))?;
        records
            .iter_mut()
            .enumerate()
            .map(|(capture_index, frames)| {
                Ok(CaptureAuthority {
                    capture_index,
                    frames: frames.take().context(format!(
                        "PTS extraction failed: capture {capture_index} produced no timestamp record"
                    ))?,
                })
            })
            .collect()
    }
}

fn send_pipe_frame(
    sender: &SyncSender<anyhow::Result<PipeFrame>>,
    frame_barrier: &FrameBarrier,
    frame: PipeFrame,
) -> bool {
    sender.send(Ok(frame)).is_ok() && frame_barrier.wait()
}

impl Drop for PipeExtractStream {
    fn drop(&mut self) {
        self.receiver.take();
        for worker in self.workers.drain(..) {
            let _ = worker.join();
        }
    }
}

fn scaled_dimensions(
    orig_w: u32,
    orig_h: u32,
    target_h: Option<u32>,
    target_w: Option<u32>,
) -> (u32, u32) {
    match (target_w, target_h) {
        (_, Some(h)) => {
            let w = ((orig_w as f64 * h as f64) / orig_h as f64).round() as u32;
            let w = if w % 2 != 0 { w + 1 } else { w };
            (w, h)
        }
        (Some(w), _) => {
            let h = ((orig_h as f64 * w as f64) / orig_w as f64).round() as u32;
            let h = if h % 2 != 0 { h + 1 } else { h };
            (w, h)
        }
        _ => (orig_w, orig_h),
    }
}
