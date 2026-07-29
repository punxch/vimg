use crate::command;
use anyhow::{Context, ensure};
use socket2::{Domain, Protocol, Socket, Type};
use std::{
    collections::{HashSet, VecDeque},
    fs,
    io::{BufRead, BufReader, Write},
    net::{SocketAddr, TcpListener, TcpStream},
    path::{Path, PathBuf},
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
}

#[derive(Clone, Debug)]
struct Job {
    file: PathBuf,
    cache: PathBuf,
}

impl Job {
    fn from_json(line: &str) -> Option<Self> {
        let value: serde_json::Value = serde_json::from_str(line).ok()?;
        Some(Self {
            file: PathBuf::from(value.get("file")?.as_str()?),
            cache: PathBuf::from(value.get("cache")?.as_str()?),
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
        match run_vcs(&job.file, &job.cache) {
            Ok(()) => match publish_manifest(&job.file, &job.cache) {
                Ok(()) => println!(
                    "[serve] Done: {} ({:.1}s)",
                    job.file_name(),
                    started.elapsed().as_secs_f32()
                ),
                Err(error) => eprintln!("[serve] Manifest error: {}: {error}", job.file_name()),
            },
            Err(error) => eprintln!("[serve] Error: {}: {error}", job.file_name()),
        }
        scheduler.finish(&job.cache);
    }
}

fn publish_manifest(video: &Path, cache: &Path) -> anyhow::Result<()> {
    let metadata = fs::metadata(video)?;
    let modified_ms = metadata
        .modified()?
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis();
    let manifest = serde_json::json!({
        "source_size": metadata.len(),
        "source_modified_ms": modified_ms,
    });
    let manifest_path = PathBuf::from(format!("{}.json", cache.display()));
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

impl Send {
    pub fn run(self) -> anyhow::Result<()> {
        let mut stream = TcpStream::connect(BIND_ADDR)
            .context("Cannot connect to vimg serve. Is it running?")?;
        let request = serde_json::json!({
            "file": self.file.to_string_lossy(),
            "cache": self.cache.to_string_lossy(),
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

fn run_vcs(video: &Path, output: &Path) -> anyhow::Result<()> {
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
        },
        keep: false,
        webp: 0,
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
}
