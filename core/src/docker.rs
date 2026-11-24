//! Runs the docker command line.

use std::path::PathBuf;
use std::process::{Command, Output};
use std::sync::OnceLock;

/// Apps opened from Finder get a bare PATH, so look in the usual install places first.
pub fn docker() -> Result<PathBuf, String> {
    static FOUND: OnceLock<Option<PathBuf>> = OnceLock::new();
    FOUND
        .get_or_init(|| {
            let mut candidates: Vec<PathBuf> = vec![
                "/usr/local/bin/docker".into(),
                "/opt/homebrew/bin/docker".into(),
                "/Applications/Docker.app/Contents/Resources/bin/docker".into(),
                "/Applications/OrbStack.app/Contents/MacOS/xbin/docker".into(),
            ];
            if let Some(home) = std::env::var_os("HOME") {
                candidates.push(PathBuf::from(home).join(".orbstack/bin/docker"));
            }
            if let Some(path) = std::env::var_os("PATH") {
                candidates.extend(std::env::split_paths(&path).map(|dir| dir.join("docker")));
            }
            candidates.into_iter().find(|path| path.is_file())
        })
        .clone()
        .ok_or_else(|| "Docker was not found. Install Docker Desktop or OrbStack.".to_string())
}

pub fn command() -> Result<Command, String> {
    Ok(Command::new(docker()?))
}

/// Runs `docker args…` and returns its standard output, or its error message.
pub fn run(args: &[&str]) -> Result<String, String> {
    let output = command()?.args(args).output().map_err(|e| e.to_string())?;
    result(output)
}

pub fn result(output: Output) -> Result<String, String> {
    if output.status.success() {
        Ok(String::from_utf8_lossy(&output.stdout).into_owned())
    } else {
        let stderr = String::from_utf8_lossy(&output.stderr);
        let message = stderr.trim().strip_prefix("Error response from daemon: ").unwrap_or(stderr.trim());
        Err(if message.contains("Cannot connect to the Docker daemon") || message.contains("docker daemon is not running") {
            "Docker is not running. Start Docker Desktop or OrbStack.".to_string()
        } else if message.is_empty() {
            format!("docker exited with {}", output.status)
        } else {
            message.to_string()
        })
    }
}

/// Whether an image is already on this computer (pulling one takes a while).
pub fn has_image(image: &str) -> bool {
    command()
        .and_then(|mut c| c.args(["image", "inspect", "--format", "{{.Id}}", image]).output().map_err(|e| e.to_string()))
        .map(|o| o.status.success())
        .unwrap_or(false)
}
