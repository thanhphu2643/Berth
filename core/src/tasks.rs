//! One-off Odoo commands (create a database, install or update modules, run tests), each in
//! its own container next to the server, so they can be stopped at once and never fight the
//! server for its port. The running server notices installed and updated modules by itself.

use crate::db::check_name;
use crate::docker;
use crate::env::Env;
use crate::jobs::{self, Job};
use serde::Deserialize;
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};

#[derive(Deserialize)]
#[serde(tag = "task", rename_all = "snake_case")]
pub enum Task {
    /// A new database with base installed.
    CreateDatabase {
        database: String,
        #[serde(default)]
        demo: bool,
        #[serde(default)]
        language: Option<String>,
    },
    Install { database: String, modules: Vec<String> },
    Update { database: String, modules: Vec<String> },
    /// Installs the module in a fresh database named test_<module> and runs its tests there,
    /// so a test run never touches a working database.
    Test { module: String },
}

fn check_module(name: &str) -> Result<(), String> {
    let valid = !name.is_empty() && name.chars().all(|c| c.is_ascii_alphanumeric() || c == '_');
    if valid { Ok(()) } else { Err(format!("invalid module name {name:?}")) }
}

pub fn start(env: Env, task: Task) -> Result<u64, String> {
    env.check()?;
    let (kind, args, database) = match &task {
        Task::CreateDatabase { database, demo, language } => {
            check_name(database)?;
            let mut args = vec!["-d".into(), database.clone(), "-i".into(), "base".into()];
            if !demo {
                args.push("--without-demo=all".into());
            }
            if let Some(language) = language.as_deref().filter(|l| *l != "en_US") {
                if !language.chars().all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '@') {
                    return Err("invalid language".into());
                }
                args.push(format!("--load-language={language}"));
            }
            ("create_database", args, database.clone())
        }
        Task::Install { database, modules } | Task::Update { database, modules } => {
            check_name(database)?;
            if modules.is_empty() {
                return Err("no module chosen".into());
            }
            modules.iter().try_for_each(|m| check_module(m))?;
            let flag = if matches!(task, Task::Install { .. }) { "-i" } else { "-u" };
            let kind = if flag == "-i" { "install" } else { "update" };
            (kind, vec!["-d".into(), database.clone(), flag.into(), modules.join(",")], database.clone())
        }
        Task::Test { module } => {
            check_module(module)?;
            let database = format!("test_{module}");
            let args = vec![
                "-d".into(), database.clone(), "-i".into(), module.clone(),
                "--test-enable".into(), format!("--test-tags=/{module}"),
                "--log-level=test".into(),
            ];
            ("test", args, database)
        }
    };

    static NEXT: AtomicU64 = AtomicU64::new(1);
    let container = format!("berth-{}-task-{}", env.id, NEXT.fetch_add(1, Ordering::Relaxed));
    let is_test = matches!(task, Task::Test { .. });
    Ok(jobs::spawn(kind, Some(container.clone()), move |job| {
        if is_test {
            job.phase("prepare");
            crate::db::drop(&env, &database, true)?; // start from a clean database every run
        }
        job.phase("run");
        let mut command = docker::command()?;
        command.args(["run", "--rm", "--name", &container]);
        command.args(env.run_options());
        command.arg(env.image()).arg("odoo");
        command.args(env.odoo_options());
        command.args(&args);
        command.arg("--stop-after-init");
        if !is_test {
            command.arg("--no-http"); // tours and HttpCase tests need the HTTP server
        }
        run_odoo(job, command, is_test)
    }))
}

/// Runs Odoo and fails the job on errors in its log, not only on its exit code:
/// `odoo -i` exits 0 even when a module fails to load.
fn run_odoo(job: &Job, mut command: std::process::Command, is_test: bool) -> Result<(), String> {
    let mut first_error: Option<String> = None;
    let mut tests: Option<String> = None;
    let exited_ok = job.run_with(&mut command, |line| {
        if first_error.is_none() && (line.contains(" ERROR ") || line.contains(" CRITICAL ")) {
            first_error = line.split_once(": ").map(|(_, message)| message.to_string()).or(Some(line.to_string()));
        }
        // "0 failed, 0 error(s) of 18 tests when loading database 'test_x'"
        if let Some(at) = line.find(" failed, ") {
            if line[at..].contains(" tests") {
                let start = line[..at].rfind(' ').map_or(0, |i| i + 1);
                let end = line[at..].find(" tests").map_or(line.len(), |i| at + i + 6);
                tests = Some(line[start..end].replace("error(s)", "errors"));
            }
        }
    })?;
    if let Some(tests) = &tests {
        job.summary(tests.clone());
    }
    if is_test {
        match &tests {
            Some(result) if result.starts_with("0 failed, 0 errors") => Ok(()),
            Some(result) => Err(result.clone()),
            None if first_error.is_some() => Err(first_error.unwrap()),
            None => {
                job.summary("No test ran.".into());
                if exited_ok { Ok(()) } else { Err("Odoo stopped with an error: see the output.".into()) }
            }
        }
    } else if let Some(error) = first_error {
        Err(error)
    } else if exited_ok {
        Ok(())
    } else {
        Err("Odoo stopped with an error: see the output.".into())
    }
}

/// Preflight, when it is installed (pipx install git+https://github.com/thanhphu2643/odoo-preflight).
/// Its first versions were called odoo-upgrade-check.
pub fn upgrade_checker() -> Option<PathBuf> {
    let mut folders: Vec<PathBuf> = Vec::new();
    if let Some(home) = std::env::var_os("HOME") {
        folders.push(PathBuf::from(home).join(".local/bin"));
    }
    folders.push("/opt/homebrew/bin".into());
    folders.push("/usr/local/bin".into());
    if let Some(path) = std::env::var_os("PATH") {
        folders.extend(std::env::split_paths(&path));
    }
    ["odoo-preflight", "odoo-upgrade-check"]
        .iter()
        .flat_map(|name| folders.iter().map(move |folder| folder.join(name)))
        .find(|path| path.is_file())
}

/// Checks what breaks in a module when it moves to `to`, with Preflight.
pub fn upgrade_check(path: PathBuf, from: u8, to: u8) -> Result<u64, String> {
    let checker = upgrade_checker().ok_or("Preflight (odoo-preflight) is not installed")?;
    if !path.join("__manifest__.py").is_file() {
        return Err(format!("{} is not an Odoo module", path.display()));
    }
    Ok(jobs::spawn("upgrade_check", None, move |job| {
        job.phase("run");
        let mut command = std::process::Command::new(checker);
        command.arg(&path).args(["--format", "json", "--from", &from.to_string(), "--to", &to.to_string()]);
        let mut output = String::new();
        // Exit code 1 means "found errors": the findings are the result either way.
        job.run_with(&mut command, |line| {
            output.push_str(line);
            output.push('\n');
        })?;
        let report: serde_json::Value = serde_json::from_str(&output).map_err(|_| "Preflight did not return a report".to_string())?;
        let findings = report["findings"].as_array().map_or(0, Vec::len);
        job.summary(match findings {
            0 => format!("Nothing to change for Odoo {to}."),
            1 => "1 finding".into(),
            n => format!("{n} findings"),
        });
        job.data(report);
        Ok(())
    }))
}
