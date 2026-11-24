//! The Odoo modules in the addons folders of an environment.

use crate::pylit;
use serde::Serialize;
use std::path::{Path, PathBuf};

#[derive(Serialize)]
pub struct Module {
    /// Technical name: the folder name.
    pub name: String,
    pub path: PathBuf,
    pub title: String,
    pub version: String,
    pub summary: String,
    pub depends: Vec<String>,
    pub application: bool,
    pub installable: bool,
    /// The manifest could not be read.
    pub error: Option<String>,
}

/// Modules found in the folders: a folder can be a module itself or contain modules.
pub fn scan(folders: &[PathBuf]) -> Vec<Module> {
    let mut modules = Vec::new();
    for folder in folders {
        if folder.join("__manifest__.py").is_file() {
            modules.push(read(folder));
        } else if let Ok(entries) = std::fs::read_dir(folder) {
            let mut paths: Vec<PathBuf> = entries.filter_map(Result::ok).map(|e| e.path()).collect();
            paths.sort();
            modules.extend(paths.iter().filter(|p| p.join("__manifest__.py").is_file()).map(|p| read(p)));
        }
    }
    modules.sort_by(|a, b| a.name.cmp(&b.name));
    modules
}

fn read(path: &Path) -> Module {
    let name = path.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
    let manifest = std::fs::read_to_string(path.join("__manifest__.py"))
        .map_err(|e| e.to_string())
        .and_then(|text| pylit::parse(&text));
    let text = |value: &serde_json::Value, key: &str| value[key].as_str().unwrap_or("").trim().to_string();
    match manifest {
        Ok(value) => Module {
            title: Some(text(&value, "name")).filter(|t| !t.is_empty()).unwrap_or_else(|| name.clone()),
            version: text(&value, "version"),
            summary: text(&value, "summary"),
            depends: value["depends"].as_array().map_or_else(Vec::new, |items| {
                items.iter().filter_map(|d| d.as_str().map(str::to_string)).collect()
            }),
            application: value["application"].as_bool().unwrap_or(false),
            installable: value["installable"].as_bool().unwrap_or(true),
            error: None,
            name,
            path: path.to_path_buf(),
        },
        Err(error) => Module {
            title: name.clone(),
            version: String::new(),
            summary: String::new(),
            depends: Vec::new(),
            application: false,
            installable: true,
            error: Some(format!("cannot read __manifest__.py: {error}")),
            name,
            path: path.to_path_buf(),
        },
    }
}
