use crate::command;
use anyhow::{Context, ensure};
use socket2::{Domain, Protocol, Socket, Type};
use std::{
    collections::{HashMap, HashSet, VecDeque},
    fs,
    io::{BufRead, BufReader, Write},
    net::{SocketAddr, TcpListener, TcpStream},
    path::{Path, PathBuf},
    process::Command as ProcessCommand,
    sync::{Arc, Condvar, Mutex},
    thread,
    time::Instant,
};

const BIND_ADDR: &str = "127.0.0.1:33582";
const MAX_JOBS: usize = 10;

/// Run as a background service, listening for vimg jobs via TCP.
#[derive(clap::Parser, Debug)]
pub struct Serve {
    /// Capture implementation fixed for every job in this service process.
    #[arg(long, value_enum, default_value_t = command::CaptureBackendPolicy::Ffmpeg)]
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
        Some(Self {
            file: PathBuf::from(value.get("file")?.as_str()?),
            cache: PathBuf::from(value.get("cache")?.as_str()?),
            source: source_size
                .zip(source_modified_s)
                .map(|(size, modified_s)| SourceDescriptor { size, modified_s }),
            media: (duration_s.is_some()
                || width.is_some()
                || height.is_some()
                || source_time_base.is_some())
            .then_some(command::MediaDescriptor {
                duration_s,
                width,
                height,
                codec: None,
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
    active: Option<PathBuf>,
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
        state.active = Some(job.cache.clone());
        job
    }

    fn finish(&self, cache: &Path) -> Vec<String> {
        let mut state = self.state.lock().unwrap();
        state.jobs.remove(cache);
        state.active = None;
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
        let worker_scheduler = Arc::clone(&scheduler);
        thread::spawn(move || worker(worker_scheduler, self.capture_backend));

        let addr: SocketAddr = BIND_ADDR.parse().unwrap();
        let socket = Socket::new(Domain::IPV4, Type::STREAM, Some(Protocol::TCP))?;
        socket.set_reuse_address(true)?;
        socket.bind(&addr.into())?;
        socket.listen(128)?;
        let listener: TcpListener = socket.into();
        println!("[serve] Listening on {BIND_ADDR}");

        for stream in listener.incoming() {
            match stream {
                Ok(stream) => handle_client(stream, &scheduler),
                Err(error) => eprintln!("[serve] Accept error: {error}"),
            }
        }
        Ok(())
    }
}

fn handle_client(mut stream: TcpStream, scheduler: &Scheduler) {
    let _ = stream.set_read_timeout(Some(std::time::Duration::from_secs(10)));
    let mut line = String::new();
    if BufReader::new(&stream)
        .read_line(&mut line)
        .ok()
        .filter(|n| *n > 0)
        .is_none()
    {
        let _ = stream.write_all(b"error: invalid request\n");
        return;
    }
    let Ok(state) = submit_request(line.trim(), scheduler) else {
        let _ = stream.write_all(b"error: invalid json\n");
        return;
    };
    let _ = stream.write_all(format!("{}\n", state.protocol()).as_bytes());
}

fn submit_request(line: &str, scheduler: &Scheduler) -> Result<SubmitResult, ()> {
    let job = Job::from_json(line).ok_or(())?;
    Ok(scheduler.submit(job))
}

fn worker(scheduler: Arc<Scheduler>, capture_backend: command::CaptureBackendPolicy) {
    loop {
        let job = scheduler.next();
        let started = Instant::now();
        println!(
            "[serve] Processing: {} -> {}",
            job.file_name(),
            job.cache.display()
        );
        let completion = complete_job(
            &scheduler,
            &job,
            capture_backend,
            |backend| run_vcs(&job.file, &job.cache, job.media.as_ref(), backend),
            || publish_manifest(&job),
        );
        match completion.outcome {
            ServiceJobOutcome::Published => {
                notify_yazi(
                    &job.file,
                    &completion.subscribers,
                    "gridthumb-avif-ready",
                    None,
                );
                println!(
                    "[serve] Done: {} ({:.1}s)",
                    job.file_name(),
                    started.elapsed().as_secs_f32()
                );
            }
            ServiceJobOutcome::Failed(reason) => notify_yazi(
                &job.file,
                &completion.subscribers,
                "gridthumb-avif-failed",
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
    Failed(String),
}

fn complete_job(
    scheduler: &Scheduler,
    job: &Job,
    capture_backend: command::CaptureBackendPolicy,
    run_capture: impl FnOnce(command::CaptureBackendPolicy) -> anyhow::Result<()>,
    publish: impl FnOnce() -> anyhow::Result<()>,
) -> ServiceCompletion {
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

fn source_descriptor(video: &Path) -> anyhow::Result<SourceDescriptor> {
    let metadata = fs::metadata(video)?;
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

fn publish_manifest(job: &Job) -> anyhow::Result<()> {
    let source = match &job.source {
        Some(source) => source.clone(),
        None => source_descriptor(&job.file)?,
    };
    let manifest = serde_json::json!({
        "source_size": source.size,
        "source_modified_s": source.modified_s,
    });
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

fn notify_yazi(video: &Path, subscribers: &[String], event: &str, failure_reason: Option<&str>) {
    let payload = match failure_reason {
        Some(reason) => serde_json::json!({ "file": video.to_string_lossy(), "error": reason }),
        None => serde_json::json!({ "file": video.to_string_lossy() }),
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
        let mut stream = TcpStream::connect(BIND_ADDR)
            .context("Cannot connect to vimg serve. Is it running?")?;
        let request = serde_json::json!({
            "file": self.file.to_string_lossy(),
            "cache": self.cache.to_string_lossy(),
            "yazi_id": self.yazi_id,
            "source_size": self.source_size,
            "source_modified_s": self.source_modified_s,
            "duration_s": self.duration_s,
            "width": self.width,
            "height": self.height,
            "source_time_base_numerator": self.source_time_base_numerator,
            "source_time_base_denominator": self.source_time_base_denominator,
        });
        stream.write_all(request.to_string().as_bytes())?;
        stream.write_all(b"\n")?;
        stream.flush()?;
        let mut response = String::new();
        BufReader::new(&stream).read_line(&mut response)?;
        match response.trim() {
            "queued" | "shared" | "done" => Ok(()),
            response => anyhow::bail!(response.to_owned()),
        }
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
            number: 9,
            ignore_start: Default::default(),
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

    fn temporary_test_dir(label: &str) -> PathBuf {
        let path = std::env::temp_dir().join(format!("vimg-{label}-{}", fastrand::u64(..)));
        fs::create_dir(&path).unwrap();
        path
    }
}
