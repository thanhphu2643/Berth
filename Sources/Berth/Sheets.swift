import AppKit
import SwiftUI

struct EnvEditor: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State var env: EnvConfig
    @State private var counts: [String: Int] = [:]

    init(env: EnvConfig) {
        _env = State(initialValue: env)
    }

    private var existing: EnvConfig? { store.envs.first { $0.id == env.id } }
    private var portTakenBy: EnvConfig? { store.envs.first { $0.id != env.id && $0.port == env.port } }
    private var valid: Bool {
        !env.name.trimmingCharacters(in: .whitespaces).isEmpty && (1024...65535).contains(env.port) && portTakenBy == nil
    }

    var body: some View {
        Form {
            Section {
                TextField(t("Name", "Tên"), text: $env.name, prompt: Text(t("Client project", "Dự án khách hàng")))
                Picker(t("Odoo version", "Phiên bản Odoo"), selection: $env.version) {
                    ForEach([16, 17, 18], id: \.self) { Text(verbatim: "Odoo \($0)").tag($0) }
                }
                .pickerStyle(.segmented)
                if let existing, existing.version != env.version {
                    Text(t("Its databases were made by Odoo \(existing.version): Odoo \(env.version) cannot open them without a migration. Create new ones after the change.",
                           "Các database hiện có được tạo bởi Odoo \(existing.version): Odoo \(env.version) không mở được nếu chưa nâng cấp dữ liệu. Hãy tạo database mới sau khi đổi."))
                        .font(.callout).foregroundStyle(.orange)
                }
                TextField(t("Port", "Cổng"), value: $env.port, format: .number.grouping(.never))
                if let other = portTakenBy {
                    Text(t("\(other.name) uses this port.", "\(other.name) đang dùng cổng này.")).font(.callout).foregroundStyle(.red)
                }
            }
            Section {
                ForEach(env.addons, id: \.self) { folder in
                    HStack {
                        Image(systemName: "folder").foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(URL(fileURLWithPath: folder).lastPathComponent)
                            Text(folder).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                        if let count = counts[folder] {
                            Text(count == 1 ? t("1 module", "1 module") : t("\(count) modules", "\(count) module"))
                                .font(.caption).foregroundStyle(count == 0 ? .orange : .secondary)
                        }
                        Button { env.addons.removeAll { $0 == folder } } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                    }
                }
                Button(t("Add Folder…", "Thêm thư mục…")) { addFolders() }
            } header: {
                Text(t("Addons folders", "Thư mục addons"))
            } footer: {
                Text(t("Folders of modules, or a module itself. They are mounted into Odoo as they are: edits show up without copying.",
                       "Thư mục chứa module, hoặc chính một module. Được gắn thẳng vào Odoo: sửa code là thấy ngay, không cần copy."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle(t("Developer mode", "Chế độ developer"), isOn: $env.dev)
                Text(t("Restarts Odoo when Python files change, and reads views and templates from disk (--dev=reload,xml,qweb).",
                       "Tự khởi động lại Odoo khi file Python thay đổi, và đọc view, template trực tiếp từ ổ đĩa (--dev=reload,xml,qweb)."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .frame(minHeight: 460)
        .onChange(of: env.version) { old, new in
            // Follow the version in the suggested port while the user has not chosen one.
            if env.port == 8000 + old || env.port == store.suggestedPort(version: old, except: env.id) {
                env.port = store.suggestedPort(version: new, except: env.id)
            }
            if env.name == "Odoo \(old)" { env.name = "Odoo \(new)" }
        }
        .task(id: env.addons) {
            for folder in env.addons where counts[folder] == nil {
                counts[folder] = (try? await offMain { try Core.modules([folder]) })?.count ?? 0
            }
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button(t("Cancel", "Hủy")) { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button(existing == nil ? t("Create", "Tạo") : t("Save", "Lưu")) {
                    env.name = env.name.trimmingCharacters(in: .whitespaces)
                    store.save(env)
                    dismiss()
                }
                .disabled(!valid)
            }
        }
    }

    private func addFolders() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = t("Add", "Thêm")
        panel.message = t("Choose folders of Odoo modules", "Chọn thư mục chứa module Odoo")
        guard panel.runModal() == .OK else { return }
        for url in panel.urls where !env.addons.contains(url.path) {
            env.addons.append(url.path)
        }
    }
}

struct UpgradeReportView: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let findings: [UpgradeFinding]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    Text(summary).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button(t("Done", "Xong")) { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(16)
            Divider()
            if findings.isEmpty {
                ContentUnavailableView(t("Nothing to change", "Không cần sửa gì"), systemImage: "checkmark.seal",
                                       description: Text(t("No rule matched this module. Still run its tests on the new version.",
                                                           "Không có quy tắc nào khớp. Vẫn nên chạy test trên phiên bản mới.")))
            } else {
                List(findings) { finding in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            Tag(text: finding.severity.uppercased(), color: finding.severity == "error" ? .red : .orange)
                            Text(verbatim: "\(finding.path):\(finding.line)").font(.callout.monospaced())
                            Text(finding.rule).font(.caption.monospaced()).foregroundStyle(.tertiary)
                        }
                        Text(finding.message)
                        if !finding.fix.isEmpty {
                            HStack(alignment: .top) {
                                Text(finding.fix).font(.system(size: 11.5, design: .monospaced)).textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Button { copy(finding.fix) } label: { Image(systemName: "doc.on.doc") }
                                    .buttonStyle(.borderless).help(t("Copy", "Copy"))
                            }
                            .padding(8)
                            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .frame(width: 720, height: 520)
    }

    private var summary: String {
        let errors = findings.filter { $0.severity == "error" }.count
        let warnings = findings.count - errors
        return t("\(errors) errors, \(warnings) warnings · Preflight", "\(errors) lỗi, \(warnings) cảnh báo · Preflight")
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

struct SettingsView: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Bindable private var lang = Lang.shared

    var body: some View {
        Form {
            Picker(t("Language", "Ngôn ngữ"), selection: $lang.choice) {
                Text(t("System", "Theo hệ thống")).tag(Language.system)
                Text("English").tag(Language.en)
                Text("Tiếng Việt").tag(Language.vi)
            }
            Section(t("Tools", "Công cụ")) {
                LabeledContent("Docker", value: store.tools.docker ?? t("not found", "không tìm thấy"))
                LabeledContent("Preflight", value: store.tools.upgradeCheck ?? t("not installed", "chưa cài"))
                if store.tools.upgradeCheck == nil {
                    Text(t("Install it to check modules for the next Odoo version:", "Cài để kiểm tra module cho phiên bản Odoo tiếp theo:"))
                        .font(.caption).foregroundStyle(.secondary)
                    Text(verbatim: "pipx install git+https://github.com/thanhphu2643/odoo-preflight")
                        .font(.caption.monospaced()).textSelection(.enabled)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) { Button(t("Done", "Xong")) { dismiss() } }
        }
    }
}
