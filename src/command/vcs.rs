use crate::{
    command::{self, sh_escape_filename},
    process::CommandExt,
};
use anyhow::{Context, ensure};
use std::{
    collections::BTreeMap,
    fs,
    io::Write,
    path::PathBuf,
    process::{Child, Command, Stdio},
    time::{Duration, Instant},
};

/// Create a new contact sheet for a video.
///
/// Extracts capture frames and joins into sheet(s) then encodes into
/// an animated, or static, vcs avif.
#[derive(clap::Parser, Debug, Clone)]
#[group(skip)]
pub struct Vcs {
    /// Number of capture columns in output.
    #[arg(long, short)]
    pub columns: u32,

    /// Output file name. Defaults to input with .avif extension.
    #[arg(long, short)]
    pub output: Option<PathBuf>,

    /// Crf quality level for encoding the output avif.
    #[arg(long, default_value_t = 30)]
    pub avif_crf: u8,

    /// Ffmpeg vcodec to use for encoding the output avif.
    #[arg(long, default_value = "libsvtav1")]
    pub avif_codec: String,

    /// Preset (or "cpu-used" for libaom-av1) for encoding the output avif.
    ///
    /// Default 1 for single-frame, 6 for multi-frame.
    #[arg(long)]
    pub avif_preset: Option<u8>,

    /// Output avif framerate for multi-frame outputs.
    ///
    /// Example: The default 20fps will result in real time playback for
    /// the default args: -f30 -t1500ms (30 frames over a 1.5s duration).
    /// So using 10fps will result in half-time playback for: -f30 -t1500ms.
    #[arg(long, default_value_t = 20.0)]
    pub avif_fps: f32,

    /// Pixel width of each capture inside the grid. Will be scaled preserving aspect.
    ///
    /// Use this or -H (not both).
    #[arg(long, short = 'W', conflicts_with = "capture_height")]
    pub capture_width: Option<u32>,

    /// Pixel height of each capture inside the grid. Will be scaled preserving aspect.
    ///
    /// Use this or -W (not both).
    #[arg(long, short = 'H', conflicts_with = "capture_width", required = true)]
    pub capture_height: Option<u32>,

    #[clap(flatten)]
    pub args: command::Extract,

    /// Keep temporary files.
    #[arg(long, default_value_t = false)]
    pub keep: bool,

    /// Output as webp instead of avif.
    #[arg(long, default_value_t = 0)]
    pub webp: u8,

    /// Print extraction, composition, and encoder phase timings.
    #[arg(long, default_value_t = false)]
    pub profile: bool,

    /// Capture implementation. In-process backends are explicit, feature-on Preview-only options.
    #[arg(long, value_enum, default_value_t = command::CaptureBackendPolicy::Ffmpeg)]
    pub capture_backend: command::CaptureBackendPolicy,

    /// Test-only authority manifest requested by `vimg authority record`.
    #[arg(skip)]
    pub(crate) authority_manifest: Option<PathBuf>,
}

