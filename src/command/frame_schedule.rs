//! Backend-independent reproduction of FFmpeg's CFR frame-selection behavior.
//!
//! The compatibility backend uses [`CaptureWindow`] today. The remaining
//! schedule types are deliberately shipped before the in-process adapters so
//! those adapters share one already-proven contract instead of reimplementing
//! timestamp drift, duplication, and dropping.

#![cfg_attr(
    not(test),
    allow(
        dead_code,
        reason = "the shared schedule seam is consumed by the planned in-process Capture adapters"
    )
)]

const FFMPEG_TIMESTAMP_PRECISION_BITS: i32 = 29;
const FFMPEG_MAX_EXTRA_TIMESTAMP_BITS: i32 = 16;
const FFMPEG_MIDPOINT_AVOIDANCE_BITS: u32 = 17;
const FFMPEG_VIDEO_RATE_MAX: u64 = 1_001_000;
const CFR_DRIFT_THRESHOLD: f64 = 1.1;
const CFR_PREVIOUS_FRAME_BIAS: f64 = 0.6;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) struct Rational {
    pub numerator: i32,
    pub denominator: i32,
}

impl Rational {
    pub(crate) const fn new(numerator: i32, denominator: i32) -> Self {
        Self {
            numerator,
            denominator,
        }
    }
}

/// Backend-independent timing for one sampling point in a Capture plan.
#[derive(Clone, Copy, Debug, PartialEq)]
pub(crate) struct CaptureWindow {
    capture_index: usize,
    start_s: f32,
    duration_s: f32,
    frame_rate: Rational,
    frame_count: usize,
}

impl CaptureWindow {
    pub(crate) fn new(
        capture_index: usize,
        start_s: f32,
        duration_s: f32,
        frame_count: usize,
    ) -> anyhow::Result<Self> {
        anyhow::ensure!(
            start_s.is_finite(),
            "capture window requires a finite start"
        );
        anyhow::ensure!(
            duration_s.is_finite() && duration_s > 0.0,
            "capture window requires a finite positive duration"
        );
        anyhow::ensure!(
            frame_count > 0,
            "capture window requires at least one output frame"
        );
        let frame_count_value = u32::try_from(frame_count)
            .map_err(|_| anyhow::anyhow!("capture window frame count is out of range"))?;
        // Match av_parse_video_rate("frames/duration"): FFmpeg evaluates the
        // expression as f64 and constrains the result with av_d2q(max=1001000).
        let ffmpeg_duration_s = duration_s.to_string().parse::<f64>()?;
        let frame_rate =
            rational_from_f64_like_ffmpeg(f64::from(frame_count_value) / ffmpeg_duration_s)?;
        Ok(Self {
            capture_index,
            start_s,
            duration_s,
            frame_rate,
            frame_count,
        })
    }

    pub(crate) const fn capture_index(self) -> usize {
        self.capture_index
    }

    pub(crate) const fn start_s(self) -> f32 {
        self.start_s
    }

    pub(crate) const fn duration_s(self) -> f32 {
        self.duration_s
    }

    pub(crate) const fn frame_rate(self) -> Rational {
        self.frame_rate
    }

    pub(crate) fn ffmpeg_frame_rate_arg(self) -> String {
        format!(
            "{}/{}",
            self.frame_rate.numerator, self.frame_rate.denominator
        )
    }

    pub(crate) const fn frame_count(self) -> usize {
        self.frame_count
    }

    pub(crate) fn source_pts_offset(self, source_time_base: Rational) -> anyhow::Result<i64> {
        anyhow::ensure!(
            source_time_base.numerator > 0 && source_time_base.denominator > 0,
            "capture window requires a positive source time base"
        );
        // FFmpeg receives the shortest decimal representation of this f32.
        // Parse the same string as f64 so values near a half-tick round on the
        // same side as the authority path's setpts expression.
        let ffmpeg_start_s = self.start_s.to_string().parse::<f64>()?;
        let source_pts_offset = (ffmpeg_start_s * f64::from(source_time_base.denominator)
            / f64::from(source_time_base.numerator))
        .round();
        anyhow::ensure!(
            source_pts_offset >= i64::MIN as f64 && source_pts_offset <= i64::MAX as f64,
            "capture window source PTS offset is out of range"
        );
        Ok(source_pts_offset as i64)
    }

    pub(crate) fn schedule(self, source_time_base: Rational) -> anyhow::Result<FrameSchedule> {
        FrameSchedule::new(
            self.capture_index,
            source_time_base,
            self.source_pts_offset(source_time_base)?,
            self.frame_rate,
            self.frame_count,
        )
    }
}

const fn greatest_common_divisor(mut left: u128, mut right: u128) -> u128 {
    while right != 0 {
        let remainder = left % right;
        left = right;
        right = remainder;
    }
    left
}

