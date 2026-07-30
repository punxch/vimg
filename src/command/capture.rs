//! One bounded Capture backend interface for VCS orchestration.

use crate::command::{
    CaptureAuthority, Extract, PipeExtractStream,
    frame_schedule::{CaptureWindow, FrameSchedule, Rational},
    label,
};
use anyhow::{Context, ensure};
use image::RgbImage;

/// Normalized shared inputs for one Capture attempt.
pub(crate) struct CapturePlan {
    #[cfg_attr(
        not(test),
        allow(
            dead_code,
            reason = "future Capture backends reuse normalized media without probing again"
        )
    )]
    media: MediaProperties,
    #[cfg_attr(
        not(test),
        allow(
            dead_code,
            reason = "future Capture backends consume materialized schedules from the shared plan"
        )
    )]
    schedules: Vec<FrameSchedule>,
    video: std::path::PathBuf,
    vfilter: Option<String>,
    #[cfg_attr(
        not(feature = "in-process-decode"),
        allow(
            dead_code,
            reason = "only the optional libav backend distinguishes custom filters from planned scaling"
        )
    )]
    has_custom_video_filter: bool,
    windows: Vec<CaptureWindow>,
    frame_width: u32,
    frame_height: u32,
    labels: Vec<String>,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub(crate) struct MediaProperties {
    pub(crate) duration_s: f32,
    pub(crate) width: u32,
    pub(crate) height: u32,
    pub(crate) source_time_base: Rational,
}

impl CapturePlan {
    fn from_extract(
        extract: &Extract,
        capture_height: Option<u32>,
        capture_width: Option<u32>,
    ) -> anyhow::Result<Self> {
        let media = media_properties(extract)?;
        let video_duration_s = media.duration_s;
        let (frame_width, frame_height) =
            scaled_dimensions(media.width, media.height, capture_height, capture_width);
        let vfilter = match (
            extract.vfilter.clone(),
            scale_filter(capture_height, capture_width),
        ) {
            (Some(filter), Some(scale)) => Some(format!("{filter},{scale}")),
            (filter, scale) => filter.or(scale),
        };
        let available_duration_s = video_duration_s
            - extract.ignore_start.to_secs(video_duration_s)
            - extract.ignore_end.to_secs(video_duration_s);
        ensure!(
            available_duration_s > 0.0,
            "invalid negative video duration minus offsets"
        );
        let capture_frames = extract.capture_frames() as usize;
        let interval = available_duration_s / extract.number as f32;
        let windows = (0..extract.number)
            .map(|capture_index| {
                let start_s = extract.ignore_start.to_secs(video_duration_s)
                    + interval * 0.5
                    + interval * capture_index as f32;
                CaptureWindow::new(
                    capture_index as usize,
                    start_s.min(video_duration_s - extract.capture_time.seconds),
                    extract.capture_time.seconds,
                    capture_frames,
                )
            })
            .collect::<anyhow::Result<Vec<_>>>()?;
        let labels = windows
            .iter()
            .map(|window| label::seconds_text(window.start_s() as u32))
            .collect();
        let schedules = windows
            .iter()
            .map(|window| window.schedule(media.source_time_base))
            .collect::<anyhow::Result<Vec<_>>>()?;

        Ok(Self {
            media,
            schedules,
            video: extract.video.clone(),
            vfilter,
            has_custom_video_filter: extract.vfilter.is_some(),
            windows,
            frame_width,
            frame_height,
            labels,
        })
    }

    pub(crate) fn capture_count(&self) -> usize {
        self.windows.len()
    }

    #[cfg_attr(
        not(test),
        allow(
            dead_code,
            reason = "future Capture backends inspect normalized media from the shared plan"
        )
    )]
    pub(crate) const fn media(&self) -> MediaProperties {
        self.media
    }

    pub(crate) fn capture_frames(&self) -> usize {
        self.windows
            .first()
            .map_or(0, |window| window.frame_count())
    }

    pub(crate) const fn frame_dimensions(&self) -> (u32, u32) {
        (self.frame_width, self.frame_height)
    }

    pub(crate) fn grid_dimensions(&self, columns: u32) -> (u32, u32) {
        let capture_count = self.capture_count() as u32;
        let (rows, columns) = if columns == 0 || capture_count <= columns {
            (1, capture_count)
        } else {
            (capture_count.div_ceil(columns), columns)
        };
        (self.frame_width * columns, self.frame_height * rows)
    }

    pub(crate) fn labels(&self) -> &[String] {
        &self.labels
    }

    pub(crate) fn windows(&self) -> &[CaptureWindow] {
        &self.windows
    }
    #[cfg_attr(
        not(test),
        allow(
            dead_code,
            reason = "future Capture backends consume materialized schedules from the shared plan"
        )
    )]
    pub(crate) fn schedules(&self) -> &[FrameSchedule] {
        &self.schedules
    }

    pub(crate) fn video(&self) -> &std::path::Path {
        &self.video
    }

    pub(crate) fn vfilter(&self) -> Option<&str> {
        self.vfilter.as_deref()
    }

    #[cfg_attr(
        not(feature = "in-process-decode"),
        allow(
            dead_code,
            reason = "only the optional libav backend distinguishes custom filters from planned scaling"
        )
    )]
    pub(crate) const fn has_custom_video_filter(&self) -> bool {
        self.has_custom_video_filter
    }
}