impl Vcs {
    pub fn run(mut self) -> anyhow::Result<()> {
        let profile = self.profile;
        let authority_manifest = self.authority_manifest.take();
        let total_started = Instant::now();
        let is_jpg = self.output.as_ref().is_some_and(|p| {
            p.extension()
                .and_then(|e| e.to_str())
                .map(|ext| ext == "jpg" || ext.is_empty())
                .unwrap_or(false)
        });
        let is_webp = self.webp != 0;
        ensure!(
            !is_jpg || (self.args.capture_frames.unwrap_or(1) == 1),
            "jpg output only supported for single-frame captures"
        );
        if is_jpg {
            self.args.capture_frames = Some(1);
        }

        let parent_dir = self
            .args
            .output_dir
            .clone()
            .unwrap_or_else(|| PathBuf::from("."));

        self.args.capture_frames = self.args.capture_frames.or(Some(30));
        ensure_in_process_preview_profile(&self, is_jpg, is_webp)?;

        let file_prefix = self.args.video.with_extension("");
        let file_prefix = file_prefix
            .file_name()
            .unwrap_or_default()
            .to_string_lossy()
            .replace('%', "");

        let suffix = if is_jpg {
            "jpg"
        } else if is_webp {
            "webp"
        } else {
            "avif"
        };
        let out_file = self.output.take().unwrap_or_else(|| {
            let mut output = parent_dir;
            output.push(format!("{file_prefix}.{suffix}"));
            output
        });
        let _authority_publication_lock = authority_manifest
            .as_ref()
            .map(|manifest| command::AuthorityPublicationLock::acquire(manifest, &out_file))
            .transpose()?;

        let spinner = indicatif::ProgressBar::new_spinner().with_style(
            indicatif::ProgressStyle::default_spinner()
                .template("{spinner:.cyan.bold} {elapsed_precise:.bold} {msg}")?,
        );
        spinner.enable_steady_tick(Duration::from_millis(100));

        let setup_started = Instant::now();
        let capture = command::Capture::plan(&self.args, self.capture_height, self.capture_width)?;
        let plan = capture.capture_plan();
        let labels = plan.labels().to_vec();
        let capture_count = plan.capture_count();
        let (grid_w, grid_h) = plan.grid_dimensions(self.columns);
        let capture_frames = plan.capture_frames();
        let (capture_width, capture_height) = plan.frame_dimensions();
        let setup_elapsed = setup_started.elapsed();
        let out_parent = out_file
            .parent()
            .unwrap_or_else(|| std::path::Path::new("."));
        fs::create_dir_all(out_parent)?;
        let attempt_context = VcsAttemptContext {
            authority_manifest: authority_manifest.as_deref(),
            spinner: &spinner,
            out_parent,
            file_prefix: &file_prefix,
            suffix,
            is_jpg,
            is_webp,
            labels: &labels,
            profile,
        };

        let selected = command::execute_backend_candidates(
            self.capture_backend,
            capture.candidates(self.capture_backend),
            |backend| {
                let attempt_started = Instant::now();
                let result = run_vcs_attempt(&self, &capture, backend, &attempt_context);
                if profile {
                    eprintln!(
                        "[profile] attempt backend={} total={:.3}s outcome={}",
                        backend.name(),
                        attempt_started.elapsed().as_secs_f64(),
                        if result.is_ok() { "success" } else { "failed" },
                    );
                }
                result
            },
        )?;
        for failure in &selected.failures {
            eprintln!("capture fallback: {failure}; retrying the next backend");
        }
        eprintln!(
            "capture selected backend={}",
            selected.value.capture_completion.diagnostics.backend
        );
        for unavailable in &selected.skipped {
            eprintln!("capture fallback: {unavailable}; skipping unavailable backend");
        }
        let mut attempt = selected.value;
        let capture_diagnostics = attempt.capture_completion.diagnostics;
        let capture_backend = capture_diagnostics.backend;
        let stream_timings = attempt.stream_timings;
        let encoder_tail = attempt.encoder_tail;
        let prepared_authority = if let Some(mut authority) = attempt.authority.take() {
            for capture in attempt.capture_completion.authority {
                for (animation_index, source) in capture.frames.iter().enumerate() {
                    authority.record(animation_index, capture.capture_index, source);
                }
            }
            Some(authority.prepare(command::AuthorityProfile {
                input: &self.args.video,
                encoded_output: &attempt.temp_output.path,
                output: &out_file,
                columns: self.columns,
                capture_count,
                capture_frames,
                capture_time_s: self.args.capture_time.seconds,
                capture_width,
                capture_height,
                grid_width: grid_w,
                grid_height: grid_h,
                frame_rate: self.avif_fps,
            })?)
        } else {
            None
        };

        if let Some(prepared_authority) = prepared_authority {
            let publication = OutputPublication::publish(&attempt.temp_output.path, &out_file)?;
            attempt.temp_output.disarm();
            let published_authority = match prepared_authority.publish() {
                Ok(published_authority) => published_authority,
                Err(error) => {
                    if let Err(rollback_error) = publication.rollback() {
                        return Err(error.context(format!(
                            "structural inspection failed: authority AVIF rollback also failed: {rollback_error:#}"
                        )));
                    }
                    return Err(error);
                }
            };
            publication.commit();
            published_authority.finish();
        } else if let Err(rename_error) = fs::rename(&attempt.temp_output.path, &out_file) {
            // Windows does not replace an existing destination with rename. Both
            // files are in the cache directory, so this fallback never exposes a
            // partially copied AVIF; readers see either the old file or no file.
            if out_file.exists() {
                fs::remove_file(&out_file)?;
                fs::rename(&attempt.temp_output.path, &out_file)?;
            } else {
                return Err(rename_error.into());
            }
            attempt.temp_output.disarm();
        } else {
            attempt.temp_output.disarm();
        }

        spinner.finish();
        if profile {
            eprintln!(
                "[profile] backend={capture_backend} availability={:.3}s backend_setup={:.3}s decode={:.3}s decoded_frames={} preroll_frames={} hardware_transfers={} transfer={:.3}s cleanup={:.3}s plan_setup={:.3}s first_grid={:.3}s frames_before_first_grid={} receive_wait={:.3}s join={:.3}s encoder_write={:.3}s encoder_tail={:.3}s total={:.3}s",
                capture_diagnostics.availability.as_secs_f64(),
                capture_diagnostics.setup.as_secs_f64(),
                capture_diagnostics.metrics.decode.as_secs_f64(),
                capture_diagnostics.metrics.decoded_frames,
                capture_diagnostics.metrics.preroll_frames,
                capture_diagnostics.metrics.hardware_transfers,
                capture_diagnostics.metrics.transfer.as_secs_f64(),
                capture_diagnostics.metrics.cleanup.as_secs_f64(),
                setup_elapsed.as_secs_f64(),
                stream_timings.first_grid.as_secs_f64(),
                stream_timings.frames_before_first_grid,
                stream_timings.receive_wait.as_secs_f64(),
                stream_timings.join.as_secs_f64(),
                stream_timings.encoder_write.as_secs_f64(),
                encoder_tail.as_secs_f64(),
                total_started.elapsed().as_secs_f64(),
            );
        }
        Ok(())
    }
}