fn rational_from_f64_like_ffmpeg(value: f64) -> anyhow::Result<Rational> {
    anyhow::ensure!(
        value.is_finite() && value > 0.0 && value <= f64::from(i32::MAX) + 3.0,
        "capture window frame rate is out of range"
    );
    let binary_exponent = if value >= 1.0 {
        (((value.to_bits() >> 52) & 0x7ff) as i32 - 1023).max(0)
    } else {
        0
    };
    let denominator = 1_u128 << (62 - binary_exponent);
    let numerator = (value * denominator as f64 + 0.5).floor() as u128;
    let mut reduced = reduce_rational(numerator, denominator, u128::from(FFMPEG_VIDEO_RATE_MAX));
    if reduced.0 == 0 || reduced.1 == 0 {
        reduced = reduce_rational(numerator, denominator, i32::MAX as u128);
    }
    let (numerator, denominator) = reduced;
    anyhow::ensure!(
        numerator > 0 && denominator > 0,
        "capture window frame rate is out of range"
    );
    Ok(Rational::new(
        i32::try_from(numerator)
            .map_err(|_| anyhow::anyhow!("capture window frame rate is out of range"))?,
        i32::try_from(denominator)
            .map_err(|_| anyhow::anyhow!("capture window frame rate is out of range"))?,
    ))
}

/// Positive-value subset of FFmpeg's `av_reduce`, used by `av_d2q`.
fn reduce_rational(mut numerator: u128, mut denominator: u128, max: u128) -> (u128, u128) {
    let divisor = greatest_common_divisor(numerator, denominator);
    if divisor != 0 {
        numerator /= divisor;
        denominator /= divisor;
    }

    let mut previous = (0, 1);
    let mut current = (1, 0);
    if numerator <= max && denominator <= max {
        current = (numerator, denominator);
        denominator = 0;
    }

    while denominator != 0 {
        let mut quotient = numerator / denominator;
        let next_denominator = numerator - denominator * quotient;
        let next = (
            quotient * current.0 + previous.0,
            quotient * current.1 + previous.1,
        );
        if next.0 > max || next.1 > max {
            if current.0 != 0 {
                quotient = (max - previous.0) / current.0;
            }
            if current.1 != 0 {
                quotient = quotient.min((max - previous.1) / current.1);
            }
            if denominator * (2 * quotient * current.1 + previous.1) > numerator * current.1 {
                current = (
                    quotient * current.0 + previous.0,
                    quotient * current.1 + previous.1,
                );
            }
            break;
        }
        previous = current;
        current = next;
        numerator = denominator;
        denominator = next_denominator;
    }
    current
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) struct SourceFrame {
    pub input_frame_index: i64,
    pub pts: i64,
    pub duration: i64,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) struct ScheduledFrame {
    pub capture_index: usize,
    pub animation_index: usize,
    pub input_frame_index: i64,
    pub source_pts: i64,
    pub source_time_base: Rational,
}

pub(crate) fn verify_frame_selection(
    expected: &[ScheduledFrame],
    observed: &[ScheduledFrame],
) -> anyhow::Result<()> {
    for position in 0..expected.len().max(observed.len()) {
        let expected_frame = expected.get(position);
        let observed_frame = observed.get(position);
        if expected_frame
            .zip(observed_frame)
            .is_some_and(|(expected, observed)| {
                expected.capture_index == observed.capture_index
                    && expected.animation_index == observed.animation_index
                    && expected.source_pts == observed.source_pts
                    && expected.source_time_base == observed.source_time_base
            })
        {
            continue;
        }
        let identity = expected_frame
            .or(observed_frame)
            .expect("position is in one slice");
        let expected_pts = expected_frame
            .map(format_source_pts)
            .unwrap_or_else(|| "<missing>".to_owned());
        let observed_pts = observed_frame
            .map(format_source_pts)
            .unwrap_or_else(|| "<missing>".to_owned());
        anyhow::bail!(
            "frame selection mismatch: capture {} animation {} expected PTS {expected_pts}, observed PTS {observed_pts}",
            identity.capture_index,
            identity.animation_index
        );
    }
    Ok(())
}

fn format_source_pts(frame: &ScheduledFrame) -> String {
    format!(
        "{}@{}/{}",
        frame.source_pts, frame.source_time_base.numerator, frame.source_time_base.denominator
    )
}

#[derive(Clone)]
pub(crate) struct FrameSchedule {
    capture_index: usize,
    source_time_base: Rational,
    source_pts_offset: i64,
    output_time_base: Rational,
    frame_count: usize,
    next_pts: i64,
    emitted: usize,
    previous_source: Option<SourceFrame>,
}

