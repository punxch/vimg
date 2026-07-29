use crate::command;
use anyhow::{Context, ensure};
use socket2::{Domain, Protocol, Socket, Type};
use std::{
    collections::{HashSet, VecDeque},
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
pub struct Serve {}

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
        Some(Self {
            file: PathBuf::from(value.get("file")?.as_str()?),
            cache: PathBuf::from(value.get("cache")?.as_str()?),
            source: source_size
                .zip(source_modified_s)
                .map(|(size, modified_s)| SourceDescriptor { size, modified_s }),
            media: (duration_s.is_some() || width.is_some() || height.is_some()).then_some(
                command::MediaDescriptor {
                    duration_s,
                    width,
                    height,
                },
            ),
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
            return SubmitResult::Shared;
        }

        // Keep the running job and evict the oldest job that has not started.
        if state.jobs.len() >= MAX_JOBS {
            if let Some(evicted) = state.queued.pop_front() {
                state.jobs.remove(&evicted.cache);
            } else {
                return SubmitResult::Busy;
            }
        }

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

    fn finish(&self, cache: &Path) {
        let mut state = self.state.lock().unwrap();
        state.jobs.remove(cache);
        state.active = None;
    }
}

impl Serve {
    pub fn run(self) -> anyhow::Result<()> {
        let scheduler = Arc::new(Scheduler {
            state: Mutex::new(QueueState::default()),
            ready: Condvar::new(),
        });
        let worker_scheduler = Arc::clone(&scheduler);
        thread::spawn(move || worker(worker_scheduler));

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
    let Some(job) = Job::from_json(line.trim()) else {
        let _ = stream.write_all(b"error: invalid json\n");
        return;
    };
    let state = scheduler.submit(job);
    let _ = stream.write_all(format!("{}\n", state.protocol()).as_bytes());
}

fn worker(scheduler: Arc<Scheduler>) {
    loop {
        let job = scheduler.next();
        let started = Instant::now();
        println!(
            "[serve] Processing: {} -> {}",
            job.file_name(),
            job.cache.display()
        );
        match run_vcs(&job.file, &job.cache, job.media.as_ref()) {
            Ok(()) => match publish_manifest(&job) {
                Ok(()) => {
                    notify_yazi(&job);
                    println!(
                        "[serve] Done: {} ({:.1}s)",
                        job.file_name(),
                        started.elapsed().as_secs_f32()
                    );
                }
                Err(error) => eprintln!("[serve] Manifest error: {}: {error}", job.file_name()),
            },
            Err(error) => eprintln!("[serve] Error: {}: {error}", job.file_name()),
        }
        scheduler.finish(&job.cache);
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

fn notify_yazi(job: &Job) {
    let Some(yazi_id) = &job.yazi_id else {
        return;
    };
    let payload = serde_json::json!({ "file": job.file.to_string_lossy() });
    let payload = payload.to_string();
    match ProcessCommand::new("ya")
        .args([
            "pub-to",
            yazi_id,
            "gridthumb-avif-ready",
            "--json",
            &payload,
        ])
        .status()
    {
        Ok(status) if status.success() => {}
        Ok(status) => eprintln!("[serve] Yazi notification exited with {status}"),
        Err(error) => eprintln!("[serve] Cannot notify Yazi: {error}"),
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
) -> anyhow::Result<()> {
    ensure!(video.exists(), "Video file not found: {}", video.display());
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
        authority_manifest: None,
    }
    .run()
}

#[cfg(test)]
mod tests {
    use super::*;

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
            r#"{"file":"video.mkv","cache":"preview.avif","duration_s":12.5,"width":1920,"height":1080}"#,
        )
        .unwrap();
        let media = job.media.unwrap();
        assert_eq!(media.duration_s, Some(12.5));
        assert_eq!(media.width, Some(1920));
        assert_eq!(media.height, Some(1080));
    }
}