fn ensure_in_process_preview_profile(vcs: &Vcs, is_jpg: bool, is_webp: bool) -> anyhow::Result<()> {
    ensure_backend_preview_profile(vcs, vcs.capture_backend, is_jpg, is_webp)
}

fn ensure_backend_preview_profile(
    vcs: &Vcs,
    backend: command::CaptureBackendPolicy,
    is_jpg: bool,
    is_webp: bool,
) -> anyhow::Result<()> {
    if !matches!(
        backend,
        command::CaptureBackendPolicy::Libav | command::CaptureBackendPolicy::VideoToolbox
    ) {
        return Ok(());
    }
    ensure!(
        is_in_process_preview_profile(vcs, is_jpg, is_webp),
        "Capture backend {} is unavailable: requires the fixed Preview profile",
        backend.name(),
    );
    Ok(())
}

fn is_in_process_preview_profile(vcs: &Vcs, is_jpg: bool, is_webp: bool) -> bool {
    vcs.columns == 3
        && vcs.capture_height == Some(160)
        && vcs.capture_width.is_none()
        && vcs.args.number == 9
        && vcs.args.capture_frames == Some(30)
        && vcs.args.capture_time.seconds == 1.5
        && vcs.args.vfilter.is_none()
        && vcs.args.ignore_start == command::DurationOrPercent::Seconds(0.0)
        && vcs.args.ignore_end == command::DurationOrPercent::Seconds(0.0)
        && !is_jpg
        && !is_webp
        && vcs.avif_fps == 20.0
        && vcs.avif_crf == 30
        && vcs.avif_codec == "libsvtav1"
        && vcs.avif_preset.is_none()
}

#[derive(Default)]
struct StreamTimings {
    first_grid: Duration,
    frames_before_first_grid: usize,
    receive_wait: Duration,
    join: Duration,
    encoder_write: Duration,
}

struct TempOutputCleanup {
    path: PathBuf,
    armed: bool,
}

