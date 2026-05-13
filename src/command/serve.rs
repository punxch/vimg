use crate::command;
use anyhow::{Context, ensure};
use socket2::{Domain, Protocol, Socket, Type};
use std::{
    io::{BufRead, BufReader, Write},
    net::{TcpListener, TcpStream, SocketAddr},
    path::PathBuf,
    sync::{Arc, atomic::{AtomicUsize, Ordering}},
    thread,
    time::{Duration, Instant},
};

const BIND_ADDR: &str = "127.0.0.1:33582";

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

impl Serve {
    pub fn run(self) -> anyhow::Result<()> {
        let pending_count = Arc::new(AtomicUsize::new(0));

        let addr: SocketAddr = BIND_ADDR.parse().unwrap();
        let socket = Socket::new(Domain::IPV4, Type::STREAM, Some(Protocol::TCP))?;
        socket.set_reuse_address(true)?;
        socket.bind(&addr.into())?;
        socket.listen(128)?;
        let listener: TcpListener = socket.into();
        println!("[serve] Listening on {BIND_ADDR}");

        for stream in listener.incoming() {
            let stream = stream?;
            let pending_count = Arc::clone(&pending_count);
            thread::spawn(move || {
                handle_client(stream, &pending_count);
            });
        }

        Ok(())
    }
}

fn handle_client(
    mut stream: TcpStream,
    pending_count: &AtomicUsize,
) {
    let peer = stream.peer_addr().ok();
    eprintln!("[serve] Client connected: {:?}", peer);

    stream
        .set_read_timeout(Some(Duration::from_secs(10)))
        .ok();

    let mut reader = BufReader::new(&stream);
    let mut line = String::new();
    match reader.read_line(&mut line) {
        Ok(0) => {
            eprintln!("[serve] Client sent empty data");
            return;
        }
        Ok(n) => {
            eprintln!("[serve] Read {n} bytes: {}", line.trim());
        }
        Err(e) => {
            eprintln!("[serve] Read error: {e}");
            return;
        }
    }

    let line = line.trim();
    if line.is_empty() {
        let _ = stream.write_all(b"error: empty request\n");
        return;
    }

    let Some(job) = Job::from_json(line) else {
        eprintln!("[serve] Invalid JSON: {line}");
        let _ = stream.write_all(b"error: invalid json\n");
        return;
    };

    let pending = pending_count.load(Ordering::Relaxed);
    println!(
        "[serve] Processing: {} ({} pending)",
        job.file_name(),
        pending
    );

    pending_count.fetch_add(1, Ordering::Relaxed);

    // Process job inline so client blocks until done
    let start = Instant::now();
    println!(
        "[serve] Processing: {} -> {}",
        job.file_name(),
        job.cache.display()
    );

    let result = run_vcs(&job.file, &job.cache);

    match result {
        Ok(()) => {
            let elapsed = start.elapsed();
            println!(
                "[serve] Done: {} ({:.1}s)",
                job.file_name(),
                elapsed.as_secs_f32()
            );
            let _ = stream.write_all(b"done\n");
        }
        Err(e) => {
            eprintln!("[serve] Error: {}: {e}", job.file_name());
            let _ = stream.write_all(b"error\n");
        }
    }

    pending_count.fetch_sub(1, Ordering::Relaxed);
}

impl Send {
    pub fn run(self) -> anyhow::Result<()> {
        let mut stream = TcpStream::connect(BIND_ADDR)
            .context("Cannot connect to vimg serve. Is it running?")?;

        let json = serde_json::json!({
            "file": self.file.to_string_lossy(),
            "cache": self.cache.to_string_lossy(),
        });

        stream.write_all(json.to_string().as_bytes())?;
        stream.write_all(b"\n")?;
        stream.flush()?;

        let mut reader = BufReader::new(&stream);
        let mut response = String::new();
        reader.read_line(&mut response)?;

        let response = response.trim();
        if response == "done" {
            Ok(())
        } else {
            anyhow::bail!("{response}");
        }
    }
}

struct Job {
    file: PathBuf,
    cache: PathBuf,
}

impl Job {
    fn from_json(line: &str) -> Option<Job> {
        let v: serde_json::Value = serde_json::from_str(line).ok()?;
        let file = v.get("file")?.as_str()?;
        let cache = v.get("cache")?.as_str()?;
        Some(Job {
            file: PathBuf::from(file),
            cache: PathBuf::from(cache),
        })
    }

    fn file_name(&self) -> &str {
        self.file
            .file_name()
            .and_then(|n| n.to_str())
            .unwrap_or("?")
    }
}

fn run_vcs(video: &PathBuf, output: &PathBuf) -> anyhow::Result<()> {
    ensure!(video.exists(), "Video file not found: {}", video.display());

    let vcs = command::Vcs {
        columns: 3,
        output: Some(output.clone()),
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
            threads: 8,
            output_dir: None,
            video: video.clone(),
        },
        keep: false,
        webp: 0,
    };

    vcs.run()
}

