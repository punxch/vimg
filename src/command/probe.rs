use anyhow::{Context, ensure};
use serde_json::Value;
use std::{io::Write, path::PathBuf, process::Command};

/// Print preview metadata as JSON (duration, video streams and attached pictures).
#[derive(clap::Parser, Debug)]
pub struct Probe {
    /// Video file input.
    pub video: PathBuf,
}

impl Probe {
    pub fn run(&self) -> anyhow::Result<()> {
        let mut metadata = self.metadata()?;
        // Let the plugin bypass this helper on later previews in feature-off
        // installations, without mistaking a per-file fallback for a missing capability.
        metadata["native_probe"] = Value::Bool(cfg!(feature = "in-process-decode"));
        let mut stdout = std::io::stdout().lock();
        serde_json::to_writer(&mut stdout, &metadata)?;
        writeln!(stdout)?;
        Ok(())
    }

    fn metadata(&self) -> anyhow::Result<Value> {
        #[cfg(feature = "in-process-decode")]
        if let Ok(metadata) = native_metadata(&self.video) {
            return Ok(metadata);
        }

        // Keep feature-off builds and inputs unsupported by the linked libav
        // usable with the user's ffprobe, without publishing partial metadata.
        let output = Command::new("ffprobe")
            .args([
                "-v", "quiet", "-select_streams", "v", "-show_entries",
                "format=duration:stream=codec_name,codec_type,width,height,time_base:stream_disposition=attached_pic",
                "-of", "json=c=1",
            ])
            .arg(&self.video)
            .output()
            .context("starting ffprobe for preview metadata")?;
        ensure!(output.status.success(), "ffprobe failed: {}", output.status);
        serde_json::from_slice(&output.stdout).context("invalid ffprobe metadata JSON")
    }
}

#[cfg(feature = "in-process-decode")]
fn native_metadata(video: &std::path::Path) -> anyhow::Result<Value> {
    metadata_from_input(&open_input(video)?)
}

#[cfg(feature = "in-process-decode")]
pub(super) fn open_input(
    video: &std::path::Path,
) -> anyhow::Result<ffmpeg_next::format::context::Input> {
    use ffmpeg_next as ffmpeg;

    ffmpeg::init().context("initializing software libav")?;
    // Match ffprobe's MPEG-TS program discovery. input_with_dictionary still
    // performs avformat_find_stream_info; do not shorten probing heuristics.
    let mut options = ffmpeg::Dictionary::new();
    options.set("scan_all_pmts", "1");
    Ok(ffmpeg::format::input_with_dictionary(video, options)?)
}

#[cfg(feature = "in-process-decode")]
pub(super) fn metadata_from_input(
    input: &ffmpeg_next::format::context::Input,
) -> anyhow::Result<Value> {
    use ffmpeg_next::{self as ffmpeg, format::stream::Disposition, media::Type};
    use serde_json::json;

    ensure!(input.duration() > 0, "missing video duration");
    let mut streams = Vec::new();
    for stream in input.streams() {
        let parameters = stream.parameters();
        if parameters.medium() != Type::Video {
            continue;
        }
        let (width, height) = unsafe {
            // Parameters remain owned by this stream while these fields are read.
            let raw = parameters.as_ptr();
            ((*raw).width, (*raw).height)
        };
        let codec = parameters.id().name();
        let time_base = stream.time_base();
        ensure!(
            width > 0 && height > 0 && codec != "none",
            "incomplete video stream"
        );
        ensure!(
            time_base.numerator() > 0 && time_base.denominator() > 0,
            "invalid video time base"
        );
        streams.push(json!({
            "codec_type": "video", "codec_name": codec,
            "width": width, "height": height,
            "time_base": format!("{}/{}", time_base.numerator(), time_base.denominator()),
            "disposition": {
                "attached_pic": i32::from(stream.disposition().contains(Disposition::ATTACHED_PIC))
            }
        }));
    }
    ensure!(!streams.is_empty(), "no video streams");
    Ok(json!({
        "format": {
            // Preserve ffprobe's six-decimal string, rather than rounding via f32.
            "duration": format!("{:.6}", input.duration() as f64 / f64::from(ffmpeg::ffi::AV_TIME_BASE))
        },
        "streams": streams
    }))
}