impl FrameSchedule {
    pub(crate) fn new(
        capture_index: usize,
        source_time_base: Rational,
        source_pts_offset: i64,
        frame_rate: Rational,
        frame_count: usize,
    ) -> anyhow::Result<Self> {
        anyhow::ensure!(
            source_time_base.numerator > 0 && source_time_base.denominator > 0,
            "frame schedule requires a positive source time base"
        );
        anyhow::ensure!(
            frame_rate.numerator > 0 && frame_rate.denominator > 0,
            "frame schedule requires a positive frame rate"
        );
        anyhow::ensure!(
            frame_count > 0,
            "frame schedule requires at least one output frame"
        );
        Ok(Self {
            capture_index,
            source_time_base,
            source_pts_offset,
            output_time_base: Rational::new(frame_rate.denominator, frame_rate.numerator),
            frame_count,
            next_pts: 0,
            emitted: 0,
            previous_source: None,
        })
    }

    pub(crate) const fn source_time_base(&self) -> Rational {
        self.source_time_base
    }

    #[cfg_attr(
        not(feature = "in-process-decode"),
        allow(
            dead_code,
            reason = "the optional libav backend excludes seek preroll before scheduling"
        )
    )]
    pub(crate) const fn source_pts_offset(&self) -> i64 {
        self.source_pts_offset
    }

    pub(crate) const fn frame_count(&self) -> usize {
        self.frame_count
    }

    pub(crate) fn push(&mut self, source: SourceFrame) -> anyhow::Result<Vec<ScheduledFrame>> {
        anyhow::ensure!(
            source.duration > 0,
            "frame schedule requires a positive source-frame duration"
        );
        if self.is_complete() {
            return Ok(Vec::new());
        }

        let mut delta0 = self.adjusted_pts(source.pts)? - self.next_pts as f64;
        let duration = source.duration as f64
            * f64::from(self.source_time_base.numerator)
            * f64::from(self.output_time_base.denominator)
            / (f64::from(self.source_time_base.denominator)
                * f64::from(self.output_time_base.numerator));
        let delta = delta0 + duration;
        if delta0 < 0.0 && delta > 0.0 {
            // FFmpeg also clips duration here. CFR keeps using the
            // already-computed delta, so only delta0 remains live below.
            delta0 = 0.0;
        }

        // Mirrors FFmpeg's video_sync_process CFR drift thresholds and
        // previous-frame duplication bias.
        let (frame_copies, previous_copies) = if delta < -CFR_DRIFT_THRESHOLD {
            (0, 0)
        } else if delta > CFR_DRIFT_THRESHOLD {
            let frame_copies = round_like_llrintf(delta);
            let previous_copies = if delta0 > CFR_DRIFT_THRESHOLD {
                round_like_llrintf(delta0 - CFR_PREVIOUS_FRAME_BIAS)
            } else {
                0
            };
            (frame_copies, previous_copies)
        } else {
            (1, 0)
        };

        let remaining = self.frame_count - self.emitted;
        let copies = usize::try_from(frame_copies.max(0))
            .unwrap_or(usize::MAX)
            .min(remaining);
        let previous_copies = usize::try_from(previous_copies.max(0))
            .unwrap_or(usize::MAX)
            .min(copies);
        let mut selected = Vec::with_capacity(copies);
        for copy_index in 0..copies {
            let selected_source = if copy_index < previous_copies {
                self.previous_source.unwrap_or(source)
            } else {
                source
            };
            selected.push(ScheduledFrame {
                capture_index: self.capture_index,
                animation_index: self.emitted,
                input_frame_index: selected_source.input_frame_index,
                source_pts: selected_source.pts,
                source_time_base: self.source_time_base,
            });
            self.emitted += 1;
            self.next_pts += 1;
        }
        self.previous_source = Some(source);
        Ok(selected)
    }

    pub(crate) fn is_complete(&self) -> bool {
        self.emitted == self.frame_count
    }

    fn adjusted_pts(&self, source_pts: i64) -> anyhow::Result<f64> {
        let relative_pts = source_pts
            .checked_sub(self.source_pts_offset)
            .ok_or_else(|| anyhow::anyhow!("frame schedule source PTS offset overflow"))?;
        let output_denominator = u32::try_from(self.output_time_base.denominator)
            .expect("positive output time base was validated");
        let extra_bits = (FFMPEG_TIMESTAMP_PRECISION_BITS - output_denominator.ilog2() as i32)
            .clamp(0, FFMPEG_MAX_EXTRA_TIMESTAMP_BITS) as u32;
        let extended_output_time_base = Rational::new(
            self.output_time_base.numerator,
            self.output_time_base
                .denominator
                .checked_mul(1_i32 << extra_bits)
                .ok_or_else(|| anyhow::anyhow!("frame schedule output time base overflow"))?,
        );
        let precise_pts = rescale_nearest(
            relative_pts,
            self.source_time_base,
            extended_output_time_base,
        )? as f64
            / f64::from(1_u32 << extra_bits);
        let nearest = precise_pts.round_ties_even();
        Ok(if precise_pts == nearest {
            precise_pts
        } else {
            precise_pts + precise_pts.signum() / f64::from(1_u32 << FFMPEG_MIDPOINT_AVOIDANCE_BITS)
        })
    }
}