impl TempOutputCleanup {
    fn new(path: PathBuf) -> Self {
        Self { path, armed: true }
    }

    fn disarm(&mut self) {
        self.armed = false;
    }
}

impl Drop for TempOutputCleanup {
    fn drop(&mut self) {
        if self.armed {
            let _ = fs::remove_file(&self.path);
        }
    }
}

struct OutputPublication {
    output: PathBuf,
    backup: Option<PathBuf>,
    committed: bool,
}

impl OutputPublication {
    fn publish(temporary: &std::path::Path, output: &std::path::Path) -> anyhow::Result<Self> {
        ensure!(
            !output.is_dir(),
            "structural inspection failed: output path is a directory"
        );
        let backup = output.exists().then(|| {
            output
                .parent()
                .unwrap_or_else(|| std::path::Path::new("."))
                .join(format!(".authority-output.{}.backup", fastrand::u64(..)))
        });
        if let Some(backup) = &backup {
            fs::rename(output, backup)
                .context("structural inspection failed: could not preserve previous AVIF")?;
        }
        if let Err(error) = fs::rename(temporary, output) {
            let publication_error = anyhow::Error::new(error)
                .context("structural inspection failed: could not publish authority AVIF");
            if let Some(backup) = &backup
                && let Err(rollback_error) = fs::rename(backup, output)
            {
                return Err(publication_error.context(format!(
                    "structural inspection failed: AVIF rollback also failed; previous AVIF remains at {}: {rollback_error}",
                    backup.display()
                )));
            }
            return Err(publication_error);
        }
        Ok(Self {
            output: output.to_path_buf(),
            backup,
            committed: false,
        })
    }

    fn commit(mut self) {
        self.committed = true;
        if let Some(backup) = &self.backup
            && let Err(error) = fs::remove_file(backup)
        {
            eprintln!(
                "warning: authority AVIF was published, but backup {} could not be removed: {error}",
                backup.display()
            );
        }
    }

    fn rollback(mut self) -> anyhow::Result<()> {
        self.rollback_in_place()?;
        self.committed = true;
        Ok(())
    }

    fn rollback_in_place(&mut self) -> anyhow::Result<()> {
        if self.output.exists() {
            fs::remove_file(&self.output)
                .context("structural inspection failed: could not remove unpublished AVIF")?;
        }
        if let Some(backup) = &self.backup {
            fs::rename(backup, &self.output).with_context(|| {
                format!(
                    "structural inspection failed: could not restore previous AVIF from {}",
                    backup.display()
                )
            })?;
        }
        Ok(())
    }
}

impl Drop for OutputPublication {
    fn drop(&mut self) {
        if self.committed {
            return;
        }
        if let Err(error) = self.rollback_in_place() {
            eprintln!("warning: authority AVIF rollback failed during cleanup: {error:#}");
        }
    }
}

struct VcsAttempt {
    temp_output: TempOutputCleanup,
    capture_completion: command::CaptureCompletion,
    stream_timings: StreamTimings,
    encoder_tail: Duration,
    authority: Option<command::AuthorityRecorder>,
}

struct VcsAttemptContext<'a> {
    authority_manifest: Option<&'a std::path::Path>,
    spinner: &'a indicatif::ProgressBar,
    out_parent: &'a std::path::Path,
    file_prefix: &'a str,
    suffix: &'a str,
    is_jpg: bool,
    is_webp: bool,
    labels: &'a [String],
    profile: bool,
}

struct AttemptEncoder {
    child: Option<Child>,
}

impl AttemptEncoder {
    fn new(child: Child) -> Self {
        Self { child: Some(child) }
    }

    fn stdin(&mut self) -> anyhow::Result<std::process::ChildStdin> {
        self.child
            .as_mut()
            .context("encoder attempt has already been closed")?
            .stdin
            .take()
            .context("encoder attempt did not expose stdin")
    }

    fn finish(&mut self, format: &str) -> anyhow::Result<Duration> {
        let tail_started = Instant::now();
        let status = self
            .child
            .as_mut()
            .context("encoder attempt has already been closed")?
            .wait()?;
        self.child.take();
        ensure!(status.success(), "ffmpeg convert-to-{format} failed");
        Ok(tail_started.elapsed())
    }
}

