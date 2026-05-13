use crate::command;
use anyhow::ensure;
use std::{
    io::{BufRead, BufReader, Write},
    net::TcpStream,
    path::PathBuf,
    process::Command,
    sync::{Arc, Mutex, atomic::{AtomicUsize, Ordering}, mpsc},
    thread,
    time::{Duration, Instant},
};

const DDS_ADDR: &str = "127.0.0.1:33581";
const MAX_WORKERS: usize = 10;

/// Run as a background service, listening for yazi DDS messages.
#[derive(clap::Parser, Debug)]
pub struct Serve {}

impl Serve {
    pub fn run(self) -> anyhow::Result<()> {
        let (tx, rx) = mpsc::sync_channel::<Job>(MAX_WORKERS * 10);
        let rx = Arc::new(Mutex::new(rx));
        let pending_count = Arc::new(AtomicUsize::new(0));

        // Spawn worker threads
        for worker_id in 0..MAX_WORKERS {
            let rx = Arc::clone(&rx);
            let pending_count = Arc::clone(&pending_count);
            thread::spawn(move || {
                loop {
                    let job = rx.lock().unwrap().recv();
                    match job {
                        Ok(job) => {
                            process_job(worker_id, &job);
                            pending_count.fetch_sub(1, Ordering::Relaxed);
                        }
                        Err(_) => break,
                    }
                }
            });
        }

        // Main loop: connect to DDS, reconnect on failure
        println!("[serve] Waiting for yazi DDS at {DDS_ADDR}...");
        loop {
            match connect_and_listen(&tx, &pending_count) {
                Ok(()) => {
                    println!("[serve] Connection lost, reconnecting...");
                }
                Err(e) => {
                    eprintln!("[serve] {e}");
                }
            }
            thread::sleep(Duration::from_secs(2));
        }
    }
}

fn connect_and_listen(
    tx: &mpsc::SyncSender<Job>,
    pending_count: &AtomicUsize,
) -> anyhow::Result<()> {
    let stream = TcpStream::connect(DDS_ADDR)?;
    stream.set_read_timeout(None)?;
    let mut writer = stream.try_clone()?;
    let reader = BufReader::new(stream);

    // Subscribe to vimg-gen events
    writer.write_all(b"vimg-gen\n")?;
    writer.flush()?;
    println!("[serve] Connected, listening for vimg-gen events...");

    for line in reader.lines() {
        let line = line?;
        let line = line.trim().to_string();
        if line.is_empty() {
            continue;
        }
        eprintln!("[serve] RAW: {line}");

        let Some(msg) = parse_dds_message(&line) else {
            eprintln!("[serve] Failed to parse DDS message: {line}");
            continue;
        };

        let Some(job) = parse_job(&msg.body) else {
            eprintln!("[serve] Failed to parse job body: {}", msg.body);
            continue;
        };

        let pending = pending_count.load(Ordering::Relaxed);
        println!(
            "[serve] Queued: {} ({} pending)",
            job.file_name(),
            pending
        );

        if tx.try_send(job).is_err() {
            eprintln!("[serve] Queue full, dropping request");
        } else {
            pending_count.fetch_add(1, Ordering::Relaxed);
        }
    }

    Ok(())
}

struct DdsMessage {
    _kind: String,
    _receiver: String,
    _sender: String,
    body: String,
}

struct Job {
    file: PathBuf,
    cache: PathBuf,
    /// Yazi instance ID to send the result back to.
    id: String,
}

impl Job {
    fn file_name(&self) -> &str {
        self.file
            .file_name()
            .and_then(|n| n.to_str())
            .unwrap_or("?")
    }
}

fn parse_dds_message(line: &str) -> Option<DdsMessage> {
    // Wire format: kind,receiver,sender,{json}
    // Split on first 3 commas; the rest is the JSON body.
    let mut parts = Vec::new();
    let mut rest = line;
    for _ in 0..3 {
        let pos = rest.find(',')?;
        parts.push(rest[..pos].to_string());
        rest = &rest[pos + 1..];
    }
    Some(DdsMessage {
        _kind: parts.remove(0),
        _receiver: parts.remove(0),
        _sender: parts.remove(0),
        body: rest.to_string(),
    })
}

fn parse_job(body: &str) -> Option<Job> {
    // Body is a JSON value. For --json it's an object, for --str it's a string.
    // We expect: {"file": "...", "cache": "...", "id": "..."}
    // Also handle --list format: ["file","cache","id"]
    let v: serde_json::Value = serde_json::from_str(body).ok()?;

    if let Some(obj) = v.as_object() {
        let file = obj.get("file")?.as_str()?;
        let cache = obj.get("cache")?.as_str()?;
        let id = obj.get("id")?.as_str()?;
        return Some(Job {
            file: PathBuf::from(file),
            cache: PathBuf::from(cache),
            id: id.to_string(),
        });
    }

    if let Some(arr) = v.as_array() {
        if arr.len() >= 3 {
            let file = arr[0].as_str()?;
            let cache = arr[1].as_str()?;
            let id = arr[2].as_str()?;
            return Some(Job {
                file: PathBuf::from(file),
                cache: PathBuf::from(cache),
                id: id.to_string(),
            });
        }
    }

    None
}

fn process_job(worker_id: usize, job: &Job) {
    let start = Instant::now();
    println!(
        "[serve] #{worker_id} Processing: {} -> {}",
        job.file_name(),
        job.cache.display()
    );

    let result = run_vcs(&job.file, &job.cache);

    match result {
        Ok(()) => {
            let elapsed = start.elapsed();
            println!(
                "[serve] #{worker_id} Done: {} ({:.1}s)",
                job.file_name(),
                elapsed.as_secs_f32()
            );
            notify_ready(&job.id, &job.cache);
        }
        Err(e) => {
            eprintln!("[serve] #{worker_id} Error: {}: {e}", job.file_name());
        }
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
            capture_time: Default::default(),
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

fn notify_ready(yazi_id: &str, cache: &PathBuf) {
    let cache_str = cache.to_string_lossy().to_string();
    let status = Command::new("ya")
        .args(["pub-to", yazi_id, "vimg-ready", "--str", &cache_str])
        .status();

    match status {
        Ok(s) if !s.success() => {
            eprintln!("[serve] ya pub-to failed for {yazi_id}");
        }
        Err(e) => {
            eprintln!("[serve] Failed to run ya pub-to: {e}");
        }
        _ => {}
    }
}
