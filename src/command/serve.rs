use crate::command;
use anyhow::{Context, ensure};
use std::{
    collections::{HashMap, HashSet, VecDeque},
    fs,
    io::{BufRead, BufReader, Read},
    path::{Path, PathBuf},
    process::{Command as ProcessCommand, Stdio},
    sync::{Arc, Condvar, Mutex},
    thread,
    time::{Duration, Instant},
};

const REQUEST_EVENT: &str = "vimg-gridthumb-request";
const READY_EVENT: &str = "gridthumb-avif-ready";
const FAILED_EVENT: &str = "gridthumb-avif-failed";
const MAX_JOBS: usize = 10;
// Bump when the fixed preview's output contract changes. Legacy manifests
// remain readable by the plugin, but are not sufficient for server reuse.
const CACHE_PROFILE: &str = "vimg-preview-3x3-h160-n9-f30-crf30-v1";

/// Run as a service, receiving vimg jobs from Yazi DDS.
#[derive(clap::Parser, Debug)]
pub struct Serve {
    /// Capture implementation fixed for every job in this service process.
    #[arg(long, value_enum, default_value_t = command::DEFAULT_CAPTURE_BACKEND)]
    pub capture_backend: command::CaptureBackendPolicy,
}

/// Send a vimg job to the running service.
#[derive(clap::Parser, Debug)]
pub struct Send {
    /// Video file path.
    pub file: PathBuf,
    /// Output cache path.
    pub cache: PathBuf,
    /// Target Yazi instance to notify when the preview is ready.
    #[arg(long)]
    pub yazi_id: Option<String>,
    /// Source file size captured by the preview client.
    #[arg(long)]
    pub source_size: Option<u64>,
    /// Source modification time, as Unix seconds, captured by the preview client.
    #[arg(long)]
    pub source_modified_s: Option<u64>,
    /// Source duration in seconds captured by the preview client.
    #[arg(long)]
    pub duration_s: Option<f32>,
    /// Source video width captured by the preview client.
    #[arg(long)]
    pub width: Option<u32>,
    /// Source video height captured by the preview client.
    #[arg(long)]
    pub height: Option<u32>,
    /// Codec name of the selected video stream, captured by the preview client.
    #[arg(long)]
    pub codec: Option<String>,
    /// Numerator of the selected video stream's time base, captured by the preview client.
    #[arg(long)]
    pub source_time_base_numerator: Option<i32>,
    /// Denominator of the selected video stream's time base, captured by the preview client.
    #[arg(long)]
    pub source_time_base_denominator: Option<i32>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct SourceDescriptor {
    size: u64,
    modified_s: u64,
}

#[derive(Clone, Debug)]
struct Job {
    file: PathBuf,
    cache: PathBuf,
    source: Option<SourceDescriptor>,
    media: Option<command::MediaDescriptor>,
    yazi_id: Option<String>,
}

impl Job {
    fn from_json(line: &str) -> Option<Self> {
        let value: serde_json::Value = serde_json::from_str(line).ok()?;
        let source_size = value.get("source_size").and_then(serde_json::Value::as_u64);
        let source_modified_s = value
            .get("source_modified_s")
            .and_then(serde_json::Value::as_u64);
        let duration_s = value
            .get("duration_s")
            .and_then(serde_json::Value::as_f64)
            .map(|duration| duration as f32)
            .filter(|duration| duration.is_finite() && *duration > 0.0);
        let width = value
            .get("width")
            .and_then(serde_json::Value::as_u64)
            .and_then(|width| u32::try_from(width).ok())
            .filter(|width| *width > 0);
        let height = value
            .get("height")
            .and_then(serde_json::Value::as_u64)
            .and_then(|height| u32::try_from(height).ok())
            .filter(|height| *height > 0);
        let source_time_base = value
            .get("source_time_base_numerator")
            .and_then(serde_json::Value::as_i64)
            .and_then(|numerator| i32::try_from(numerator).ok())
            .filter(|numerator| *numerator > 0)
            .zip(
                value
                    .get("source_time_base_denominator")
                    .and_then(serde_json::Value::as_i64)
                    .and_then(|denominator| i32::try_from(denominator).ok())
                    .filter(|denominator| *denominator > 0),
            )
            .map(|(numerator, denominator)| {
                command::frame_schedule::Rational::new(numerator, denominator)
            });
        let codec = value
            .get("codec")
            .and_then(serde_json::Value::as_str)
            .filter(|codec| !codec.is_empty())
            .map(str::to_owned);
        Some(Self {
            file: PathBuf::from(value.get("file")?.as_str()?),
            cache: PathBuf::from(value.get("cache")?.as_str()?),
            source: source_size
                .zip(source_modified_s)
                .map(|(size, modified_s)| SourceDescriptor { size, modified_s }),
            media: (duration_s.is_some()
                || width.is_some()
                || height.is_some()
                || source_time_base.is_some()
                || codec.is_some())
            .then_some(command::MediaDescriptor {
                duration_s,
                width,
                height,
                codec,
                source_time_base,
            }),
            yazi_id: value
                .get("yazi_id")
                .and_then(serde_json::Value::as_str)
                .map(str::to_owned),
        })
    }