impl Drop for AttemptEncoder {
    fn drop(&mut self) {
        if let Some(child) = self.child.as_mut() {
            let _ = child.kill();
            let _ = child.wait();
        }
    }
}

fn run_vcs_attempt(
    vcs: &Vcs,
    capture: &command::Capture,
    backend: command::CaptureBackendPolicy,
    context: &VcsAttemptContext,
) -> Result<VcsAttempt, command::CaptureAttemptError> {
    ensure_backend_preview_profile(vcs, backend, context.is_jpg, context.is_webp).map_err(
        |error| command::CaptureBackendFailure::unavailable(backend, "eligibility", error),
    )?;

    context.spinner.set_message("Extracting");
    let stream = capture.start(backend, context.authority_manifest.is_some())?;
    let plan = stream.plan();
    let (grid_w, grid_h) = plan.grid_dimensions(vcs.columns);
    let nonce = fastrand::u64(..);
    let temp_output = TempOutputCleanup::new(context.out_parent.join(format!(
        ".{}.{nonce}.tmp.{}",
        context.file_prefix, context.suffix
    )));
    context.spinner.set_message(format!(
        "Encoding {}",
        sh_escape_filename(&temp_output.path)
    ));
    let child = spawn_attempt_encoder(
        vcs,
        &temp_output.path,
        grid_w,
        grid_h,
        context.is_jpg,
        context.is_webp,
    )
    .map_err(command::CaptureAttemptError::fatal)?;
    let mut encoder = AttemptEncoder::new(child);
    let mut authority = context
        .authority_manifest
        .map(|path| command::AuthorityRecorder::new(path.to_owned()))
        .transpose()
        .map_err(command::CaptureAttemptError::fatal)?;
    let stream_timings = {
        let stdin = encoder
            .stdin()
            .map_err(command::CaptureAttemptError::fatal)?;
        let mut writer = std::io::BufWriter::new(stdin);
        context.spinner.set_message("Joining");
        write_stream_frames(
            &stream,
            vcs.columns,
            context.labels,
            &mut writer,
            context.profile,
            &mut authority,
        )?
    };
    let encoder_tail = encoder
        .finish(if context.is_jpg {
            "jpg"
        } else if context.is_webp {
            "webp"
        } else {
            "avif"
        })
        .map_err(command::CaptureAttemptError::fatal)?;
    let capture_completion = stream.finish()?;

    Ok(VcsAttempt {
        temp_output,
        capture_completion,
        stream_timings,
        encoder_tail,
        authority,
    })
}

fn spawn_attempt_encoder(
    vcs: &Vcs,
    output: &std::path::Path,
    grid_w: u32,
    grid_h: u32,
    is_jpg: bool,
    is_webp: bool,
) -> anyhow::Result<Child> {
    let mut command = Command::new("ffmpeg");
    if is_jpg {
        command
            .arg2("-f", "rawvideo")
            .arg2("-pix_fmt", "rgb24")
            .arg2("-s", format!("{grid_w}x{grid_h}"))
            .arg2("-r", vcs.avif_fps)
            .arg2("-i", "pipe:0")
            .arg2("-vframes", "1")
            .arg2("-v", "quiet");
    } else if is_webp {
        command
            .arg2("-v", "quiet")
            .arg2("-f", "rawvideo")
            .arg2("-pix_fmt", "rgb24")
            .arg2("-s", format!("{grid_w}x{grid_h}"))
            .arg2("-r", vcs.avif_fps)
            .arg2("-i", "pipe:0")
            .arg2("-lossless", "0")
            .arg2("-loop", "0")
            .arg2("-c:v", "libwebp")
            .arg2("-vf", "cropdetect=24:16:0, crop=iw-2*24:ih-2*16")
            .arg2("-quality", "60")
            .arg2("-compression_level", "2")
            .arg2("-crf", vcs.avif_crf)
            .arg2("-pix_fmt", "yuv420p10le");
    } else {
        command
            .arg2("-v", "error")
            .arg2("-f", "rawvideo")
            .arg2("-pix_fmt", "rgb24")
            .arg2("-s", format!("{grid_w}x{grid_h}"))
            .arg2("-r", vcs.avif_fps)
            .arg2("-i", "pipe:0")
            .arg2("-c:v", &vcs.avif_codec)
            .arg2(
                match vcs.avif_codec.as_str() {
                    "libaom-av1" => "-cpu-used",
                    _ => "-preset",
                },
                vcs.avif_preset.unwrap_or(match vcs.args.capture_frames() {
                    1 => 4,
                    _ => 8,
                }),
            )
            .arg2("-crf", vcs.avif_crf)
            .arg2("-pix_fmt", "yuv420p10le");
    }
    command
        .arg("-y")
        .arg(output)
        .stdin(Stdio::piped())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .map_err(Into::into)
}

