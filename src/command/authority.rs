use crate::{command::Vcs, process::CommandExt};
use anyhow::{Context, bail, ensure};
use serde_json::{Value, json};
use std::{
    fs,
    io::Read,
    path::{Path, PathBuf},
    process::Command,
};

const DEFAULT_MIN_SSIM: f64 = 0.999;
const AUTHORITY_MARKER: &str = "vimg-authority-v1\n";

/// Record or verify the production FFmpeg capture authority.
#[derive(clap::Parser, Debug)]
pub struct Authority {
    #[command(subcommand)]
    command: AuthorityCommand,
}

#[derive(clap::Subcommand, Debug)]
enum AuthorityCommand {
    /// Generate an AVIF plus its source-PTS and visual authority record.
    Record(Box<AuthorityRecord>),
    /// Compare two AVIF animations structurally and frame by frame.
    Verify(AuthorityVerify),
}

#[derive(clap::Args, Debug)]
struct AuthorityRecord {
    /// JSON authority manifest to write.
    #[arg(long)]
    manifest: PathBuf,

    #[command(flatten)]
    vcs: Vcs,
}

#[derive(clap::Args, Debug)]
struct AuthorityVerify {
    /// Production authority AVIF.
    reference: PathBuf,

    /// Candidate AVIF to verify.
    candidate: PathBuf,

    /// Minimum permitted SSIM for every animation frame.
    #[arg(long, default_value_t = DEFAULT_MIN_SSIM)]
    min_ssim: f64,
}

impl Authority {
    pub fn run(self) -> anyhow::Result<()> {
        match self.command {
            AuthorityCommand::Record(record) => record.run(),
            AuthorityCommand::Verify(verify) => verify.run(),
        }
    }
}

impl AuthorityRecord {
    fn run(mut self) -> anyhow::Result<()> {
        let capture_frames = self.vcs.args.capture_frames.unwrap_or(30);
        ensure!(
            self.vcs.columns == 3
                && self.vcs.capture_height == Some(160)
                && self.vcs.capture_width.is_none()
                && self.vcs.args.number == 9
                && capture_frames == 30
                && (self.vcs.args.capture_time.seconds - 1.5).abs() < f32::EPSILON
                && self.vcs.args.ignore_start.to_secs(1.0) == 0.0
                && self.vcs.args.ignore_end.to_secs(1.0) == 0.0
                && self.vcs.args.vfilter.is_none()
                && self.vcs.avif_crf == 30
                && self.vcs.avif_codec == "libsvtav1"
                && self.vcs.avif_preset.is_none()
                && (self.vcs.avif_fps - 20.0).abs() < f32::EPSILON
                && self.vcs.webp == 0,
            "structural inspection failed: authority recording requires the fixed Preview profile (-c3 -H160 -n9, 30 frames/1.5s, 20fps, CRF 30, libsvtav1, no offsets or custom filter)"
        );
        let output = self
            .vcs
            .output
            .as_ref()
            .context("structural inspection failed: authority recording requires --output")?;
        ensure!(
            output
                .extension()
                .is_some_and(|extension| extension == "avif"),
            "structural inspection failed: authority recording requires an .avif output"
        );
        validate_artifact_paths(&self.vcs.args.video, output, &self.manifest)?;
        self.vcs.authority_manifest = Some(self.manifest);
        self.vcs.run()
    }
}

impl AuthorityVerify {
    fn run(self) -> anyhow::Result<()> {
        ensure!(
            self.min_ssim.is_finite() && (0.0..=1.0).contains(&self.min_ssim),
            "visual comparison failed: --min-ssim must be between 0 and 1"
        );
        let reference = inspect_animation(&self.reference)?;
        let candidate = inspect_animation(&self.candidate)?;
        ensure_same_structure(&reference, &candidate)?;

        let filter = format!(
            "[0:{}][1:{}]ssim=stats_file=-",
            reference.stream_index, candidate.stream_index
        );
        let output = Command::new("ffmpeg")
            .arg2("-v", "error")
            .arg2("-i", &self.reference)
            .arg2("-i", &self.candidate)
            .arg2("-filter_complex", filter)
            .arg2("-f", "null")
            .arg("-")
            .output()
            .context("decoding failed: could not start ffmpeg visual comparison")?;
        ensure!(
            output.status.success(),
            "decoding failed: ffmpeg could not decode the authority pair\n{}",
            String::from_utf8_lossy(&output.stderr).trim()
        );
        let scores = parse_ssim_frames(&String::from_utf8_lossy(&output.stdout))?;
        ensure!(
            scores.len() == reference.frame_count,
            "decoding failed: expected {} SSIM frames, decoded {}",
            reference.frame_count,
            scores.len()
        );
        verify_frame_ssim(&scores, self.min_ssim)?;

        let minimum = scores.iter().copied().fold(1.0_f64, f64::min);
        println!(
            "authority verified: {} frames, minimum SSIM {:.6}",
            scores.len(),
            minimum
        );
        Ok(())
    }
}

#[derive(Clone, Debug)]
pub(crate) struct SourceSelection {
    pub source_pts: i64,
    pub source_time_base: String,
    pub input_frame_index: i64,
}

#[derive(Debug)]
struct RecordedSelection {
    animation_index: usize,
    capture_index: usize,
    source: SourceSelection,
}

pub(crate) struct AuthorityRecorder {
    manifest_path: PathBuf,
    temp_frames_dir: PathBuf,
    selected: Vec<RecordedSelection>,
    pre_encoder_frames: usize,
    workspace_released: bool,
}

