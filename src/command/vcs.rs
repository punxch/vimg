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
    process::{Command, Stdio},
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

    /// Test-only authority manifest requested by `vimg authority record`.
    #[arg(skip)]
    pub(crate) authority_manifest: Option<PathBuf>,
}

impl Vcs {
    pub fn run(mut self) -> anyhow::Result<()> {
        let profile = self.profile;
        let authority_manifest = self.authority_manifest.take();
        let authority_enabled = authority_manifest.is_some();
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

        let ex_scale = self.extract_scale();
        self.args.vfilter = match (self.args.vfilter, ex_scale) {
            (Some(vf), Some(scale)) => Some(format!("{vf},{scale}")),
            (vf, scale) => vf.or(scale),
        };

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
        let mut authority = authority_manifest
            .map(command::AuthorityRecorder::new)
            .transpose()?;

        let spinner = indicatif::ProgressBar::new_spinner().with_style(
            indicatif::ProgressStyle::default_spinner()
                .template("{spinner:.cyan.bold} {elapsed_precise:.bold} {msg}")?,
        );
        spinner.enable_steady_tick(Duration::from_millis(100));

        // Start bounded extraction before the encoder. The workers block on a small
        // frame channel while the encoder consumes complete grids in order.
        spinner.set_message("Extracting");
        let setup_started = Instant::now();
        let extract =
            self.args
                .stream_pipe(self.capture_height, self.capture_width, authority_enabled)?;
        let setup_elapsed = setup_started.elapsed();

        // Join and encode one frame at a time. The stream holds at most two frames
        // per extraction worker, plus the single grid currently being encoded.
        spinner.set_message("Joining");
        let labels = &extract.labels;

        let out_parent = out_file
            .parent()
            .unwrap_or_else(|| std::path::Path::new("."));
        fs::create_dir_all(out_parent)?;
        let nonce = fastrand::u64(..);
        let temp_out_file = out_parent.join(format!(".{file_prefix}.{nonce}.tmp.{suffix}"));
        let mut temp_output_cleanup = TempOutputCleanup::new(temp_out_file.clone());

        let capture_count = extract.capture_count as u32;
        let (rows, cols) = if self.columns == 0 || capture_count <= self.columns {
            (1, capture_count)
        } else {
            (capture_count.div_ceil(self.columns), self.columns)
        };
        let grid_w = extract.frame_width * cols;
        let grid_h = extract.frame_height * rows;
        let capture_frames = extract.capture_frames;
        let capture_width = extract.frame_width;
        let capture_height = extract.frame_height;
        // Encode by piping raw frames to ffmpeg (no intermediate BMP files)
        spinner.set_message(format!("Encoding {}", sh_escape_filename(&out_file)));
        let stream_timings;
        let encoder_tail;

        if is_jpg {
            let mut child = Command::new("ffmpeg")
                .arg2("-f", "rawvideo")
                .arg2("-pix_fmt", "rgb24")
                .arg2("-s", format!("{grid_w}x{grid_h}"))
                .arg2("-r", self.avif_fps)
                .arg2("-i", "pipe:0")
                .arg2("-vframes", "1")
                .arg2("-v", "quiet")
                .arg("-y")
                .arg(&temp_out_file)
                .stdin(Stdio::piped())
                .stdout(Stdio::null())
                .spawn()?;

            {
                let stdin = child.stdin.take().unwrap();
                let mut writer = std::io::BufWriter::new(stdin);
                stream_timings = write_stream_frames(
                    &extract,
                    self.columns,
                    labels,
                    &mut writer,
                    profile,
                    &mut authority,
                )?;
            }

            let tail_started = Instant::now();
            let out = child.wait_with_output()?;
            encoder_tail = tail_started.elapsed();
            ensure!(out.status.success(), "ffmpeg convert-to-jpg failed");
        } else if is_webp {
            let mut child = Command::new("ffmpeg")
                .arg2("-v", "quiet")
                .arg2("-f", "rawvideo")
                .arg2("-pix_fmt", "rgb24")
                .arg2("-s", format!("{grid_w}x{grid_h}"))
                .arg2("-r", self.avif_fps)
                .arg2("-i", "pipe:0")
                .arg2("-lossless", "0")
                .arg2("-loop", "0")
                .arg2("-c:v", "libwebp")
                .arg2("-vf", "cropdetect=24:16:0, crop=iw-2*24:ih-2*16")
                .arg2("-quality", "60")
                .arg2("-compression_level", "2")
                .arg2("-crf", self.avif_crf)
                .arg2("-pix_fmt", "yuv420p10le")
                .arg("-y")
                .arg(&temp_out_file)
                .stdin(Stdio::piped())
                .stdout(Stdio::null())
                .spawn()?;

            {
                let stdin = child.stdin.take().unwrap();
                let mut writer = std::io::BufWriter::new(stdin);
                stream_timings = write_stream_frames(
                    &extract,
                    self.columns,
                    labels,
                    &mut writer,
                    profile,
                    &mut authority,
                )?;
            }

            let tail_started = Instant::now();
            let out = child.wait_with_output()?;
            encoder_tail = tail_started.elapsed();
            ensure!(
                out.status.success(),
                "ffmpeg convert-to-webp failed\n---stderr---\n{}\n------",
                String::from_utf8_lossy(&out.stderr).trim(),
            );
        } else {
            let mut child = Command::new("ffmpeg")
                .arg2("-v", "error")
                .arg2("-f", "rawvideo")
                .arg2("-pix_fmt", "rgb24")
                .arg2("-s", format!("{grid_w}x{grid_h}"))
                .arg2("-r", self.avif_fps)
                .arg2("-i", "pipe:0")
                .arg2("-c:v", &self.avif_codec)
                .arg2(
                    match self.avif_codec.as_str() {
                        "libaom-av1" => "-cpu-used",
                        _ => "-preset",
                    },
                    self.avif_preset
                        .unwrap_or(match self.args.capture_frames() {
                            1 => 4,
                            _ => 8,
                        }),
                )
                .arg2("-crf", self.avif_crf)
                .arg2("-pix_fmt", "yuv420p10le")
                .arg("-y")
                .arg(&temp_out_file)
                .stdin(Stdio::piped())
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .spawn()?;

            {
                let stdin = child.stdin.take().unwrap();
                let mut writer = std::io::BufWriter::new(stdin);
                stream_timings = write_stream_frames(
                    &extract,
                    self.columns,
                    labels,
                    &mut writer,
                    profile,
                    &mut authority,
                )?;
            }

            let tail_started = Instant::now();
            let out = child.wait_with_output()?;
            encoder_tail = tail_started.elapsed();
            ensure!(
                out.status.success(),
                "ffmpeg convert-to-avif failed\n---stderr---\n{}\n------",
                String::from_utf8_lossy(&out.stderr).trim(),
            );
        }

        let capture_authority = extract.finish()?;
        let prepared_authority = if let Some(mut authority) = authority.take() {
            for capture in capture_authority {
                for (animation_index, source) in capture.frames.iter().enumerate() {
                    authority.record(animation_index, capture.capture_index, source);
                }
            }
            Some(authority.prepare(command::AuthorityProfile {
                input: &self.args.video,
                encoded_output: &temp_out_file,
                output: &out_file,
                columns: self.columns,
                capture_count: capture_count as usize,
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
            let publication = OutputPublication::publish(&temp_out_file, &out_file)?;
            temp_output_cleanup.disarm();
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
        } else if let Err(rename_error) = fs::rename(&temp_out_file, &out_file) {
            // Windows does not replace an existing destination with rename. Both
            // files are in the cache directory, so this fallback never exposes a
            // partially copied AVIF; readers see either the old file or no file.
            if out_file.exists() {
                fs::remove_file(&out_file)?;
                fs::rename(&temp_out_file, &out_file)?;
            } else {
                return Err(rename_error.into());
            }
            temp_output_cleanup.disarm();
        } else {
            temp_output_cleanup.disarm();
        }

        spinner.finish();
        if profile {
            eprintln!(
                "[profile] setup={:.3}s first_grid={:.3}s frames_before_first_grid={} receive_wait={:.3}s join={:.3}s encoder_write={:.3}s encoder_tail={:.3}s total={:.3}s",
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

    fn extract_scale(&self) -> Option<String> {
        if let Some(h) = self.capture_height {
            return Some(format!("scale=-1:{h}:flags=bicubic"));
        }
        let w = self.capture_width?;
        Some(format!("scale={w}:-1:flags=bicubic"))
    }
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

fn write_stream_frames(
    stream: &command::PipeExtractStream,
    columns: u32,
    labels: &[String],
    writer: &mut std::io::BufWriter<std::process::ChildStdin>,
    profile: bool,
    authority: &mut Option<command::AuthorityRecorder>,
) -> anyhow::Result<StreamTimings> {
    let started = Instant::now();
    let mut timings = StreamTimings::default();
    let mut pending: BTreeMap<usize, Vec<Option<command::PipeFrame>>> = BTreeMap::new();
    for expected_frame in 0..stream.capture_frames {
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
            ensure!(
                frame.frame_index >= expected_frame && frame.frame_index < stream.capture_frames,
                "extraction emitted an out-of-order frame {} while waiting for {expected_frame}",
                frame.frame_index,
            );
            ensure!(
                frame.capture_index < stream.capture_count,
                "extraction emitted an invalid capture index {}",
                frame.capture_index,
            );
            let captures = pending
                .entry(frame.frame_index)
                .or_insert_with(|| (0..stream.capture_count).map(|_| None).collect());
            ensure!(
                captures[frame.capture_index].is_none(),
                "extraction emitted a duplicate frame for capture {} index {}",
                frame.capture_index,
                frame.frame_index,
            );
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
        let grid = command::join_from_memory(&images, columns, labels)?;
        if let Some(join_started) = join_started {
            timings.join += join_started.elapsed();
        }
        if let Some(authority) = authority {
            authority.record_grid(expected_frame, &grid)?;
        }
        let write_started = profile.then(Instant::now);
        writer.write_all(grid.as_raw())?;
        if let Some(write_started) = write_started {
            timings.encoder_write += write_started.elapsed();
        }
    }
    writer.flush()?;
    Ok(timings)
}

#[cfg(test)]
mod tests {
    use super::*;

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
