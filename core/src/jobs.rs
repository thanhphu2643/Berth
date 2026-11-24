//! Background jobs (start an environment, install a module, run tests…) that the app polls
//! for their phase and output, and can stop.

use serde::Serialize;
use std::collections::HashMap;
use std::io::{BufRead, BufReader, Read};
use std::process::{Child, Command, Stdio};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex, OnceLock};

const MAX_LINES: usize = 5000;

#[derive(Serialize, Clone, Default)]
pub struct Status {
    pub kind: String,
    pub phase: String,
    pub finished: bool,
    pub ok: bool,
    pub error: Option<String>,
    /// A one-line result, e.g. "0 failed, 0 errors of 18 tests".
    pub summary: Option<String>,
    /// Structured result, e.g. the findings of an upgrade check.
    pub data: Option<serde_json::Value>,
    /// Output lines from `from` on, and how many lines there are in all.
    pub lines: Vec<String>,
    pub total: usize,
}

pub struct Job {
    status: Mutex<Status>,
    lines: Mutex<Vec<String>>,
    dropped: AtomicU64,
    cancelled: AtomicBool,
    child: Mutex<Option<Child>>,
    /// A container to remove on cancel: killing `docker run` would leave it running.
    container: Mutex<Option<String>>,
}

impl Job {
    pub fn phase(&self, phase: &str) {
        self.status.lock().unwrap().phase = phase.to_string();
    }

    pub fn line(&self, line: String) {
        let mut lines = self.lines.lock().unwrap();
        lines.push(line);
        if lines.len() > MAX_LINES {
            let extra = lines.len() - MAX_LINES;
            lines.drain(..extra);
            self.dropped.fetch_add(extra as u64, Ordering::Relaxed);
        }
    }

    pub fn summary(&self, summary: String) {
        self.status.lock().unwrap().summary = Some(summary);
    }

    pub fn data(&self, data: serde_json::Value) {
        self.status.lock().unwrap().data = Some(data);
    }

    pub fn cancelled(&self) -> bool {
        self.cancelled.load(Ordering::Relaxed)
    }

    pub fn container(&self, name: String) {
        *self.container.lock().unwrap() = Some(name);
    }

    /// Runs a command, adding its output (stdout and stderr) to the job line by line.
    /// Returns its exit status as Ok(true/false), or Err when it could not run or was stopped.
    pub fn run(&self, mut command: Command) -> Result<bool, String> {
        self.run_with(&mut command, |_| {})
    }

    /// Like run, and calls `each` on every line as it arrives.
    pub fn run_with(&self, command: &mut Command, mut each: impl FnMut(&str)) -> Result<bool, String> {
        if self.cancelled() {
            return Err("cancelled".into());
        }
        let mut child = command.stdin(Stdio::null()).stdout(Stdio::piped()).stderr(Stdio::piped()).spawn().map_err(|e| e.to_string())?;
        let stdout = child.stdout.take().unwrap();
        let stderr = child.stderr.take().unwrap();
        *self.child.lock().unwrap() = Some(child);

        let (sender, receiver) = std::sync::mpsc::channel::<String>();
        let readers: Vec<_> = [Box::new(stdout) as Box<dyn Read + Send>, Box::new(stderr)]
            .into_iter()
            .map(|stream| {
                let sender = sender.clone();
                std::thread::spawn(move || {
                    for line in BufReader::new(stream).split(b'\n').map_while(Result::ok) {
                        let text = String::from_utf8_lossy(&line).trim_end_matches('\r').to_string();
                        // docker pull redraws progress lines: keep the meaningful ones only.
                        if sender.send(text).is_err() {
                            break;
                        }
                    }
                })
            })
            .collect();
        drop(sender);
        for line in receiver {
            each(&line);
            self.line(line);
        }
        for reader in readers {
            let _ = reader.join();
        }
        let status = self.child.lock().unwrap().take().map(|mut c| c.wait());
        if self.cancelled() {
            return Err("cancelled".into());
        }
        match status {
            Some(Ok(status)) => Ok(status.success()),
            Some(Err(error)) => Err(error.to_string()),
            None => Err("cancelled".into()),
        }
    }

    fn snapshot(&self, from: usize) -> Status {
        let mut status = self.status.lock().unwrap().clone();
        let lines = self.lines.lock().unwrap();
        let dropped = self.dropped.load(Ordering::Relaxed) as usize;
        let start = from.saturating_sub(dropped).min(lines.len());
        status.lines = lines[start..].to_vec();
        status.total = dropped + lines.len();
        status
    }
}

fn registry() -> &'static Mutex<HashMap<u64, Arc<Job>>> {
    static JOBS: OnceLock<Mutex<HashMap<u64, Arc<Job>>>> = OnceLock::new();
    JOBS.get_or_init(Default::default)
}

/// Starts `work` on its own thread and returns the job id.
pub fn spawn(kind: &str, container: Option<String>, work: impl FnOnce(&Job) -> Result<(), String> + Send + 'static) -> u64 {
    static NEXT: AtomicU64 = AtomicU64::new(1);
    let id = NEXT.fetch_add(1, Ordering::Relaxed);
    let job = Arc::new(Job {
        status: Mutex::new(Status { kind: kind.to_string(), phase: "start".into(), ..Default::default() }),
        lines: Mutex::new(Vec::new()),
        dropped: AtomicU64::new(0),
        cancelled: AtomicBool::new(false),
        child: Mutex::new(None),
        container: Mutex::new(container),
    });
    registry().lock().unwrap().insert(id, job.clone());
    std::thread::spawn(move || {
        let result = work(&job);
        let mut status = job.status.lock().unwrap();
        status.finished = true;
        status.ok = result.is_ok();
        status.phase = if result.is_ok() { "done".into() } else { "failed".into() };
        status.error = result.err();
    });
    id
}

pub fn status(id: u64, from: usize) -> Result<Status, String> {
    let job = registry().lock().unwrap().get(&id).cloned().ok_or("unknown job")?;
    Ok(job.snapshot(from))
}

pub fn cancel(id: u64) -> Result<(), String> {
    let job = registry().lock().unwrap().get(&id).cloned().ok_or("unknown job")?;
    job.cancelled.store(true, Ordering::Relaxed);
    if let Some(name) = job.container.lock().unwrap().clone() {
        let _ = crate::docker::run(&["rm", "-f", &name]);
    }
    if let Some(child) = job.child.lock().unwrap().as_mut() {
        let _ = child.kill();
    }
    Ok(())
}

/// Forgets a finished job.
pub fn forget(id: u64) {
    registry().lock().unwrap().remove(&id);
}