pub(crate) struct PreparedAuthority {
    manifest_path: PathBuf,
    temporary_manifest: PathBuf,
    frames_container: PathBuf,
    frames_dir: PathBuf,
    frames_container_created: bool,
    frames_dir_created: bool,
    source_count: usize,
    frame_count: usize,
    published: bool,
}

pub(crate) struct PublishedAuthority {
    manifest_path: PathBuf,
    manifest_backup: Option<PathBuf>,
    frames_container: PathBuf,
    frames_dir: PathBuf,
    source_count: usize,
    frame_count: usize,
}

pub(crate) struct AuthorityPublicationLock {
    _files: Vec<fs::File>,
}

pub(crate) struct AuthorityProfile<'a> {
    pub input: &'a Path,
    pub encoded_output: &'a Path,
    pub output: &'a Path,
    pub columns: u32,
    pub capture_count: usize,
    pub capture_frames: usize,
    pub capture_time_s: f32,
    pub capture_width: u32,
    pub capture_height: u32,
    pub grid_width: u32,
    pub grid_height: u32,
    pub frame_rate: f32,
}

impl AuthorityPublicationLock {
    pub(crate) fn acquire(manifest: &Path, output: &Path) -> anyhow::Result<Self> {
        let mut lock_paths = Vec::with_capacity(2);
        for artifact in [manifest, output] {
            let parent = artifact.parent().unwrap_or_else(|| Path::new("."));
            fs::create_dir_all(parent)
                .context("structural inspection failed: could not create artifact directory")?;
            let artifact = path_identity(artifact)?;
            let parent = artifact.parent().unwrap_or_else(|| Path::new("."));
            let file_name = artifact
                .file_name()
                .unwrap_or_else(|| std::ffi::OsStr::new("authority"));
            lock_paths.push(parent.join(format!(
                ".{}.vimg-authority.lock",
                file_name.to_string_lossy()
            )));
        }
        lock_paths.sort_unstable();
        lock_paths.dedup();

        let mut files = Vec::with_capacity(lock_paths.len());
        for lock_path in lock_paths {
            let file = fs::OpenOptions::new()
                .create(true)
                .truncate(false)
                .read(true)
                .write(true)
                .open(&lock_path)
                .with_context(|| {
                    format!(
                        "structural inspection failed: could not open authority publication lock {}",
                        lock_path.display()
                    )
                })?;
            file.lock().with_context(|| {
                format!(
                    "structural inspection failed: could not acquire authority publication lock {}",
                    lock_path.display()
                )
            })?;
            files.push(file);
        }
        Ok(Self { _files: files })
    }
}

impl AuthorityRecorder {
    pub(crate) fn new(manifest_path: PathBuf) -> anyhow::Result<Self> {
        ensure_owned_frames_dir(&frames_dir_for(&manifest_path))?;
        let parent = manifest_path.parent().unwrap_or_else(|| Path::new("."));
        fs::create_dir_all(parent)
            .context("visual comparison failed: could not create authority directory")?;
        let temp_frames_dir = parent.join(format!(".authority.frames.{}.tmp", fastrand::u64(..)));
        fs::create_dir(&temp_frames_dir)
            .context("visual comparison failed: could not create authority workspace")?;
        let initialize = || -> anyhow::Result<()> {
            fs::write(temp_frames_dir.join(".vimg-authority"), AUTHORITY_MARKER)
                .context("visual comparison failed: could not mark authority workspace")?;
            fs::create_dir(temp_frames_dir.join("pre-encoder")).context(
                "visual comparison failed: could not create pre-encoder reference directory",
            )?;
            Ok(())
        };
        if let Err(error) = initialize() {
            let _ = fs::remove_dir_all(&temp_frames_dir);
            return Err(error);
        }
        Ok(Self {
            manifest_path,
            temp_frames_dir,
            selected: Vec::new(),
            pre_encoder_frames: 0,
            workspace_released: false,
        })
    }

    pub(crate) fn record(
        &mut self,
        animation_index: usize,
        capture_index: usize,
        source: &SourceSelection,
    ) {
        self.selected.push(RecordedSelection {
            animation_index,
            capture_index,
            source: source.clone(),
        });
    }

    pub(crate) fn record_grid(
        &mut self,
        animation_index: usize,
        grid: &image::RgbImage,
    ) -> anyhow::Result<()> {
        ensure!(
            animation_index == self.pre_encoder_frames,
            "visual comparison failed: expected pre-encoder frame {}, received {animation_index}",
            self.pre_encoder_frames
        );
        let path = self
            .temp_frames_dir
            .join("pre-encoder")
            .join(format!("frame-{:03}.png", animation_index + 1));
        grid.save(&path).with_context(|| {
            format!(
                "visual comparison failed: could not save pre-encoder frame {}",
                animation_index + 1
            )
        })?;
        self.pre_encoder_frames += 1;
        Ok(())
    }

