import AppKit
import ArchiveCore
import Combine
import SwiftUI

/// 「添加到压缩包」双栏表单：主窗口内 sheet 与 Finder 右键独立对话框共用，
/// 布局对齐参考项目 window-add-to-archive（左栏编码参数，右栏模式/选项/加密）。
struct CompressFormView: View {
    @Binding var options: CompressionOptions
    @Binding var passwordConfirm: String
    @Binding var showCompressPassword: Bool
    @Binding var archiveDestPath: String
    var onBrowse: () -> Void = {}

    static let labelWidth: CGFloat = 96
    static let controlWidth: CGFloat = 200

    var passwordsMatch: Bool { options.password.isEmpty || options.password == passwordConfirm }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // 归档路径：目录标签 + 路径输入 + 浏览（对齐参考图 Archive 行）。
            Text(URL(fileURLWithPath: archiveDestPath).deletingLastPathComponent().path)
                .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            HStack(spacing: 8) {
                Text("归档:").frame(width: Self.labelWidth, alignment: .leading)
                TextField("归档路径", text: $archiveDestPath)
                Button("…") { onBrowse() }.frame(width: 28)
            }
            HStack(alignment: .top, spacing: 28) {
                leftColumn
                rightColumn
            }
        }
        .onChange(of: options.format) { newFormat in
            archiveDestPath = ((archiveDestPath as NSString).deletingPathExtension as String)
                + "." + newFormat.rawValue
            if newFormat == .tar { options.password = ""; passwordConfirm = "" }
        }
    }

    @ViewBuilder
    private func labelRow<Content: View>(_ title: String,
                                         @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title).frame(width: Self.labelWidth, alignment: .leading)
            content()
            Spacer(minLength: 0)
        }
    }

    /// 左侧栏：格式/级别/方法/字典/词长/固实块/线程/内存估算/分卷/参数。
    private var leftColumn: some View {
        VStack(alignment: .leading, spacing: 8) {
            labelRow("压缩格式:") {
                Picker("", selection: $options.format) {
                    ForEach(ArchiveFormat.allCases) { Text($0.title).tag($0) }
                }.labelsHidden().frame(width: Self.controlWidth)
            }
            labelRow("压缩级别:") {
                Picker("", selection: $options.level) {
                    ForEach(0...9, id: \.self) { Text(CompressionOptions.levelTitle($0)).tag($0) }
                }.labelsHidden().frame(width: Self.controlWidth)
            }
            if options.format != .tar {
                labelRow("压缩方法:") {
                    Picker("", selection: $options.method) {
                        ForEach(CompressionOptions.methodChoices(for: options.format), id: \.self) { m in
                            Text(m.isEmpty ? "默认" : (m == "Copy" ? "Copy（仅存储）" : m)).tag(m)
                        }
                    }.labelsHidden().frame(width: Self.controlWidth)
                }
                labelRow("字典大小:") {
                    Picker("", selection: $options.dictionaryMB) {
                        Text("默认").tag(0)
                        ForEach([1, 4, 8, 16, 32, 64, 128], id: \.self) { Text("\($0) MB").tag($0) }
                    }.labelsHidden().frame(width: Self.controlWidth)
                }
                labelRow("词长:") {
                    Picker("", selection: $options.wordSize) {
                        Text("默认").tag(0)
                        ForEach([32, 64, 128, 273], id: \.self) { Text("\($0)").tag($0) }
                    }.labelsHidden().frame(width: Self.controlWidth)
                }
                if options.format == .sevenZip {
                    labelRow("固实块大小:") {
                        Picker("", selection: $options.solidBlockMB) {
                            ForEach(CompressionOptions.solidBlockChoices, id: \.self) {
                                Text(CompressionOptions.solidBlockTitle($0)).tag($0)
                            }
                        }.labelsHidden().frame(width: Self.controlWidth)
                    }
                }
                labelRow("CPU 线程数:") {
                    HStack(spacing: 6) {
                        Picker("", selection: $options.threads) {
                            Text("自动").tag(0)
                            ForEach(1...max(ProcessInfo.processInfo.processorCount, 1), id: \.self) {
                                Text("\($0)").tag($0)
                            }
                        }.labelsHidden().frame(width: 110)
                        Text("/ \(ProcessInfo.processInfo.processorCount)").foregroundStyle(.secondary)
                    }
                }
                if let estimate = memoryEstimate {
                    Text(estimate).font(.caption).foregroundStyle(.secondary)
                }
            }
            labelRow("分卷大小（MB):") {
                TextField("", value: $options.volumeMB, format: .number)
                    .frame(width: Self.controlWidth)
            }
            labelRow("参数:") {
                TextField("透传给 7zz 的额外开关", text: $options.extraParams)
                    .frame(width: Self.controlWidth)
            }
            Spacer(minLength: 0)
        }
    }

    /// 右侧栏：更新模式/路径模式/选项/加密。
    private var rightColumn: some View {
        VStack(alignment: .leading, spacing: 8) {
            if options.format != .tar {
                labelRow("更新模式:") {
                    Picker("", selection: $options.updateMode) {
                        ForEach(UpdateMode.allCases) { Text($0.title).tag($0) }
                    }.labelsHidden().frame(width: Self.controlWidth)
                }
            }
            labelRow("路径模式:") {
                Picker("", selection: $options.keepTopName) {
                    Text("相对路径名").tag(true)
                    Text("不含顶层文件夹").tag(false)
                }.labelsHidden().frame(width: Self.controlWidth)
            }
            GroupBox("选项") {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("压缩共享文件（-ssw）", isOn: $options.compressSharedFiles)
                    Toggle("排除 .DS_Store 和 __MACOSX", isOn: $options.excludeMacMetadata)
                    Toggle("排除 Mac 资源叉（._* 文件）", isOn: $options.excludeResourceForks)
                    Toggle("压缩成功后删除源文件", isOn: $options.deleteAfterCompress)
                    if options.deleteAfterCompress {
                        Text("源文件将被永久删除（不进废纸篓）。")
                            .font(.caption).foregroundStyle(.red)
                    }
                }.padding(6)
            }
            GroupBox("加密") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("输入密码:").font(.callout)
                    passwordField(text: $options.password)
                    Text("再次输入:").font(.callout)
                    passwordField(text: $passwordConfirm)
                    HStack {
                        Toggle("显示密码", isOn: $showCompressPassword)
                        if !passwordsMatch {
                            Text("两次输入不一致").foregroundStyle(.red).font(.caption)
                        }
                    }
                    if options.format == .zip, !options.password.isEmpty {
                        Picker("加密方法", selection: $options.zipEncryption) {
                            Text("AES-256").tag("AES256")
                            Text("ZipCrypto（兼容旧系统）").tag("ZipCrypto")
                        }
                    }
                    if options.format == .sevenZip {
                        Toggle("同时加密文件名", isOn: $options.encryptFileNames)
                            .disabled(options.password.isEmpty)
                    }
                }.padding(6)
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func passwordField(text: Binding<String>) -> some View {
        if showCompressPassword {
            TextField("", text: text)
        } else {
            SecureField("", text: text)
        }
    }

    /// 字典选定且方法为 LZMA 系时的内存占用估算（压缩 ≈ 字典×11，解压 ≈ 字典）。
    private var memoryEstimate: String? {
        guard options.dictionaryMB > 0 else { return nil }
        let method = options.method.isEmpty
            ? (options.format == .sevenZip ? "LZMA2" : "Deflate") : options.method
        guard ["LZMA2", "LZMA"].contains(method) else { return nil }
        return "内存占用估算：压缩 ≈ \(options.dictionaryMB * 11) MB · 解压 ≈ \(options.dictionaryMB) MB"
    }
}

