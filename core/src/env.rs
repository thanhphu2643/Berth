//! An environment: one Odoo version in Docker, with its own PostgreSQL, data volume,
//! network and port, and the addons folders of this computer mounted into it.
//!
//! Everything Berth creates is named berth-<id>-… and labelled berth.env=<id>.

use crate::docker;
use crate::jobs::{self, Job};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::io::{Read, Write};
use std::net::{SocketAddr, TcpStream};
use std::path::PathBuf;
use std::time::{Duration, Instant};

pub const VERSIONS: [u8; 3] = [16, 17, 18];

#[derive(Deserialize, Clone, Debug)]
pub struct Env {
    pub id: String,
    pub version: u8,
    pub port: u16,
    #[serde(default)]
    pub addons: Vec<PathBuf>,
    /// --dev=reload,xml,qweb: restart on Python changes, read views and templates from disk.
    #[serde(default)]
    pub dev: bool,
}

impl Env {
    pub fn check(&self) -> Result<(), String> {
        let valid_id = !self.id.is_empty()
            && self.id.len() <= 32
            && self.id.chars().all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '-');
        if !valid_id {
            return Err("invalid environment id".into());
        }
        if !VERSIONS.contains(&self.version) {
            return Err(format!("Odoo {} is not supported (16, 17 or 18)", self.version));
        }
        if self.port < 1024 {
            return Err("choose a port from 1024".into());
        }
        for folder in &self.addons {
            if !folder.is_dir() {
                return Err(format!("{} is not a folder", folder.display()));
            }
        }
        Ok(())
    }

    fn name(&self, part: &str) -> String {
        format!("berth-{}-{}", self.id, part)
    }
    pub fn odoo(&self) -> String {
        self.name("odoo")
    }
    pub fn db(&self) -> String {
        self.name("db")
    }
    pub fn network(&self) -> String {
        format!("berth-{}", self.id)
    }
    pub fn data_volume(&self) -> String {
        self.name("data")
    }
    fn pg_volume(&self) -> String {
        self.name("pg")
    }
    pub fn image(&self) -> String {
        format!("odoo:{}", self.version)
    }
    /// The PostgreSQL version the official Odoo images are tested with.
    fn pg_image(&self) -> &'static str {
        if self.version == 16 { "postgres:15" } else { "postgres:16" }
    }

    /// Each folder is mounted at /mnt/addons/<n>. A folder that is itself a module is mounted
    /// one level down, so that /mnt/addons/<n> is a folder of modules, as Odoo expects.
    fn mounts(&self) -> Vec<(PathBuf, String)> {
        self.addons
            .iter()
            .enumerate()
            .map(|(index, folder)| {
                let target = if folder.join("__manifest__.py").is_file() {
                    let name = folder.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
                    format!("/mnt/addons/{index}/{name}")
                } else {
                    format!("/mnt/addons/{index}")
                };
                (folder.clone(), target)
            })
            .collect()
    }

    pub fn addons_path(&self) -> String {
        (0..self.addons.len()).map(|i| format!("/mnt/addons/{i}")).collect::<Vec<_>>().join(",")
    }

    /// `docker run` options shared by the server and the one-off tasks.
    pub fn run_options(&self) -> Vec<String> {
        let mut options = vec![
            "--network".into(),
            self.network(),
            "--label".into(),
            format!("berth.env={}", self.id),
            "-e".into(),
            format!("HOST={}", self.db()),
            "-e".into(),
            "USER=odoo".into(),
            "-e".into(),
            "PASSWORD=odoo".into(),
            "-v".into(),
            format!("{}:/var/lib/odoo", self.data_volume()),
        ];
        for (folder, target) in self.mounts() {
            options.push("-v".into());
            options.push(format!("{}:{}", folder.display(), target));
        }
        options
    }

    /// Odoo options shared by the server and the one-off tasks.
    pub fn odoo_options(&self) -> Vec<String> {
        let mut options = Vec::new();
        if !self.addons.is_empty() {
            options.push(format!("--addons-path={}", self.addons_path()));
        }
        options
    }

    /// Changes to these need a new container; the rest (databases, data) lives in volumes.
    fn fingerprint(&self) -> String {
        let text = format!("{}|{}|{}|{:?}", self.version, self.port, self.dev, self.addons);
        // FNV-1a: stable across Rust versions, unlike the standard hasher.
        let hash = text.bytes().fold(0xcbf29ce484222325u64, |h, b| (h ^ b as u64).wrapping_mul(0x100000001b3));
        format!("{hash:016x}")
    }
}

/// Starts the environment as a background job: pull the images if needed, start PostgreSQL,
/// (re)create the Odoo container when its settings changed, and wait until Odoo answers.
pub fn start(env: Env) -> Result<u64, String> {
    env.check()?;
    Ok(jobs::spawn("start", None, move |job| start_steps(&env, job)))
}

