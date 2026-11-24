import SwiftUI

struct DatabasesView: View {
    @Environment(Store.self) private var store
    let env: EnvConfig
    @State private var selection: Database.ID?
    @State private var creating = false
    @State private var duplicating: Database?
    @State private var dropping: Database?

    private var running: Bool { store.status(env)?.running ?? false }
    private var ready: Bool { store.status(env)?.ready ?? false }
    private var list: [Database] { store.databases[env.id] ?? [] }
    private var selected: Database? { list.first { $0.id == selection } }

    var body: some View {
        Group {
            if !ready {
                NotRunning(env: env, what: t("its databases", "các database"))
            } else if let error = store.databaseErrors[env.id], list.isEmpty {
                ContentUnavailableView(t("Cannot list the databases", "Không đọc được danh sách database"),
                                       systemImage: "exclamationmark.triangle", description: Text(error))
            } else {
                VStack(spacing: 0) {
                    toolbar
                    if list.isEmpty {
                        ContentUnavailableView {
                            Label(t("No database yet", "Chưa có database"), systemImage: "cylinder")
                        } description: {
                            Text(t("Create one with base installed, with or without demo data.",
                                   "Tạo database với module base, có hoặc không có dữ liệu demo."))
                        } actions: {
                            Button(t("New Database…", "Tạo database…")) { creating = true }.buttonStyle(.borderedProminent)
                                .disabled(store.busy(env))
                        }
                        .frame(maxHeight: .infinity)
                    } else {
                        table
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
        .task(id: ready) { if ready { await store.loadDatabases(env) } }
        .sheet(isPresented: $creating) { NewDatabaseSheet(env: env, existing: list.map(\.name)) }
        .sheet(item: $duplicating) { db in DuplicateSheet(env: env, source: db.name, existing: list.map(\.name)) }
        .confirmationDialog(t("Drop \(dropping?.name ?? "")?", "Xóa \(dropping?.name ?? "")?"),
                            isPresented: Binding(get: { dropping != nil }, set: { if !$0 { dropping = nil } }), presenting: dropping) { db in
            Button(t("Drop the database and its files", "Xóa database và file của nó"), role: .destructive) { store.drop(env, database: db.name) }
        } message: { _ in
            Text(t("This cannot be undone.", "Không thể hoàn tác."))
        }
    }

    private var toolbar: some View {
        HStack {
            Button { creating = true } label: { Label(t("New Database…", "Tạo database…"), systemImage: "plus") }
                .disabled(store.busy(env))
            Spacer()
            Button { Task { await store.loadDatabases(env) } } label: { Image(systemName: "arrow.clockwise") }
                .help(t("Refresh", "Làm mới")).buttonStyle(.borderless)
        }
        .padding(.horizontal, 20).padding(.vertical, 10)
    }

    private var table: some View {
        Table(list, selection: $selection) {
            TableColumn(t("Name", "Tên")) { db in
                HStack(spacing: 6) {
                    Text(db.name)
                    if db.name.hasPrefix("test_") {
                        Text(t("tests", "test")).font(.caption2).foregroundStyle(.secondary)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(.quaternary, in: Capsule())
                    }
                }
            }
            TableColumn(t("Size", "Dung lượng")) { db in Text(formatBytes(db.size)).foregroundStyle(.secondary) }
                .width(110)
            TableColumn("") { db in
                HStack(spacing: 12) {
                    Button(t("Open", "Mở")) { store.openBrowser(env, database: db.name) }.disabled(!ready)
                    Button(t("Shell", "Shell")) { store.openShell(env, database: db.name) }
                }
                .buttonStyle(.link)
            }
            .width(110)
        }
        .contextMenu(forSelectionType: Database.ID.self) { ids in
            if let id = ids.first, let db = list.first(where: { $0.id == id }) {
                Button(t("Open in Browser", "Mở trên trình duyệt")) { store.openBrowser(env, database: db.name) }.disabled(!ready)
                Button(t("Odoo Shell", "Odoo Shell")) { store.openShell(env, database: db.name) }
                Divider()
                Button(t("Duplicate…", "Nhân bản…")) { duplicating = db }
                Button(t("Drop…", "Xóa…"), role: .destructive) { dropping = db }
            }
        } primaryAction: { ids in
            if let id = ids.first { store.openBrowser(env, database: id) }
        }
    }
}

struct NotRunning: View {
    @Environment(Store.self) private var store
    let env: EnvConfig
    let what: String

    var body: some View {
        if store.starting(env) || store.status(env)?.running == true {
            ProgressView(t("Starting…", "Đang khởi động…")).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            stopped
        }
    }

    private var stopped: some View {
        ContentUnavailableView {
            Label(t("Not running", "Chưa chạy"), systemImage: "power")
        } description: {
            Text(t("Start the environment to see \(what).", "Hãy khởi động môi trường để xem \(what)."))
        } actions: {
            Button(t("Start", "Khởi động")) { store.start(env) }
                .buttonStyle(.borderedProminent).disabled(store.starting(env) || store.dockerProblem != nil)
        }
    }
}

/// Odoo's rule for database names.
func validDatabaseName(_ name: String) -> Bool {
    name.range(of: "^[A-Za-z0-9][A-Za-z0-9_.-]{0,62}$", options: .regularExpression) != nil
}

struct NewDatabaseSheet: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    let env: EnvConfig
    let existing: [String]
    @State private var name = ""
    @State private var demo = false
    @State private var language = "en_US"

    private var problem: String? {
        if name.isEmpty { return nil }
        if !validDatabaseName(name) { return t("Use letters, digits, _ . - (starting with a letter or digit).", "Dùng chữ, số, _ . - (bắt đầu bằng chữ hoặc số).") }
        if existing.contains(name) { return t("This name is taken.", "Tên này đã có.") }
        return nil
    }

    var body: some View {
        Form {
            TextField(t("Name", "Tên"), text: $name, prompt: Text("dev"))
            Toggle(t("Load demo data", "Nạp dữ liệu demo"), isOn: $demo)
            Picker(t("Language", "Ngôn ngữ"), selection: $language) {
                Text("English").tag("en_US")
                Text("Tiếng Việt").tag("vi_VN")
            }
            if let problem { Text(problem).font(.callout).foregroundStyle(.red) }
            Text(t("Creates the database with base installed, like Odoo's database manager. It takes a minute.",
                   "Tạo database có sẵn module base, như trang quản lý database của Odoo. Mất khoảng một phút."))
                .font(.callout).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button(t("Cancel", "Hủy")) { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button(t("Create", "Tạo")) {
                    store.createDatabase(env, name: name, demo: demo, language: language)
                    dismiss()
                }
                .disabled(name.isEmpty || problem != nil)
            }
        }
    }
}

struct DuplicateSheet: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    let env: EnvConfig
    let source: String
    let existing: [String]
    @State private var name = ""

    private var valid: Bool { validDatabaseName(name) && !existing.contains(name) }

    var body: some View {
        Form {
            LabeledContent(t("Copy of", "Bản sao của"), value: source)
            TextField(t("New name", "Tên mới"), text: $name)
            Text(t("Copies the database and its files. Its open sessions are closed first.",
                   "Sao chép database và file đính kèm. Các phiên đang mở sẽ bị đóng trước."))
                .font(.callout).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .onAppear { name = "\(source)_copy" }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button(t("Cancel", "Hủy")) { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button(t("Duplicate", "Nhân bản")) {
                    store.duplicate(env, source: source, target: name)
                    dismiss()
                }
                .disabled(!valid)
            }
        }
    }
}