fn write_stream_frames(
    stream: &command::CaptureStream,
    columns: u32,
    labels: &[String],
    writer: &mut std::io::BufWriter<std::process::ChildStdin>,
    profile: bool,
    authority: &mut Option<command::AuthorityRecorder>,
) -> Result<StreamTimings, command::CaptureAttemptError> {
    let started = Instant::now();
    let mut timings = StreamTimings::default();
    let plan = stream.plan();
    let mut pending: BTreeMap<usize, Vec<Option<command::CaptureFrame>>> = BTreeMap::new();
    for expected_frame in 0..plan.capture_frames() {
        while pending
            .get(&expected_frame)
            .is_none_or(|captures| captures.iter().any(Option::is_none))
        {
            let receive_started = profile.then(Instant::now);
            let frame = stream.recv()?;
            if expected_frame == 0 {
                timings.frames_before_first_grid += 1;
            }
            if let Some(receive_started) = receive_started {
                timings.receive_wait += receive_started.elapsed();
            }
            if frame.animation_index < expected_frame
                || frame.animation_index >= plan.capture_frames()
            {
                return Err(stream
                    .attempt_failure(
                        "validation",
                        anyhow::anyhow!(
                            "extraction emitted an out-of-order frame {} while waiting for {expected_frame}",
                            frame.animation_index,
                        ),
                    )
                    .into());
            }
            if frame.capture_index >= plan.capture_count() {
                return Err(stream
                    .attempt_failure(
                        "validation",
                        anyhow::anyhow!(
                            "extraction emitted an invalid capture index {}",
                            frame.capture_index,
                        ),
                    )
                    .into());
            }
            let captures = pending
                .entry(frame.animation_index)
                .or_insert_with(|| (0..plan.capture_count()).map(|_| None).collect());
            if captures[frame.capture_index].is_some() {
                return Err(stream
                    .attempt_failure(
                        "validation",
                        anyhow::anyhow!(
                            "extraction emitted a duplicate frame for capture {} index {}",
                            frame.capture_index,
                            frame.animation_index,
                        ),
                    )
                    .into());
            }
            let capture_index = frame.capture_index;
            captures[capture_index] = Some(frame);
        }

        let captures = pending.remove(&expected_frame).unwrap();
        let images: Vec<_> = captures
            .iter()
            .map(|frame| {
                &frame
                    .as_ref()
                    .expect("complete frame was checked above")
                    .image
            })
            .collect();
        if expected_frame == 0 {
            timings.first_grid = started.elapsed();
        }
        let join_started = profile.then(Instant::now);
        let grid = command::join_from_memory(&images, columns, labels)
            .map_err(command::CaptureAttemptError::fatal)?;
        if let Some(join_started) = join_started {
            timings.join += join_started.elapsed();
        }
        if let Some(authority) = authority {
            authority
                .record_grid(expected_frame, &grid)
                .map_err(command::CaptureAttemptError::fatal)?;
        }
        let write_started = profile.then(Instant::now);
        writer
            .write_all(grid.as_raw())
            .map_err(|error| command::CaptureAttemptError::fatal(error.into()))?;
        if let Some(write_started) = write_started {
            timings.encoder_write += write_started.elapsed();
        }
    }
    writer
        .flush()
        .map_err(|error| command::CaptureAttemptError::fatal(error.into()))?;
    Ok(timings)
}

