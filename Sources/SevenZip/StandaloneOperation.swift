import AppKit
import ArchiveCore
import SwiftUI

/// Finder 右键/服务命令的独立执行器（不开主窗口）。
/// 规则：右键操作里只有「用七压打开」允许弹出主程序；解压/测试/压缩/校验和等
/// 在主窗口已开时仍由窗格执行（进度就地显示），未开时由本控制器承载——
/// 每个命令一个独立小窗，自带 ArchiveModel 队列，成功自动关闭，失败停留报错。
enum StandaloneOperation {
    case extractHere([URL])                 // 解压到当前目录
    case extractToNamedFolders([URL])       // 解压到 "名称/"
    case extractChoosing([URL])             // 解压到…（先弹目录选择）
    case test([URL])                        // 测试压缩包（结果停留展示）
    case compress([URL], format: String)    // 压缩为 "名称.7z/zip"
    case compressAndEmail([URL], format: String)
    case checksum([URL], algorithm: String) // 计算校验和（结果停留展示）

    /// 成功（队列排空且无错误）后是否自动关窗。结果型操作停留。
    var autoCloseOnSuccess: Bool {
        switch self {
        case .test, .checksum: return false
        default: return true
        }
    }

    var title: String {
        switch self {
        case .extractHere, .extractToNamedFolders, .extractChoosing: return "解压"
        case .test: return "测试压缩包"
        case .compress: return "压缩"
        case .compressAndEmail: return "压缩并邮件"
        case .checksum: return "计算校验和"
        }
    }
}

/// 单个命令的执行视图：进度 + 状态 + 日志（测试/校验和/失败时展开）。
struct StandaloneOperationView: View {
    let operation: StandaloneOperation
    /// 由控制器创建并注入（控制器需要在关窗前取消进行中的任务）。
    @ObservedObject var model: ArchiveModel
    var onClose: () -> Void

    @State private var started = false

    /// 测试/校验和需要展示日志；失败时也展开便于排查。
    private var showLog: Bool {
        if model.errorMessage != nil { return true }
        switch operation {
        case .test, .checksum: return true
        default: return false
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(operation.title).font(.title3)
            HStack(spacing: 8) {
                if model.busy {
                    if let fraction = model.progress {
                        ProgressView(value: fraction).frame(width: 140)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
                Text(model.status).font(.callout).foregroundStyle(.secondary)
                    .lineLimit(2).truncationMode(.middle)
                Spacer(minLength: 0)
            }
            if let error = model.errorMessage {
                Text(error).font(.caption).foregroundStyle(.red)
                    .textSelection(.enabled).lineLimit(6)
            }
            if showLog, !model.output.isEmpty {
                ScrollView {
                    Text(model.output).font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minHeight: 120, maxHeight: 220)
                .border(Color.secondary.opacity(0.3))
            }
            HStack {
                Spacer()
                Button(model.busy ? "取消" : "关闭") {
                    if model.busy { model.cancel() } else { onClose() }
                }
                .keyboardShortcut(model.busy ? .cancelAction : .defaultAction)
            }
        }
        .padding(16)
        .frame(width: 460)
        .onAppear(perform: start)
        .onChange(of: model.busy) { busy in
            // 队列排空：成功 → 结果型操作停留，其余 1.2s 后自动关窗；失败停留。
            guard started, !busy, model.errorMessage == nil,
                  operation.autoCloseOnSuccess else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                onClose()
            }
        }
        .onChange(of: model.emailShareURL) { url in
            // 「压缩并邮件」：调出系统邮件分享；未配置邮件则回退 Finder 选中。
            guard let url else { return }
            model.emailShareURL = nil
            if let service = NSSharingService(named: .composeEmail) {
                service.perform(withItems: [url])
            } else {
                NSWorkspace.shared.selectFile(url.path,
                                              inFileViewerRootedAtPath: url.deletingLastPathComponent().path)
                model.warn("系统未配置邮件应用，已在 Finder 中选中生成的压缩包。")
            }
        }
    }

    private func start() {
        guard !started else { return }
        started = true
        switch operation {
        case .extractHere(let urls):
            for archive in urls {
                model.extractArchive(archive, to: archive.deletingLastPathComponent(),
                                     createDirectory: false, conflict: .skip)
            }
        case .extractToNamedFolders(let urls):
            for archive in urls {
                let dest = archive.deletingLastPathComponent()
                    .appendingPathComponent(CompressDestination.baseName(for: [archive]), isDirectory: true)
                model.extractArchive(archive, to: dest, createDirectory: true, conflict: .skip)
            }
        case .extractChoosing(let urls):
            guard let dest = chooseFolder() else { onClose(); return }
            for archive in urls {
                model.extractArchive(archive, to: dest, createDirectory: false, conflict: .skip)
            }
        case .test(let urls):
            for archive in urls { model.testArchive(archive) }
        case .compress(let urls, let format):
            compress(urls: urls, format: format, email: false)
        case .compressAndEmail(let urls, let format):
            compress(urls: urls, format: format, email: true)
        case .checksum(let urls, let algorithm):
            model.checksumFiles(urls, algorithm: algorithm)
        }
    }

    /// 免确认压缩：目标与源同目录，重名自动追加 -2/-3…（对齐主窗口内逻辑）。
    private func compress(urls: [URL], format: String, email: Bool) {
        guard let first = urls.first else { return }
        let parent = first.deletingLastPathComponent()
        let base = CompressDestination.baseName(for: urls)
        var options = CompressionOptions()
        options.format = ArchiveFormat(rawValue: format) ?? (email ? .sevenZip : .zip)
        var destination = parent.appendingPathComponent("\(base).\(options.format.rawValue)")
        var suffix = 2
        while FileManager.default.fileExists(atPath: destination.path) {
            destination = parent.appendingPathComponent("\(base)-\(suffix).\(options.format.rawValue)")
            suffix += 1
        }
        model.compress(sources: urls, destination: destination, options: options,
                       emailAfter: email, openAfter: false)
    }

    private func chooseFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "选择解压目标目录"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url : nil
    }
}

/// 命令窗口控制器：每次命令一个实例，窗口关闭后自释放。
@MainActor
final class StandaloneOperationController: NSObject, NSWindowDelegate {
    /// 存活的控制器表（窗口开着就持有，关闭即移除；ObjectIdentifier 不 retain，
    /// 必须存控制器本体，否则控制器提前释放、自动关窗失效）。
    private static var live: [ObjectIdentifier: StandaloneOperationController] = [:]

    static func run(_ operation: StandaloneOperation) {
        let controller = StandaloneOperationController(operation: operation)
        live[ObjectIdentifier(controller)] = controller
        controller.show()
    }

    private let operation: StandaloneOperation
    private let model = ArchiveModel()
    private var window: NSWindow?

    private init(operation: StandaloneOperation) {
        self.operation = operation
        super.init()
    }

    private func show() {
        let view = StandaloneOperationView(operation: operation, model: model) { [weak self] in
            self?.close()
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 200),
            styleMask: [.titled, .closable],
            backing: .buffered, defer: false)
        window.title = operation.title
        window.contentView = NSHostingView(rootView: view)
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = self
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func close() {
        window?.close()
    }

    /// 任务进行中关窗 = 取消：否则 7zz 成孤儿继续写盘，用户却以为已取消。
    nonisolated func windowShouldClose(_ sender: NSWindow) -> Bool {
        Task { @MainActor in self.model.cancel() }
        return true
    }

    nonisolated func windowWillClose(_ notification: Notification) {
        Task { @MainActor in
            self.window = nil
            Self.live.removeValue(forKey: ObjectIdentifier(self))
        }
    }
}