/// 覆盖已有归档时的原文件暂存。
///
/// 不能「先删旧文件再建新文件」：压缩可能失败（磁盘满、源文件不可读、
/// 参数非法），那样原归档就永久丢失了。改为把旧文件移到同目录的备份名，
/// 压缩成功后删除备份，失败或取消则还原原文件。
@MainActor
final class OverwriteBackup {
    private(set) var original: URL?
    private(set) var backup: URL?

    /// 已有文件则移到备份名；成功返回 true。失败返回 false（调用方应中止）。
    func take(_ url: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return true }
        let backupURL = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).七压备份")
        do {
            if FileManager.default.fileExists(atPath: backupURL.path) {
                try FileManager.default.removeItem(at: backupURL)
            }
            try FileManager.default.moveItem(at: url, to: backupURL)
        } catch {
            NSLog("[七压] 备份已有归档失败：\(error.localizedDescription)")
            return false
        }
        original = url
        backup = backupURL
        return true
    }

    /// 压缩成功：原文件已被新归档取代，删掉备份。
    func discard() {
        guard let backup else { return }
        try? FileManager.default.removeItem(at: backup)
        original = nil
        self.backup = nil
    }

    /// 压缩失败/取消/中途关窗：还原原文件。
    ///
    /// 7zz 失败时可能已在目标路径留下半截文件，必须先删掉再还原备份。
    func restore() {
        guard let original, let backup else { return }
        if FileManager.default.fileExists(atPath: original.path) {
            try? FileManager.default.removeItem(at: original)
        }
        try? FileManager.default.moveItem(at: backup, to: original)
        self.original = nil
        self.backup = nil
    }
}

