//! End-to-end run against Docker: cargo run --example smoke -- <addons folder> [version] [port]
//! Creates an environment named "smoke", uses it, and removes it with its data.

use berth_core::{db, env, jobs, logs, modules, tasks};
use std::time::Duration;

fn wait(job: u64, label: &str) -> jobs::Status {
    let mut shown = 0;
    loop {
        let status = jobs::status(job, shown).unwrap();
        for line in &status.lines {
            if line.contains("ERROR") || line.contains("tests") || line.starts_with("Downloading") {
                println!("    | {line}");
            }
        }
        shown = status.total;
        if status.finished {
            println!("{label}: ok={} phase={} summary={:?} error={:?}", status.ok, status.phase, status.summary, status.error);
            return status;
        }
        std::thread::sleep(Duration::from_millis(500));
    }
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let addons = args.get(1).expect("addons folder");
    let version: u8 = args.get(2).map_or(17, |v| v.parse().unwrap());
    let port: u16 = args.get(3).map_or(8097, |v| v.parse().unwrap());
    let environment: env::Env = serde_json::from_value(serde_json::json!({
        "id": "smoke", "version": version, "port": port, "addons": [addons], "dev": true,
    })).unwrap();

    println!("modules: {:?}", modules::scan(&environment.addons).iter().map(|m| (&m.name, &m.version)).collect::<Vec<_>>());
    let start = std::time::Instant::now();
    assert!(wait(env::start(environment.clone()).unwrap(), "start").ok);
    println!("  started in {:?}; status {:?}", start.elapsed(), serde_json::to_string(&env::status(&[environment.clone()]).unwrap()).unwrap());

    let task = |value: serde_json::Value| -> tasks::Task { serde_json::from_value(value).unwrap() };
    assert!(wait(tasks::start(environment.clone(), task(serde_json::json!({"task": "create_database", "database": "dev", "demo": false, "language": "vi_VN"}))).unwrap(), "create dev").ok);
    assert!(wait(tasks::start(environment.clone(), task(serde_json::json!({"task": "install", "database": "dev", "modules": ["l10n_vn_address"]}))).unwrap(), "install").ok);
    let installed = db::installed(&environment, "dev").unwrap();
    println!("  installed: {} modules, l10n_vn_address = {:?}", installed.len(),
        installed.iter().find(|m| m.name == "l10n_vn_address").map(|m| (&m.state, &m.version)));
    assert!(wait(tasks::start(environment.clone(), task(serde_json::json!({"task": "update", "database": "dev", "modules": ["l10n_vn_address"]}))).unwrap(), "update").ok);
    let tested = wait(tasks::start(environment.clone(), task(serde_json::json!({"task": "test", "module": "l10n_vn_address"}))).unwrap(), "test");
    assert!(tested.ok);

    db::duplicate(&environment, "dev", "dev_copy").unwrap();
    println!("  databases: {:?}", db::list(&environment).unwrap().iter().map(|d| (&d.name, d.size / 1_000_000)).collect::<Vec<_>>());
    db::drop(&environment, "dev_copy", false).unwrap();
    assert!(db::drop(&environment, "nope", false).is_err());

    let page = logs::read(&environment, 0).unwrap();
    std::thread::sleep(Duration::from_secs(2));
    let page2 = logs::read(&environment, 0).unwrap();
    println!("  log entries: {} then {}; levels {:?}", page.entries.len(), page2.entries.len(),
        page2.entries.iter().fold(std::collections::BTreeMap::new(), |mut m, e| { *m.entry(e.level.clone()).or_insert(0) += 1; m }));

    env::stop(&environment).unwrap();
    println!("  after stop: {}", serde_json::to_string(&env::status(&[environment.clone()]).unwrap()).unwrap());
    env::remove(&environment, true).unwrap();
    println!("  after remove: {}", serde_json::to_string(&env::status(&[environment.clone()]).unwrap()).unwrap());
}