fn round_like_llrintf(value: f64) -> i64 {
    f64::from(value as f32).round_ties_even() as i64
}

fn rescale_nearest(value: i64, source: Rational, destination: Rational) -> anyhow::Result<i64> {
    let numerator = i128::from(value)
        .checked_mul(i128::from(source.numerator))
        .and_then(|value| value.checked_mul(i128::from(destination.denominator)))
        .ok_or_else(|| anyhow::anyhow!("frame schedule timestamp rescale overflow"))?;
    let denominator = i128::from(source.denominator)
        .checked_mul(i128::from(destination.numerator))
        .ok_or_else(|| anyhow::anyhow!("frame schedule timestamp rescale overflow"))?;
    let rounded = if numerator < 0 {
        -(numerator
            .checked_neg()
            .and_then(|value| value.checked_add(denominator / 2))
            .ok_or_else(|| anyhow::anyhow!("frame schedule timestamp rescale overflow"))?
            / denominator)
    } else {
        (numerator + denominator / 2) / denominator
    };
    i64::try_from(rounded).map_err(|_| anyhow::anyhow!("frame schedule timestamp is out of range"))
}

#[cfg(test)]
mod tests {
    use super::*;
    use anyhow::Context as _;
    use serde_json::Value;
    use std::{
        fs,
        path::{Path, PathBuf},
        process::{Command as ProcessCommand, Output},
    };

    #[test]
    fn representative_first_window_matches_ffmpeg_cfr_authority() {
        let source_pts = [
            183100, 183141, 183183, 183225, 183266, 183308, 183350, 183392, 183433, 183475, 183517,
            183558, 183600, 183642, 183684, 183725, 183767, 183809, 183850, 183892, 183934, 183975,
            184017, 184059, 184101, 184142, 184184, 184226, 184267, 184309, 184351, 184393, 184434,
            184476, 184518, 184559, 184601,
        ];
        let expected = [
            183100, 183141, 183183, 183225, 183266, 183308, 183350, 183392, 183433, 183475, 183517,
            183558, 183600, 183642, 183684, 183767, 183809, 183850, 183892, 183934, 184017, 184059,
            184101, 184142, 184184, 184267, 184309, 184351, 184393, 184434,
        ];
        let mut schedule =
            FrameSchedule::new(0, Rational::new(1, 1000), 183080, Rational::new(20, 1), 30)
                .unwrap();
        let mut selected = Vec::new();

        for (input_frame_index, pts) in source_pts.into_iter().enumerate() {
            selected.extend(
                schedule
                    .push(SourceFrame {
                        input_frame_index: input_frame_index as i64 + 29,
                        pts,
                        duration: 41,
                    })
                    .unwrap(),
            );
            if schedule.is_complete() {
                break;
            }
        }

        assert_eq!(
            selected
                .iter()
                .map(|frame| frame.source_pts)
                .collect::<Vec<_>>(),
            expected
        );
        assert_eq!(
            selected
                .iter()
                .map(|frame| frame.animation_index)
                .collect::<Vec<_>>(),
            (0..30).collect::<Vec<_>>()
        );
    }

    #[test]
    fn representative_fixture_matches_all_270_ffmpeg_authority_pts() {
        let fixture: Value = serde_json::from_str(include_str!(
            "../../tests/fixtures/frame-selection/representative.json"
        ))
        .unwrap();
        let source_time_base = json_rational(&fixture["source_time_base"]);
        let frame_rate = json_rational(&fixture["frame_rate"]);
        let source_frame_duration = fixture["source_frame_duration"].as_i64().unwrap();
        let frame_count = fixture["frame_count"].as_u64().unwrap() as usize;
        let mut selected_count = 0;

        for capture in fixture["captures"].as_array().unwrap() {
            let capture_index = capture["capture_index"].as_u64().unwrap() as usize;
            let mut schedule = FrameSchedule::new(
                capture_index,
                source_time_base,
                capture["source_pts_offset"].as_i64().unwrap(),
                frame_rate,
                frame_count,
            )
            .unwrap();
            let mut selected = Vec::new();
            for (input_frame_index, pts) in
                capture["source_pts"].as_array().unwrap().iter().enumerate()
            {
                selected.extend(
                    schedule
                        .push(SourceFrame {
                            input_frame_index: input_frame_index as i64,
                            pts: pts.as_i64().unwrap(),
                            duration: source_frame_duration,
                        })
                        .unwrap(),
                );
                if schedule.is_complete() {
                    break;
                }
            }
            let expected = capture["authority_pts"]
                .as_array()
                .unwrap()
                .iter()
                .map(|pts| pts.as_i64().unwrap())
                .collect::<Vec<_>>();
            assert_eq!(
                selected
                    .iter()
                    .map(|frame| frame.source_pts)
                    .collect::<Vec<_>>(),
                expected,
                "capture {capture_index}"
            );
            assert_eq!(
                selected
                    .iter()
                    .map(|frame| (frame.capture_index, frame.animation_index))
                    .collect::<Vec<_>>(),
                (0..frame_count)
                    .map(|animation_index| (capture_index, animation_index))
                    .collect::<Vec<_>>(),
                "capture {capture_index} ordering"
            );
            selected_count += selected.len();
        }

        assert_eq!(selected_count, 270);
    }

