import CBerthCore
import Foundation

// Mirrors the JSON types of core/src.

/// An environment as the user set it up; saved in the preferences.
struct EnvConfig: Codable, Identifiable, Hashable {
    /// Short and stable: Docker names are berth-<id>-odoo, berth-<id>-db…
    var id: String = EnvConfig.newID()
    var name: String
    var version: Int = 17
    var port: Int = 8069
    var addons: [String] = []
    var dev: Bool = true

    static func newID() -> String {
        String(UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "").prefix(8))
    }

    var json: [String: Any] {
        ["id": id, "version": version, "port": port, "addons": addons, "dev": dev]
    }

    var url: URL { URL(string: "http://localhost:\(port)")! }
    func url(database: String) -> URL { URL(string: "http://localhost:\(port)/web?db=\(database)")! }
    /// The next Odoo version, for upgrade checks.
    var nextVersion: Int? { version < 18 ? version + 1 : nil }
}

struct EnvStatus: Decodable, Hashable {
    let id: String
    let odoo: String
    let db: String
    let ready: Bool
    let stale: Bool

    var running: Bool { odoo == "running" }
}

struct Database: Decodable, Identifiable, Hashable {
    let name: String
    let size: UInt64
    var id: String { name }
}

struct Installed: Decodable, Hashable {
    let name: String
    let state: String
    let version: String
}

struct Module: Decodable, Identifiable, Hashable {
    let name: String
    let path: String
    let title: String
    let version: String
    let summary: String
    let depends: [String]
    let application: Bool
    let installable: Bool
    let error: String?
    var id: String { name }
}

struct LogEntry: Decodable, Identifiable, Hashable {
    let seq: UInt64
    let time: String
    let level: String
    let db: String
    let logger: String
    let message: String
    let detail: String
    var id: UInt64 { seq }

    var isRequest: Bool { logger == "werkzeug" }
    var isProblem: Bool { level == "ERROR" || level == "CRITICAL" }
    var text: String {
        let head = [time, level, db, logger.isEmpty ? "" : "\(logger):", message].filter { !$0.isEmpty }.joined(separator: " ")
        return detail.isEmpty ? head : "\(head)\n\(detail)"
    }
}

struct LogPage: Decodable {
    let entries: [LogEntry]
    let reset: Bool
}

struct JobStatus: Decodable {
    let kind: String
    let phase: String
    let finished: Bool
    let ok: Bool
    let error: String?
    let summary: String?
    let lines: [String]
    let total: Int
}

struct UpgradeFinding: Decodable, Identifiable, Hashable {
    let rule: String
    let severity: String
    let version: Int
    let path: String
    let line: Int
    let column: Int
    let message: String
    let fix: String
    var id: String { "\(path):\(line):\(column):\(rule)" }
}

struct UpgradeReport: Decodable {
    let findings: [UpgradeFinding]
}

private struct UpgradeJob: Decodable {
    let data: UpgradeReport?
}

struct Tools: Decodable {
    let docker: String?
    let upgradeCheck: String?
}

struct Failure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

private struct Done: Decodable { let ok: Bool }
private struct Started: Decodable { let job: UInt64 }

/// Calls into the Rust core. Every call blocks, so the app makes them off the main thread.
enum Core {
    static func tools() -> Tools {
        (try? call(berth_tools, [:])) ?? Tools(docker: nil, upgradeCheck: nil)
    }

    static func status(_ envs: [EnvConfig]) throws -> [EnvStatus] {
        try call(berth_status, ["envs": envs.map(\.json)])
    }

    static func start(_ env: EnvConfig) throws -> UInt64 {
        let started: Started = try call(berth_start, ["env": env.json])
        return started.job
    }

    static func stop(_ env: EnvConfig) throws {
        let _: Done = try call(berth_stop, ["env": env.json])
    }

    static func remove(_ env: EnvConfig, data: Bool) throws {
        let _: Done = try call(berth_remove, ["env": env.json, "data": data])
    }

    static func portFree(_ port: Int) -> Bool {
        let done: Done? = try? call(berth_port_free, ["port": port])
        return done?.ok ?? true
    }

    static func databases(_ env: EnvConfig) throws -> [Database] {
        try call(berth_databases, ["env": env.json])
    }

    static func drop(_ env: EnvConfig, database: String) throws {
        let _: Done = try call(berth_drop, ["env": env.json, "database": database])
    }

    static func duplicate(_ env: EnvConfig, source: String, target: String) throws {
        let _: Done = try call(berth_duplicate, ["env": env.json, "source": source, "target": target])
    }

    static func installed(_ env: EnvConfig, database: String) throws -> [Installed] {
        try call(berth_installed, ["env": env.json, "database": database])
    }

    static func modules(_ folders: [String]) throws -> [Module] {
        try call(berth_modules, ["folders": folders])
    }

    /// task: create_database {database, demo, language} | install / update {database, modules} | test {module}
    static func task(_ env: EnvConfig, _ task: [String: Any]) throws -> UInt64 {
        var input = task
        input["env"] = env.json
        let started: Started = try call(berth_task, input)
        return started.job
    }

    static func upgradeCheck(path: String, from: Int, to: Int) throws -> UInt64 {
        let started: Started = try call(berth_upgrade_check, ["path": path, "from": from, "to": to])
        return started.job
    }

    static func upgradeReport(_ job: UInt64) -> UpgradeReport? {
        let result: UpgradeJob? = try? call(berth_job, ["job": job, "from": Int.max])
        return result?.data
    }

    static func logs(_ env: EnvConfig, after: UInt64) throws -> LogPage {
        try call(berth_logs, ["env": env.json, "after": after])
    }

    static func clearLogs(_ env: EnvConfig) {
        let _: Done? = try? call(berth_clear_logs, ["env": env.json])
    }

    static func job(_ id: UInt64, from: Int) throws -> JobStatus {
        try call(berth_job, ["job": id, "from": from])
    }

    static func cancel(_ id: UInt64) {
        let _: Done? = try? call(berth_cancel, ["job": id])
    }

    static func forget(_ id: UInt64) {
        let _: Done? = try? call(berth_forget, ["job": id])
    }

    private static func call<T: Decodable>(
        _ fn: (UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>?, _ input: [String: Any]
    ) throws -> T {
        let json = String(decoding: try JSONSerialization.data(withJSONObject: input), as: UTF8.self)
        guard let out = json.withCString({ fn($0) }) else { throw Failure(message: "The Rust core returned nothing") }
        defer { berth_free(out) }
        let data = Data(String(cString: out).utf8)
        if let err = try? JSONDecoder().decode([String: String].self, from: data), let msg = err["error"] {
            throw Failure(message: msg)
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(T.self, from: data)
    }
}

/// Runs a blocking core call off the main thread.
func offMain<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
    try await Task.detached(priority: .userInitiated) { try work() }.value
}
