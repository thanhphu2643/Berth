//! Berth: Odoo development environments in Docker, one per Odoo version and project.
//! The Swift app calls the C functions below, which take and return JSON strings.

pub mod db;
pub mod docker;
pub mod env;
pub mod jobs;
pub mod logs;
pub mod modules;
pub mod pylit;
pub mod tasks;

use env::Env;
use serde::{Deserialize, Serialize};
use std::ffi::{c_char, CStr, CString};
use std::path::PathBuf;

fn json_call<I, O>(input: *const c_char, f: impl FnOnce(I) -> Result<O, String>) -> *mut c_char
where
    I: for<'de> Deserialize<'de>,
    O: Serialize,
{
    let out = (|| -> Result<String, String> {
        if input.is_null() {
            return Err("null input".into());
        }
        let text = unsafe { CStr::from_ptr(input) }.to_str().map_err(|e| e.to_string())?;
        let parsed: I = serde_json::from_str(text).map_err(|e| e.to_string())?;
        serde_json::to_string(&f(parsed)?).map_err(|e| e.to_string())
    })()
    .unwrap_or_else(|e| serde_json::json!({ "error": e }).to_string());
    CString::new(out).map_or(std::ptr::null_mut(), CString::into_raw)
}

#[derive(Serialize)]
struct Done {
    ok: bool,
}

#[derive(Serialize)]
struct Started {
    job: u64,
}

#[derive(Deserialize)]
struct EnvsRequest {
    envs: Vec<Env>,
}

#[derive(Deserialize)]
struct EnvRequest {
    env: Env,
}

#[derive(Deserialize)]
struct RemoveRequest {
    env: Env,
    #[serde(default)]
    data: bool,
}

#[derive(Deserialize)]
struct DatabaseRequest {
    env: Env,
    database: String,
}

#[derive(Deserialize)]
struct DuplicateRequest {
    env: Env,
    source: String,
    target: String,
}

#[derive(Deserialize)]
struct TaskRequest {
    env: Env,
    #[serde(flatten)]
    task: tasks::Task,
}

#[derive(Deserialize)]
struct FoldersRequest {
    folders: Vec<PathBuf>,
}

#[derive(Deserialize)]
struct LogsRequest {
    env: Env,
    #[serde(default)]
    after: u64,
}

#[derive(Deserialize)]
struct JobRequest {
    job: u64,
    #[serde(default)]
    from: usize,
}

#[derive(Deserialize)]
struct CheckRequest {
    path: PathBuf,
    from: u8,
    to: u8,
}

#[derive(Deserialize)]
struct PortRequest {
    port: u16,
}

#[derive(Serialize)]
struct Tools {
    docker: Option<String>,
    upgrade_check: Option<String>,
}

/// {} → {docker, upgrade_check}: paths of the tools Berth uses, null when missing.
#[no_mangle]
pub extern "C" fn berth_tools(json: *const c_char) -> *mut c_char {
    json_call(json, |_: serde_json::Value| {
        Ok(Tools {
            docker: docker::docker().ok().map(|p| p.display().to_string()),
            upgrade_check: tasks::upgrade_checker().map(|p| p.display().to_string()),
        })
    })
}

/// {envs} → [{id, odoo, db, ready, stale}]
#[no_mangle]
pub extern "C" fn berth_status(json: *const c_char) -> *mut c_char {
    json_call(json, |r: EnvsRequest| env::status(&r.envs))
}

/// {env} → {job}
#[no_mangle]
pub extern "C" fn berth_start(json: *const c_char) -> *mut c_char {
    json_call(json, |r: EnvRequest| env::start(r.env).map(|job| Started { job }))
}

/// {env} → {ok}
#[no_mangle]
pub extern "C" fn berth_stop(json: *const c_char) -> *mut c_char {
    json_call(json, |r: EnvRequest| env::stop(&r.env).map(|_| Done { ok: true }))
}

