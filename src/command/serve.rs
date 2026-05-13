use crate::command;
use anyhow::ensure;
use std::{
    fs,
    path::PathBuf,
    sync::{Arc, Mutex, atomic::{AtomicUsize, Ordering}, mpsc},
    thread,
    time::{Duration, Instant},
};

const MAX_WORKERS: usize = 10;

/// Run as a background service, watching for vimg job files.
#[derive(clap::Parser, Debug)]
pub struct Serve {}

impl Serve {
    pub fn run(self) -> anyhow::Result<()> {
        let job_dir = job_dir();
        fs::create_dir_all(&job_dir)?;
        println!("[serve] Watching: {}", job_dir.display());

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

        // Poll for job files
        loop {
            match fs::read_dir(&job_dir) {
                Ok(entries) => {
                    for entry in entries.flatten() {
                        let path = entry.path();
                        let Some(name) = path.file_name().and_then(|n| n.to_str()) else {
                            continue;
                        };
                        if !name.ends_with(".json") {
                            continue;
                        }
                        let Some(job) = Job::from_file(&path) else {
                            eprintln!("[serve] Bad job file: {}", path.display());
                            let _ = fs::remove_file(&path);
                            continue;
                        };

                        let _ = fs::remove_file(&path);

                        let pending = pending_count.load(Ordering::Relaxed);
                        println!(
                            "[serve] Queued: {} ({} pending)",
                            job.file_name(),
                            pending
                        );

                        if tx.try_send(job).is_err() {
                            eprintln!("[serve] Queue full, dropping");
                        } else {
                            pending_count.fetch_add(1, Ordering::Relaxed);
                        }
                    }
                }
                Err(e) => {
                    eprintln!("[serve] read_dir error: {e}");
                }
            }
            thread::sleep(Duration::from_millis(200));
        }
    }
}

fn job_dir() -> PathBuf {
    let mut dir = std::env::temp_dir();
    dir.push("vimg-serve");
    dir
}

struct Job {
    file: PathBuf,
    cache: PathBuf,
}

impl Job {
    fn from_file(path: &PathBuf) -> Option<Job> {
        let content = fs::read_to_string(path).ok()?;
        let v: serde_json::Value = serde_json::from_str(&content).ok()?;
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
