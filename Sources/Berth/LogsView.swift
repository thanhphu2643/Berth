import AppKit
import SwiftUI

struct LogsView: View {
    enum Level: String, CaseIterable, Identifiable {
        case all, warnings, errors
        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: t("All", "Tất cả")
            case .warnings: t("Warnings and errors", "Cảnh báo và lỗi")
            case .errors: t("Errors", "Lỗi")
            }
        }
    }

    @Environment(Store.self) private var store
    let env: EnvConfig
    @AppStorage("logLevel") private var level: Level = .all
    @AppStorage("logRequests") private var requests = false
    @State private var search = ""
    @State private var follow = true
    @State private var expanded: Set<UInt64> = []

    private var entries: [LogEntry] {
        (store.logs[env.id]?.entries ?? []).filter { entry in
            switch level {
            case .all: break
            case .warnings: guard entry.level == "WARNING" || entry.isProblem else { return false }
            case .errors: guard entry.isProblem else { return false }
            }
            if !requests && entry.isRequest { return false }
            if !search.isEmpty && !entry.text.localizedCaseInsensitiveContains(search) { return false }
            return true
        }
    }

    var body: some View {
        let entries = entries
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Picker(t("Show", "Hiện"), selection: $level) {
                    ForEach(Level.allCases) { Text($0.title).tag($0) }
                }
                .frame(maxWidth: 240)
                Toggle(t("HTTP requests", "Request HTTP"), isOn: $requests).toggleStyle(.checkbox)
                Toggle(t("Follow", "Theo dõi"), isOn: $follow).toggleStyle(.checkbox)
                Spacer()
                TextField(t("Search", "Tìm"), text: $search).textFieldStyle(.roundedBorder).frame(width: 200)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(entries.map(\.text).joined(separator: "\n"), forType: .string)
                } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.borderless).help(t("Copy the shown entries", "Copy các dòng đang hiện"))
                Button { store.clearLogs(env) } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless).help(t("Clear", "Xóa"))
            }
            .padding(.horizontal, 20).padding(.vertical, 10)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(entries) { entry in
                            LogRow(entry: entry, expanded: expanded.contains(entry.seq)) {
                                if expanded.contains(entry.seq) { expanded.remove(entry.seq) } else { expanded.insert(entry.seq) }
                            }
                            .id(entry.seq)
                        }
                    }
                    .padding(.vertical, 6)
                }
                .background(Color(nsColor: .textBackgroundColor))
                .overlay {
                    if entries.isEmpty {
                        ContentUnavailableView(
                            (store.logs[env.id]?.entries ?? []).isEmpty ? t("No log yet", "Chưa có log") : t("Nothing matches", "Không có dòng nào khớp"),
                            systemImage: "text.alignleft",
                            description: Text((store.status(env)?.running ?? false) ? "" : t("The log appears when the environment runs.", "Log sẽ hiện khi môi trường chạy.")))
                    }
                }
                .onChange(of: entries.last?.seq) {
                    if follow, let last = entries.last?.seq { proxy.scrollTo(last, anchor: .bottom) }
                }
                .onAppear { if let last = entries.last?.seq { proxy.scrollTo(last, anchor: .bottom) } }
            }
        }
        .task(id: env.id) {
            while !Task.isCancelled {
                await store.pollLogs(env)
                try? await Task.sleep(for: .milliseconds(800))
            }
        }
    }
}

struct LogRow: View {
    let entry: LogEntry
    let expanded: Bool
    let toggle: () -> Void

    private var color: Color {
        switch entry.level {
        case "ERROR", "CRITICAL": .red
        case "WARNING": .orange
        case "DEBUG": .secondary
        default: .primary
        }
    }

    /// The last line of a traceback: the exception itself.
    private var exception: String? {
        entry.detail.split(separator: "\n").last { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.map(String.init)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if entry.detail.isEmpty {
                    Color.clear.frame(width: 10, height: 1)
                } else {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .bold)).foregroundStyle(.secondary).frame(width: 10)
                }
                Text(entry.time.count > 11 ? String(entry.time.suffix(8)) : entry.time)
                    .foregroundStyle(.tertiary)
                if !entry.level.isEmpty {
                    Text(entry.level).foregroundStyle(color).fontWeight(entry.isProblem ? .bold : .regular)
                        .frame(width: 58, alignment: .leading)
                }
                if !entry.db.isEmpty { Text(entry.db).foregroundStyle(.secondary) }
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.message).foregroundStyle(entry.isProblem ? .red : .primary)
                    if !expanded, let exception, entry.isProblem || entry.level == "WARNING" {
                        Text(exception).foregroundStyle(.red.opacity(0.8)).lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                if !entry.logger.isEmpty {
                    Text(entry.logger).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.head)
                        .frame(maxWidth: 220, alignment: .trailing)
                }
            }
            if expanded {
                Text(entry.detail)
                    .textSelection(.enabled)
                    .foregroundStyle(entry.isProblem ? .red : .secondary)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                    .padding(.leading, 18)
            }
        }
        .font(.system(size: 11.5, design: .monospaced))
        .padding(.horizontal, 14).padding(.vertical, 3)
        .background(entry.isProblem ? Color.red.opacity(0.06) : .clear)
        .contentShape(Rectangle())
        .onTapGesture { if !entry.detail.isEmpty { toggle() } }
        .contextMenu {
            Button(t("Copy", "Copy")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(entry.text, forType: .string)
            }
        }
    }
}