    #[test]
    fn mismatch_names_capture_animation_and_both_pts() {
        let expected = [ScheduledFrame {
            capture_index: 4,
            animation_index: 12,
            input_frame_index: 100,
            source_pts: 42,
            source_time_base: Rational::new(1, 1000),
        }];
        let observed = [ScheduledFrame {
            source_pts: 43,
            ..expected[0]
        }];

        let error = verify_frame_selection(&expected, &observed).unwrap_err();

        assert_eq!(
            error.to_string(),
            "frame selection mismatch: capture 4 animation 12 expected PTS 42@1/1000, observed PTS 43@1/1000"
        );
    }

    #[test]
    fn capture_window_builds_the_same_schedule_for_every_backend() {
        let window = CaptureWindow::new(7, 2_746.205, 1.5, 30).unwrap();

        assert_eq!(window.capture_index(), 7);
        assert_eq!(window.start_s(), 2_746.205);
        assert_eq!(window.duration_s(), 1.5);
        assert_eq!(window.frame_rate(), Rational::new(20, 1));
        let schedule = window.schedule(Rational::new(1, 1000)).unwrap();
        assert_eq!(schedule.source_pts_offset, 2746205);
        assert_eq!(schedule.frame_count, 30);
    }

    #[test]
    fn media_shorter_than_capture_duration_preserves_negative_ffmpeg_seek() {
        let window = CaptureWindow::new(0, -0.25, 1.5, 30).unwrap();

        assert_eq!(window.start_s(), -0.25);
        assert_eq!(
            window.source_pts_offset(Rational::new(1, 1000)).unwrap(),
            -250
        );
    }

    #[test]
    fn non_integer_microsecond_duration_has_one_canonical_frame_rate() {
        let window = CaptureWindow::new(0, 0.0, 0.33333334, 30).unwrap();
        let ntsc_window = CaptureWindow::new(0, 0.0, 1.001, 30).unwrap();
        let sparse_window = CaptureWindow::new(0, 0.0, 3_000_000.0, 1).unwrap();

        assert_eq!(window.frame_rate(), Rational::new(90, 1));
        assert_eq!(window.ffmpeg_frame_rate_arg(), "90/1");
        assert_eq!(ntsc_window.frame_rate(), Rational::new(30000, 1001));
        assert_eq!(ntsc_window.ffmpeg_frame_rate_arg(), "30000/1001");
        assert_eq!(sparse_window.frame_rate(), Rational::new(1, 3_000_000));
        assert_eq!(sparse_window.ffmpeg_frame_rate_arg(), "1/3000000");
    }

    #[test]
    fn capture_window_rejects_a_frame_rate_ffmpeg_cannot_represent() {
        let result = CaptureWindow::new(0, 0.0, f32::MAX, 1);

        assert!(result.is_err());
    }

    #[test]
    fn late_first_source_frame_is_duplicated_at_the_window_boundary() {
        let window = CaptureWindow::new(7, 2_746.205, 1.5, 30).unwrap();
        let mut schedule = window.schedule(Rational::new(1, 1000)).unwrap();

        let selected = schedule
            .push(SourceFrame {
                input_frame_index: 225,
                pts: 2746244,
                duration: 41,
            })
            .unwrap();

        assert_eq!(
            selected
                .iter()
                .map(|frame| (frame.animation_index, frame.source_pts))
                .collect::<Vec<_>>(),
            [(0, 2746244), (1, 2746244)]
        );
    }

    #[test]
    fn accumulated_early_source_frame_is_dropped_at_the_window_boundary() {
        let mut schedule = CaptureWindow::new(0, 183.080_34, 1.5, 30)
            .unwrap()
            .schedule(Rational::new(1, 1000))
            .unwrap();
        let source_pts = [
            183100, 183141, 183183, 183225, 183266, 183308, 183350, 183392, 183433, 183475, 183517,
            183558, 183600, 183642, 183684,
        ];
        for (input_frame_index, pts) in source_pts.into_iter().enumerate() {
            assert_eq!(
                schedule
                    .push(SourceFrame {
                        input_frame_index: input_frame_index as i64 + 29,
                        pts,
                        duration: 41,
                    })
                    .unwrap()
                    .len(),
                1
            );
        }

        let dropped = schedule
            .push(SourceFrame {
                input_frame_index: 44,
                pts: 183725,
                duration: 41,
            })
            .unwrap();
        let resumed = schedule
            .push(SourceFrame {
                input_frame_index: 45,
                pts: 183767,
                duration: 41,
            })
            .unwrap();

        assert!(dropped.is_empty());
        assert_eq!(
            resumed
                .iter()
                .map(|frame| (frame.animation_index, frame.source_pts))
                .collect::<Vec<_>>(),
            [(15, 183767)]
        );
    }