#[cfg(test)]
mod tests {
    use super::*;
    use clap::Parser;

    #[test]
    fn in_process_backends_require_the_fixed_preview_encoding_profile() {
        let mut vcs = Vcs::try_parse_from(["vimg", "-c3", "-H160", "-n9", "input.mkv"]).unwrap();
        vcs.args.capture_frames = Some(30);
        vcs.capture_backend = command::CaptureBackendPolicy::Libav;

        assert!(ensure_in_process_preview_profile(&vcs, false, false).is_ok());

        vcs.avif_crf = 31;
        assert_eq!(
            ensure_in_process_preview_profile(&vcs, false, false)
                .unwrap_err()
                .to_string(),
            "Capture backend libav is unavailable: requires the fixed Preview profile"
        );

        vcs.capture_backend = command::CaptureBackendPolicy::VideoToolbox;
        assert_eq!(
            ensure_in_process_preview_profile(&vcs, false, false)
                .unwrap_err()
                .to_string(),
            "Capture backend videotoolbox is unavailable: requires the fixed Preview profile"
        );
    }

    #[test]
    fn direct_vcs_skips_in_process_candidates_for_a_non_preview_profile() {
        let mut vcs = Vcs::try_parse_from(["vimg", "-c3", "-H160", "-n9", "input.mkv"]).unwrap();
        vcs.args.capture_frames = Some(30);
        vcs.avif_crf = 31;

        for backend in [
            command::CaptureBackendPolicy::VideoToolbox,
            command::CaptureBackendPolicy::Libav,
        ] {
            assert_eq!(
                ensure_backend_preview_profile(&vcs, backend, false, false)
                    .unwrap_err()
                    .to_string(),
                format!(
                    "Capture backend {} is unavailable: requires the fixed Preview profile",
                    backend.name()
                )
            );
        }
        assert!(
            ensure_backend_preview_profile(
                &vcs,
                command::CaptureBackendPolicy::Ffmpeg,
                false,
                false,
            )
            .is_ok()
        );
    }

    #[test]
    fn videotoolbox_uses_the_documented_capture_backend_value() {
        let vcs = Vcs::try_parse_from([
            "vimg",
            "--capture-backend",
            "videotoolbox",
            "-c3",
            "-H160",
            "-n9",
            "input.mkv",
        ])
        .unwrap();

        assert_eq!(
            vcs.capture_backend,
            command::CaptureBackendPolicy::VideoToolbox
        );
    }

    #[test]
    fn uncommitted_output_publication_restores_previous_output() {
        let root = temporary_test_dir("output-rollback");
        let output = root.join("output.avif");
        let temporary = root.join("temporary.avif");
        fs::write(&output, b"old").unwrap();
        fs::write(&temporary, b"new").unwrap();

        let publication = OutputPublication::publish(&temporary, &output).unwrap();
        assert_eq!(fs::read(&output).unwrap(), b"new");
        drop(publication);

        assert_eq!(fs::read(&output).unwrap(), b"old");
        assert!(!temporary.exists());
        assert_eq!(fs::read_dir(&root).unwrap().count(), 1);
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn committed_output_publication_keeps_new_output() {
        let root = temporary_test_dir("output-commit");
        let output = root.join("output.avif");
        let temporary = root.join("temporary.avif");
        fs::write(&output, b"old").unwrap();
        fs::write(&temporary, b"new").unwrap();

        OutputPublication::publish(&temporary, &output)
            .unwrap()
            .commit();

        assert_eq!(fs::read(&output).unwrap(), b"new");
        assert!(!temporary.exists());
        assert_eq!(fs::read_dir(&root).unwrap().count(), 1);
        fs::remove_dir_all(root).unwrap();
    }

    fn temporary_test_dir(label: &str) -> PathBuf {
        let path = std::env::temp_dir().join(format!("vimg-{label}-{}", fastrand::u64(..)));
        fs::create_dir(&path).unwrap();
        path
    }
}
