//! Follows the log of an environment's Odoo container and splits it into entries: one per
//! log record, with the lines that follow (a traceback) kept with the record they belong to.

use crate::docker;
use crate::env::Env;
use serde::Serialize;
use std::collections::{HashMap, VecDeque};
use std::io::{BufRead, BufReader};
use std::process::Stdio;
use std::sync::{Arc, Mutex, OnceLock};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

const MAX_ENTRIES: usize = 5000;
/// A follower stops when the app has not asked for this log for so long.
const IDLE: Duration = Duration::from_secs(60);

#[derive(Serialize, Clone, Debug, PartialEq)]
pub struct Entry {
    pub seq: u64,
    pub time: String,
    /// DEBUG, INFO, WARNING, ERROR, CRITICAL; empty for lines that are not log records.
    pub level: String,
    pub db: String,
    pub logger: String,
    pub message: String,
    /// The lines after the record, usually a traceback.
    pub detail: String,
}

impl Entry {
    /// "2026-11-23 16:15:54,804 1 INFO mydb odoo.modules.loading: Loading module sale"
    fn parse(line: &str) -> Option<Entry> {
        let bytes = line.as_bytes();
        let timestamp = bytes.len() > 24
            && bytes[4] == b'-' && bytes[7] == b'-' && bytes[10] == b' '
            && bytes[13] == b':' && bytes[16] == b':' && bytes[19] == b','
            && bytes[..4].iter().all(u8::is_ascii_digit);
        if !timestamp {
            return None;
        }
        let mut rest = line[23..].trim_start().splitn(4, ' ');
        let _pid = rest.next()?;
        let level = rest.next()?;
        if !matches!(level, "DEBUG" | "INFO" | "WARNING" | "ERROR" | "CRITICAL") {
            return None;
        }
        let db = rest.next()?;
        let (logger, message) = rest.next()?.split_once(": ")?;
        Some(Entry {
            seq: 0,
            time: line[..19].to_string(),
            level: level.to_string(),
            db: if db == "?" { String::new() } else { db.to_string() },
            logger: logger.to_string(),
            message: message.to_string(),
            detail: String::new(),
        })
    }
}

struct Follower {
    entries: Mutex<VecDeque<Entry>>,
    next: Mutex<u64>,
    asked: Mutex<Instant>,
}

impl Follower {
    fn add(&self, line: &str) {
        let mut entries = self.entries.lock().unwrap();
        if let Some(mut entry) = Entry::parse(line) {
            let mut next = self.next.lock().unwrap();
            *next += 1;
            entry.seq = *next;
            entries.push_back(entry);
            if entries.len() > MAX_ENTRIES {
                entries.pop_front();
            }
        } else if let Some(last) = entries.back_mut() {
            if !last.detail.is_empty() {
                last.detail.push('\n');
            }
            last.detail.push_str(line);
        } else if !line.trim().is_empty() {
            let mut next = self.next.lock().unwrap();
            *next += 1;
            entries.push_back(Entry {
                seq: *next, time: String::new(), level: String::new(), db: String::new(),
                logger: String::new(), message: line.to_string(), detail: String::new(),
            });
        }
    }
}

fn followers() -> &'static Mutex<HashMap<String, Arc<Follower>>> {
    static FOLLOWERS: OnceLock<Mutex<HashMap<String, Arc<Follower>>>> = OnceLock::new();
    FOLLOWERS.get_or_init(Default::default)
}

#[derive(Serialize)]
pub struct Page {
    /// Entries from `after` on. The entry numbered `after` is sent again because a traceback
    /// may have been added to it since: the app replaces it.
    pub entries: Vec<Entry>,
    /// The entries before `after` were dropped: the app should start over.
    pub reset: bool,
}