    pub(crate) fn prepare(
        mut self,
        profile: AuthorityProfile<'_>,
    ) -> anyhow::Result<PreparedAuthority> {
        let expected_selections = profile.capture_count * profile.capture_frames;
        ensure!(
            self.selected.len() == expected_selections,
            "PTS extraction failed: expected {expected_selections} selected source frames, recorded {}",
            self.selected.len()
        );
        self.selected
            .sort_by_key(|frame| (frame.animation_index, frame.capture_index));
        ensure!(
            self.pre_encoder_frames == profile.capture_frames,
            "visual comparison failed: expected {} pre-encoder frames, recorded {}",
            profile.capture_frames,
            self.pre_encoder_frames
        );

        let structure = inspect_animation(profile.encoded_output)?;
        ensure!(
            structure.width == profile.grid_width
                && structure.height == profile.grid_height
                && structure.frame_count == profile.capture_frames,
            "structural inspection failed: expected {}x{} and {} frames, found {}x{} and {} frames",
            profile.grid_width,
            profile.grid_height,
            profile.capture_frames,
            structure.width,
            structure.height,
            structure.frame_count
        );
        let expected_rate = profile.frame_rate as f64;
        ensure!(
            (structure.frame_rate_value()? - expected_rate).abs() < 0.000_001,
            "structural inspection failed: expected frame rate {expected_rate}, found {}",
            structure.frame_rate
        );

        let decoded_frames_dir = self.temp_frames_dir.join("decoded");
        let decoded_visual_frames =
            decode_visual_references(profile.encoded_output, &structure, &decoded_frames_dir)?;
        let digest = authority_visual_digest(
            profile.encoded_output,
            &self.temp_frames_dir,
            profile.capture_frames,
        )?;
        let (frames_container, frames_dir, frames_container_created, frames_dir_created) =
            self.release_frames(&digest, profile.capture_frames)?;
        let manifest_parent = self
            .manifest_path
            .parent()
            .unwrap_or_else(|| Path::new("."));
        let pre_encoder_visual_paths: Vec<_> = (1..=profile.capture_frames)
            .map(|frame_index| {
                frames_dir
                    .join("pre-encoder")
                    .join(format!("frame-{frame_index:03}.png"))
            })
            .map(|path| {
                path.strip_prefix(manifest_parent)
                    .unwrap_or(&path)
                    .to_string_lossy()
                    .into_owned()
            })
            .collect();
        let decoded_visual_paths: Vec<_> = decoded_visual_frames
            .iter()
            .map(|file_name| {
                let path = frames_dir.join("decoded").join(file_name);
                path.strip_prefix(manifest_parent)
                    .unwrap_or(&path)
                    .to_string_lossy()
                    .into_owned()
            })
            .collect();
        let selected: Vec<_> = self
            .selected
            .iter()
            .map(|frame| {
                json!({
                    "animation_index": frame.animation_index,
                    "capture_index": frame.capture_index,
                    "source_pts": frame.source.source_pts,
                    "source_time_base": frame.source.source_time_base,
                    "input_frame_index": frame.source.input_frame_index,
                })
            })
            .collect();
        let manifest = json!({
            "version": 1,
            "authority": "production-ffmpeg-capture",
            "input": profile.input.to_string_lossy(),
            "output": profile.output.to_string_lossy(),
            "profile": {
                "columns": profile.columns,
                "capture_count": profile.capture_count,
                "capture_frames": profile.capture_frames,
                "capture_time_s": profile.capture_time_s,
                "capture_width": profile.capture_width,
                "capture_height": profile.capture_height,
            },
            "selected_frames": selected,
            "animation": {
                "width": structure.width,
                "height": structure.height,
                "frame_rate": structure.frame_rate,
                "duration_s": structure.duration_s,
                "frame_count": structure.frame_count,
                "stream_index": structure.stream_index,
                "pre_encoder_visual_frames": pre_encoder_visual_paths,
                "decoded_visual_frames": decoded_visual_paths,
            },
        });
        let temporary_manifest = match prepare_manifest(&self.manifest_path, &manifest) {
            Ok(temporary_manifest) => temporary_manifest,
            Err(error) => {
                cleanup_released_frames(
                    &frames_container,
                    &frames_dir,
                    frames_container_created,
                    frames_dir_created,
                );
                return Err(error);
            }
        };
        Ok(PreparedAuthority {
            manifest_path: self.manifest_path.clone(),
            temporary_manifest,
            frames_container,
            frames_dir,
            frames_container_created,
            frames_dir_created,
            source_count: expected_selections,
            frame_count: decoded_visual_frames.len(),
            published: false,
        })
    }

    fn release_frames(
        &mut self,
        digest: &str,
        frame_count: usize,
    ) -> anyhow::Result<(PathBuf, PathBuf, bool, bool)> {
        let frames_container = frames_dir_for(&self.manifest_path);
        let mut frames_container_created = false;
        if !frames_container.exists() {
            fs::create_dir(&frames_container)
                .context("visual comparison failed: could not create visual-reference container")?;
            if let Err(error) =
                fs::write(frames_container.join(".vimg-authority"), AUTHORITY_MARKER)
            {
                let _ = fs::remove_dir(&frames_container);
                return Err(error).context(
                    "visual comparison failed: could not mark visual-reference container",
                );
            }
            frames_container_created = true;
        }
        if let Err(error) = ensure_owned_frames_dir(&frames_container) {
            if frames_container_created {
                let _ = fs::remove_file(frames_container.join(".vimg-authority"));
                let _ = fs::remove_dir(&frames_container);
            }
            return Err(error);
        }
        let frames_dir = frames_container.join(digest);
        let frames_dir_created = if frames_dir.exists() {
            let matches = visual_directories_match(&self.temp_frames_dir, &frames_dir, frame_count);
            match matches {
                Ok(true) => {}
                Ok(false) => {
                    if frames_container_created {
                        let _ = fs::remove_file(frames_container.join(".vimg-authority"));
                        let _ = fs::remove_dir(&frames_container);
                    }
                    bail!(
                        "visual comparison failed: immutable authority digest collision at {}",
                        frames_dir.display()
                    );
                }
                Err(error) => {
                    if frames_container_created {
                        let _ = fs::remove_file(frames_container.join(".vimg-authority"));
                        let _ = fs::remove_dir(&frames_container);
                    }
                    return Err(error);
                }
            }
            if let Err(error) = fs::remove_dir_all(&self.temp_frames_dir) {
                if frames_container_created {
                    let _ = fs::remove_file(frames_container.join(".vimg-authority"));
                    let _ = fs::remove_dir(&frames_container);
                }
                return Err(error).context(
                    "visual comparison failed: could not discard duplicate visual workspace",
                );
            }
            false
        } else {
            if let Err(error) = fs::rename(&self.temp_frames_dir, &frames_dir) {
                if frames_container_created {
                    let _ = fs::remove_file(frames_container.join(".vimg-authority"));
                    let _ = fs::remove_dir(&frames_container);
                }
                return Err(error).context(
                    "visual comparison failed: could not publish immutable visual references",
                );
            }
            true
        };
        self.workspace_released = true;
        Ok((
            frames_container,
            frames_dir,
            frames_container_created,
            frames_dir_created,
        ))
    }
}

