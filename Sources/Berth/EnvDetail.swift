import SwiftUI

enum Tab: String, CaseIterable, Identifiable {
    case databases, modules, logs
    var id: String { rawValue }
    var title: String {
        switch self {
        case .databases: t("Databases", "Database")
        case .modules: t("Modules", "Module")
        case .logs: t("Logs", "Log")
        }
    }
}

struct EnvDetail: View {
    @Environment(Store.self) private var store
    let env: EnvConfig
    @AppStorage("tab") private var tab: Tab = .databases
    @State private var confirmRemove = false

    private var status: EnvStatus? { store.status(env) }
    private var running: Bool { status?.running ?? false }

    private var statusText: String {
        store.starting(env) ? t("Starting…", "Đang khởi động…") : StatusDot(status: status, busy: false).label
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 360)
            .padding(.vertical, 12)
            if let status, status.stale {
                StaleBanner(env: env, running: status.running)
            }
            Divider()
            Group {
                switch tab {
                case .databases: DatabasesView(env: env)
                case .modules: ModulesView(env: env)
                case .logs: LogsView(env: env)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if let job = store.job(for: env) {
                Divider()
                JobPanel(job: job)
            }
        }
        .navigationTitle(env.name)
        .navigationSubtitle("Odoo \(env.version) · localhost:\(String(env.port)) · \(statusText)")
        .toolbar { toolbar }
        .task {
            await store.loadModules(env)
            if running { await store.loadDatabases(env) }
        }
        .confirmationDialog(t("Remove \(env.name)?", "Xóa \(env.name)?"), isPresented: $confirmRemove) {
            Button(t("Remove, keep the databases", "Xóa, giữ lại database")) { store.remove(env, data: false) }
            Button(t("Remove with its databases and files", "Xóa cả database và file"), role: .destructive) { store.remove(env, data: true) }
        } message: {
            Text(t("Your addons folders are not touched.", "Thư mục addons của bạn không bị đụng tới."))
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            if running {
                Button { store.stop(env) } label: { Label(t("Stop", "Dừng"), systemImage: "stop.fill") }
                    .help(t("Stop Odoo and PostgreSQL", "Dừng Odoo và PostgreSQL"))
            } else {
                Button { store.start(env) } label: { Label(t("Start", "Khởi động"), systemImage: "play.fill") }
                    .disabled(store.starting(env) || store.dockerProblem != nil)
                    .help(t("Start Odoo and PostgreSQL", "Khởi động Odoo và PostgreSQL"))
            }
            Button { store.openBrowser(env) } label: { Label(t("Open in Browser", "Mở trên trình duyệt"), systemImage: "safari") }
                .disabled(!(status?.ready ?? false))
                .help(t("Open in the browser", "Mở trên trình duyệt"))
            Menu {
                Button(t("Edit…", "Sửa…")) { store.editing = env }
                Menu(t("Odoo Shell", "Odoo Shell")) {
                    ForEach(store.databases[env.id] ?? []) { db in
                        Button(db.name) { store.openShell(env, database: db.name) }
                    }
                }
                .disabled(!running || (store.databases[env.id] ?? []).isEmpty)
                Divider()
                Button(t("Remove…", "Xóa…"), role: .destructive) { confirmRemove = true }
            } label: {
                Label(t("More", "Thêm"), systemImage: "ellipsis.circle")
            }
        }
    }
}

struct StaleBanner: View {
    @Environment(Store.self) private var store
    let env: EnvConfig
    let running: Bool

    var body: some View {
        HStack {
            Label(t("The settings changed. They apply at the next start.", "Cấu hình đã thay đổi, sẽ áp dụng ở lần khởi động tới."),
                  systemImage: "arrow.triangle.2.circlepath")
            Spacer()
            if running {
                Button(t("Restart now", "Khởi động lại")) { store.start(env) }.disabled(store.starting(env))
            }
        }
        .font(.callout)
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 20).padding(.bottom, 12)
    }
}

struct JobPanel: View {
    @Environment(Store.self) private var store
    let job: RunningJob
    @State private var showOutput = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                icon.frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(job.title).font(.callout.weight(.medium)).lineLimit(1)
                    Text(detail).font(.caption).foregroundStyle(job.finished && !job.ok ? .red : .secondary)
                        .lineLimit(2).textSelection(.enabled)
                }
                Spacer()
                Button(showOutput ? t("Hide output", "Ẩn output") : t("Show output", "Xem output")) { showOutput.toggle() }
                    .buttonStyle(.link).disabled(job.lines.isEmpty)
                if job.finished {
                    Button { store.dismiss(job) } label: { Image(systemName: "xmark") }
                        .buttonStyle(.borderless).help(t("Close", "Đóng"))
                } else {
                    Button(t("Stop", "Dừng")) { store.cancel(job) }
                }
            }
            if showOutput {
                OutputView(lines: job.lines)
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 10)
        .background(.bar)
    }

    private var detail: String {
        guard let status = job.status else { return t("Starting", "Bắt đầu") }
        if status.finished {
            if let error = status.error { return errorText(error) }
            return status.summary ?? t("Done", "Xong")
        }
        return phaseText(status.phase) + "…"
    }

    @ViewBuilder private var icon: some View {
        if !job.finished {
            ProgressView().controlSize(.small)
        } else if job.ok {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        } else {
            Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        }
    }
}

/// The last lines of a job, following the end.
struct OutputView: View {
    let lines: [String]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView([.vertical, .horizontal]) {
                Text(lines.suffix(400).joined(separator: "\n"))
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                Color.clear.frame(height: 1).id("end")
            }
            .frame(height: 180)
            .background(Color(nsColor: .textBackgroundColor).opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
            .onAppear { proxy.scrollTo("end") }
            .onChange(of: lines.count) { proxy.scrollTo("end") }
        }
    }
}
