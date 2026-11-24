import AppKit
import SwiftUI

struct ModulesView: View {
    @Environment(Store.self) private var store
    let env: EnvConfig
    @State private var search = ""
    @State private var onlyInstalled = false

    private var running: Bool { store.status(env)?.ready ?? false }
    private var database: String? { store.moduleDatabase[env.id] }
    private var installed: [String: Installed] {
        database.flatMap { store.installed[store.installedKey(env, $0)] } ?? [:]
    }
    private var all: [Module] { store.modules[env.id] ?? [] }
    private var shown: [Module] {
        all.filter { module in
            (search.isEmpty || module.name.localizedCaseInsensitiveContains(search) || module.title.localizedCaseInsensitiveContains(search))
                && (!onlyInstalled || installed[module.name] != nil)
        }
    }
    /// Installed modules whose manifest version moved on since they were installed.
    private var changed: [Module] { all.filter { state(of: $0) == .outdated } }

    enum State { case notInstalled, installed, outdated, pending }

    func state(of module: Module) -> State {
        guard let row = installed[module.name] else { return .notInstalled }
        if row.state != "installed" { return .pending }
        return normalized(module.version) == row.version ? .installed : .outdated
    }

    /// Odoo prefixes versions without a series ("1.2") with it ("17.0.1.2").
    private func normalized(_ version: String) -> String {
        let series = "\(env.version).0"
        if version.isEmpty { return series }
        return version.hasPrefix(series + ".") || version == series ? version : "\(series).\(version)"
    }

    var body: some View {
        Group {
            if env.addons.isEmpty {
                ContentUnavailableView {
                    Label(t("No addons folder", "Chưa có thư mục addons"), systemImage: "folder.badge.plus")
                } description: {
                    Text(t("Add the folders of your modules to this environment.", "Thêm thư mục chứa module của bạn vào môi trường này."))
                } actions: {
                    Button(t("Edit Environment…", "Sửa môi trường…")) { store.editing = env }
                }
            } else {
                VStack(spacing: 0) {
                    toolbar
                    if !running {
                        Label(t("Start the environment to install, update or test modules.", "Khởi động môi trường để cài, cập nhật hoặc test module."),
                              systemImage: "info.circle")
                            .font(.callout).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 20).padding(.bottom, 8)
                    } else if let database, let error = store.installedErrors[store.installedKey(env, database)] {
                        Label(error, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 20).padding(.bottom, 8)
                    }
                    List(shown) { module in
                        ModuleRow(env: env, module: module, state: state(of: module), installed: installed[module.name],
                                  database: running ? database : nil)
                    }
                    .overlay {
                        if all.isEmpty {
                            ContentUnavailableView(t("No module found", "Không tìm thấy module"), systemImage: "shippingbox",
                                                   description: Text(t("No folder with a __manifest__.py in the addons folders.",
                                                                       "Không có thư mục nào chứa __manifest__.py trong các thư mục addons.")))
                        } else if shown.isEmpty {
                            ContentUnavailableView.search(text: search)
                        }
                    }
                }
            }
        }
        .task(id: "\(running)\(database ?? "")") {
            if running && store.databases[env.id] == nil { await store.loadDatabases(env) }
            if running, let database { await store.loadInstalled(env, database: database) }
        }
    }

    private var toolbar: some View {
        @Bindable var store = store
        return HStack(spacing: 12) {
            Picker(t("Database", "Database"), selection: Binding(get: { database ?? "" }, set: { store.moduleDatabase[env.id] = $0 })) {
                ForEach(store.databases[env.id] ?? []) { Text($0.name).tag($0.name) }
            }
            .frame(maxWidth: 260)
            .disabled(!running || (store.databases[env.id] ?? []).isEmpty)
            Toggle(t("Installed only", "Chỉ module đã cài"), isOn: $onlyInstalled).toggleStyle(.checkbox)
            Spacer()
            if running, let database, !changed.isEmpty {
                Button {
                    store.update(env, database: database, modules: changed.map(\.name))
                } label: {
                    Label(t("Update \(changed.count) changed", "Cập nhật \(changed.count) module đã đổi"), systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(store.busy(env))
                .help(changed.map(\.name).joined(separator: ", "))
            }
            TextField(t("Search", "Tìm"), text: $search).textFieldStyle(.roundedBorder).frame(width: 180)
            Button { Task { await store.loadModules(env); if let database { await store.loadInstalled(env, database: database) } } } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless).help(t("Read the modules again", "Đọc lại các module"))
        }
        .padding(.horizontal, 20).padding(.vertical, 10)
    }
}

struct ModuleRow: View {
    @Environment(Store.self) private var store
    let env: EnvConfig
    let module: Module
    let state: ModulesView.State
    let installed: Installed?
    /// nil when the environment is not running or has no database.
    let database: String?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: module.application ? "app.badge" : "shippingbox")
                .foregroundStyle(.secondary).frame(width: 18).padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(module.title).fontWeight(.medium)
                    Text(module.name).font(.callout.monospaced()).foregroundStyle(.secondary)
                    badge
                }
                if let error = module.error {
                    Text(error).font(.caption).foregroundStyle(.red)
                } else if !module.summary.isEmpty {
                    Text(module.summary).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                }
                Text(versionLine).font(.caption).foregroundStyle(.tertiary)
            }
            Spacer()
            actions
        }
        .padding(.vertical, 4)
        .contextMenu { menuItems }
    }

    private var versionLine: String {
        var parts = [module.version.isEmpty ? t("no version", "không có version") : module.version]
        if let installed, state == .outdated { parts.append(t("installed \(installed.version)", "đã cài \(installed.version)")) }
        if !module.depends.isEmpty { parts.append(t("depends on ", "phụ thuộc ") + module.depends.joined(separator: ", ")) }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private var badge: some View {
        switch state {
        case .notInstalled: EmptyView()
        case .installed: Tag(text: t("Installed", "Đã cài"), color: .green)
        case .outdated: Tag(text: t("Needs update", "Cần cập nhật"), color: .orange)
        case .pending: Tag(text: installed?.state ?? "", color: .secondary)
        }
    }

    @ViewBuilder private var actions: some View {
        HStack(spacing: 8) {
            if let database {
                if state == .notInstalled {
                    Button(t("Install", "Cài")) { store.install(env, database: database, modules: [module.name]) }
                } else {
                    Button(t("Update", "Cập nhật")) { store.update(env, database: database, modules: [module.name]) }
                }
            }
            Menu {
                menuItems
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuIndicator(.hidden).fixedSize().buttonStyle(.borderless)
        }
        .disabled(store.busy(env))
    }

    @ViewBuilder private var menuItems: some View {
        Button(t("Run Tests", "Chạy test")) { store.test(env, module: module.name) }
            .disabled(!(store.status(env)?.running ?? false) || store.busy(env))
        if let next = env.nextVersion {
            Button(t("Check for Odoo \(next)", "Kiểm tra lên Odoo \(next)")) { store.upgradeCheck(env, module: module) }
                .disabled(store.tools.upgradeCheck == nil || store.busy(env))
        }
        Divider()
        Button(t("Show in Finder", "Mở trong Finder")) {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: module.path)])
        }
    }
}

struct Tag: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text).font(.caption2.weight(.semibold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .foregroundStyle(color)
            .background(color.opacity(0.14), in: Capsule())
    }
}