impl Drop for AuthorityRecorder {
    fn drop(&mut self) {
        if !self.workspace_released {
            let _ = fs::remove_dir_all(&self.temp_frames_dir);
        }
    }
}

impl PreparedAuthority {
    pub(crate) fn publish(mut self) -> anyhow::Result<PublishedAuthority> {
        let mut published = PublishedAuthority {
            manifest_path: self.manifest_path.clone(),
            manifest_backup: None,
            frames_container: self.frames_container.clone(),
            frames_dir: self.frames_dir.clone(),
            source_count: self.source_count,
            frame_count: self.frame_count,
        };
        published.manifest_backup = replace_file(&self.temporary_manifest, &self.manifest_path)?;
        self.published = true;
        Ok(published)
    }
}

impl PublishedAuthority {
    pub(crate) fn finish(self) {
        if let Some(backup) = &self.manifest_backup
            && let Err(error) = fs::remove_file(backup)
        {
            eprintln!(
                "warning: manifest was published, but backup {} could not be removed: {error}",
                backup.display()
            );
        }
        if let Err(error) = cleanup_stale_generations(&self.frames_container, &self.frames_dir) {
            eprintln!(
                "warning: authority was published, but stale visual generations could not be removed: {error:#}"
            );
        }
        println!(
            "authority recorded: {} source PTS, {} pre-encoder and {} decoded visual frames, manifest {}",
            self.source_count,
            self.frame_count,
            self.frame_count,
            self.manifest_path.display()
        );
    }
}

impl Drop for PreparedAuthority {
    fn drop(&mut self) {
        let _ = fs::remove_file(&self.temporary_manifest);
        if self.published {
            return;
        }
        cleanup_released_frames(
            &self.frames_container,
            &self.frames_dir,
            self.frames_container_created,
            self.frames_dir_created,
        );
    }
}

fn cleanup_released_frames(
    frames_container: &Path,
    frames_dir: &Path,
    frames_container_created: bool,
    frames_dir_created: bool,
) {
    if frames_dir_created {
        let _ = fs::remove_dir_all(frames_dir);
    }
    if frames_container_created {
        let _ = fs::remove_file(frames_container.join(".vimg-authority"));
        let _ = fs::remove_dir(frames_container);
    }
}

fn cleanup_stale_generations(frames_container: &Path, current: &Path) -> anyhow::Result<()> {
    for entry in fs::read_dir(frames_container)
        .context("visual comparison failed: could not inspect visual-reference generations")?
    {
        let entry = entry
            .context("visual comparison failed: could not inspect visual-reference generation")?;
        let path = entry.path();
        if path == current || !path.is_dir() {
            continue;
        }
        let owned = fs::read_to_string(path.join(".vimg-authority"))
            .is_ok_and(|marker| marker == AUTHORITY_MARKER);
        if owned {
            fs::remove_dir_all(&path).with_context(|| {
                format!(
                    "visual comparison failed: could not remove stale visual generation {}",
                    path.display()
                )
            })?;
        }
    }
    Ok(())
}

#[derive(Clone, Debug)]
struct AnimationStructure {
    stream_index: usize,
    width: u32,
    height: u32,
    frame_rate: String,
    duration_s: f64,
    frame_count: usize,
}

impl AnimationStructure {
    fn frame_rate_value(&self) -> anyhow::Result<f64> {
        parse_ratio(&self.frame_rate).context("structural inspection failed: invalid frame rate")
    }
}

