import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// 「文件类型关联」独立窗口（对标 Windows 7-Zip「选项 → 文件关联」页）。
///
/// 形态照搬那张参考图的核心结构：
/// - 上方说明「使用七压关联的文件类型」；
/// - 中间一张表：左列是类型（图标 + 扩展名），右列是当前归属（谁来打开它）；
/// - 「+」添加类型；选中行后可改成七压 / 换成别的应用 / 恢复系统默认。
///
/// macOS 的对应关系：Windows 表格里的「所有者」列 = LaunchServices 里
/// 该 UTI 的默认打开程序。改归属要走 NSWorkspace.setDefaultApplication，
/// 系统会弹确认框，这和 Windows 改关联时的提示是对应的。
struct AssociationDialogView: View {
    @Environment(\.dismiss) private var dismiss
    var onClose: () -> Void = {}

    @State private var entries: [FileAssociation.Entry] = []
    @State private var selection: String?
    @State private var message = ""
    @State private var showAdd = false
    /// 「添加类型」里的可选清单：清单之外、但 7-Zip 也能处理的扩展名。
    @State private var addable: [String] = []

    private var selected: FileAssociation.Entry? {
        guard let selection else { return nil }
        return entries.first { $0.ext == selection }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("使用七压关联的文件类型")
                .font(.headline)
            Text("改动后由系统确认归属（LaunchServices），与 Windows 改关联时弹确认框对应。")
                .font(.caption).foregroundStyle(.secondary)

            // 表：类型 | 当前归属
            HSplitView {
                table
                    .frame(minWidth: 380)
                detail
                    .frame(minWidth: 260)
            }
            .frame(height: 320)

            if !message.isEmpty {
                Text(message).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            HStack {
                Button { showAdd = true } label: {
                    Label("添加类型", systemImage: "plus")
                }
                .popover(isPresented: $showAdd, arrowEdge: .bottom) {
                    addList
                }
                Spacer()
                Button("完成") { onClose(); dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 720, height: 460)
        .onAppear { refresh() }
    }

    // MARK: - 表

    private var table: some View {
        Table(entries, selection: $selection) {
            TableColumn("类型") { entry in
                HStack(spacing: 6) {
                    Image(nsImage: FileIcons.image(forExtension: entry.ext))
                        .resizable().frame(width: 16, height: 16)
                    Text("." + entry.ext).monospaced()
                }
            }
            TableColumn("当前打开方式") { entry in
                HStack(spacing: 6) {
                    if let icon = entry.handlerIcon {
                        Image(nsImage: icon).resizable().frame(width: 16, height: 16)
                    }
                    Text(entry.handlerName)
                    if entry.isOurs {
                        Text("（七压）")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    // MARK: - 右侧操作区

    @ViewBuilder
    private var detail: some View {
        if let entry = selected {
            VStack(alignment: .leading, spacing: 10) {
                Text("." + entry.ext).font(.title3.monospaced())
                Text("当前由「\(entry.handlerName)」打开")
                    .font(.caption).foregroundStyle(.secondary)

                Button {
                    FileAssociation.bind(ext: entry.ext) { ok in
                        message = ok ? "已把 .\(entry.ext) 关联到七压。"
                                     : "系统拒绝了这次更改（.\(entry.ext)）。"
                        refresh()
                    }
                } label: {
                    Label("设为七压", systemImage: "archivebox")
                }
                .disabled(entry.isOurs)

                Button {
                    FileAssociation.remove(ext: entry.ext) { ok in
                        message = ok ? "已把 .\(entry.ext) 恢复为系统默认打开方式。"
                                     : "恢复 .\(entry.ext) 的默认打开方式失败。"
                        refresh()
                    }
                } label: {
                    Label("恢复系统默认", systemImage: "arrow.uturn.backward")
                }
                .disabled(entry.isOurs)

                Divider()

                Text("更改为其他应用").font(.caption).foregroundStyle(.secondary)
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(FileAssociation.candidateHandlers(ext: entry.ext), id: \.self) { app in
                            Button {
                                FileAssociation.setHandler(app: app, ext: entry.ext) { ok in
                                    message = ok ? "已把 .\(entry.ext) 改为由「\(app.deletingPathExtension().lastPathComponent)」打开。"
                                                 : "系统拒绝了这次更改（.\(entry.ext)）。"
                                    refresh()
                                }
                            } label: {
                                HStack(spacing: 6) {
                                    Image(nsImage: NSWorkspace.shared.icon(forFile: app.path))
                                        .resizable().frame(width: 16, height: 16)
                                    Text(app.deletingPathExtension().lastPathComponent)
                                    Spacer()
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(height: 150)
            }
            .padding(.leading, 4)
        } else {
            VStack {
                Spacer()
                Text("选择一种格式查看关联设置").foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - 添加类型

    private var addList: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("添加类型").font(.headline).padding(10)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(addable, id: \.self) { ext in
                        Button {
                            showAdd = false
                            FileAssociation.bind(ext: ext) { ok in
                                message = ok ? "已把 .\(ext) 关联到七压。"
                                             : "系统拒绝了这次更改（.\(ext)）。"
                                refresh()
                            }
                        } label: {
                            Text("." + ext).monospaced().padding(.horizontal, 10).padding(.vertical, 4)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(width: 160, height: 220)
        }
    }

    private func refresh() {
        entries = FileAssociation.status()
        // 「添加类型」只列清单之外、且还没被七压接管的扩展名。
        let known = Set(FileAssociation.supported.map(\.ext))
        let ours = Set(entries.filter { $0.isOurs }.map { $0.ext })
        addable = ["dmg", "lha", "arj", "z", "war", "xar", "pak", "sit", "sea", "hqx"]
            .filter { !known.contains($0) && !ours.contains($0) }
    }
}

/// 独立窗口控制器（AppKit 承载；与压缩对话框同因：命令 URL 冷启动时
/// 不能依赖主窗口存在）。
@MainActor
final class AssociationWindowController: NSObject, NSWindowDelegate {
    static let shared = AssociationWindowController()
    private(set) var window: NSWindow?

    func show() {
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 460),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = "文件类型关联"
        window.contentView = NSHostingView(rootView: AssociationDialogView { [weak self, weak window] in
            guard let self, let window, self.window === window else { return }
            self.window = nil
            window.close()
        })
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = self
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    nonisolated func windowWillClose(_ notification: Notification) {
        MainActor.assumeIsolated { self.window = nil }
    }
}
