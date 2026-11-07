import AppKit
import ArchiveCore
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

    /// ArchiveModel 出于安全拒绝覆盖已有文件；用户确认后由调用方先移除再创建。
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
    var onClose: () -> Void

    @StateObject private var model = ArchiveModel()
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
        .onChange(of: model.busy) { busy in
            // 队列排空：成功（状态"已创建 …"）→ 短暂停留让用户看到结果后自动关窗；
            // 失败/取消则停留并展示错误信息。
            if submitted, !busy, model.status.hasPrefix("已创建") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { onClose() }
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
            try? FileManager.default.removeItem(at: url)
        }
        submitted = true
        model.compress(sources: sources, destination: url, options: options,
                       emailAfter: email, openAfter: false)
    }
}

/// 独立对话框窗口控制器（AppKit 承载，与 Benchmark 同因：WindowGroup 场景会为
/// 命令 URL 新开主窗口，故对话框不走 SwiftUI Scene）。
@MainActor
final class CompressDialogController {
    static let shared = CompressDialogController()
    private(set) var window: NSWindow?

    func show(sources: [URL], email: Bool) {
        window?.close()
        let view = StandaloneCompressView(sources: sources, email: email) { [weak self] in
            self?.window?.close()
            self?.window = nil
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 660),
            styleMask: [.titled, .closable],
            backing: .buffered, defer: false)
        window.title = email ? "压缩并邮件" : "添加到压缩包"
        window.contentView = NSHostingView(rootView: view)
        window.center()
        window.isReleasedWhenClosed = false
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}
