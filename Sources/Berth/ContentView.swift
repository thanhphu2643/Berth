import SwiftUI

struct ContentView: View {
    @Environment(Store.self) private var store

    var body: some View {
        @Bindable var store = store
        NavigationSplitView {
            List(selection: $store.selection) {
                ForEach(store.envs) { env in
                    EnvRow(env: env, status: store.status(env), busy: store.busy(env)).tag(env.id)
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 230)
            .toolbar {
                ToolbarItem {
                    Button { store.editing = store.newEnvironment() } label: {
                        Label(t("New Environment", "Môi trường mới"), systemImage: "plus")
                    }
                    .help(t("New environment (⌘N)", "Môi trường mới (⌘N)"))
                }
            }
            .safeAreaInset(edge: .bottom) {
                if let problem = store.dockerProblem {
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout).foregroundStyle(.orange)
                        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        } detail: {
            if let env = store.selected {
                EnvDetail(env: env).id(env.id)
            } else {
                Welcome()
            }
        }
        .frame(minWidth: 960, minHeight: 600)
        .sheet(item: $store.editing) { env in EnvEditor(env: env) }
        .sheet(isPresented: $store.showSettings) { SettingsView() }
        .sheet(isPresented: Binding(get: { store.report != nil }, set: { if !$0 { store.report = nil } })) {
            if let report = store.report { UpgradeReportView(title: report.title, findings: report.findings) }
        }
        .alert(t("Something went wrong", "Có lỗi xảy ra"), isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
            Button("OK") { store.error = nil }
        } message: {
            Text(store.error ?? "")
        }
    }
}

struct StatusDot: View {
    let status: EnvStatus?
    let busy: Bool

    var body: some View {
        Circle().fill(color).frame(width: 8, height: 8)
            .overlay { if busy { Circle().stroke(color.opacity(0.4), lineWidth: 3).frame(width: 14, height: 14) } }
            .accessibilityLabel(label)
    }

    private var color: Color {
        guard let status else { return .secondary.opacity(0.4) }
        if status.ready { return .green }
        if status.running { return .orange }
        return .secondary.opacity(0.4)
    }

    var label: String {
        guard let status else { return t("Unknown", "Không rõ") }
        if status.ready { return t("Running", "Đang chạy") }
        if status.running { return t("Starting", "Đang khởi động") }
        return status.odoo == "missing" ? t("Never started", "Chưa chạy lần nào") : t("Stopped", "Đã dừng")
    }
}

struct EnvRow: View {
    let env: EnvConfig
    let status: EnvStatus?
    let busy: Bool

    var body: some View {
        HStack(spacing: 10) {
            StatusDot(status: status, busy: busy)
            VStack(alignment: .leading, spacing: 2) {
                Text(env.name).lineLimit(1)
                Text(verbatim: "Odoo \(env.version) · :\(env.port)").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
    }
}

struct Welcome: View {
    @Environment(Store.self) private var store

    var body: some View {
        ContentUnavailableView {
            Label("Berth", systemImage: "shippingbox")
        } description: {
            Text(t("Odoo development environments in Docker: one per Odoo version and project, with your addons mounted, side by side.",
                   "Môi trường phát triển Odoo trong Docker: mỗi phiên bản và dự án một môi trường, gắn sẵn addons của bạn, chạy song song."))
            if store.tools.docker == nil {
                Text(t("Docker was not found: install Docker Desktop or OrbStack first.",
                       "Không tìm thấy Docker: hãy cài Docker Desktop hoặc OrbStack trước."))
                    .foregroundStyle(.orange)
            }
        } actions: {
            Button(t("New Environment…", "Tạo môi trường…")) { store.editing = store.newEnvironment() }
                .buttonStyle(.borderedProminent)
        }
    }
}
