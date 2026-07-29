use crate::command;
use anyhow::{Context, ensure};
use socket2::{Domain, Protocol, Socket, Type};
use std::{
    collections::{HashSet, VecDeque},
    io::{BufRead, BufReader, Write},
    net::{SocketAddr, TcpListener, TcpStream},
    path::{Path, PathBuf},
    sync::{Arc, Mutex, mpsc},
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
    known: HashSet<PathBuf>,
    queued: VecDeque<PathBuf>,
}

struct Scheduler {
    sender: mpsc::Sender<Job>,
    state: Mutex<QueueState>,
}

impl Scheduler {
    fn submit(&self, job: Job) -> &'static str {
        let mut state = self.state.lock().unwrap();
        if state.known.contains(&job.cache) {
            return "shared";
        }

        // Keep the running job and evict the oldest job that has not started.
        if state.known.len() >= MAX_JOBS {
            if let Some(evicted) = state.queued.pop_front() {
                state.known.remove(&evicted);
            } else {
                return "busy";
            }
        }

        state.known.insert(job.cache.clone());
        state.queued.push_back(job.cache.clone());
        if self.sender.send(job).is_err() {
            let cache = state.queued.pop_back().unwrap();
            state.known.remove(&cache);
            return "error";
        }
        "queued"
    }

    fn begin(&self, cache: &Path) -> bool {
        let mut state = self.state.lock().unwrap();
        if !state.known.contains(cache) {
            return false;
        }
        state.queued.retain(|queued| queued != cache);
        true
    }

    fn finish(&self, cache: &Path) {
        self.state.lock().unwrap().known.remove(cache);
    }
}

impl Serve {
    pub fn run(self) -> anyhow::Result<()> {
        let (sender, receiver) = mpsc::channel();
        let scheduler = Arc::new(Scheduler {
            sender,
            state: Mutex::new(QueueState::default()),
        });
        let worker_scheduler = Arc::clone(&scheduler);
        thread::spawn(move || worker(receiver, worker_scheduler));

        let addr: SocketAddr = BIND_ADDR.parse().unwrap();
        let socket = Socket::new(Domain::IPV4, Type::STREAM, Some(Protocol::TCP))?;
        socket.set_reuse_address(true)?;
        socket.bind(&addr.into())?;
        socket.listen(128)?;
        let listener: TcpListener = socket.into();
        println!("[serve] Listening on {BIND_ADDR}");

        for stream in listener.incoming() {
            let scheduler = Arc::clone(&scheduler);
            thread::spawn(move || match stream {
                Ok(stream) => handle_client(stream, scheduler),
                Err(error) => eprintln!("[serve] Accept error: {error}"),
            });
        }
        Ok(())
    }
}

fn handle_client(mut stream: TcpStream, scheduler: Arc<Scheduler>) {
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
    let _ = stream.write_all(format!("{state}\n").as_bytes());
}

fn worker(receiver: mpsc::Receiver<Job>, scheduler: Arc<Scheduler>) {
    for job in receiver {
        if !scheduler.begin(&job.cache) {
            continue;
        }
        let started = Instant::now();
        println!(
            "[serve] Processing: {} -> {}",
            job.file_name(),
            job.cache.display()
        );
        match run_vcs(&job.file, &job.cache) {
            Ok(()) => println!(
                "[serve] Done: {} ({:.1}s)",
                job.file_name(),
                started.elapsed().as_secs_f32()
            ),
            Err(error) => eprintln!("[serve] Error: {}: {error}", job.file_name()),
        }
        scheduler.finish(&job.cache);
    }
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
        let (sender, receiver) = mpsc::channel();
        let scheduler = Scheduler {
            sender,
            state: Mutex::new(QueueState::default()),
        };

        assert_eq!(scheduler.submit(job("preview.avif")), "queued");
        assert_eq!(scheduler.submit(job("preview.avif")), "shared");
        assert_eq!(receiver.try_iter().count(), 1);
    }

    #[test]
    fn replaces_the_oldest_unstarted_preview_at_capacity() {
        let (sender, receiver) = mpsc::channel();
        let scheduler = Scheduler {
            sender,
            state: Mutex::new(QueueState::default()),
        };
        for index in 0..MAX_JOBS {
            assert_eq!(scheduler.submit(job(&format!("{index}.avif"))), "queued");
        }
        assert_eq!(scheduler.submit(job("newest.avif")), "queued");

        let queued: Vec<_> = receiver.try_iter().collect();
        assert!(!scheduler.begin(&queued[0].cache));
        assert!(scheduler.begin(&queued[1].cache));
        assert!(scheduler.begin(&queued[MAX_JOBS].cache));
    }
}