/// The only Capture interface used by VCS orchestration in this stage.
pub(crate) struct Capture {
    plan: CapturePlan,
}

#[derive(clap::ValueEnum, Clone, Copy, Debug, Default, Eq, PartialEq)]
pub enum CaptureBackendPolicy {
    #[default]
    Ffmpeg,
    Libav,
}

impl Capture {
    pub(crate) fn plan(
        extract: &Extract,
        capture_height: Option<u32>,
        capture_width: Option<u32>,
    ) -> anyhow::Result<Self> {
        Ok(Self {
            plan: CapturePlan::from_extract(extract, capture_height, capture_width)?,
        })
    }

    #[cfg(test)]
    pub(crate) const fn plan_ref(&self) -> &CapturePlan {
        &self.plan
    }

    pub(crate) fn start(
        &self,
        policy: CaptureBackendPolicy,
        authority: bool,
    ) -> anyhow::Result<CaptureStream<'_>> {
        let inner: Box<dyn CaptureAttempt> = match policy {
            CaptureBackendPolicy::Ffmpeg => FfmpegCaptureBackend.start(&self.plan, authority)?,
            CaptureBackendPolicy::Libav => libav_attempt(&self.plan, authority)?,
        };
        Ok(CaptureStream {
            inner,
            plan: &self.plan,
        })
    }
}

#[cfg(feature = "in-process-decode")]
fn libav_attempt(plan: &CapturePlan, authority: bool) -> anyhow::Result<Box<dyn CaptureAttempt>> {
    crate::command::libav::start(plan, authority)
}

#[cfg(not(feature = "in-process-decode"))]
fn libav_attempt(_: &CapturePlan, _: bool) -> anyhow::Result<Box<dyn CaptureAttempt>> {
    anyhow::bail!("Capture backend libav is unavailable: rebuild with --features in-process-decode")
}

trait CaptureBackend {
    fn start(&self, plan: &CapturePlan, authority: bool)
    -> anyhow::Result<Box<dyn CaptureAttempt>>;
}

struct FfmpegCaptureBackend;

impl CaptureBackend for FfmpegCaptureBackend {
    fn start(
        &self,
        plan: &CapturePlan,
        authority: bool,
    ) -> anyhow::Result<Box<dyn CaptureAttempt>> {
        Ok(Box::new(FfmpegCaptureAttempt {
            inner: Extract::stream_pipe(plan, authority)?,
        }))
    }
}

/// Bounded ordered frames supplied by the selected Capture backend.
pub(crate) struct CaptureStream<'plan> {
    inner: Box<dyn CaptureAttempt>,
    plan: &'plan CapturePlan,
}

pub(crate) struct CaptureFrame {
    pub(crate) capture_index: usize,
    pub(crate) animation_index: usize,
    pub(crate) image: RgbImage,
}

pub(crate) struct CaptureCompletion {
    pub(crate) authority: Vec<CaptureAuthority>,
    pub(crate) diagnostics: CaptureDiagnostics,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) struct CaptureDiagnostics {
    pub(crate) backend: &'static str,
}

pub(crate) trait CaptureAttempt {
    fn recv(&self) -> anyhow::Result<CaptureFrame>;
    fn finish(self: Box<Self>) -> anyhow::Result<CaptureCompletion>;
}

struct FfmpegCaptureAttempt {
    inner: PipeExtractStream,
}

impl CaptureAttempt for FfmpegCaptureAttempt {
    fn recv(&self) -> anyhow::Result<CaptureFrame> {
        let frame = self.inner.recv()?;
        Ok(CaptureFrame {
            capture_index: frame.capture_index,
            animation_index: frame.frame_index,
            image: frame.image,
        })
    }

    fn finish(self: Box<Self>) -> anyhow::Result<CaptureCompletion> {
        Ok(CaptureCompletion {
            authority: self.inner.finish()?,
            diagnostics: CaptureDiagnostics { backend: "ffmpeg" },
        })
    }
}

impl CaptureStream<'_> {
    pub(crate) fn recv(&self) -> anyhow::Result<CaptureFrame> {
        self.inner.recv()
    }

    pub(crate) fn finish(self) -> anyhow::Result<CaptureCompletion> {
        self.inner.finish()
    }

    pub(crate) const fn plan(&self) -> &CapturePlan {
        self.plan
    }
}