fn inspect_animation(path: &Path) -> anyhow::Result<AnimationStructure> {
    let output = Command::new("ffprobe")
        .arg2("-v", "error")
        .arg("-count_frames")
        .arg("-show_streams")
        .arg2("-of", "json")
        .arg(path)
        .output()
        .context("structural inspection failed: could not start ffprobe")?;
    ensure!(
        output.status.success(),
        "structural inspection failed: ffprobe rejected {}\n{}",
        path.display(),
        String::from_utf8_lossy(&output.stderr).trim()
    );
    let probe: Value = serde_json::from_slice(&output.stdout)
        .context("structural inspection failed: ffprobe returned invalid JSON")?;
    let streams = probe
        .get("streams")
        .and_then(Value::as_array)
        .context("structural inspection failed: ffprobe returned no streams")?;
    let stream = streams
        .iter()
        .filter(|stream| stream.get("codec_type").and_then(Value::as_str) == Some("video"))
        .max_by_key(|stream| stream_frame_count(stream).unwrap_or_default())
        .context("structural inspection failed: no video stream found")?;

    let frame_count = stream_frame_count(stream)
        .context("structural inspection failed: animation frame count is unavailable")?;
    let frame_rate = stream
        .get("avg_frame_rate")
        .and_then(Value::as_str)
        .context("structural inspection failed: animation frame rate is unavailable")?
        .to_owned();
    let frame_rate_value =
        parse_ratio(&frame_rate).context("structural inspection failed: invalid frame rate")?;
    let duration_s = stream
        .get("duration")
        .and_then(Value::as_str)
        .and_then(|value| value.parse::<f64>().ok())
        .unwrap_or(frame_count as f64 / frame_rate_value);

    Ok(AnimationStructure {
        stream_index: json_usize(stream, "index")
            .context("structural inspection failed: animation stream index is unavailable")?,
        width: json_u32(stream, "width")
            .context("structural inspection failed: animation width is unavailable")?,
        height: json_u32(stream, "height")
            .context("structural inspection failed: animation height is unavailable")?,
        frame_rate,
        duration_s,
        frame_count,
    })
}

fn ensure_same_structure(
    reference: &AnimationStructure,
    candidate: &AnimationStructure,
) -> anyhow::Result<()> {
    let same_rate =
        (reference.frame_rate_value()? - candidate.frame_rate_value()?).abs() < 0.000_001;
    ensure!(
        reference.width == candidate.width
            && reference.height == candidate.height
            && reference.frame_count == candidate.frame_count
            && same_rate
            && (reference.duration_s - candidate.duration_s).abs() < 0.000_001,
        "structural inspection failed: reference is {}x{}, {} frames, {} fps, {:.6}s; candidate is {}x{}, {} frames, {} fps, {:.6}s",
        reference.width,
        reference.height,
        reference.frame_count,
        reference.frame_rate,
        reference.duration_s,
        candidate.width,
        candidate.height,
        candidate.frame_count,
        candidate.frame_rate,
        candidate.duration_s
    );
    Ok(())
}

fn validate_artifact_paths(input: &Path, output: &Path, manifest: &Path) -> anyhow::Result<()> {
    let input = path_identity(input)?;
    let output = path_identity(output)?;
    let manifest = path_identity(manifest)?;
    let frames = path_identity(&frames_dir_for(manifest.as_path()))?;
    ensure!(
        input != output
            && input != manifest
            && output != manifest
            && input != frames
            && output != frames
            && !input.starts_with(&frames)
            && !output.starts_with(&frames),
        "structural inspection failed: input, output, manifest, and authority frame directory must not overlap"
    );
    Ok(())
}

fn path_identity(path: &Path) -> anyhow::Result<PathBuf> {
    let absolute = if path.is_absolute() {
        path.to_path_buf()
    } else {
        std::env::current_dir()
            .context("structural inspection failed: could not resolve current directory")?
            .join(path)
    };
    let ancestor = absolute
        .ancestors()
        .find(|ancestor| ancestor.exists())
        .context(
            "structural inspection failed: artifact path has no resolvable existing ancestor",
        )?;
    let mut identity = fs::canonicalize(ancestor)
        .context("structural inspection failed: could not resolve artifact path")?;
    use std::path::Component;

    let unresolved = absolute
        .strip_prefix(ancestor)
        .context("structural inspection failed: could not resolve artifact path suffix")?;
    for component in unresolved.components() {
        match component {
            Component::CurDir => {}
            Component::ParentDir => {
                identity.pop();
            }
            Component::Normal(part) => identity.push(part),
            Component::Prefix(_) | Component::RootDir => {
                bail!("structural inspection failed: artifact path suffix is unexpectedly absolute")
            }
        }
    }
    Ok(identity)
}

fn frames_dir_for(manifest_path: &Path) -> PathBuf {
    let parent = manifest_path.parent().unwrap_or_else(|| Path::new("."));
    let file_name = manifest_path
        .file_name()
        .unwrap_or_else(|| std::ffi::OsStr::new("authority"));
    parent.join(format!("{}.frames", file_name.to_string_lossy()))
}

fn ensure_owned_frames_dir(frames_dir: &Path) -> anyhow::Result<()> {
    if !frames_dir.exists() {
        return Ok(());
    }
    ensure!(
        frames_dir.is_dir()
            && fs::read_to_string(frames_dir.join(".vimg-authority"))
                .is_ok_and(|marker| marker == AUTHORITY_MARKER),
        "visual comparison failed: refusing to replace unowned authority frame path {}",
        frames_dir.display()
    );
    Ok(())
}

fn authority_visual_digest(
    encoded_output: &Path,
    frames_dir: &Path,
    frame_count: usize,
) -> anyhow::Result<String> {
    const FNV_OFFSET: u128 = 0x6c62_272e_07bb_0142_62b8_2175_6295_c58d;
    const FNV_PRIME: u128 = 0x0000_0000_0100_0000_0000_0000_0000_013b;
    let mut hash = FNV_OFFSET;
    let mut update_file = |path: &Path| -> anyhow::Result<()> {
        let mut file = fs::File::open(path).with_context(|| {
            format!(
                "visual comparison failed: could not hash authority artifact {}",
                path.display()
            )
        })?;
        let mut buffer = [0_u8; 64 * 1024];
        loop {
            let read = file.read(&mut buffer).with_context(|| {
                format!(
                    "visual comparison failed: could not hash authority artifact {}",
                    path.display()
                )
            })?;
            if read == 0 {
                break;
            }
            for byte in &buffer[..read] {
                hash ^= u128::from(*byte);
                hash = hash.wrapping_mul(FNV_PRIME);
            }
        }
        hash ^= 0xff;
        hash = hash.wrapping_mul(FNV_PRIME);
        Ok(())
    };
    update_file(encoded_output)?;
    for kind in ["pre-encoder", "decoded"] {
        for frame_index in 1..=frame_count {
            update_file(
                &frames_dir
                    .join(kind)
                    .join(format!("frame-{frame_index:03}.png")),
            )?;
        }
    }
    Ok(format!("{hash:032x}"))
}