    fn file_name(&self) -> &str {
        self.file
            .file_name()
            .and_then(|name| name.to_str())
            .unwrap_or("?")
    }
}

#[derive(Default)]
struct QueueState {
    jobs: HashSet<PathBuf>,
    subscribers: HashMap<PathBuf, HashSet<String>>,
    queued: VecDeque<Job>,
    active: HashSet<PathBuf>,
}

struct Scheduler {
    state: Mutex<QueueState>,
    ready: Condvar,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum SubmitResult {
    Queued,
    Shared,
    Busy,
}

impl SubmitResult {
    fn protocol(self) -> &'static str {
        match self {
            Self::Queued => "queued",
            Self::Shared => "shared",
            Self::Busy => "busy",
        }
    }
}

impl Scheduler {
    fn submit(&self, job: Job) -> SubmitResult {
        let mut state = self.state.lock().unwrap();
        if state.jobs.contains(&job.cache) {
            add_subscriber(&mut state, &job);
            return SubmitResult::Shared;
        }

        // Keep the running job and evict the oldest job that has not started.
        if state.jobs.len() >= MAX_JOBS {
            if let Some(evicted) = state.queued.pop_front() {
                state.jobs.remove(&evicted.cache);
                state.subscribers.remove(&evicted.cache);
            } else {
                return SubmitResult::Busy;
            }
        }

        add_subscriber(&mut state, &job);
        state.jobs.insert(job.cache.clone());
        state.queued.push_back(job);
        self.ready.notify_one();
        SubmitResult::Queued
    }

    fn next(&self) -> Job {
        let mut state = self.state.lock().unwrap();
        while state.queued.is_empty() {
            state = self.ready.wait(state).unwrap();
        }
        // Taking the newest entry preserves interactive priority. The oldest
        // queued entry is the one replaced at the Admission limit.
        let job = state.queued.pop_back().unwrap();
        state.active.insert(job.cache.clone());
        job
    }