/// 目标路径解析与覆盖确认的共用逻辑。
enum CompressDestination {
    /// 扩展名与所选格式保持一致（用户手改路径时兜底）。
    static func normalize(_ raw: String, format: ArchiveFormat) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        var url = URL(fileURLWithPath: trimmed)
        if url.pathExtension.lowercased() != format.rawValue {
            url = url.deletingPathExtension().appendingPathExtension(format.rawValue)
        }
        return url
    }

    /// ArchiveModel 出于安全拒绝覆盖已有文件；用户确认后由调用方先备份再创建。
    static func confirmOverwrite(_ url: URL) -> Bool {
        let alert = NSAlert()
        alert.messageText = "替换已存在的归档？"
        alert.informativeText = "「\(url.lastPathComponent)」已存在，替换后原内容不可恢复。"
        alert.addButton(withTitle: "替换")
        alert.addButton(withTitle: "取消")
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// 默认路径：源文件父目录 + 基础名 + 格式扩展名。
    static func defaultPath(sources: [URL], format: ArchiveFormat) -> String {
        guard let first = sources.first else { return "" }
        return first.deletingLastPathComponent()
            .appendingPathComponent(Self.baseName(for: sources) + "." + format.rawValue).path
    }

    /// 基础名：单选取文件名（剥离 .tar.gz 等复合扩展名），多选统一为 Archive。
    static func baseName(for urls: [URL]) -> String {
        guard let first = urls.first, urls.count == 1 else { return "Archive" }
        let name = first.lastPathComponent
        let lower = name.lowercased()
        for compound in [".tar.gz", ".tar.bz2", ".tar.xz", ".tgz"] where lower.hasSuffix(compound) {
            return String(name.dropLast(compound.count))
        }
        return first.deletingPathExtension().lastPathComponent
    }
}

/// Finder 右键「添加到压缩包…/压缩并邮件…」的独立对话框（不打开主窗口）。
/// 自带 ArchiveModel 执行队列，进度与状态在对话框内呈现，成功后自动关闭。
struct StandaloneCompressView: View {
    let sources: [URL]
    let email: Bool
    /// 由 CompressDialogController 注入（控制器需要查询忙闲）。
    @ObservedObject var model: ArchiveModel
    /// 覆盖已有归档时的原文件暂存（由控制器注入，视图与控制器共用一份）。
    let backup: OverwriteBackup
    var onClose: () -> Void

    @State private var options = CompressionOptions()
    @State private var passwordConfirm = ""
    @State private var showCompressPassword = false
    @State private var archiveDestPath = ""
    @State private var submitted = false