fn visual_directories_match(left: &Path, right: &Path, frame_count: usize) -> anyhow::Result<bool> {
    if !matches!(
        fs::read_to_string(right.join(".vimg-authority")),
        Ok(marker) if marker == AUTHORITY_MARKER
    ) {
        return Ok(false);
    }
    for kind in ["pre-encoder", "decoded"] {
        for frame_index in 1..=frame_count {
            let file_name = format!("frame-{frame_index:03}.png");
            if !files_equal(
                &left.join(kind).join(&file_name),
                &right.join(kind).join(&file_name),
            )? {
                return Ok(false);
            }
        }
    }
    Ok(true)
}

fn files_equal(left: &Path, right: &Path) -> anyhow::Result<bool> {
    let left_meta = match fs::metadata(left) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(false),
        Err(error) => return Err(error.into()),
    };
    let right_meta = match fs::metadata(right) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(false),
        Err(error) => return Err(error.into()),
    };
    if left_meta.len() != right_meta.len() {
        return Ok(false);
    }
    let mut left = fs::File::open(left)?;
    let mut right = fs::File::open(right)?;
    let mut left_buffer = [0_u8; 64 * 1024];
    let mut right_buffer = [0_u8; 64 * 1024];
    loop {
        let left_read = left.read(&mut left_buffer)?;
        let right_read = right.read(&mut right_buffer)?;
        if left_read != right_read || left_buffer[..left_read] != right_buffer[..right_read] {
            return Ok(false);
        }
        if left_read == 0 {
            return Ok(true);
        }
    }
}

fn decode_visual_references(
    output_path: &Path,
    structure: &AnimationStructure,
    frames_dir: &Path,
) -> anyhow::Result<Vec<String>> {
    fs::create_dir(frames_dir)
        .context("decoding failed: could not create decoded-frame directory")?;
    let template = frames_dir.join("frame-%03d.png");
    let decode = Command::new("ffmpeg")
        .arg2("-v", "error")
        .arg2("-i", output_path)
        .arg2("-map", format!("0:{}", structure.stream_index))
        .arg2("-fps_mode", "passthrough")
        .arg2("-frames:v", structure.frame_count.to_string())
        .arg("-y")
        .arg(&template)
        .output()
        .context("decoding failed: could not start ffmpeg")?;
    if !decode.status.success() {
        bail!(
            "decoding failed: ffmpeg could not decode visual references\n{}",
            String::from_utf8_lossy(&decode.stderr).trim()
        );
    }

    for frame_index in 1..=structure.frame_count {
        let frame = frames_dir.join(format!("frame-{frame_index:03}.png"));
        if !frame.is_file() {
            bail!(
                "decoding failed: expected visual reference frame {frame_index}, but it was not produced"
            );
        }
    }
    let frames = (1..=structure.frame_count)
        .map(|frame_index| format!("frame-{frame_index:03}.png"))
        .collect();
    Ok(frames)
}

fn prepare_manifest(path: &Path, manifest: &Value) -> anyhow::Result<PathBuf> {
    let parent = path.parent().unwrap_or_else(|| Path::new("."));
    fs::create_dir_all(parent)
        .context("structural inspection failed: could not create manifest directory")?;
    ensure!(
        !path.is_dir(),
        "structural inspection failed: authority manifest path is a directory"
    );
    let temporary = parent.join(format!(".authority.{}.tmp", fastrand::u64(..)));
    let contents = serde_json::to_string_pretty(manifest)
        .context("structural inspection failed: could not serialize authority manifest")?;
    fs::write(&temporary, format!("{contents}\n"))
        .context("structural inspection failed: could not write authority manifest")?;
    Ok(temporary)
}

fn replace_file(temporary: &Path, target: &Path) -> anyhow::Result<Option<PathBuf>> {
    ensure!(
        !target.is_dir(),
        "structural inspection failed: publication target is a directory"
    );
    let parent = target.parent().unwrap_or_else(|| Path::new("."));
    let backup = parent.join(format!(".authority.{}.backup", fastrand::u64(..)));
    let had_target = target.exists();
    if had_target {
        fs::rename(target, &backup)
            .context("structural inspection failed: could not preserve previous manifest")?;
    }
    if let Err(error) = fs::rename(temporary, target) {
        let publication_error = anyhow::Error::new(error)
            .context("structural inspection failed: could not publish manifest");
        if had_target && let Err(rollback_error) = fs::rename(&backup, target) {
            return Err(publication_error.context(format!(
                "structural inspection failed: manifest rollback also failed; previous manifest remains at {}: {rollback_error}",
                backup.display()
            )));
        }
        return Err(publication_error);
    }
    Ok(had_target.then_some(backup))
}