/// {env, data} → {ok}
#[no_mangle]
pub extern "C" fn berth_remove(json: *const c_char) -> *mut c_char {
    json_call(json, |r: RemoveRequest| env::remove(&r.env, r.data).map(|_| Done { ok: true }))
}

/// {port} → {ok}: ok is true when nothing listens on the port.
#[no_mangle]
pub extern "C" fn berth_port_free(json: *const c_char) -> *mut c_char {
    json_call(json, |r: PortRequest| Ok(Done { ok: !env::port_in_use(r.port) }))
}

/// {env} → [{name, size}]
#[no_mangle]
pub extern "C" fn berth_databases(json: *const c_char) -> *mut c_char {
    json_call(json, |r: EnvRequest| db::list(&r.env))
}

/// {env, database} → {ok}
#[no_mangle]
pub extern "C" fn berth_drop(json: *const c_char) -> *mut c_char {
    json_call(json, |r: DatabaseRequest| db::drop(&r.env, &r.database, false).map(|_| Done { ok: true }))
}

/// {env, source, target} → {ok}
#[no_mangle]
pub extern "C" fn berth_duplicate(json: *const c_char) -> *mut c_char {
    json_call(json, |r: DuplicateRequest| db::duplicate(&r.env, &r.source, &r.target).map(|_| Done { ok: true }))
}

/// {env, database} → [{name, state, version}]
#[no_mangle]
pub extern "C" fn berth_installed(json: *const c_char) -> *mut c_char {
    json_call(json, |r: DatabaseRequest| db::installed(&r.env, &r.database))
}

/// {folders} → [Module]
#[no_mangle]
pub extern "C" fn berth_modules(json: *const c_char) -> *mut c_char {
    json_call(json, |r: FoldersRequest| Ok(modules::scan(&r.folders)))
}

/// {env, task: create_database | install | update | test, …} → {job}
#[no_mangle]
pub extern "C" fn berth_task(json: *const c_char) -> *mut c_char {
    json_call(json, |r: TaskRequest| tasks::start(r.env, r.task).map(|job| Started { job }))
}

/// {path, from, to} → {job}
#[no_mangle]
pub extern "C" fn berth_upgrade_check(json: *const c_char) -> *mut c_char {
    json_call(json, |r: CheckRequest| tasks::upgrade_check(r.path, r.from, r.to).map(|job| Started { job }))
}

/// {env, after} → {entries, reset}
#[no_mangle]
pub extern "C" fn berth_logs(json: *const c_char) -> *mut c_char {
    json_call(json, |r: LogsRequest| logs::read(&r.env, r.after))
}

/// {env} → {ok}
#[no_mangle]
pub extern "C" fn berth_clear_logs(json: *const c_char) -> *mut c_char {
    json_call(json, |r: EnvRequest| {
        logs::clear(&r.env);
        Ok(Done { ok: true })
    })
}

/// {job, from} → {kind, phase, finished, ok, error, summary, data, lines, total}
#[no_mangle]
pub extern "C" fn berth_job(json: *const c_char) -> *mut c_char {
    json_call(json, |r: JobRequest| jobs::status(r.job, r.from))
}

/// {job} → {ok}
#[no_mangle]
pub extern "C" fn berth_cancel(json: *const c_char) -> *mut c_char {
    json_call(json, |r: JobRequest| jobs::cancel(r.job).map(|_| Done { ok: true }))
}

/// {job} → {ok}
#[no_mangle]
pub extern "C" fn berth_forget(json: *const c_char) -> *mut c_char {
    json_call(json, |r: JobRequest| {
        jobs::forget(r.job);
        Ok(Done { ok: true })
    })
}

/// Releases a string returned by any berth_ function.
#[no_mangle]
pub extern "C" fn berth_free(s: *mut c_char) {
    if !s.is_null() {
        unsafe { drop(CString::from_raw(s)) };
    }
}