    #[test]
    #[ignore = "requires FFmpeg and the generated H.264/HEVC corpus"]
    fn ffmpeg_corpus_matches_shared_schedule() {
        let original = std::env::var_os("VIMG_FRAME_SELECTION_ORIGINAL")
            .expect("VIMG_FRAME_SELECTION_ORIGINAL must name the representative input");
        let corpus_dir = std::env::var_os("VIMG_FRAME_SELECTION_CORPUS")
            .expect("VIMG_FRAME_SELECTION_CORPUS must name the generated corpus directory");
        let corpus_dir = Path::new(&corpus_dir);
        let cases = [
            ("original", PathBuf::from(original)),
            ("h264-longgop-b3", corpus_dir.join("h264-longgop-b3.mkv")),
            (
                "h264-shortgop-nob",
                corpus_dir.join("h264-shortgop-nob.mkv"),
            ),
            ("h264-vfr-b3", corpus_dir.join("h264-vfr-b3.mkv")),
            ("h264-short-b3", corpus_dir.join("h264-short-b3.mkv")),
            (
                "h264-tail-g360-b8",
                corpus_dir.join("h264-tail-g360-b8.mkv"),
            ),
            ("hevc-longgop-b4", corpus_dir.join("hevc-longgop-b4.mkv")),
            (
                "hevc-shortgop-nob",
                corpus_dir.join("hevc-shortgop-nob.mkv"),
            ),
            ("hevc-vfr-b4", corpus_dir.join("hevc-vfr-b4.mkv")),
            ("hevc-short-b4", corpus_dir.join("hevc-short-b4.mkv")),
            (
                "hevc-tail-g360-b8",
                corpus_dir.join("hevc-tail-g360-b8.mkv"),
            ),
        ];

        for (case_name, media) in cases {
            verify_media_contract(case_name, &media).unwrap();
        }
    }

    #[test]
    #[ignore = "requires FFmpeg and the generated hardware-boundary corpus"]
    fn hardware_boundary_corpus_records_ffmpeg_authority() {
        let corpus_dir = std::env::var_os("VIMG_HARDWARE_BOUNDARY_CORPUS")
            .expect("VIMG_HARDWARE_BOUNDARY_CORPUS must name the generated corpus directory");

        verify_hardware_boundary_corpus(Path::new(&corpus_dir)).unwrap();
    }

    fn verify_hardware_boundary_corpus(corpus_dir: &Path) -> anyhow::Result<()> {
        let declarations: Value = serde_json::from_str(include_str!(
            "../../tests/fixtures/hardware-boundary/declarations.json"
        ))?;
        let fixtures = declarations["fixtures"]
            .as_array()
            .context("hardware-boundary declarations must contain fixtures")?;

        for fixture in fixtures {
            let name = fixture["name"]
                .as_str()
                .context("hardware-boundary fixture must have a name")?;
            let media = corpus_dir.join(
                fixture["file"]
                    .as_str()
                    .context("hardware-boundary fixture must name its media file")?,
            );
            anyhow::ensure!(media.is_file(), "{name}: generated media is missing");
            let valid = fixture["valid"]
                .as_bool()
                .context("hardware-boundary fixture must declare validity")?;
            let expectation = fixture["videotoolbox"]
                .as_str()
                .context("hardware-boundary fixture must declare VideoToolbox expectation")?;
            anyhow::ensure!(
                matches!(expectation, "supported" | "backend-fallback" | "failure"),
                "{name}: invalid VideoToolbox expectation {expectation}"
            );

            let authority_dir = corpus_dir.join("authority");
            let manifest_path = authority_dir.join(format!("{name}.json"));
            let output_path = authority_dir.join(format!("{name}.avif"));
            if valid {
                anyhow::ensure!(
                    expectation != "failure",
                    "{name}: valid fixture cannot expect decode failure"
                );
                verify_hardware_stream(name, &media, &fixture["stream"])?;
                verify_hardware_authority(name, &manifest_path, &output_path)?;
            } else {
                anyhow::ensure!(
                    expectation == "failure",
                    "{name}: invalid fixture must expect decode failure"
                );
                anyhow::ensure!(
                    !manifest_path.exists() && !output_path.exists(),
                    "{name}: invalid fixture published an authority artifact"
                );
                let failure_log = corpus_dir.join("failures").join(format!("{name}.log"));
                anyhow::ensure!(
                    failure_log.is_file() && fs::metadata(&failure_log)?.len() > 0,
                    "{name}: invalid fixture did not report an explicit failure"
                );
            }
        }
        Ok(())
    }