pub fn read(env: &Env, after: u64) -> Result<Page, String> {
    env.check()?;
    let follower = {
        let mut map = followers().lock().unwrap();
        match map.get(&env.id) {
            Some(follower) => follower.clone(),
            None => {
                let follower = Arc::new(Follower {
                    entries: Mutex::new(VecDeque::new()),
                    next: Mutex::new(0),
                    asked: Mutex::new(Instant::now()),
                });
                map.insert(env.id.clone(), follower.clone());
                follow(env.id.clone(), env.odoo(), follower.clone());
                follower
            }
        }
    };
    *follower.asked.lock().unwrap() = Instant::now();
    let entries = follower.entries.lock().unwrap();
    let first = entries.front().map_or(0, |e| e.seq);
    Ok(Page {
        reset: after > 0 && after < first,
        entries: entries.iter().filter(|e| e.seq >= after).cloned().collect(),
    })
}

/// Forgets what was read, e.g. after "Clear".
pub fn clear(env: &Env) {
    if let Some(follower) = followers().lock().unwrap().get(&env.id) {
        follower.entries.lock().unwrap().clear();
    }
}

fn follow(id: String, container: String, follower: Arc<Follower>) {
    std::thread::spawn(move || {
        // The first time, the recent past; after a restart of the container, what is new.
        let mut since: Option<u64> = None;
        loop {
            if follower.asked.lock().unwrap().elapsed() > IDLE {
                break;
            }
            if let Ok(mut command) = docker::command() {
                command.args(["logs", "--follow"]);
                match since {
                    Some(seconds) => command.args(["--since", &seconds.to_string()]),
                    None => command.args(["--tail", "1000"]),
                };
                command.arg(&container).stdin(Stdio::null()).stdout(Stdio::piped()).stderr(Stdio::piped());
                if let Ok(mut child) = command.spawn() {
                    // Odoo logs to stderr; Python's own messages may go to stdout.
                    let stdout = child.stdout.take().unwrap();
                    let other = follower.clone();
                    let reader = std::thread::spawn(move || {
                        for line in BufReader::new(stdout).lines().map_while(Result::ok) {
                            other.add(&line);
                        }
                    });
                    let stderr = child.stderr.take().unwrap();
                    let mut idle = false;
                    for line in BufReader::new(stderr).lines().map_while(Result::ok) {
                        follower.add(&line);
                        if follower.asked.lock().unwrap().elapsed() > IDLE {
                            idle = true;
                            break;
                        }
                    }
                    if idle {
                        let _ = child.kill();
                    }
                    let _ = child.wait();
                    let _ = reader.join();
                    // Resume after what was read; the container may be restarted meanwhile.
                    since = Some(now().max(1));
                }
            }
            // The container is stopped or missing: try again in a moment.
            std::thread::sleep(Duration::from_secs(2));
        }
        followers().lock().unwrap().remove(&id);
    });
}

fn now() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map_or(0, |d| d.as_secs())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_record() {
        let entry = Entry::parse("2026-11-23 16:15:54,804 1 INFO vn_test odoo.modules.loading: Loading module sale (23/26)").unwrap();
        assert_eq!((entry.level.as_str(), entry.db.as_str()), ("INFO", "vn_test"));
        assert_eq!(entry.logger, "odoo.modules.loading");
        assert_eq!(entry.message, "Loading module sale (23/26)");
        assert_eq!(entry.time, "2026-11-23 16:15:54");
        let entry = Entry::parse("2026-11-23 16:15:54,804 7 WARNING ? odoo.service.server: no db").unwrap();
        assert_eq!(entry.db, "");
        assert!(Entry::parse("Traceback (most recent call last):").is_none());
        assert!(Entry::parse("2026-11-23 16:15:54,804 1 NOTALEVEL x y: z").is_none());
    }

    #[test]
    fn traceback_joins_its_record() {
        let follower = Follower { entries: Mutex::new(VecDeque::new()), next: Mutex::new(0), asked: Mutex::new(Instant::now()) };
        follower.add("2026-11-23 16:15:54,804 1 ERROR db odoo.http: Exception during request handling.");
        follower.add("Traceback (most recent call last):");
        follower.add("ValueError: boom");
        follower.add("2026-11-23 16:15:55,000 1 INFO db werkzeug: GET /web 200");
        let entries = follower.entries.lock().unwrap();
        assert_eq!(entries.len(), 2);
        assert_eq!(entries[0].detail, "Traceback (most recent call last):\nValueError: boom");
        assert_eq!(entries[1].seq, 2);
    }
}