pub(crate) fn parse_source_frames(
    stats: &str,
    expected_frames: usize,
) -> anyhow::Result<Vec<SourceSelection>> {
    let mut selected = Vec::with_capacity(expected_frames);
    for (line_index, line) in stats
        .lines()
        .filter(|line| !line.trim().is_empty())
        .enumerate()
    {
        let mut fields = line.split_ascii_whitespace();
        let animation_index = fields
            .next()
            .and_then(|value| value.parse::<usize>().ok())
            .context("PTS extraction failed: invalid FFmpeg animation index")?;
        ensure!(
            animation_index == line_index,
            "PTS extraction failed: expected animation frame {line_index}, found {animation_index}"
        );
        let input_frame_index = fields
            .next()
            .and_then(|value| value.parse::<i64>().ok())
            .context("PTS extraction failed: invalid FFmpeg input frame index")?;
        let source_pts = fields
            .next()
            .and_then(|value| value.parse::<i64>().ok())
            .context("PTS extraction failed: invalid FFmpeg source PTS")?;
        let source_time_base = fields
            .next()
            .context("PTS extraction failed: missing FFmpeg source time base")?;
        ensure!(
            fields.next().is_none()
                && parse_ratio(source_time_base).is_ok()
                && input_frame_index >= 0
                && source_pts != i64::MAX,
            "PTS extraction failed: invalid FFmpeg encoder stats for animation frame {animation_index}"
        );
        selected.push(SourceSelection {
            source_pts,
            source_time_base: source_time_base.to_owned(),
            input_frame_index,
        });
    }
    ensure!(
        selected.len() == expected_frames,
        "PTS extraction failed: expected {expected_frames} animation frames, recorded {}",
        selected.len()
    );
    Ok(selected)
}

fn parse_ssim_frames(stats: &str) -> anyhow::Result<Vec<f64>> {
    let scores: Vec<_> = stats
        .lines()
        .filter_map(|line| {
            line.split_ascii_whitespace()
                .find_map(|field| field.strip_prefix("All:"))
        })
        .map(|score| {
            score
                .parse::<f64>()
                .context("visual comparison failed: FFmpeg emitted an invalid SSIM score")
        })
        .collect::<anyhow::Result<_>>()?;
    ensure!(
        !scores.is_empty(),
        "visual comparison failed: FFmpeg emitted no per-frame SSIM scores"
    );
    Ok(scores)
}

fn verify_frame_ssim(scores: &[f64], minimum: f64) -> anyhow::Result<()> {
    for (index, score) in scores.iter().copied().enumerate() {
        ensure!(
            score >= minimum,
            "visual comparison failed: frame {} SSIM {:.6} is below required {:.6}",
            index + 1,
            score,
            minimum
        );
    }
    Ok(())
}

fn stream_frame_count(stream: &Value) -> Option<usize> {
    json_usize(stream, "nb_read_frames").or_else(|| json_usize(stream, "nb_frames"))
}

fn json_usize(value: &Value, key: &str) -> Option<usize> {
    value
        .get(key)
        .and_then(|value| {
            value
                .as_u64()
                .or_else(|| value.as_str()?.parse::<u64>().ok())
        })
        .and_then(|value| usize::try_from(value).ok())
}

fn json_u32(value: &Value, key: &str) -> Option<u32> {
    json_usize(value, key).and_then(|value| u32::try_from(value).ok())
}

fn parse_ratio(value: &str) -> anyhow::Result<f64> {
    let (numerator, denominator) = value
        .split_once('/')
        .context("frame rate is not a fraction")?;
    let numerator = numerator.parse::<f64>()?;
    let denominator = denominator.parse::<f64>()?;
    ensure!(denominator != 0.0, "frame-rate denominator is zero");
    Ok(numerator / denominator)
}

#[cfg(test)]
mod tests {
    use super::*;

    const ENCODER_STATS: &str = "\
0 29 183100 1/1000\n\
1 30 183141 1/1000\n\
2 31 183183 1/1000\n";

    #[test]
    fn records_exact_input_pts_and_time_base_from_ffmpeg_encoder_stats() {
        let selected = parse_source_frames(ENCODER_STATS, 3).unwrap();

        assert_eq!(selected.len(), 3);
        assert_eq!(selected[0].source_pts, 183100);
        assert_eq!(selected[0].source_time_base, "1/1000");
        assert_eq!(selected[0].input_frame_index, 29);
        assert_eq!(selected[2].source_pts, 183183);
    }

    #[test]
    fn pts_failures_name_the_validation_phase() {
        let error = parse_source_frames("0 29 183100 1/1000\n2 31 183183 1/1000\n", 2).unwrap_err();

        assert!(error.to_string().starts_with("PTS extraction failed:"));
        assert!(error.to_string().contains("animation frame 1"));
    }

    #[test]
    fn parses_every_ssim_frame() {
        let stats = "\
n:1 Y:1.000000 U:1.000000 V:1.000000 All:1.000000 (inf)\n\
n:2 Y:0.995000 U:0.996000 V:0.997000 All:0.995100 (23.01)\n";

        assert_eq!(parse_ssim_frames(stats).unwrap(), vec![1.0, 0.9951]);
    }

    #[test]
    fn visual_checker_accepts_identical_frames() {
        verify_frame_ssim(&[1.0; 30], 0.999).unwrap();
    }

    #[test]
    fn visual_checker_rejects_known_frame_selection_mismatch() {
        let mut scores = [1.0; 30];
        scores[16] = 0.9685;

        let error = verify_frame_ssim(&scores, 0.999).unwrap_err();

        assert!(error.to_string().contains("visual comparison failed"));
        assert!(error.to_string().contains("frame 17"));
        assert!(error.to_string().contains("0.968500"));
    }