fn media_properties(extract: &Extract) -> anyhow::Result<MediaProperties> {
    let descriptor = extract.media.as_ref();
    let needs_probe = descriptor.is_none_or(|media| {
        media.duration_s.is_none()
            || media.width.is_none()
            || media.height.is_none()
            || media.source_time_base.is_none()
    });
    let probe = needs_probe
        .then(|| ffprobe::ffprobe(&extract.video))
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
    let source_time_base = match descriptor.and_then(|media| media.source_time_base) {
        Some(source_time_base) => source_time_base,
        None => {
            let time_base = stream()
                .map(|stream| stream.time_base.as_str())
                .context("selected video stream has no time base")?;
            let (numerator, denominator) = time_base
                .split_once('/')
                .context("invalid source time base")?;
            Rational::new(numerator.parse()?, denominator.parse()?)
        }
    };
    Ok(MediaProperties {
        duration_s,
        width,
        height,
        source_time_base,
    })
}

fn scaled_dimensions(
    original_width: u32,
    original_height: u32,
    target_height: Option<u32>,
    target_width: Option<u32>,
) -> (u32, u32) {
    match (target_width, target_height) {
        (_, Some(height)) => {
            let width =
                ((original_width as f64 * height as f64) / original_height as f64).round() as u32;
            (if width % 2 == 0 { width } else { width + 1 }, height)
        }
        (Some(width), _) => {
            let height =
                ((original_height as f64 * width as f64) / original_width as f64).round() as u32;
            (width, if height % 2 == 0 { height } else { height + 1 })
        }
        _ => (original_width, original_height),
    }
}

fn scale_filter(capture_height: Option<u32>, capture_width: Option<u32>) -> Option<String> {
    capture_height
        .map(|height| format!("scale=-1:{height}:flags=bicubic"))
        .or_else(|| capture_width.map(|width| format!("scale={width}:-1:flags=bicubic")))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::command::{DurationOrPercent, Extract, HumanDuration, MediaDescriptor};
    use std::path::PathBuf;

    fn preview_extract(video: impl Into<PathBuf>) -> Extract {
        Extract {
            number: 9,
            ignore_start: DurationOrPercent::Seconds(0.0),
            ignore_end: DurationOrPercent::Seconds(0.0),
            capture_frames: Some(30),
            capture_time: HumanDuration { seconds: 1.5 },
            vfilter: None,
            threads: 4,
            output_dir: None,
            video: video.into(),
            media: Some(MediaDescriptor {
                duration_s: Some(18.0),
                width: Some(1920),
                height: Some(1080),
                source_time_base: Some(Rational::new(1, 1_000)),
            }),
        }
    }

    #[test]
    fn preview_capture_plan_normalizes_media_windows_dimensions_and_labels_once() {
        let extract = preview_extract("preview.mkv");

        let capture = Capture::plan(&extract, Some(160), None).unwrap();
        let plan = capture.plan_ref();

        assert_eq!(plan.capture_count(), 9);
        assert_eq!(plan.capture_frames(), 30);
        assert_eq!(
            plan.media(),
            MediaProperties {
                duration_s: 18.0,
                width: 1920,
                height: 1080,
                source_time_base: Rational::new(1, 1_000),
            }
        );
        assert_eq!(plan.schedules().len(), 9);
        assert!(plan.schedules().iter().all(|schedule| {
            schedule.source_time_base() == Rational::new(1, 1_000)
                && schedule.frame_count() == 30
                && !schedule.is_complete()
        }));
        assert_eq!(plan.frame_dimensions(), (284, 160));
        assert_eq!(plan.grid_dimensions(3), (852, 480));
        assert_eq!(
            plan.labels(),
            [
                "00:01", "00:03", "00:05", "00:07", "00:09", "00:11", "00:13", "00:15", "00:16"
            ]
        );
    }

    #[cfg(not(feature = "in-process-decode"))]
    #[test]
    fn explicit_libav_policy_fails_fast_without_the_optional_build_feature() {
        let capture = Capture::plan(&preview_extract("preview.mkv"), Some(160), None).unwrap();

        let error = capture
            .start(CaptureBackendPolicy::Libav, false)
            .err()
            .expect("feature-off libav policy must be unavailable");

        assert_eq!(
            error.to_string(),
            "Capture backend libav is unavailable: rebuild with --features in-process-decode"
        );
    }

    #[test]
    #[ignore = "requires FFmpeg and the representative Preview input"]
    fn ffmpeg_capture_stream_emits_complete_preview_frames_and_authority() {
        let capture = Capture::plan(&preview_extract("sample/input.mkv"), Some(160), None).unwrap();
        let stream = capture.start(CaptureBackendPolicy::Ffmpeg, true).unwrap();
        let plan = stream.plan();
        let capture_count = plan.capture_count();
        let capture_frames = plan.capture_frames();
        let frame_dimensions = plan.frame_dimensions();

        for _ in 0..capture_count * capture_frames {
            let frame = stream.recv().unwrap();
            assert!(frame.capture_index < capture_count);
            assert!(frame.animation_index < capture_frames);
            assert_eq!(frame.image.dimensions(), frame_dimensions);
        }

        let completion = stream.finish().unwrap();
        assert_eq!(completion.authority.len(), capture_count);
        assert_eq!(completion.diagnostics.backend, "ffmpeg");
        assert!(
            completion
                .authority
                .iter()
                .all(|capture| capture.frames.len() == capture_frames)
        );
    }
}
