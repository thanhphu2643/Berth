//! The databases of an environment, through psql in its PostgreSQL container. Their files
//! (attachments) live in the Odoo data volume under filestore/<database>, and are copied and
//! removed with the database.

use crate::docker;
use crate::env::Env;
use serde::Serialize;

/// Odoo's own rule for database names.
pub fn check_name(name: &str) -> Result<(), String> {
    let mut chars = name.chars();
    let valid = name.len() <= 63
        && chars.next().is_some_and(|c| c.is_ascii_alphanumeric())
        && chars.all(|c| c.is_ascii_alphanumeric() || matches!(c, '_' | '.' | '-'));
    if valid { Ok(()) } else { Err(format!("“{name}” is not a valid database name: use letters, digits, _ . -")) }
}

fn psql(env: &Env, database: &str, sql: &str) -> Result<String, String> {
    docker::run(&["exec", &env.db(), "psql", "-U", "odoo", "-d", database, "-v", "ON_ERROR_STOP=1", "-AtF", "\t", "-c", sql])
        .map_err(|e| if e.contains("is not running") || e.contains("No such container") {
            "The environment is not running: start it first.".to_string()
        } else if e.contains("connection to server on socket") || e.contains("the database system is starting up") {
            "PostgreSQL is still starting: try again in a moment.".to_string()
        } else {
            e
        })
}

#[derive(Serialize)]
pub struct Database {
    pub name: String,
    pub size: u64,
}

pub fn list(env: &Env) -> Result<Vec<Database>, String> {
    env.check()?;
    let out = psql(env, "postgres",
        "SELECT datname, pg_database_size(datname) FROM pg_database \
         WHERE NOT datistemplate AND datname <> 'postgres' ORDER BY datname")?;
    Ok(out
        .lines()
        .filter_map(|line| {
            let (name, size) = line.split_once('\t')?;
            Some(Database { name: name.to_string(), size: size.parse().unwrap_or(0) })
        })
        .collect())
}

fn exists(env: &Env, database: &str) -> Result<bool, String> {
    Ok(psql(env, "postgres", &format!("SELECT 1 FROM pg_database WHERE datname = '{database}'"))?.trim() == "1")
}

/// Runs a shell command on the data volume, with the Odoo image (already here, unlike any other).
fn on_filestore(env: &Env, script: &str) -> Result<(), String> {
    docker::run(&[
        "run", "--rm", "--label", &format!("berth.env={}", env.id),
        "-v", &format!("{}:/var/lib/odoo", env.data_volume()),
        "--entrypoint", "sh", &env.image(), "-c", script,
    ])
    .map(|_| ())
}

/// Drops a database and its files. With `missing_ok`, a missing database is not an error.
pub fn drop(env: &Env, database: &str, missing_ok: bool) -> Result<(), String> {
    env.check()?;
    check_name(database)?;
    if !exists(env, database)? {
        return if missing_ok { Ok(()) } else { Err(format!("There is no database “{database}”.")) };
    }
    psql(env, "postgres", &format!("DROP DATABASE \"{database}\" WITH (FORCE)"))?;
    on_filestore(env, &format!("rm -rf '/var/lib/odoo/filestore/{database}'"))
}

/// Copies a database and its files. Its open connections are closed first, as PostgreSQL
/// requires; Odoo reconnects by itself.
pub fn duplicate(env: &Env, source: &str, target: &str) -> Result<(), String> {
    env.check()?;
    check_name(source)?;
    check_name(target)?;
    if exists(env, target)? {
        return Err(format!("A database named “{target}” already exists."));
    }
    psql(env, "postgres", &format!(
        "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '{source}' AND pid <> pg_backend_pid()"))?;
    psql(env, "postgres", &format!("CREATE DATABASE \"{target}\" WITH TEMPLATE \"{source}\""))?;
    let (from, to) = (format!("/var/lib/odoo/filestore/{source}"), format!("/var/lib/odoo/filestore/{target}"));
    on_filestore(env, &format!("if [ -d '{from}' ]; then cp -a '{from}' '{to}'; fi"))
}

#[derive(Serialize)]
pub struct Installed {
    pub name: String,
    /// installed, to upgrade, to install, to remove
    pub state: String,
    pub version: String,
}

/// The modules installed (or about to be) in a database.
pub fn installed(env: &Env, database: &str) -> Result<Vec<Installed>, String> {
    env.check()?;
    check_name(database)?;
    let out = psql(env, database,
        "SELECT name, state, COALESCE(latest_version, '') FROM ir_module_module \
         WHERE state NOT IN ('uninstalled', 'uninstallable') ORDER BY name")
        .map_err(|e| if e.contains("ir_module_module") { "This is not an Odoo database.".to_string() } else { e })?;
    Ok(out
        .lines()
        .filter_map(|line| {
            let mut parts = line.split('\t');
            Some(Installed {
                name: parts.next()?.to_string(),
                state: parts.next()?.to_string(),
                version: parts.next().unwrap_or("").to_string(),
            })
        })
        .collect())
}
