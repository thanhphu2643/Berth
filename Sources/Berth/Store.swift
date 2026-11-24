import AppKit
import Foundation
import Observation

func formatBytes<T: BinaryInteger>(_ n: T) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .file)
}

/// A background job of the core (start, install, test…) as the app shows it.
struct RunningJob: Identifiable {
    enum Kind { case start, createDatabase, install, update, test, upgradeCheck }

    let id: UInt64
    let envID: String
    let kind: Kind
    let title: String
    /// The database or module it is about, to refresh what it changed when it ends.
    let database: String?
    var status: JobStatus?
    var lines: [String] = []

    var finished: Bool { status?.finished ?? false }
    var ok: Bool { status?.ok ?? false }
}

struct LogBuffer {
    static let limit = 5000
    var entries: [LogEntry] = []
    var last: UInt64 = 0

    /// Adds a page; its first entry may be the last one already here, with more detail.
    mutating func add(_ page: LogPage) {
        if page.reset { entries = [] }
        for entry in page.entries {
            if let last = entries.last, last.seq == entry.seq {
                entries[entries.count - 1] = entry
            } else if entry.seq > (entries.last?.seq ?? 0) {
                entries.append(entry)
            }
        }
        if entries.count > Self.limit { entries.removeFirst(entries.count - Self.limit) }
        last = entries.last?.seq ?? last
    }
}

@MainActor @Observable
final class Store {
    var envs: [EnvConfig] { didSet { Self.save("environments", envs) } }
    var selection: EnvConfig.ID? { didSet { UserDefaults.standard.set(selection, forKey: "selection") } }

    var statuses: [String: EnvStatus] = [:]
    /// Docker is missing or not running.
    var dockerProblem: String?
    var tools = Tools(docker: nil, upgradeCheck: nil)

    var databases: [String: [Database]] = [:]
    var databaseErrors: [String: String] = [:]
    var modules: [String: [Module]] = [:]
    /// Installed modules by "<env>/<database>".
    var installed: [String: [String: Installed]] = [:]
    var installedErrors: [String: String] = [:]
    /// The database the Modules tab works on, per environment.
    var moduleDatabase: [String: String] = [:]

    var jobs: [RunningJob] = []
    var logs: [String: LogBuffer] = [:]

    var editing: EnvConfig?
    var showSettings = false
    var error: String?
    var report: (title: String, findings: [UpgradeFinding])?

    init() {
        envs = Self.load("environments") ?? []
        selection = UserDefaults.standard.string(forKey: "selection")
        if selection == nil || !envs.contains(where: { $0.id == selection }) { selection = envs.first?.id }
        Task { await self.watch() }
    }

    private static func save<T: Encodable>(_ key: String, _ value: T) {
        UserDefaults.standard.set(try? JSONEncoder().encode(value), forKey: key)
    }
    private static func load<T: Decodable>(_ key: String) -> T? {
        UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }

    var selected: EnvConfig? { envs.first { $0.id == selection } }
    func status(_ env: EnvConfig) -> EnvStatus? { statuses[env.id] }
    func job(for env: EnvConfig) -> RunningJob? { jobs.last { $0.envID == env.id } }
    func busy(_ env: EnvConfig) -> Bool { jobs.contains { $0.envID == env.id && !$0.finished } }
    func starting(_ env: EnvConfig) -> Bool { jobs.contains { $0.envID == env.id && $0.kind == .start && !$0.finished } }

    // MARK: watching

    /// Refreshes the container states every few seconds, and the jobs while any runs.
    private func watch() async {
        tools = await (try? offMain { Core.tools() }) ?? tools
        var tick = 0
        while true {
            if tick % 4 == 0 { await refreshStatus() }
            await pollJobs()
            tick += 1
            try? await Task.sleep(for: .milliseconds(500))
        }
    }

    func refreshStatus() async {
        let envs = envs
        do {
            let list = try await offMain { try Core.status(envs) }
            statuses = Dictionary(uniqueKeysWithValues: list.map { ($0.id, $0) })
            dockerProblem = nil
        } catch {
            dockerProblem = error.localizedDescription
        }
    }