fn start_steps(env: &Env, job: &Job) -> Result<(), String> {
    for image in [env.image(), env.pg_image().to_string()] {
        if !docker::has_image(&image) {
            job.phase("pull");
            job.line(format!("Downloading {image}…"));
            let mut command = docker::command()?;
            command.args(["pull", &image]);
            job.run(command)?;
        }
    }

    job.phase("database");
    let _ = docker::run(&["network", "create", "--label", &format!("berth.env={}", env.id), &env.network()]);
    let containers = states()?;
    match containers.get(&env.db()) {
        Some(c) if c.state == "running" => {}
        Some(_) => {
            docker::run(&["start", &env.db()])?;
        }
        None => {
            docker::run(&[
                "run", "-d", "--name", &env.db(), "--network", &env.network(),
                "--label", &format!("berth.env={}", env.id),
                "-e", "POSTGRES_USER=odoo", "-e", "POSTGRES_PASSWORD=odoo", "-e", "POSTGRES_DB=postgres",
                "-v", &format!("{}:/var/lib/postgresql/data", env.pg_volume()),
                env.pg_image(),
            ])?;
        }
    }

    job.phase("odoo");
    let fingerprint = env.fingerprint();
    match containers.get(&env.odoo()) {
        Some(c) if c.fingerprint == fingerprint => {
            if c.state != "running" {
                docker::run(&["start", &env.odoo()])?;
            }
        }
        existing => {
            if existing.is_some() {
                docker::run(&["rm", "-f", &env.odoo()])?;
            }
            let mut args: Vec<String> = vec![
                "run".into(), "-d".into(), "--name".into(), env.odoo(),
                "--label".into(), format!("berth.config={fingerprint}"),
                "-p".into(), format!("127.0.0.1:{}:8069", env.port),
            ];
            args.extend(env.run_options());
            args.push(env.image());
            args.push("odoo".into());
            args.extend(env.odoo_options());
            if env.dev {
                args.push("--dev=reload,xml,qweb".into());
            }
            docker::run(&args.iter().map(String::as_str).collect::<Vec<_>>())?;
        }
    }

    job.phase("ready");
    let deadline = Instant::now() + Duration::from_secs(180);
    while !answers(env.port, Duration::from_secs(2)) {
        if job.cancelled() {
            return Err("cancelled".into());
        }
        if Instant::now() > deadline {
            return Err("Odoo did not answer within 3 minutes: see the logs.".into());
        }
        if states()?.get(&env.odoo()).is_some_and(|c| c.state != "running") {
            return Err("Odoo stopped while starting: see the logs.".into());
        }
        std::thread::sleep(Duration::from_millis(700));
    }
    Ok(())
}

pub fn stop(env: &Env) -> Result<(), String> {
    env.check()?;
    let states = states()?;
    let names: Vec<String> = [env.odoo(), env.db()].into_iter().filter(|n| states.contains_key(n)).collect();
    if !names.is_empty() {
        let mut args = vec!["stop", "-t", "5"];
        args.extend(names.iter().map(String::as_str));
        docker::run(&args)?;
    }
    Ok(())
}

/// Removes the containers and network; with `data`, also the databases and filestore.
pub fn remove(env: &Env, data: bool) -> Result<(), String> {
    env.check()?;
    let containers = docker::run(&["ps", "-aq", "--filter", &format!("label=berth.env={}", env.id)])?;
    let ids: Vec<&str> = containers.split_whitespace().collect();
    if !ids.is_empty() {
        let mut args = vec!["rm", "-f"];
        args.extend(ids);
        docker::run(&args)?;
    }
    let _ = docker::run(&["network", "rm", &env.network()]);
    if data {
        for volume in [env.data_volume(), env.pg_volume()] {
            let _ = docker::run(&["volume", "rm", &volume]);
        }
    }
    Ok(())
}

pub struct Container {
    pub state: String,
    pub fingerprint: String,
}

/// Every container Berth made, by name.
pub fn states() -> Result<HashMap<String, Container>, String> {
    let out = docker::run(&[
        "ps", "-a", "--filter", "label=berth.env",
        "--format", "{{.Names}}\t{{.State}}\t{{.Label \"berth.config\"}}",
    ])?;
    Ok(out
        .lines()
        .filter_map(|line| {
            let mut parts = line.split('\t');
            let name = parts.next()?.to_string();
            let state = parts.next()?.to_string();
            let fingerprint = parts.next().unwrap_or("").to_string();
            Some((name, Container { state, fingerprint }))
        })
        .collect())
}

#[derive(Serialize)]
pub struct Status {
    pub id: String,
    /// running, exited, created, restarting… or "missing" before the first start.
    pub odoo: String,
    pub db: String,
    /// Odoo answers HTTP on its port.
    pub ready: bool,
    /// The settings changed since the container was made: the next start recreates it.
    pub stale: bool,
}

pub fn status(envs: &[Env]) -> Result<Vec<Status>, String> {
    let states = states()?;
    let state = |name: &str| states.get(name).map_or("missing".to_string(), |c| c.state.clone());
    Ok(envs
        .iter()
        .map(|env| {
            let odoo = state(&env.odoo());
            Status {
                id: env.id.clone(),
                ready: odoo == "running" && answers(env.port, Duration::from_millis(400)),
                stale: states.get(&env.odoo()).is_some_and(|c| c.fingerprint != env.fingerprint()),
                db: state(&env.db()),
                odoo,
            }
        })
        .collect())
}

/// Odoo answers an HTTP request on this port.
fn answers(port: u16, timeout: Duration) -> bool {
    let address = SocketAddr::from(([127, 0, 0, 1], port));
    let Ok(mut stream) = TcpStream::connect_timeout(&address, timeout) else { return false };
    let _ = stream.set_read_timeout(Some(timeout));
    let _ = stream.set_write_timeout(Some(timeout));
    if stream.write_all(b"GET /web/login HTTP/1.0\r\nHost: localhost\r\n\r\n").is_err() {
        return false;
    }
    let mut head = [0u8; 12];
    stream.read_exact(&mut head).is_ok() && head.starts_with(b"HTTP/1.")
}

/// Whether something already listens on this port (to suggest a free one).
pub fn port_in_use(port: u16) -> bool {
    TcpStream::connect_timeout(&SocketAddr::from(([127, 0, 0, 1], port)), Duration::from_millis(150)).is_ok()
}