    private var form: CompressFormView {
        CompressFormView(options: $options, passwordConfirm: $passwordConfirm,
                         showCompressPassword: $showCompressPassword,
                         archiveDestPath: $archiveDestPath, onBrowse: browse)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("添加到压缩包").font(.title2)
            Text("选中 \(sources.count) 个项目").foregroundStyle(.secondary).font(.callout)
            form
            // 失败/警告的具体原因（否则只有一句毫无信息的「操作失败」）。
            if let error = model.errorMessage {
                Text(error).font(.caption).foregroundStyle(.red)
                    .textSelection(.enabled).lineLimit(6)
            }
            HStack(spacing: 12) {
                if model.busy {
                    if let fraction = model.progress {
                        ProgressView(value: fraction).frame(width: 130)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
                Text(model.status).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Button("取消") {
                    if model.busy { model.cancel() } else { onClose() }
                }
                .keyboardShortcut(.cancelAction)
                Button("创建") { submit() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.busy || !form.passwordsMatch
                              || archiveDestPath.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 720, height: 620)
        .onAppear { archiveDestPath = CompressDestination.defaultPath(sources: sources, format: options.format) }
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
        .onChange(of: model.busy) { busy in
            // 队列排空：成功（状态"已创建 …"）→ 短暂停留让用户看到结果后自动关窗；
            // 失败/取消/警告（errorMessage 非空，如未配置邮件）则停留展示。
            guard submitted, !busy else { return }
            if model.status.hasPrefix("已创建") {
                // 成功：原归档已被新归档取代，备份可以删了。
                backup.discard()
                if model.errorMessage == nil {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { onClose() }
                }
            } else {
                // 失败/取消：还原原归档（压缩可能已在目标路径留下半截文件）。
                backup.restore()
            }
        }
    }

    private func browse() {
        let panel = NSSavePanel()
        panel.title = "保存新压缩包"
        panel.nameFieldStringValue = URL(fileURLWithPath: archiveDestPath).lastPathComponent
        panel.directoryURL = URL(fileURLWithPath: archiveDestPath).deletingLastPathComponent()
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url { archiveDestPath = url.path }
    }

    private func submit() {
        guard let url = CompressDestination.normalize(archiveDestPath, format: options.format) else {
            model.warn("请填写归档保存路径。")
            return
        }
        if FileManager.default.fileExists(atPath: url.path) {
            guard CompressDestination.confirmOverwrite(url) else { return }
            // 不直接删旧归档：压缩可能失败（磁盘满、源文件不可读、参数非法），
            // 那样原归档就永久没了。改为移到备份名，成功后再删，失败则还原。
            guard backup.take(url) else {
                model.warn("无法备份已存在的压缩包，已取消操作。")
                return
            }
        }
        submitted = true
        model.compress(sources: sources, destination: url, options: options,
                       emailAfter: email, openAfter: false)
        // compress 可能在建命令时就同步失败（此时 busy 从未变 true）：
        // 没有任务在跑 → 立即还原备份。
        if !model.busy { backup.restore() }
    }
}

/// 独立对话框窗口控制器（AppKit 承载，与 Benchmark 同因：WindowGroup 场景会为
/// 命令 URL 新开主窗口，故对话框不走 SwiftUI Scene）。
@MainActor
final class CompressDialogController: NSObject, NSWindowDelegate {
    static let shared = CompressDialogController()
    private(set) var window: NSWindow?
    /// 由控制器创建并注入视图，便于在 show() 时查询忙闲。
    private var model: ArchiveModel?
    /// 覆盖已有归档时的原文件暂存（视图与控制器共用一份）。
    private var backup = OverwriteBackup()
    /// 压缩进行中时到来的新请求：不能丢弃（用户会以为文件没被识别），
    /// 暂存到队列，当前任务结束后再弹。
    private var pendingRequest: (sources: [URL], email: Bool)?
    /// 监听引擎忙闲：任务结束后弹出排队中的新请求。
    private var busyObserver: AnyCancellable?

    func show(sources: [URL], email: Bool) {
        // 压缩进行中不销毁旧窗口（否则 7zz 成孤儿、进度归零）：
        // 把进行中的对话框带到前面，用户可等待或取消后重试。
        if model?.busy == true {
            pendingRequest = (sources, email)
            if let window {
                NSApp.activate(ignoringOtherApps: true)
                window.makeKeyAndOrderFront(nil)
            }
            return
        }
        window?.close()
        backup = OverwriteBackup()
        let model = ArchiveModel()
        self.model = model
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 660),
            styleMask: [.titled, .closable],
            backing: .buffered, defer: false)
        // onClose 必须绑定本窗口实例：成功后 1.2s 的自动关窗定时器触发时，
        // 用户可能已打开新对话框，经单例间接寻址会把新窗口误关。
        let view = StandaloneCompressView(sources: sources, email: email, model: model,
                                          backup: backup, onClose: { [weak self, weak window] in
            guard let self, let window, self.window === window else { return }
            self.window = nil
            self.model = nil
            window.close()
        })
        window.title = email ? "压缩并邮件" : "添加到压缩包"
        window.contentView = NSHostingView(rootView: view)
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = self
        self.window = window
        // 引擎忙闲：任务结束后把排队中的新请求弹出来（压缩进行中时
        // 右键另一批文件不能被丢弃）。
        var wasBusy = false
        busyObserver = model.$busy.sink { [weak self] busy in
            guard let self else { return }
            if busy { wasBusy = true; return }
            guard wasBusy else { return }
            wasBusy = false
            guard let pending = self.pendingRequest else { return }
            self.pendingRequest = nil
            self.show(sources: pending.sources, email: pending.email)
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// 任务进行中点红钮关窗 = 取消：否则 7zz 成孤儿继续写盘，
    /// 用户却以为压缩已停止（与 StandaloneOperation 同款处理）。
    ///
    /// 取消必须**同步**执行：本回调虽在主线程，但若把 cancel 排进 Task，
    /// windowWillClose 会先同步把 model 置空，Task 执行时 model 已是 nil，
    /// 取消就丢了 —— 7zz 继续跑，勾了「压缩成功后删除源文件」时还会删掉
    /// 用户以为已经取消的源文件。
    nonisolated func windowShouldClose(_ sender: NSWindow) -> Bool {
        MainActor.assumeIsolated { self.model?.cancel() }
        return true
    }

    /// 关窗后释放 window/model 引用，下次 show() 重建。同步执行
    /// （本回调本就在主线程）：show() 的重建路径先 close() 旧窗再赋新窗，
    /// 异步置空会把刚建好的新窗口误清。
    nonisolated func windowWillClose(_ notification: Notification) {
        MainActor.assumeIsolated {
            // 收尾覆盖前的原归档：成功则删备份，失败/取消则还原。
            // 判据用 model 的最终状态——成功通知可能还没送到视图，
            // 此时若按「有备份就还原」处理，会用旧归档盖掉刚生成的新归档。
            if let model = self.model {
                if model.status.hasPrefix("已创建") { self.backup.discard() }
                else { self.backup.restore() }
            }
            self.window = nil
            self.model = nil
            self.busyObserver = nil
        }
    }
}