    fn finish(&self, cache: &Path) -> Vec<String> {
        let mut state = self.state.lock().unwrap();
        state.jobs.remove(cache);
        state.active.remove(cache);
        state
            .subscribers
            .remove(cache)
            .unwrap_or_default()
            .into_iter()
            .collect()
    }
}

fn add_subscriber(state: &mut QueueState, job: &Job) {
    if let Some(yazi_id) = &job.yazi_id {
        state
            .subscribers
            .entry(job.cache.clone())
            .or_default()
            .insert(yazi_id.clone());
    }
}

impl Serve {
    pub fn run(self) -> anyhow::Result<()> {
        let scheduler = Arc::new(Scheduler {
            state: Mutex::new(QueueState::default()),
            ready: Condvar::new(),
        });
        for worker_id in 1..=MAX_JOBS {
            let worker_scheduler = Arc::clone(&scheduler);
            let capture_backend = self.capture_backend;
            thread::Builder::new()
                .name(format!("vimg-worker-{worker_id}"))
                .spawn(move || worker(worker_id, worker_scheduler, capture_backend))
                .context("Cannot start a vimg service worker")?;
        }

        println!("[serve] Started {MAX_JOBS} workers; waiting for Yazi DDS");
        receive_yazi_requests(scheduler)
    }
}

fn receive_yazi_requests(scheduler: Arc<Scheduler>) -> anyhow::Result<()> {
    loop {
        let mut child = ProcessCommand::new("ya")
            .args(["sub", REQUEST_EVENT])
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .spawn()
            .context("Cannot start `ya sub`; is Yazi installed?")?;
        let stdout = child
            .stdout
            .take()
            .context("Cannot read messages from `ya sub`")?;
        println!("[serve] Subscribed to Yazi DDS event {REQUEST_EVENT}");

        for line in BufReader::new(stdout).lines() {
            match line {
                Ok(line) => match submit_dds_message(&line, &scheduler) {
                    Ok(result) => println!("[serve] DDS request: {}", result.protocol()),
                    Err(error) => eprintln!("[serve] Invalid DDS request: {error}"),
                },
                Err(error) => {
                    eprintln!("[serve] Cannot read Yazi DDS: {error}");
                    break;
                }
            }
        }

        match child.wait() {
            Ok(status) => eprintln!("[serve] `ya sub` disconnected ({status}); retrying"),
            Err(error) => eprintln!("[serve] Cannot wait for `ya sub`: {error}; retrying"),
        }
        thread::sleep(Duration::from_secs(1));
    }
}

#[cfg(test)]
fn submit_request(line: &str, scheduler: &Scheduler) -> Result<SubmitResult, ()> {
    let job = Job::from_json(line).ok_or(())?;
    Ok(scheduler.submit(job))
}

fn submit_dds_message(line: &str, scheduler: &Scheduler) -> anyhow::Result<SubmitResult> {
    let mut fields = line.splitn(4, ',');
    let kind = fields.next().context("missing event kind")?;
    ensure!(kind == REQUEST_EVENT, "unexpected event kind {kind}");
    let _receiver = fields.next().context("missing receiver")?;
    let sender = fields.next().context("missing sender")?;
    let body = fields.next().context("missing JSON body")?;
    let mut job = Job::from_json(body).context("invalid JSON body")?;
    if job.yazi_id.is_none() && sender != "0" {
        job.yazi_id = Some(sender.to_owned());
    }
    Ok(scheduler.submit(job))
}

fn worker(
    worker_id: usize,
    scheduler: Arc<Scheduler>,
    capture_backend: command::CaptureBackendPolicy,
) {
    loop {
        let job = scheduler.next();
        let started = Instant::now();
        println!(
            "[serve:{worker_id}] Processing: {} -> {}",
            job.file_name(),
            job.cache.display()
        );
        let completion = complete_job(
            &scheduler,
            &job,
            capture_backend,
            |backend| run_vcs(&job.file, &job.cache, job.media.as_ref(), backend),
            || publish_manifest(&job, capture_backend),
        );
        if std::env::var("VIMG_PROTO_MI_STATS").is_ok_and(|value| value == "1") {
            report_mi_stats();
        }
        match completion.outcome {
            ServiceJobOutcome::Published | ServiceJobOutcome::Reused => {
                if completion.outcome == ServiceJobOutcome::Reused {
                    println!("[serve:{worker_id}] Cache hit: {}", job.file_name());
                }
                notify_yazi(
                    &job.file,
                    &job.cache,
                    &completion.subscribers,
                    READY_EVENT,
                    None,
                );
                println!(
                    "[serve:{worker_id}] Done: {} ({:.1}s)",
                    job.file_name(),
                    started.elapsed().as_secs_f32()
                );
            }
            ServiceJobOutcome::Failed(reason) => notify_yazi(
                &job.file,
                &job.cache,
                &completion.subscribers,
                FAILED_EVENT,
                Some(&reason),
            ),
        }
    }
}

struct ServiceCompletion {
    outcome: ServiceJobOutcome,
    subscribers: Vec<String>,
}

#[derive(Debug, Eq, PartialEq)]
enum ServiceJobOutcome {
    Published,
    Reused,
    Failed(String),
}

fn complete_job(
    scheduler: &Scheduler,
    job: &Job,
    capture_backend: command::CaptureBackendPolicy,
    run_capture: impl FnOnce(command::CaptureBackendPolicy) -> anyhow::Result<()>,
    publish: impl FnOnce() -> anyhow::Result<()>,
) -> ServiceCompletion {
    if cache_is_current(job, capture_backend) {
        return ServiceCompletion {
            outcome: ServiceJobOutcome::Reused,
            subscribers: scheduler.finish(&job.cache),
        };
    }
    let outcome = match run_capture(capture_backend) {
        Ok(()) => match publish() {
            Ok(()) => ServiceJobOutcome::Published,
            Err(error) => {
                eprintln!("[serve] Manifest error: {}: {error}", job.file_name());
                ServiceJobOutcome::Failed(error.to_string())
            }
        },
        Err(error) => {
            eprintln!("[serve] Error: {}: {error}", job.file_name());
            ServiceJobOutcome::Failed(error.to_string())
        }
    };
    ServiceCompletion {
        outcome,
        subscribers: scheduler.finish(&job.cache),
    }
}

fn source_descriptor(metadata: &fs::Metadata) -> anyhow::Result<SourceDescriptor> {
    let modified_s = metadata
        .modified()?
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs();
    Ok(SourceDescriptor {
        size: metadata.len(),
        modified_s,
    })
}

fn manifest_path(cache: &Path, source: &SourceDescriptor) -> PathBuf {
    PathBuf::from(format!(
        "{}.{}-{}.json",
        cache.display(),
        source.size,
        source.modified_s
    ))
}

fn current_manifest(
    job: &Job,
    backend: command::CaptureBackendPolicy,
) -> anyhow::Result<(SourceDescriptor, serde_json::Value)> {
    let source_metadata = fs::metadata(&job.file)?;
    ensure!(source_metadata.is_file(), "preview source is not a file");
    let source = source_descriptor(&source_metadata)?;
    ensure!(
        job.source
            .as_ref()
            .is_none_or(|requested| requested == &source),
        "preview source changed since the request"
    );
    let mut output = fs::File::open(&job.cache)?;
    let output_metadata = output.metadata()?;
    ensure!(output_metadata.is_file(), "preview output is not a file");
    let mut header = [0; 12];
    output.read_exact(&mut header)?;
    ensure!(
        &header[4..8] == b"ftyp" && matches!(&header[8..12], b"avif" | b"avis"),
        "preview output has no AVIF header"
    );
    let modified_ns = |metadata: &fs::Metadata| -> anyhow::Result<String> {
        Ok(metadata
            .modified()?
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap_or_default()
            .as_nanos()
            .to_string())
    };
    let manifest = serde_json::json!({
        "source_size": source.size,
        "source_modified_s": source.modified_s,
        "source_modified_ns": modified_ns(&source_metadata)?,
        "source_path": fs::canonicalize(&job.file)?.to_string_lossy(),
        "output_size": output_metadata.len(),
        "output_modified_ns": modified_ns(&output_metadata)?,
        "profile": CACHE_PROFILE,
        "backend_policy": backend.name(),
        "prototype_run": prototype_run(),
    });
    Ok((source, manifest))
}

fn cache_is_current(job: &Job, backend: command::CaptureBackendPolicy) -> bool {
    // Diagnostic knobs can change the capture profile or intentionally omit
    // work. Neither consume cached results nor promote them to normal runs.
    if prototype_run() {
        return false;
    }
    let check = || -> anyhow::Result<bool> {
        let (source, expected) = current_manifest(job, backend)?;
        let bytes = fs::read(manifest_path(&job.cache, &source))?;
        let stored: serde_json::Value = serde_json::from_slice(&bytes)?;
        Ok(stored == expected)
    };
    // Missing, legacy, changed or invalid artifacts take the generation path.
    check().unwrap_or(false)
}

fn prototype_run() -> bool {
    std::env::vars_os().any(|(name, _)| name.to_string_lossy().starts_with("VIMG_PROTO_"))
}

fn publish_manifest(job: &Job, backend: command::CaptureBackendPolicy) -> anyhow::Result<()> {
    let (source, manifest) = current_manifest(job, backend)?;
    let manifest_path = manifest_path(&job.cache, &source);
    let parent = manifest_path.parent().unwrap_or_else(|| Path::new("."));
    let temporary = parent.join(format!(".{}.tmp", fastrand::u64(..)));
    fs::write(&temporary, manifest.to_string())?;
    if let Err(error) = fs::rename(&temporary, &manifest_path) {
        if manifest_path.exists() {
            fs::remove_file(&manifest_path)?;
            fs::rename(&temporary, &manifest_path)?;
        } else {
            return Err(error.into());
        }
    }
    Ok(())
}

fn notify_yazi(
    video: &Path,
    cache: &Path,
    subscribers: &[String],
    event: &str,
    failure_reason: Option<&str>,
) {
    let payload = match failure_reason {
        Some(reason) => serde_json::json!({
            "file": video.to_string_lossy(),
            "cache": cache.to_string_lossy(),
            "error": reason,
        }),
        None => serde_json::json!({
            "file": video.to_string_lossy(),
            "cache": cache.to_string_lossy(),
        }),
    };
    let payload = payload.to_string();
    for yazi_id in subscribers {
        match ProcessCommand::new("ya")
            .args(["pub-to", yazi_id, event, "--json", &payload])
            .status()
        {
            Ok(status) if status.success() => {}
            Ok(status) => eprintln!("[serve] Yazi notification exited with {status}"),
            Err(error) => eprintln!("[serve] Cannot notify Yazi: {error}"),
        }
    }
}

impl Send {
    pub fn run(self) -> anyhow::Result<()> {
        let request = serde_json::json!({
            "file": self.file.to_string_lossy(),
            "cache": self.cache.to_string_lossy(),
            "yazi_id": self.yazi_id,
            "source_size": self.source_size,
            "source_modified_s": self.source_modified_s,
            "duration_s": self.duration_s,
            "width": self.width,
            "height": self.height,
            "codec": self.codec,
            "source_time_base_numerator": self.source_time_base_numerator,
            "source_time_base_denominator": self.source_time_base_denominator,
        })
        .to_string();
        let status = ProcessCommand::new("ya")
            .args(["pub-to", "0", REQUEST_EVENT, "--json", &request])
            .status()
            .context("Cannot publish the request through `ya`")?;
        ensure!(status.success(), "`ya pub-to` exited with {status}");
        Ok(())
    }
}

fn run_vcs(
    video: &Path,
    output: &Path,
    media: Option<&command::MediaDescriptor>,
    capture_backend: command::CaptureBackendPolicy,
) -> anyhow::Result<()> {
    ensure!(video.exists(), "Video file not found: {}", video.display());
    vcs_for_job(video, output, media, capture_backend).run()
}

/// Prototype bisection: force mimalloc to release idle pages, then report the
/// process RSS/commit. If commit drops after mi_collect, retention is allocator
/// idle-page caching; if it stays, blocks are genuinely leaked.
#[cfg(feature = "proto-mimalloc")]
fn report_mi_stats() {
    unsafe extern "C" {
        fn mi_collect(force: i32);
        fn mi_process_info(
            elapsed_msecs: *mut usize,
            user_msecs: *mut usize,
            system_msecs: *mut usize,
            current_rss: *mut usize,
            peak_rss: *mut usize,
            current_commit: *mut usize,
            peak_commit: *mut usize,
            page_faults: *mut usize,
        );
    }
    unsafe {
        mi_collect(1);
        let (mut rss, mut peak, mut commit) = (0usize, 0usize, 0usize);
        mi_process_info(
            std::ptr::null_mut(),
            std::ptr::null_mut(),
            std::ptr::null_mut(),
            &mut rss,
            &mut peak,
            &mut commit,
            std::ptr::null_mut(),
            std::ptr::null_mut(),
        );
        eprintln!(
            "[proto] mi_collect: rss={}MB peak={}MB commit={}MB",
            rss / 1048576,
            peak / 1048576,
            commit / 1048576
        );
    }
}

#[cfg(not(feature = "proto-mimalloc"))]
fn report_mi_stats() {}

fn vcs_for_job(
    video: &Path,
    output: &Path,
    media: Option<&command::MediaDescriptor>,
    capture_backend: command::CaptureBackendPolicy,
) -> command::Vcs {
    command::Vcs {
        columns: 3,
        output: Some(output.to_path_buf()),
        avif_crf: 30,
        avif_codec: "libsvtav1".to_string(),
        avif_preset: None,
        avif_fps: 20.0,
        capture_width: None,
        capture_height: Some(160),
        args: command::Extract {
            number: std::env::var("VIMG_PROTO_CAPTURES")
                .ok()
                .and_then(|value| value.parse::<u32>().ok())
                .unwrap_or(9),
            ignore_start: std::env::var("VIMG_PROTO_IGNORE_START")
                .ok()
                .and_then(|value| value.parse::<f32>().ok())
                .map(command::DurationOrPercent::Seconds)
                .unwrap_or_default(),
            ignore_end: Default::default(),
            capture_frames: None,
            capture_time: command::HumanDuration { seconds: 1.5 },
            vfilter: None,
            threads: 4,
            output_dir: None,
            video: video.to_path_buf(),
            media: media.cloned(),
        },
        keep: false,
        webp: 0,
        profile: false,
        capture_backend,
        authority_manifest: None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use clap::Parser;
    use std::cell::Cell;
    #[cfg(all(target_os = "macos", feature = "in-process-decode"))]
    use std::cell::RefCell;
    use std::io::Write;

    fn job(cache: &str) -> Job {
        Job {
            file: PathBuf::from("video.mkv"),
            cache: PathBuf::from(cache),
            source: None,
            media: None,
            yazi_id: None,
        }
    }

    #[test]
    fn coalesces_requests_for_the_same_preview_cache() {
        let scheduler = Scheduler {
            state: Mutex::new(QueueState::default()),
            ready: Condvar::new(),
        };

        assert_eq!(scheduler.submit(job("preview.avif")), SubmitResult::Queued);
        assert_eq!(scheduler.submit(job("preview.avif")), SubmitResult::Shared);
        assert_eq!(scheduler.next().cache, PathBuf::from("preview.avif"));
    }

    #[test]
    fn coalesced_capture_job_completes_for_every_waiting_yazi_subscriber() {
        let scheduler = Scheduler {
            state: Mutex::new(QueueState::default()),
            ready: Condvar::new(),
        };
        let mut first = job("preview.avif");
        first.yazi_id = Some("first".to_owned());
        let mut second = job("preview.avif");
        second.yazi_id = Some("second".to_owned());

        assert_eq!(scheduler.submit(first), SubmitResult::Queued);
        assert_eq!(scheduler.submit(second), SubmitResult::Shared);
        let active = scheduler.next();
        let mut subscribers = scheduler.finish(&active.cache);
        subscribers.sort();

        assert_eq!(subscribers, ["first", "second"]);
    }

    #[test]
    fn service_execution_seam_uses_the_startup_policy_for_explicit_and_auto_jobs() {
        for policy in [
            command::CaptureBackendPolicy::Ffmpeg,
            command::CaptureBackendPolicy::Auto,
            command::CaptureBackendPolicy::Libav,
            command::CaptureBackendPolicy::VideoToolbox,
        ] {
            let scheduler = Scheduler {
                state: Mutex::new(QueueState::default()),
                ready: Condvar::new(),
            };
            assert_eq!(scheduler.submit(job("preview.avif")), SubmitResult::Queued);
            let active = scheduler.next();
            let applied_policy = Cell::new(None);

            let completion = complete_job(
                &scheduler,
                &active,
                policy,
                |backend| {
                    applied_policy.set(Some(backend));
                    Ok(())
                },
                || Ok(()),
            );

            assert_eq!(completion.outcome, ServiceJobOutcome::Published);
            assert_eq!(applied_policy.get(), Some(policy));
        }
    }

    #[cfg(all(target_os = "macos", feature = "in-process-decode"))]
    #[test]
    fn service_auto_publishes_the_ffmpeg_result_after_both_in_process_attempts_fail() {
        let scheduler = Scheduler {
            state: Mutex::new(QueueState::default()),
            ready: Condvar::new(),
        };
        assert_eq!(scheduler.submit(job("preview.avif")), SubmitResult::Queued);
        let active = scheduler.next();
        let mut vcs = command::Vcs::try_parse_from([
            "vimg",
            "--capture-backend",
            "auto",
            "-c3",
            "-H160",
            "-n9",
            "input.mkv",
        ])
        .unwrap();
        vcs.args.capture_frames = Some(30);
        vcs.args.media = Some(command::MediaDescriptor {
            duration_s: Some(18.0),
            width: Some(1920),
            height: Some(1080),
            codec: Some("h264".to_owned()),
            source_time_base: Some(crate::command::frame_schedule::Rational::new(1, 1_000)),
        });
        let capture =
            command::Capture::plan(&vcs.args, vcs.capture_height, vcs.capture_width, 0).unwrap();
        let started = RefCell::new(Vec::new());
        let published = Cell::new(false);

        let completion = complete_job(
            &scheduler,
            &active,
            command::CaptureBackendPolicy::Auto,
            |policy| {
                assert_eq!(policy, command::CaptureBackendPolicy::Auto);
                let _selected = crate::command::vcs::execute_vcs_backend_candidates(
                    &vcs,
                    &capture,
                    |backend| {
                        started.borrow_mut().push(backend);
                        match backend {
                            command::CaptureBackendPolicy::VideoToolbox
                            | command::CaptureBackendPolicy::Libav => {
                                Err(command::CaptureBackendFailure::attempt(
                                    backend,
                                    "decode",
                                    anyhow::anyhow!("injected backend failure"),
                                )
                                .into())
                            }
                            command::CaptureBackendPolicy::Ffmpeg => Ok(()),
                            command::CaptureBackendPolicy::Auto => unreachable!(),
                        }
                    },
                )?;
                Ok(())
            },
            || {
                published.set(true);
                Ok(())
            },
        );

        assert_eq!(completion.outcome, ServiceJobOutcome::Published);
        assert!(published.get());
        assert_eq!(
            started.into_inner(),
            [
                command::CaptureBackendPolicy::VideoToolbox,
                command::CaptureBackendPolicy::Libav,
                command::CaptureBackendPolicy::Ffmpeg,
            ]
        );
    }

    #[test]
    fn fatal_service_capture_error_skips_publication_and_releases_the_next_job() {
        let scheduler = Scheduler {
            state: Mutex::new(QueueState::default()),
            ready: Condvar::new(),
        };
        let mut active_job = job("active.avif");
        active_job.yazi_id = Some("waiting".to_owned());
        assert_eq!(scheduler.submit(active_job), SubmitResult::Queued);
        let active = scheduler.next();
        assert_eq!(scheduler.submit(job("next.avif")), SubmitResult::Queued);
        let published = Cell::new(false);

        let completion = complete_job(
            &scheduler,
            &active,
            command::CaptureBackendPolicy::Auto,
            |_| anyhow::bail!("injected fatal capture error"),
            || {
                published.set(true);
                Ok(())
            },
        );

        assert_eq!(
            completion.outcome,
            ServiceJobOutcome::Failed("injected fatal capture error".to_owned())
        );
        assert_eq!(completion.subscribers, ["waiting"]);
        assert!(!published.get());
        assert_eq!(scheduler.next().cache, PathBuf::from("next.avif"));
    }

    #[test]
    fn replaces_the_oldest_unstarted_preview_at_capacity() {
        let scheduler = Scheduler {
            state: Mutex::new(QueueState::default()),
            ready: Condvar::new(),
        };
        for index in 0..MAX_JOBS {
            assert_eq!(
                scheduler.submit(job(&format!("{index}.avif"))),
                SubmitResult::Queued
            );
        }
        assert_eq!(scheduler.submit(job("newest.avif")), SubmitResult::Queued);
        assert_eq!(scheduler.next().cache, PathBuf::from("newest.avif"));
        let state = scheduler.state.lock().unwrap();
        assert!(!state.jobs.contains(&PathBuf::from("0.avif")));
    }

    #[test]
    fn never_runs_more_than_ten_jobs_at_once() {
        let scheduler = Scheduler {
            state: Mutex::new(QueueState::default()),
            ready: Condvar::new(),
        };
        for index in 0..MAX_JOBS {
            assert_eq!(
                scheduler.submit(job(&format!("{index}.avif"))),
                SubmitResult::Queued
            );
            scheduler.next();
        }

        let state = scheduler.state.lock().unwrap();
        assert_eq!(state.active.len(), MAX_JOBS);
        drop(state);
        assert_eq!(scheduler.submit(job("overflow.avif")), SubmitResult::Busy);
    }

    #[test]
    fn dds_request_uses_sender_as_the_yazi_subscriber() {
        let scheduler = Scheduler {
            state: Mutex::new(QueueState::default()),
            ready: Condvar::new(),
        };
        let line = concat!(
            "vimg-gridthumb-request,0,987654321,",
            r#"{"file":"video,one.mkv","cache":"preview.avif"}"#
        );

        assert_eq!(
            submit_dds_message(line, &scheduler).unwrap(),
            SubmitResult::Queued
        );
        let active = scheduler.next();
        assert_eq!(active.file, PathBuf::from("video,one.mkv"));
        assert_eq!(scheduler.finish(&active.cache), ["987654321"]);
    }

    #[test]
    fn explicit_yazi_id_takes_precedence_over_a_cli_dds_sender() {
        let scheduler = Scheduler {
            state: Mutex::new(QueueState::default()),
            ready: Condvar::new(),
        };
        let line = concat!(
            "vimg-gridthumb-request,0,111,",
            r#"{"file":"video.mkv","cache":"preview.avif","yazi_id":"222"}"#
        );

        assert_eq!(
            submit_dds_message(line, &scheduler).unwrap(),
            SubmitResult::Queued
        );
        let active = scheduler.next();
        assert_eq!(scheduler.finish(&active.cache), ["222"]);
    }

    #[test]
    fn manifest_path_is_bound_to_the_source_identity() {
        let path = manifest_path(
            Path::new("preview.avif"),
            &SourceDescriptor {
                size: 42,
                modified_s: 7,
            },
        );
        assert_eq!(path, PathBuf::from("preview.avif.42-7.json"));
    }

    #[test]
    fn accepts_an_optional_source_descriptor_from_the_protocol() {
        let job = Job::from_json(
            r#"{"file":"video.mkv","cache":"preview.avif","source_size":42,"source_modified_s":7}"#,
        )
        .unwrap();
        assert_eq!(
            job.source,
            Some(SourceDescriptor {
                size: 42,
                modified_s: 7,
            })
        );
    }

    #[test]
    fn accepts_duration_and_dimensions_from_the_media_descriptor() {
        let job = Job::from_json(
            r#"{"file":"video.mkv","cache":"preview.avif","duration_s":12.5,"width":1920,"height":1080,"source_time_base_numerator":1,"source_time_base_denominator":1000}"#,
        )
        .unwrap();
        let media = job.media.unwrap();
        assert_eq!(media.duration_s, Some(12.5));
        assert_eq!(media.width, Some(1920));
        assert_eq!(media.height, Some(1080));
        assert_eq!(
            media.source_time_base,
            Some(command::frame_schedule::Rational::new(1, 1_000))
        );
    }

    #[test]
    fn complete_dds_descriptor_plans_without_reopening_the_video() {
        let job = Job::from_json(
            r#"{"file":"missing-probe-test.mkv","cache":"preview.avif","duration_s":12.5,"width":1920,"height":1080,"codec":"h264","source_time_base_numerator":1,"source_time_base_denominator":1000}"#,
        ).unwrap();
        let vcs = vcs_for_job(
            &job.file,
            &job.cache,
            job.media.as_ref(),
            command::CaptureBackendPolicy::Auto,
        );
        let capture = command::Capture::plan(&vcs.args, Some(160), None, 4).unwrap();
        assert_eq!(capture.capture_plan().media().codec, "h264");
        let mut partial = vcs.args;
        partial.media.as_mut().unwrap().codec = None;
        assert!(command::Capture::plan(&partial, Some(160), None, 4).is_err());
    }

    fn cached_test_job(root: &Path) -> Job {
        let mut job = job("unused");
        job.file = root.join("video.mkv");
        job.cache = root.join("preview.avif");
        fs::write(&job.file, b"source").unwrap();
        // A header fixture for testing manifest reuse, not decoding.
        fs::write(&job.cache, b"\0\0\0\x18ftypavif\0\0\0\0avifmif1").unwrap();
        job
    }

    #[test]
    fn completed_cache_skips_generation_and_notifies_all_waiters() {
        let root = temporary_test_dir("cache-hit");
        let mut job = cached_test_job(&root);
        let policy = command::CaptureBackendPolicy::Auto;
        publish_manifest(&job, policy).unwrap();
        let scheduler = Scheduler {
            state: Mutex::new(QueueState::default()),
            ready: Condvar::new(),
        };
        job.yazi_id = Some("first".to_owned());
        scheduler.submit(job.clone());
        job.yazi_id = Some("second".to_owned());
        scheduler.submit(job);
        let active = scheduler.next();
        let mut completion = complete_job(
            &scheduler,
            &active,
            policy,
            |_| panic!("cache hit must not run capture"),
            || panic!("cache hit must not republish"),
        );
        assert_eq!(completion.outcome, ServiceJobOutcome::Reused);
        completion.subscribers.sort();
        assert_eq!(completion.subscribers, ["first", "second"]);
        assert!(scheduler.state.lock().unwrap().jobs.is_empty());
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn cache_requires_matching_profile_source_and_unchanged_output() {
        let root = temporary_test_dir("cache-invalid");
        let job = cached_test_job(&root);
        let policy = command::CaptureBackendPolicy::Auto;
        let (source, _) = current_manifest(&job, policy).unwrap();
        let manifest = manifest_path(&job.cache, &source);
        assert!(!cache_is_current(&job, policy));
        fs::write(&manifest, b"{\"source_size\":6,\"source_modified_s\":0}").unwrap();
        assert!(!cache_is_current(&job, policy));
        publish_manifest(&job, policy).unwrap();
        assert!(cache_is_current(&job, policy));
        assert!(!cache_is_current(
            &job,
            command::CaptureBackendPolicy::Ffmpeg
        ));
        let mut stored: serde_json::Value =
            serde_json::from_slice(&fs::read(&manifest).unwrap()).unwrap();
        stored["profile"] = "obsolete".into();
        fs::write(&manifest, stored.to_string()).unwrap();
        assert!(!cache_is_current(&job, policy));
        publish_manifest(&job, policy).unwrap();
        fs::OpenOptions::new()
            .append(true)
            .open(&job.cache)
            .unwrap()
            .write_all(b"changed")
            .unwrap();
        assert!(!cache_is_current(&job, policy));
        publish_manifest(&job, policy).unwrap();
        fs::write(&job.cache, b"damaged output").unwrap();
        assert!(!cache_is_current(&job, policy));
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn cache_rejects_source_changes_within_the_same_second() {
        let root = temporary_test_dir("cache-source-stamp");
        let job = cached_test_job(&root);
        let source = fs::OpenOptions::new().write(true).open(&job.file).unwrap();
        let timestamp = std::time::UNIX_EPOCH + Duration::new(1_700_000_000, 100_000);
        source
            .set_times(fs::FileTimes::new().set_modified(timestamp))
            .unwrap();
        let policy = command::CaptureBackendPolicy::Auto;
        publish_manifest(&job, policy).unwrap();
        assert!(cache_is_current(&job, policy));
        source
            .set_times(fs::FileTimes::new().set_modified(timestamp + Duration::from_millis(1)))
            .unwrap();
        assert!(!cache_is_current(&job, policy));
        drop(source);
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn service_startup_policy_is_propagated_to_each_vcs_job() {
        let vcs = vcs_for_job(
            Path::new("video.mkv"),
            Path::new("preview.avif"),
            None,
            command::CaptureBackendPolicy::Auto,
        );

        assert_eq!(vcs.capture_backend, command::CaptureBackendPolicy::Auto);
    }

    #[test]
    fn service_accepts_the_same_named_backend_policy_values_as_vcs() {
        let serve = Serve::try_parse_from(["vimg", "--capture-backend", "videotoolbox"]).unwrap();

        assert_eq!(
            serve.capture_backend,
            command::CaptureBackendPolicy::VideoToolbox
        );
    }

    #[test]
    fn request_backend_field_does_not_change_service_policy_or_cache_identity() {
        let job = Job::from_json(
            r#"{"file":"video.mkv","cache":"preview.avif","capture_backend":"libav"}"#,
        )
        .unwrap();
        let scheduler = Scheduler {
            state: Mutex::new(QueueState::default()),
            ready: Condvar::new(),
        };

        assert_eq!(scheduler.submit(job.clone()), SubmitResult::Queued);
        assert_eq!(scheduler.submit(job), SubmitResult::Shared);
    }

    #[test]
    fn service_request_seam_remains_backend_agnostic() {
        let scheduler = Scheduler {
            state: Mutex::new(QueueState::default()),
            ready: Condvar::new(),
        };
        let request = r#"{"file":"video.mkv","cache":"preview.avif","capture_backend":"libav"}"#;

        assert_eq!(
            submit_request(request, &scheduler).unwrap(),
            SubmitResult::Queued
        );
        assert_eq!(
            submit_request(request, &scheduler).unwrap(),
            SubmitResult::Shared
        );
    }

    #[test]
    fn service_fatal_preflight_error_does_not_create_an_output() {
        let root = temporary_test_dir("fatal-service-policy");
        let output = root.join("preview.avif");
        let error = run_vcs(
            &root.join("missing.mkv"),
            &output,
            None,
            command::CaptureBackendPolicy::Auto,
        )
        .unwrap_err();

        assert!(error.to_string().starts_with("Video file not found:"));
        assert!(!output.exists());
        fs::remove_dir_all(root).unwrap();
    }

    #[cfg(feature = "in-process-decode")]
    #[test]
    #[ignore = "measures ten real preview jobs in one process; requires sample/input.mkv"]
    fn repeated_service_jobs_and_cache_hits() {
        let video = std::env::var_os("VIMG_BENCH_VIDEO")
            .map(PathBuf::from)
            .unwrap_or_else(|| PathBuf::from("sample/input.mkv"));
        let root = temporary_test_dir("service-warm-benchmark");
        let policy = command::CaptureBackendPolicy::Libav;
        let vcs = vcs_for_job(&video, &root.join("unused.avif"), None, policy);
        let capture = command::Capture::plan(&vcs.args, Some(160), None, 4).unwrap();
        let properties = capture.capture_plan().media();
        let media = command::MediaDescriptor {
            duration_s: Some(properties.duration_s),
            width: Some(properties.width),
            height: Some(properties.height),
            codec: Some(properties.codec.clone()),
            source_time_base: Some(properties.source_time_base),
        };
        let source = source_descriptor(&fs::metadata(&video).unwrap()).unwrap();
        let scheduler = Scheduler {
            state: Mutex::new(QueueState::default()),
            ready: Condvar::new(),
        };
        let mut reference = None;
        for index in 0..10 {
            let job = Job {
                file: video.clone(),
                cache: root.join(format!("{index}.avif")),
                source: Some(source.clone()),
                media: Some(media.clone()),
                yazi_id: None,
            };
            scheduler.submit(job.clone());
            let active = scheduler.next();
            let started = Instant::now();
            let result = complete_job(
                &scheduler,
                &active,
                policy,
                |backend| {
                    if std::env::var_os("VIMG_BENCH_PROFILE").is_some() {
                        let mut vcs = vcs_for_job(
                            &active.file,
                            &active.cache,
                            active.media.as_ref(),
                            backend,
                        );
                        vcs.profile = true;
                        vcs.run()
                    } else {
                        run_vcs(&active.file, &active.cache, active.media.as_ref(), backend)
                    }
                },
                || publish_manifest(&active, policy),
            );
            let render = started.elapsed().as_secs_f64();
            assert_eq!(result.outcome, ServiceJobOutcome::Published);
            let bytes = fs::read(&active.cache).unwrap();
            if let Some(reference) = &reference {
                assert_eq!(&bytes, reference);
            } else {
                reference = Some(bytes);
            }
            scheduler.submit(job);
            let active = scheduler.next();
            let started = Instant::now();
            let result = complete_job(
                &scheduler,
                &active,
                policy,
                |_| panic!("repeat request rendered again"),
                || panic!("repeat request republished"),
            );
            let cached = started.elapsed().as_secs_f64();
            assert_eq!(result.outcome, ServiceJobOutcome::Reused);
            println!("[service-bench] job={index} render={render:.6}s cached={cached:.6}s");
        }
        fs::remove_dir_all(root).unwrap();
    }

    fn temporary_test_dir(label: &str) -> PathBuf {
        let path = std::env::temp_dir().join(format!("vimg-{label}-{}", fastrand::u64(..)));
        fs::create_dir(&path).unwrap();
        path
    }
}
