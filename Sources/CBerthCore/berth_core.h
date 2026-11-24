#pragma once

// Every function takes a UTF-8 JSON string and returns a newly allocated JSON string
// (or {"error": "..."}) that must be released with berth_free.
// An env is {id, version: 16|17|18, port, addons: [folder], dev}.

/// {} -> {docker, upgrade_check}
char *berth_tools(const char *json);
/// {envs} -> [{id, odoo, db, ready, stale}]
char *berth_status(const char *json);
/// {env} -> {job}
char *berth_start(const char *json);
/// {env} -> {ok}
char *berth_stop(const char *json);
/// {env, data} -> {ok}
char *berth_remove(const char *json);
/// {port} -> {ok}
char *berth_port_free(const char *json);
/// {env} -> [{name, size}]
char *berth_databases(const char *json);
/// {env, database} -> {ok}
char *berth_drop(const char *json);
/// {env, source, target} -> {ok}
char *berth_duplicate(const char *json);
/// {env, database} -> [{name, state, version}]
char *berth_installed(const char *json);
/// {folders} -> [Module]
char *berth_modules(const char *json);
/// {env, task: create_database|install|update|test, ...} -> {job}
char *berth_task(const char *json);
/// {path, from, to} -> {job}
char *berth_upgrade_check(const char *json);
/// {env, after} -> {entries, reset}
char *berth_logs(const char *json);
/// {env} -> {ok}
char *berth_clear_logs(const char *json);
/// {job, from} -> {kind, phase, finished, ok, error, summary, data, lines, total}
char *berth_job(const char *json);
/// {job} -> {ok}
char *berth_cancel(const char *json);
/// {job} -> {ok}
char *berth_forget(const char *json);
void berth_free(char *s);