    #[test]
    fn visual_checker_rejects_bilinear_result_below_required_threshold() {
        let error = verify_frame_ssim(&[0.9951], 0.999).unwrap_err();

        assert!(error.to_string().contains("0.995100"));
        assert!(error.to_string().contains("0.999000"));
    }

    #[test]
    fn structure_failures_name_the_validation_phase() {
        let reference = AnimationStructure {
            stream_index: 1,
            width: 852,
            height: 480,
            frame_rate: "20/1".to_owned(),
            duration_s: 1.5,
            frame_count: 30,
        };
        let mut candidate = reference.clone();
        candidate.frame_count = 29;

        let error = ensure_same_structure(&reference, &candidate).unwrap_err();

        assert!(
            error
                .to_string()
                .starts_with("structural inspection failed:")
        );
        assert!(error.to_string().contains("29 frames"));
    }

    #[test]
    fn artifact_path_conflicts_are_rejected_before_recording() {
        let error = validate_artifact_paths(
            Path::new("same.mkv"),
            Path::new("output.avif"),
            Path::new("same.mkv"),
        )
        .unwrap_err();

        assert!(
            error
                .to_string()
                .starts_with("structural inspection failed:")
        );
        assert!(error.to_string().contains("must not overlap"));
    }

    #[test]
    fn artifact_path_conflicts_normalize_missing_parent_segments() {
        let root = temporary_test_dir("authority-path-normalization");
        let input = root.join("input.mkv");
        let output = root.join("output.avif");
        let manifest = root.join("missing-parent").join("..").join("input.mkv");
        fs::write(&input, b"video").unwrap();

        let error = validate_artifact_paths(&input, &output, &manifest).unwrap_err();

        assert!(error.to_string().contains("must not overlap"));
        assert!(!root.join("missing-parent").exists());
        fs::remove_dir_all(root).unwrap();
    }

    #[cfg(unix)]
    #[test]
    fn artifact_path_conflicts_resolve_symlink_before_parent_segments() {
        use std::os::unix::fs::symlink;

        let root = temporary_test_dir("authority-symlink-normalization");
        let real_parent = root.join("real");
        let linked_subdir = real_parent.join("subdir");
        let input = real_parent.join("input.mkv");
        let output = root.join("output.avif");
        fs::create_dir_all(&linked_subdir).unwrap();
        fs::write(&input, b"video").unwrap();
        symlink(&linked_subdir, root.join("link")).unwrap();
        let manifest = root.join("link").join("..").join("input.mkv");

        let error = validate_artifact_paths(&input, &output, &manifest).unwrap_err();

        assert!(error.to_string().contains("must not overlap"));
        assert_eq!(fs::read(&input).unwrap(), b"video");
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn unpublished_authority_removes_new_visual_generation() {
        let root = temporary_test_dir("authority-rollback");
        let manifest_path = root.join("authority.json");
        let temporary_manifest = root.join(".authority.tmp");
        let frames_container = frames_dir_for(&manifest_path);
        let frames_dir = frames_container.join("digest");
        fs::create_dir_all(&frames_dir).unwrap();
        fs::write(frames_container.join(".vimg-authority"), AUTHORITY_MARKER).unwrap();
        fs::write(&temporary_manifest, "new manifest").unwrap();

        drop(PreparedAuthority {
            manifest_path,
            temporary_manifest: temporary_manifest.clone(),
            frames_container: frames_container.clone(),
            frames_dir,
            frames_container_created: true,
            frames_dir_created: true,
            source_count: 270,
            frame_count: 30,
            published: false,
        });

        assert!(!temporary_manifest.exists());
        assert!(!frames_container.exists());
        fs::remove_dir(root).unwrap();
    }

    #[test]
    fn published_authority_keeps_visual_generation_and_replaces_manifest() {
        let root = temporary_test_dir("authority-publish");
        let manifest_path = root.join("authority.json");
        let temporary_manifest = root.join(".authority.tmp");
        let frames_container = frames_dir_for(&manifest_path);
        let frames_dir = frames_container.join("digest");
        let stale_frames_dir = frames_container.join("stale-digest");
        fs::create_dir_all(&frames_dir).unwrap();
        fs::create_dir(&stale_frames_dir).unwrap();
        fs::write(frames_container.join(".vimg-authority"), AUTHORITY_MARKER).unwrap();
        fs::write(stale_frames_dir.join(".vimg-authority"), AUTHORITY_MARKER).unwrap();
        fs::write(&manifest_path, "old manifest").unwrap();
        fs::write(&temporary_manifest, "new manifest").unwrap();

        PreparedAuthority {
            manifest_path: manifest_path.clone(),
            temporary_manifest,
            frames_container,
            frames_dir: frames_dir.clone(),
            frames_container_created: true,
            frames_dir_created: true,
            source_count: 270,
            frame_count: 30,
            published: false,
        }
        .publish()
        .unwrap()
        .finish();

        assert_eq!(fs::read_to_string(manifest_path).unwrap(), "new manifest");
        assert!(frames_dir.exists());
        assert!(!stale_frames_dir.exists());
        fs::remove_dir_all(root).unwrap();
    }

    fn temporary_test_dir(label: &str) -> PathBuf {
        let path = std::env::temp_dir().join(format!("vimg-{label}-{}", fastrand::u64(..)));
        fs::create_dir(&path).unwrap();
        path
    }
}