    fn verify_hardware_stream(name: &str, media: &Path, expected: &Value) -> anyhow::Result<()> {
        let output = ProcessCommand::new("ffprobe")
            .args([
                "-v",
                "error",
                "-select_streams",
                "v:0",
                "-show_entries",
                "stream=codec_name,pix_fmt,color_range,color_space,color_transfer,color_primaries,sample_aspect_ratio,field_order:stream_side_data=rotation",
                "-of",
                "json",
            ])
            .arg(media)
            .output()?;
        ensure_process_success("ffprobe hardware fixture", media, &output)?;
        let probe: Value = serde_json::from_slice(&output.stdout)?;
        let stream = probe["streams"]
            .as_array()
            .and_then(|streams| streams.first())
            .context("ffprobe hardware fixture did not return a video stream")?;
        let expected = expected
            .as_object()
            .context("valid hardware fixture must declare stream properties")?;
        for (key, value) in expected {
            if key == "rotation" {
                let found_rotation = stream["side_data_list"]
                    .as_array()
                    .into_iter()
                    .flatten()
                    .any(|side_data| side_data["rotation"] == *value);
                anyhow::ensure!(found_rotation, "{name}: expected rotation {value}");
            } else {
                anyhow::ensure!(
                    stream[key] == *value,
                    "{name}: expected {key} {value}, found {}",
                    stream[key]
                );
            }
        }
        Ok(())
    }

    fn verify_hardware_authority(
        name: &str,
        manifest_path: &Path,
        output_path: &Path,
    ) -> anyhow::Result<()> {
        anyhow::ensure!(output_path.is_file(), "{name}: authority AVIF is missing");
        let manifest: Value = serde_json::from_slice(&fs::read(manifest_path)?)?;
        anyhow::ensure!(
            manifest["authority"] == "production-ffmpeg-capture",
            "{name}: authority does not identify the production FFmpeg capture"
        );
        anyhow::ensure!(
            manifest["selected_frames"]
                .as_array()
                .is_some_and(|frames| frames.len() == 270),
            "{name}: authority does not record 270 selected source PTS"
        );
        let animation = &manifest["animation"];
        anyhow::ensure!(
            animation["width"].as_u64().is_some_and(|width| width > 0)
                && animation["height"]
                    .as_u64()
                    .is_some_and(|height| height > 0)
                && animation["frame_count"] == 30,
            "{name}: authority has an incomplete structural record"
        );
        for visual_kind in ["pre_encoder_visual_frames", "decoded_visual_frames"] {
            let frames = animation[visual_kind]
                .as_array()
                .context("authority visual record is missing")?;
            anyhow::ensure!(
                frames.len() == 30,
                "{name}: authority has {} {visual_kind}, expected 30",
                frames.len()
            );
            for frame in frames {
                let path = manifest_path
                    .parent()
                    .unwrap_or_else(|| Path::new("."))
                    .join(
                        frame
                            .as_str()
                            .context("authority visual record contains a non-path")?,
                    );
                anyhow::ensure!(path.is_file(), "{name}: authority visual frame is missing");
            }
        }
        Ok(())
    }

    fn verify_media_contract(case_name: &str, media: &Path) -> anyhow::Result<()> {
        let duration_output = ProcessCommand::new("ffprobe")
            .args([
                "-v",
                "error",
                "-show_entries",
                "format=duration",
                "-of",
                "default=noprint_wrappers=1:nokey=1",
            ])
            .arg(media)
            .output()?;
        ensure_process_success("ffprobe duration", media, &duration_output)?;
        let duration_s = String::from_utf8(duration_output.stdout)?
            .trim()
            .parse::<f32>()?;
        let interval = duration_s / 9.0;
        let mut selected_count = 0;

        for capture_index in 0..9 {
            let start_s = (interval * 0.5 + interval * capture_index as f32).min(duration_s - 1.5);
            let window = CaptureWindow::new(capture_index, start_s, 1.5, 30)?;
            let (source_time_base, source_frames) = showinfo_source_frames(media, window)?;
            let mut schedule = window.schedule(source_time_base)?;
            let mut observed = Vec::new();
            for source in source_frames {
                observed.extend(schedule.push(source)?);
                if schedule.is_complete() {
                    break;
                }
            }
            anyhow::ensure!(
                schedule.is_complete(),
                "{case_name}: capture {capture_index} produced only {} scheduled frames",
                observed.len()
            );

            let authority_output = authority_frames(media, window)?;
            let authority =
                crate::command::parse_source_frames(&authority_output, window.frame_count())?;
            let expected = authority
                .iter()
                .enumerate()
                .map(|(animation_index, source)| {
                    let source_time_base = parse_rational(&source.source_time_base)?;
                    Ok(ScheduledFrame {
                        capture_index,
                        animation_index,
                        input_frame_index: source.input_frame_index,
                        source_pts: source.source_pts,
                        source_time_base,
                    })
                })
                .collect::<anyhow::Result<Vec<_>>>()?;
            verify_frame_selection(&expected, &observed)
                .map_err(|error| anyhow::anyhow!("{case_name}: {error}"))?;
            selected_count += observed.len();
        }

        anyhow::ensure!(
            selected_count == 270,
            "{case_name}: expected 270 scheduled frames, found {selected_count}"
        );
        eprintln!("{case_name}: 270/270 PTS");
        Ok(())
    }