    private func pollJobs() async {
        // By id: jobs can be added or dismissed while a call is waiting.
        for id in jobs.filter({ !$0.finished }).map(\.id) {
            guard let from = jobs.first(where: { $0.id == id })?.lines.count else { continue }
            guard let status = try? await offMain({ try Core.job(id, from: from) }) else { continue }
            guard let i = jobs.firstIndex(where: { $0.id == id }) else { continue }
            jobs[i].lines.append(contentsOf: status.lines)
            if jobs[i].lines.count > 4000 { jobs[i].lines.removeFirst(jobs[i].lines.count - 4000) }
            jobs[i].status = status
            if status.finished { await finished(jobs[i]) }
        }
    }

    private func finished(_ job: RunningJob) async {
        guard let env = envs.first(where: { $0.id == job.envID }) else { return }
        switch job.kind {
        case .start:
            await refreshStatus()
            if job.ok { await loadDatabases(env) }
        case .createDatabase, .test:
            await loadDatabases(env)
        case .install, .update:
            if let database = job.database { await loadInstalled(env, database: database) }
        case .upgradeCheck:
            if job.ok, let findings = Core.upgradeReport(job.id)?.findings {
                report = (job.title, findings)
            }
        }
    }

    private func track(_ env: EnvConfig, _ kind: RunningJob.Kind, _ title: String, database: String? = nil,
                       _ start: @escaping @Sendable () throws -> UInt64) {
        Task {
            do {
                let id = try await offMain(start)
                jobs.append(RunningJob(id: id, envID: env.id, kind: kind, title: title, database: database))
                // Keep the last few finished jobs per environment.
                let done = jobs.filter { $0.envID == env.id && $0.finished }
                for old in done.dropLast(3) {
                    Core.forget(old.id)
                    jobs.removeAll { $0.id == old.id }
                }
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    func cancel(_ job: RunningJob) {
        let id = job.id
        Task { _ = try? await offMain { Core.cancel(id) } }
    }

    func dismiss(_ job: RunningJob) {
        Core.forget(job.id)
        jobs.removeAll { $0.id == job.id }
    }

    // MARK: environments

    func save(_ env: EnvConfig) {
        if let index = envs.firstIndex(where: { $0.id == env.id }) {
            envs[index] = env
        } else {
            envs.append(env)
        }
        selection = env.id
        Task {
            await refreshStatus()
            await loadModules(env)
        }
    }

    func newEnvironment() -> EnvConfig {
        let version = envs.last?.version ?? 17
        return EnvConfig(name: "Odoo \(version)", version: version, port: suggestedPort(version: version))
    }

    /// A port for a new environment: 80<version>, or the next free one after it.
    func suggestedPort(version: Int, except id: String? = nil) -> Int {
        let taken = Set(envs.filter { $0.id != id }.map(\.port))
        var port = 8000 + version
        while taken.contains(port) || !Core.portFree(port) { port += 100 }
        return port
    }

    func start(_ env: EnvConfig) {
        track(env, .start, t("Starting \(env.name)", "Khởi động \(env.name)")) { try Core.start(env) }
    }

    func stop(_ env: EnvConfig) {
        Task {
            do {
                try await offMain { try Core.stop(env) }
            } catch {
                self.error = error.localizedDescription
            }
            await refreshStatus()
        }
    }

    func remove(_ env: EnvConfig, data: Bool) {
        Task {
            do {
                try await offMain { try Core.remove(env, data: data) }
                envs.removeAll { $0.id == env.id }
                if selection == env.id { selection = envs.first?.id }
                logs[env.id] = nil
                await refreshStatus()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    func openBrowser(_ env: EnvConfig, database: String? = nil) {
        NSWorkspace.shared.open(database.map { env.url(database: $0) } ?? env.url)
    }

    /// Opens Terminal on `odoo shell` for the database.
    func openShell(_ env: EnvConfig, database: String) {
        guard let docker = tools.docker else { error = t("Docker was not found.", "Không tìm thấy Docker."); return }
        let script = """
        #!/bin/zsh
        clear
        echo "odoo shell · \(env.name) · \(database)"
        exec '\(docker)' exec -it berth-\(env.id)-odoo /entrypoint.sh odoo shell -d '\(database)' --no-http
        """
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("berth-shell-\(env.id)-\(database).command")
        do {
            try script.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            NSWorkspace.shared.open(url)
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: databases

    func loadDatabases(_ env: EnvConfig) async {
        do {
            let list = try await offMain { try Core.databases(env) }
            databases[env.id] = list
            databaseErrors[env.id] = nil
            if moduleDatabase[env.id].map({ name in !list.contains { $0.name == name } }) ?? true {
                moduleDatabase[env.id] = list.first { !$0.name.hasPrefix("test_") }?.name ?? list.first?.name
            }
        } catch {
            databases[env.id] = nil
            databaseErrors[env.id] = error.localizedDescription
        }
    }

    func createDatabase(_ env: EnvConfig, name: String, demo: Bool, language: String) {
        track(env, .createDatabase, t("Creating \(name)", "Tạo \(name)"), database: name) {
            try Core.task(env, ["task": "create_database", "database": name, "demo": demo, "language": language])
        }
    }

    func duplicate(_ env: EnvConfig, source: String, target: String) {
        Task {
            do {
                try await offMain { try Core.duplicate(env, source: source, target: target) }
            } catch {
                self.error = error.localizedDescription
            }
            await loadDatabases(env)
        }
    }

    func drop(_ env: EnvConfig, database: String) {
        Task {
            do {
                try await offMain { try Core.drop(env, database: database) }
            } catch {
                self.error = error.localizedDescription
            }
            await loadDatabases(env)
        }
    }

    // MARK: modules

    func loadModules(_ env: EnvConfig) async {
        let folders = env.addons
        modules[env.id] = (try? await offMain { try Core.modules(folders) }) ?? []
    }

    func installedKey(_ env: EnvConfig, _ database: String) -> String { "\(env.id)/\(database)" }

    func loadInstalled(_ env: EnvConfig, database: String) async {
        let key = installedKey(env, database)
        do {
            let list = try await offMain { try Core.installed(env, database: database) }
            installed[key] = Dictionary(uniqueKeysWithValues: list.map { ($0.name, $0) })
            installedErrors[key] = nil
        } catch {
            installed[key] = nil
            installedErrors[key] = error.localizedDescription
        }
    }

    func install(_ env: EnvConfig, database: String, modules: [String]) {
        let names = modules.joined(separator: ", ")
        track(env, .install, t("Installing \(names) in \(database)", "Cài \(names) vào \(database)"), database: database) {
            try Core.task(env, ["task": "install", "database": database, "modules": modules])
        }
    }

    func update(_ env: EnvConfig, database: String, modules: [String]) {
        let names = modules.joined(separator: ", ")
        track(env, .update, t("Updating \(names) in \(database)", "Cập nhật \(names) trong \(database)"), database: database) {
            try Core.task(env, ["task": "update", "database": database, "modules": modules])
        }
    }

    func test(_ env: EnvConfig, module: String) {
        track(env, .test, t("Testing \(module)", "Chạy test \(module)")) {
            try Core.task(env, ["task": "test", "module": module])
        }
    }

    func upgradeCheck(_ env: EnvConfig, module: Module) {
        guard let next = env.nextVersion else { return }
        let path = module.path, from = env.version
        track(env, .upgradeCheck, t("\(module.name) on Odoo \(next)", "\(module.name) trên Odoo \(next)")) {
            try Core.upgradeCheck(path: path, from: from, to: next)
        }
    }

    // MARK: logs

    func pollLogs(_ env: EnvConfig) async {
        let after = logs[env.id]?.last ?? 0
        guard let page = try? await offMain({ try Core.logs(env, after: after) }) else { return }
        var buffer = logs[env.id] ?? LogBuffer()
        buffer.add(page)
        logs[env.id] = buffer
    }

    func clearLogs(_ env: EnvConfig) {
        Core.clearLogs(env)
        var buffer = logs[env.id] ?? LogBuffer()
        buffer.entries = []
        logs[env.id] = buffer
    }
}
