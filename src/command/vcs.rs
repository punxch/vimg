use crate::{
    command::{self, label, sh_escape, sh_escape_filename},
    process::CommandExt,
    temporary,
};
use anyhow::ensure;
use rayon::prelude::{IntoParallelIterator, ParallelIterator};
use std::{
    fs, io::Write,
    path::PathBuf,
    process::{Command, Stdio},
    time::Duration,
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
}

impl Vcs {
    pub fn run(mut self) -> anyhow::Result<()> {
        let is_jpg = self
            .output
            .as_ref()
            .is_some_and(|p| {
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

        let spinner = indicatif::ProgressBar::new_spinner().with_style(
            indicatif::ProgressStyle::default_spinner()
                .template("{spinner:.cyan.bold} {elapsed_precise:.bold} {msg}")?,
        );
        spinner.enable_steady_tick(Duration::from_millis(100));

        // Extract frames in memory (pipe-based, no temp BMP files)
        spinner.set_message("Extracting");
        let extract = self.args.run_pipe(self.capture_height, self.capture_width)?;

        for msg in &extract.warnings {
            spinner.println(format!("Warning: {msg}"));
        }

        // Join frames in memory
        spinner.set_message("Joining");
        let labels: Vec<String> = extract
            .captures
            .iter()
            .map(|c| label::seconds_text(c.seconds))
            .collect();

        let joined_frames: Vec<image::RgbImage> = (0..self.args.capture_frames())
            .into_par_iter()
            .map(|f| {
                let frame_images: Vec<image::RgbImage> = extract
                    .captures
                    .iter()
                    .map(|c| c.frames[f as usize].clone())
                    .collect();
                command::join_from_memory(&frame_images, self.columns, &labels)
            })
            .collect::<anyhow::Result<Vec<_>>>()?;

        // Output file path
        let file_prefix = self.args.video.with_extension("");
        let file_prefix = file_prefix
            .file_name()
            .unwrap_or_default()
            .to_string_lossy()
            .replace('%', "");

        let suffix = if is_jpg { "jpg" } else if is_webp { "webp" } else { "avif" };
        let temp_dir = temporary::process_dir(self.args.output_dir.clone(), !self.keep);
        let temp_out_file = {
            let mut o = temp_dir.clone();
            o.push(format!("{file_prefix}.{suffix}"));
            o
        };
        let out_file = self.output.unwrap_or_else(|| {
            let mut o = parent_dir;
            o.push(format!("{file_prefix}.{suffix}"));
            o
        });

        if self.keep {
            spinner.println(format!(
                "Keeping temporary files in {}",
                sh_escape(&temp_dir)
            ));
        }

        // Encode by piping raw frames to ffmpeg (no intermediate BMP files)
        let (grid_w, grid_h) = (joined_frames[0].width(), joined_frames[0].height());
        spinner.set_message(format!("Encoding {}", sh_escape_filename(&out_file)));

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
                for frame in &joined_frames {
                    writer.write_all(frame.as_raw())?;
                }
                writer.flush()?;
            }

            let out = child.wait_with_output()?;
            ensure!(
                out.status.success(),
                "ffmpeg convert-to-jpg failed"
            );
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
                for frame in &joined_frames {
                    writer.write_all(frame.as_raw())?;
                }
                writer.flush()?;
            }

            let out = child.wait_with_output()?;
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
                for frame in &joined_frames {
                    writer.write_all(frame.as_raw())?;
                }
                writer.flush()?;
            }

            let out = child.wait_with_output()?;
            ensure!(
                out.status.success(),
                "ffmpeg convert-to-avif failed\n---stderr---\n{}\n------",
                String::from_utf8_lossy(&out.stderr).trim(),
            );
        }

        fs::rename(&temp_out_file, &out_file)
            .or_else(|_| fs::copy(&temp_out_file, &out_file).map(|_| ()))?;

        spinner.finish();
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