    fn showinfo_source_frames(
        media: &Path,
        window: CaptureWindow,
    ) -> anyhow::Result<(Rational, Vec<SourceFrame>)> {
        let start_s = window.start_s().to_string();
        let duration_s = window.duration_s().to_string();
        let filter = format!("setpts=PTS-round({start_s}/TB),showinfo");
        let output = ProcessCommand::new("ffmpeg")
            .args(["-copyts", "-v", "info", "-threads", "3", "-ss", &start_s])
            .args(["-t", &duration_s, "-i"])
            .arg(media)
            .args([
                "-vf",
                &filter,
                "-fps_mode",
                "passthrough",
                "-f",
                "null",
                "-",
            ])
            .output()?;
        ensure_process_success("FFmpeg source timing", media, &output)?;
        let stderr = String::from_utf8(output.stderr)?;
        let mut source_time_base = None;
        let mut frames = Vec::new();
        for line in stderr.lines() {
            if let Some((_, timing)) = line.split_once("config in time_base: ") {
                let value = timing.split(',').next().unwrap_or_default().trim();
                source_time_base = Some(parse_rational(value)?);
                continue;
            }
            if !line.contains("Parsed_showinfo") || !line.contains(" n:") {
                continue;
            }
            let fields = line.split_ascii_whitespace().collect::<Vec<_>>();
            let value_after = |name: &str| -> anyhow::Result<i64> {
                let position = fields
                    .iter()
                    .position(|field| *field == name)
                    .ok_or_else(|| anyhow::anyhow!("missing showinfo field {name}"))?;
                fields
                    .get(position + 1)
                    .ok_or_else(|| anyhow::anyhow!("missing showinfo value after {name}"))?
                    .parse::<i64>()
                    .map_err(Into::into)
            };
            let relative_pts = value_after("pts:")?;
            frames.push(SourceFrame {
                input_frame_index: value_after("n:")?,
                pts: relative_pts
                    .checked_add(window.source_pts_offset(
                        source_time_base.context("missing showinfo source time base")?,
                    )?)
                    .context("showinfo source PTS overflow")?,
                duration: value_after("duration:")?,
            });
        }
        Ok((
            source_time_base.context("FFmpeg showinfo did not report a source time base")?,
            frames,
        ))
    }

    fn authority_frames(media: &Path, window: CaptureWindow) -> anyhow::Result<String> {
        let start_s = window.start_s().to_string();
        let duration_s = window.duration_s().to_string();
        let frame_count = window.frame_count().to_string();
        let rate = format!("{frame_count}/{duration_s}");
        let filter = format!("setpts=PTS-round({start_s}/TB)");
        let output = ProcessCommand::new("ffmpeg")
            .args(["-copyts", "-v", "error", "-threads", "3", "-ss", &start_s])
            .args(["-t", &duration_s, "-i"])
            .arg(media)
            .args([
                "-r",
                &rate,
                "-fps_mode",
                "cfr",
                "-vf",
                &filter,
                "-vframes",
                &frame_count,
                "-stats_enc_pre",
                "pipe:1",
                "-stats_enc_pre_fmt",
                "{n} {ni} {ptsi} {tbi}",
                "-f",
                "null",
                "-",
            ])
            .output()?;
        ensure_process_success("FFmpeg authority", media, &output)?;
        String::from_utf8(output.stdout).map_err(Into::into)
    }

    fn ensure_process_success(phase: &str, media: &Path, output: &Output) -> anyhow::Result<()> {
        anyhow::ensure!(
            output.status.success(),
            "{phase} failed for {}: {}",
            media.display(),
            String::from_utf8_lossy(&output.stderr).trim()
        );
        Ok(())
    }

    fn parse_rational(value: &str) -> anyhow::Result<Rational> {
        let (numerator, denominator) = value
            .split_once('/')
            .context("invalid rational without slash")?;
        Ok(Rational::new(numerator.parse()?, denominator.parse()?))
    }

    fn json_rational(value: &Value) -> Rational {
        let values = value.as_array().unwrap();
        Rational::new(
            values[0].as_i64().unwrap() as i32,
            values[1].as_i64().unwrap() as i32,
        )
    }
}
