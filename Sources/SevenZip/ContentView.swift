import AppKit
import ArchiveCore
import QuickLook
import SwiftUI

/// 7-Zip File Manager (Windows) interaction paradigm, on macOS:
/// single-pane file list, large-icon toolbar, address bar, status bar.
/// Archives open like folders; ".." climbs back out to the disk.
struct ContentView: View {
    @EnvironmentObject private var model: ArchiveModel
    @EnvironmentObject private var actions: AppActions

    // Navigation: either browsing the local disk or inside the opened archive.
    @State private var inArchive = false
    @State private var currentDir = FileManager.default.homeDirectoryForCurrentUser
    @State private var dirFiles: [URL] = []
    @State private var dirError = ""
    @State private var innerFolder = ""
    @State private var history: [String] = []

    @State private var selected = Set<String>()
    @State private var archivePassword = ""
    @State private var conflict: ConflictPolicy = .skip
    @State private var options = CompressionOptions()
    @State private var sourcesForCompression: [URL] = []
    @State private var batchCompression = false
    @State private var showCompressionSheet = false
    @State private var showDeleteConfirmation = false
    @State private var showRenameDialog = false
    @State private var renamedPath = ""
    @State private var showInfo = false
    @State private var showLog = false
    @State private var showAbout = false
    @State private var showAssociation = false
    @State private var manualPasswordPrompt = false
    @State private var sortDescriptors: [NSSortDescriptor] = []

    /// 嵌套归档栈：每一项记录一层外层归档的浏览状态与本次解压出的临时目录。
    private struct NestedContext: Equatable {
        let outerURL: URL       // 外层归档文件（最外层是磁盘文件，深层是上一层临时文件）
        let innerFolder: String // 外层归档内的浏览位置
        let tempDir: URL        // 本层嵌套解压出的临时目录（退出嵌套时清理）
        let displayPath: String // 嵌套归档在外层中的路径（地址栏显示用）
    }
    @State private var nestingStack: [NestedContext] = []

    private static let archiveExtensions: Set<String> = ["7z", "zip", "tar", "gz", "tgz", "bz2", "xz", "rar", "001"]

    private var canEditArchive: Bool {
        // 嵌套归档是临时解压出的副本，写回外层不可行——一律只读。
        guard nestingStack.isEmpty, inArchive, let url = model.archiveURL else { return false }
        return ["7z", "zip"].contains(url.pathExtension.lowercased())
    }

    // MARK: - Row model

    private var rows: [FileListRow] {
        applySort(inArchive ? archiveRows() : localRows())
    }

    /// 表头排序：".." 恒在最前，文件夹与文件分组保持（7zFM 行为），组内按描述符排序。
    private func applySort(_ raw: [FileListRow]) -> [FileListRow] {
        guard let descriptor = sortDescriptors.first, let key = descriptor.key else { return raw }
        func compare(_ lhs: FileListRow, _ rhs: FileListRow) -> Bool {
            var result: ComparisonResult
            switch key {
            case "size":
                result = lhs.sizeKey == rhs.sizeKey ? .orderedSame
                    : (lhs.sizeKey < rhs.sizeKey ? .orderedAscending : .orderedDescending)
            case "packed":
                result = lhs.packedKey == rhs.packedKey ? .orderedSame
                    : (lhs.packedKey < rhs.packedKey ? .orderedAscending : .orderedDescending)
            case "modified":
                result = lhs.modifiedKey.compare(rhs.modifiedKey)
            default:
                result = lhs.name.localizedStandardCompare(rhs.name)
            }
            if result == .orderedSame { result = lhs.name.localizedStandardCompare(rhs.name) }
            let ascending = descriptor.ascending ? result != .orderedDescending : result == .orderedDescending
            return ascending
        }
        let up = raw.filter { $0.kind == .up }
        let folders = raw.filter { $0.kind == .folder }.sorted(by: compare)
        let files = raw.filter { $0.kind == .file }.sorted(by: compare)
        return up + folders + files
    }

    private func localRows() -> [FileListRow] {
        var result: [FileListRow] = []
        if currentDir.path != "/" {
            result.append(FileListRow(id: "..", kind: .up, name: "..", sizeText: "", packedText: "",
                                      modified: "", isArchiveFile: false))
        }
        for file in dirFiles {
            let values = try? file.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey])
            let isDirectory = values?.isDirectory == true
            let modified = values?.contentModificationDate.map {
                $0.formatted(date: .numeric, time: .shortened)
            } ?? ""
            let sizeText = isDirectory ? "文件夹"
                : (values?.fileSize.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) } ?? "—")
            var row = FileListRow(id: file.path, kind: isDirectory ? .folder : .file,
                                  name: file.lastPathComponent, sizeText: sizeText, packedText: "",
                                  modified: modified,
                                  isArchiveFile: Self.archiveExtensions.contains(file.pathExtension.lowercased()))
            row.sizeKey = values?.fileSize.map { Int64($0) } ?? -1
            row.modifiedKey = values?.contentModificationDate
                .map { String(format: "%020.3f", $0.timeIntervalSince1970) } ?? ""
            result.append(row)
        }
        return result
    }

    /// 7zFM shows only the immediate children of the current inner folder.
    private func archiveRows() -> [FileListRow] {
        var result: [FileListRow] = [FileListRow(id: "..", kind: .up, name: "..", sizeText: "", packedText: "",
                                                 modified: "", isArchiveFile: false)]
        let byName: (FileListRow, FileListRow) -> Bool = {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        // 平铺视图：不折叠目录，直接列出全部文件条目，名称列显示完整相对路径。
        if actions.flatView {
            var files: [FileListRow] = []
            for entry in model.entries where !entry.isDirectory {
                files.append(fileRow(for: entry, displayName: entry.path))
            }
            result += files.sorted(by: byName)
            return result
        }
        let prefix = innerFolder.isEmpty ? "" : innerFolder + "/"
        var foldersSeen = Set<String>()
        var folders: [FileListRow] = []
        var files: [FileListRow] = []
        for entry in model.entries {
            guard entry.path.hasPrefix(prefix) else { continue }
            let rest = String(entry.path.dropFirst(prefix.count))
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !rest.isEmpty else { continue }
            if rest.contains("/") {
                let name = String(rest.split(separator: "/", maxSplits: 1)[0])
                if foldersSeen.insert(name).inserted {
                    let fullPath = prefix + name
                    let modified = model.entries.first { $0.path == fullPath && $0.isDirectory }?.modified ?? ""
                    var row = FileListRow(id: fullPath, kind: .folder, name: name, sizeText: "文件夹",
                                          packedText: "", modified: modified, isArchiveFile: false)
                    row.modifiedKey = modified
                    folders.append(row)
                }
            } else if entry.isDirectory {
                if foldersSeen.insert(rest).inserted {
                    var row = FileListRow(id: entry.path, kind: .folder, name: rest, sizeText: "文件夹",
                                          packedText: "", modified: entry.modified, isArchiveFile: false)
                    row.modifiedKey = entry.modified
                    folders.append(row)
                }
            } else {
                files.append(fileRow(for: entry, displayName: rest))
            }
        }
        result += folders.sorted(by: byName) + files.sorted(by: byName)
        return result
    }

    private func fileRow(for entry: ArchiveEntry, displayName: String) -> FileListRow {
        var row = FileListRow(id: entry.path, kind: .file, name: displayName, sizeText: entry.sizeLabel,
                              packedText: entry.packedLabel, modified: entry.modified,
                              isArchiveFile: Self.archiveExtensions.contains(
                                URL(fileURLWithPath: entry.path).pathExtension.lowercased()))
        row.sizeKey = entry.size ?? -1
        row.packedKey = entry.packedSize ?? -1
        row.modifiedKey = entry.modified
        return row
    }

    // MARK: - Address

    private var addressText: String {
        if inArchive, let archive = model.archiveURL {
            // 嵌套时把外层路径逐层拼上：outer.zip\inner.7z\…
            let base: String
            if let first = nestingStack.first {
                base = first.outerURL.path + nestingStack.map { "\\" + $0.displayPath }.joined()
            } else {
                base = archive.path
            }
            let inner = innerFolder.replacingOccurrences(of: "/", with: "\\")
            return inner.isEmpty ? base + "\\" : base + "\\" + inner + "\\"
        }
        return currentDir.path
    }

    private func pushHistory() {
        let address = addressText
        if history.last != address { history.append(address) }
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            toolbar
            Divider()
            addressBar
            Divider()
            fileList
            Divider()
            statusBar
            if showLog { logDrawer }
        }
        .frame(minWidth: 940, minHeight: 560)
        .sheet(isPresented: $showCompressionSheet) { compressionSheet }
        .sheet(isPresented: $showInfo) { infoSheet }
        .sheet(isPresented: $showAbout) { aboutSheet }
        .sheet(isPresented: $showAssociation) { AssociationSheet() }
        .sheet(isPresented: $manualPasswordPrompt) { passwordSheet }
        .sheet(isPresented: Binding(get: { model.passwordNeededFor != nil },
                                    set: { if !$0 { model.dismissPasswordRequest() } })) {
            retryPasswordSheet
        }
        .quickLookPreview($model.previewURL)
        .onOpenURL { url in openArchive(url) }
        .onAppear {
            refreshLocal()
            installMenuActions()
            // Finder 双击/服务启动时，事件可能先于界面就绪：回放缓冲的请求。
            actions.drainPendingServices()
        }
        .onChange(of: model.archiveURL) { _ in
            innerFolder = ""
            selected.removeAll()
        }
        .onChange(of: model.nestedArchiveURL) { nested in
            // 嵌套归档已解压到临时目录：压栈并切换进去（model.open 会重置 nestedArchiveURL）。
            guard let nested, let outer = model.archiveURL, inArchive else { return }
            let context = NestedContext(outerURL: outer,
                                        innerFolder: innerFolder,
                                        tempDir: nested.deletingLastPathComponent(),
                                        displayPath: model.nestedEntryPath ?? nested.lastPathComponent)
            nestingStack.append(context)
            innerFolder = ""
            selected.removeAll()
            model.open(nested, password: consumePassword())
        }
        .onChange(of: model.entries) { entries in
            selected.formIntersection(Set(entries.map(\.path)).union([".."]))
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first, url.isFileURL else { return false }
            handleDrop(urls)
            return true
        }
        .alert("操作提示", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.dismissError() } }
        )) { Button("确定", role: .cancel) { model.dismissError() } }
        message: { Text(model.errorMessage ?? "") }
        .alert("重命名", isPresented: $showRenameDialog) {
            TextField("新名称", text: $renamedPath)
            Button("取消", role: .cancel) { }
            Button("重命名") { performRename() }
        } message: { Text(inArchive ? "修改归档内部路径。" : "重命名本机文件。") }
        .confirmationDialog("确定删除所选项目？", isPresented: $showDeleteConfirmation) {
            Button(inArchive ? "从归档中删除" : "移到废纸篓", role: .destructive) { performDelete() }
        } message: {
            Text(inArchive ? "此操作会修改压缩包文件，无法直接撤销。建议先备份重要归档。" : "所选文件将被移入废纸篓。")
        }
    }

    // MARK: - Toolbar (7zFM large-icon style)

    private func toolButton(_ title: String, _ icon: String, enabled: Bool = true,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: icon).font(.system(size: 20))
                Text(title).font(.caption2)
            }
            .frame(width: 56, height: 44)
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? Color.primary : Color.secondary.opacity(0.5))
        .disabled(!enabled)
    }

    private var toolbar: some View {
        HStack(spacing: 4) {
            toolButton("添加", "plus") { addAction() }
            toolButton("释放", "arrow.up.doc", enabled: inArchive) { extractAction() }
            toolButton("测试", "checkmark.circle", enabled: inArchive) {
                model.test(password: consumePassword())
            }
            toolButton("复制", "doc.on.doc", enabled: !actionableSelection.isEmpty) { copyAction() }
            toolButton("移动", "rectangle.portrait.and.arrow.right",
                       enabled: !actionableSelection.isEmpty && (!inArchive || canEditArchive)) { moveAction() }
            toolButton("删除", "trash", enabled: !actionableSelection.isEmpty) {
                showDeleteConfirmation = true
            }
            toolButton("信息", "info.circle", enabled: inArchive || !actionableSelection.isEmpty) {
                showInfo = true
            }
            Spacer()
            Picker("文件冲突", selection: $conflict) {
                ForEach(ConflictPolicy.allCases) { value in Text(value.title).tag(value) }
            }
            .frame(width: 200)
            .disabled(!inArchive)
        }
        .disabled(model.busy)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    // MARK: - Address bar

    private var addressBar: some View {
        HStack(spacing: 8) {
            Text("地址:")
                .foregroundStyle(.secondary)
            Image(systemName: inArchive ? "doc.zipper" : "folder")
                .foregroundStyle(Color.accentColor)
            Text(addressText)
                .font(.callout.monospaced())
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Menu {
                if history.isEmpty { Text("暂无历史") }
                ForEach(history.reversed(), id: \.self) { item in
                    Button(item) { navigateToAddress(item) }
                }
            } label: { Image(systemName: "chevron.down") }
                .menuStyle(.borderlessButton)
                .frame(width: 24)
                .help("历史位置")
            Spacer()
            if inArchive {
                Text("\(model.entries.count) 个对象")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    // MARK: - File list

    private var fileList: some View {
        FileListView(rows: rows, selection: $selected,
                     onActivate: activate, menuProvider: menuItems,
                     onSortChange: { sortDescriptors = $0 })
    }

    /// Right-click menu: local disk and archive contents get distinct action
    /// sets, mirroring 7zFM.
    private func menuItems(for row: FileListRow?) -> [FileListMenuAction] {
        guard let row, row.kind != .up else {
            // Background / ".." row: only generic location actions.
            var items = [FileListMenuAction(title: "刷新") { refreshCurrent() }]
            if !inArchive {
                items.append(.separator())
                items.append(FileListMenuAction(title: "在 Finder 中打开当前文件夹") {
                    NSWorkspace.shared.open(currentDir)
                })
            }
            return items
        }
        if inArchive {
            return [
                FileListMenuAction(title: row.kind == .folder ? "进入" : "预览") { activate(row) },
                FileListMenuAction(title: "释放到…") { extractAction() },
                .separator(),
                FileListMenuAction(title: "复制到…") { copyAction() },
                FileListMenuAction(title: "移出到…", enabled: canEditArchive) { moveAction() },
                .separator(),
                FileListMenuAction(title: "重命名…",
                                   enabled: canEditArchive && actionableSelection.count == 1) { renameRow(row) },
                FileListMenuAction(title: "从归档删除…", destructive: true,
                                   enabled: canEditArchive) { showDeleteConfirmation = true },
                .separator(),
                FileListMenuAction(title: "属性信息") { showInfo = true },
            ]
        }
        return [
            FileListMenuAction(title: "打开") { activate(row) },
            FileListMenuAction(title: "在 Finder 中显示") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: row.id)])
            },
            .separator(),
            FileListMenuAction(title: "压缩所选…") { addAction() },
            FileListMenuAction(title: "复制到…") { copyAction() },
            FileListMenuAction(title: "移动到…") { moveAction() },
            .separator(),
            FileListMenuAction(title: "重命名…",
                               enabled: actionableSelection.count == 1) { renameRow(row) },
            FileListMenuAction(title: "移到废纸篓", destructive: true) { showDeleteConfirmation = true },
            .separator(),
            FileListMenuAction(title: "属性信息") { showInfo = true },
        ]
    }

    private func renameRow(_ row: FileListRow) {
        renamedPath = inArchive ? row.id : row.name
        showRenameDialog = true
    }

    private func refreshCurrent() {
        if inArchive, let url = model.archiveURL {
            model.open(url)
        } else {
            refreshLocal()
        }
    }

    // MARK: - Status bar

    private var statusBar: some View {
        HStack(spacing: 12) {
            let files = rows.filter { $0.kind == .file }
            Text("\(rows.filter { $0.kind != .up }.count) 个对象")
            if inArchive, !files.isEmpty {
                let ids = Set(files.map(\.id))
                let total = model.entries.filter { ids.contains($0.path) }.compactMap(\.size).reduce(0, +)
                if total > 0 { Text(ByteCountFormatter.string(fromByteCount: total, countStyle: .file)) }
            }
            Text(model.status).lineLimit(1)
            Spacer()
            if model.busy {
                if let fraction = model.progress {
                    ProgressView(value: fraction).frame(width: 130)
                    Text("\(Int(fraction * 100))%")
                } else {
                    ProgressView().controlSize(.small)
                }
                Button("取消") { model.cancel() }
            }
            if model.queueCount > 0 { Text("等待 \(model.queueCount) 项") }
            Button { showLog.toggle() } label: {
                Label("日志", systemImage: showLog ? "chevron.down" : "chevron.up")
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.borderless)
        }
        .font(.caption)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private var logDrawer: some View {
        ScrollView {
            Text(model.output)
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
        }
        .frame(height: 120)
        .background(Color(nsColor: .textBackgroundColor))
    }

    // MARK: - Sheets

    private var compressionSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("创建压缩包").font(.title2)
            Text("选中 \(sourcesForCompression.count) 个项目").foregroundStyle(.secondary)
            Form {
                Picker("压缩格式", selection: $options.format) {
                    ForEach(ArchiveFormat.allCases) { format in Text(format.title).tag(format) }
                }
                Picker("压缩级别", selection: $options.level) {
                    ForEach(0...9, id: \.self) { level in Text("\(level)").tag(level) }
                }
                Stepper("CPU 线程数：\(options.threads == 0 ? "自动" : String(options.threads))",
                        value: $options.threads, in: 0...64)
                TextField("分卷大小（MB，0 为不分卷）", value: $options.volumeMB, format: .number)
                SecureField("加密密码（留空不加密）", text: $options.password)
                Toggle("7z 同时加密文件名", isOn: $options.encryptFileNames)
                    .disabled(options.format != .sevenZip || options.password.isEmpty)
                Toggle("排除 .DS_Store 和 __MACOSX", isOn: $options.excludeMacMetadata)
            }
            HStack {
                Spacer()
                Button("取消") { showCompressionSheet = false }
                Button("创建…") { finalizeCompression() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 510)
    }

    private var infoSheet: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("属性信息").font(.title2)
            if inArchive, let archive = model.archiveURL {
                infoRow("压缩包", archive.path)
                infoRow("格式", archive.pathExtension.uppercased())
                infoRow("条目数", "\(model.entries.count)")
                let total = model.entries.compactMap(\.size).reduce(0, +)
                let packed = model.entries.compactMap(\.packedSize).reduce(0, +)
                infoRow("原始大小", ByteCountFormatter.string(fromByteCount: total, countStyle: .file))
                infoRow("压缩后", ByteCountFormatter.string(fromByteCount: packed, countStyle: .file))
                if let selectedEntry = singleSelectedEntry {
                    Divider()
                    infoRow("选中条目", selectedEntry.path)
                    infoRow("大小", selectedEntry.sizeLabel)
                    infoRow("压缩后", selectedEntry.packedLabel)
                    infoRow("修改时间", selectedEntry.modified)
                }
            } else if let url = singleSelectedURL {
                let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .localizedTypeDescriptionKey])
                infoRow("名称", url.lastPathComponent)
                infoRow("位置", url.deletingLastPathComponent().path)
                infoRow("类型", values?.localizedTypeDescription ?? "—")
                infoRow("大小", values?.fileSize.map {
                    ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file)
                } ?? "—")
                infoRow("修改时间", values?.contentModificationDate?.formatted() ?? "—")
            } else {
                infoRow("当前文件夹", currentDir.path)
                infoRow("项目数", "\(dirFiles.count)")
            }
            HStack { Spacer(); Button("关闭") { showInfo = false }.keyboardShortcut(.defaultAction) }
        }
        .padding(24)
        .frame(width: 460)
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label).foregroundStyle(.secondary).frame(width: 80, alignment: .trailing)
            Text(value).textSelection(.enabled)
        }
    }

    /// 文件类型关联面板：自包含，onAppear 时自行加载状态，
    /// 不依赖外部 @State 的赋值时序。
    private struct AssociationSheet: View {
        @EnvironmentObject private var model: ArchiveModel
        @State private var entries: [FileAssociation.Entry] = []

        var body: some View {
            VStack(alignment: .leading, spacing: 12) {
                Text("文件类型关联").font(.title3)
                Text("勾选后双击该类型文件直接进入七压；取消勾选恢复系统默认打开方式。系统会为每次更改弹确认框。")
                    .font(.caption).foregroundStyle(.secondary)
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                    ForEach(entries) { entry in
                        GridRow {
                            Toggle(isOn: binding(for: entry)) {
                                Text("." + entry.ext).monospaced()
                            }
                            .toggleStyle(.checkbox)
                            Text(entry.isOurs ? "已关联" : "未关联")
                                .foregroundStyle(entry.isOurs ? Color.green : Color.secondary)
                        }
                    }
                }
                HStack {
                    Button("全部选中") { applyAll(associate: true) }
                    Button("全部移除") { applyAll(associate: false) }
                    Spacer()
                    Button("关闭") { dismiss() }.keyboardShortcut(.defaultAction)
                }
            }
            .padding(24)
            .frame(minWidth: 340)
            .onAppear { entries = FileAssociation.status() }
        }

        @Environment(\.dismiss) private var dismiss

        private func binding(for entry: FileAssociation.Entry) -> SwiftUI.Binding<Bool> {
            SwiftUI.Binding(
                get: { entry.isOurs },
                set: { on in
                    if on {
                        FileAssociation.bind(ext: entry.ext) { ok in
                            if !ok { model.warn("关联 .\(entry.ext) 失败：系统拒绝了更改。") }
                            entries = FileAssociation.status()
                        }
                    } else {
                        FileAssociation.remove(ext: entry.ext) { ok in
                            if !ok { model.warn("移除 .\(entry.ext) 关联失败。") }
                            entries = FileAssociation.status()
                        }
                    }
                }
            )
        }

        private func applyAll(associate: Bool) {
            let pending = FileAssociation.supported.map(\.ext).filter { ext in
                (entries.first { $0.ext == ext }?.isOurs ?? false) != associate
            }
            applySequentially(pending, associate: associate)
        }

        /// 每次更改都会弹系统确认框，串行执行避免弹窗堆叠。
        private func applySequentially(_ exts: [String], associate: Bool) {
            guard let ext = exts.first else {
                entries = FileAssociation.status()
                return
            }
            let operation = associate ? FileAssociation.bind : FileAssociation.remove
            operation(ext) { _ in applySequentially(Array(exts.dropFirst()), associate: associate) }
        }
    }

    private var aboutSheet: some View {        VStack(spacing: 12) {
            Image(systemName: "archivebox.fill").font(.system(size: 44)).foregroundStyle(Color.accentColor)
            Text("七压 SevenZip").font(.title2)
            Text("7-Zip 26.05 · 原生 Apple Silicon · SwiftUI").foregroundStyle(.secondary)
            Text("界面范式参照 Windows 7-Zip File Manager。").font(.caption)
            Button("关闭") { showAbout = false }.keyboardShortcut(.defaultAction)
        }
        .padding(30)
    }

    private var passwordSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("输入压缩包密码").font(.title3)
            SecureField("密码（用于接下来的打开/解压操作）", text: $archivePassword)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("取消") { manualPasswordPrompt = false }
                Button("确定") { manualPasswordPrompt = false }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 380)
    }

    private var retryPasswordSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("此压缩包已加密").font(.title3)
            Text(model.passwordNeededFor?.lastPathComponent ?? "").foregroundStyle(.secondary)
            SecureField("密码", text: $archivePassword).textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("取消") { model.dismissPasswordRequest() }
                Button("打开") {
                    if let url = model.passwordNeededFor {
                        model.dismissPasswordRequest()
                        model.open(url, password: consumePassword())
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 380)
    }

    // MARK: - Selection helpers

    private var actionableSelection: Set<String> { selected.subtracting([".."]) }

    private var singleSelectedEntry: ArchiveEntry? {
        guard inArchive, actionableSelection.count == 1, let id = actionableSelection.first else { return nil }
        return model.entries.first { $0.path == id }
    }

    private var singleSelectedURL: URL? {
        guard !inArchive, actionableSelection.count == 1, let id = actionableSelection.first else { return nil }
        return URL(fileURLWithPath: id)
    }

    /// Selected archive paths plus all descendants of selected folders.
    private var expandedArchiveSelection: [String] {
        var result = Set<String>()
        for id in actionableSelection {
            result.insert(id)
            let prefix = id + "/"
            for entry in model.entries where entry.path.hasPrefix(prefix) { result.insert(entry.path) }
        }
        return result.sorted()
    }

    private var selectedLocalURLs: [URL] {
        actionableSelection.sorted().map { URL(fileURLWithPath: $0) }
    }

    // MARK: - Navigation

    private func refreshLocal() {
        do {
            dirFiles = try FileManager.default.contentsOfDirectory(
                at: currentDir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
                .sorted { left, right in
                    let ldir = (try? left.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                    let rdir = (try? right.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                    if ldir != rdir { return ldir }
                    return left.lastPathComponent.localizedStandardCompare(right.lastPathComponent) == .orderedAscending
                }
            dirError = ""
        } catch {
            dirFiles = []
            dirError = error.localizedDescription
        }
    }

    private func activate(_ row: FileListRow) {
        switch row.kind {
        case .up:
            goUpAction()
        case .folder:
            pushHistory()
            selected.removeAll()
            if inArchive {
                innerFolder = row.id
            } else {
                currentDir = URL(fileURLWithPath: row.id)
                refreshLocal()
            }
        case .file:
            if inArchive {
                if row.isArchiveFile {
                    // 归档里的归档：解压到临时目录后作为新一层进入（只读）。
                    model.openNested(path: row.id, password: consumePassword())
                } else {
                    model.preview(path: row.id, password: consumePassword())
                }
            } else {
                let url = URL(fileURLWithPath: row.id)
                if row.isArchiveFile {
                    openArchive(url)
                } else {
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }

    private func goUpAction() {
        pushHistory()
        selected.removeAll()
        if inArchive {
            if !innerFolder.isEmpty {
                innerFolder = innerFolder.components(separatedBy: "/").dropLast().joined(separator: "/")
            } else if let context = nestingStack.popLast() {
                // 嵌套根目录的 ".."：回到外层归档并清理本层临时文件。
                try? FileManager.default.removeItem(at: context.tempDir)
                innerFolder = context.innerFolder
                model.open(context.outerURL)
            } else if let archive = model.archiveURL {
                // ".." at the archive root climbs back out to the disk (7zFM behavior).
                inArchive = false
                currentDir = archive.deletingLastPathComponent()
                refreshLocal()
            }
        } else {
            let parent = currentDir.deletingLastPathComponent()
            if parent != currentDir {
                currentDir = parent
                refreshLocal()
            }
        }
    }

    /// 打开/关闭/跳转归档前调用：清掉所有嵌套层及其临时目录。
    private func clearNesting() {
        for context in nestingStack {
            try? FileManager.default.removeItem(at: context.tempDir)
        }
        nestingStack.removeAll()
    }

    private func openArchive(_ url: URL) {
        pushHistory()
        clearNesting()
        inArchive = true
        innerFolder = ""
        selected.removeAll()
        model.open(url, password: consumePassword())
    }

    private func closeArchive() {
        guard let archive = nestingStack.first?.outerURL ?? model.archiveURL else { return }
        clearNesting()
        inArchive = false
        currentDir = archive.deletingLastPathComponent()
        selected.removeAll()
        refreshLocal()
    }

    private func navigateToAddress(_ address: String) {
        clearNesting()
        if let archive = model.archiveURL,
           address.hasPrefix(archive.path + "\\") {
            inArchive = true
            innerFolder = String(address.dropFirst(archive.path.count + 1))
                .trimmingCharacters(in: CharacterSet(charactersIn: "\\"))
                .replacingOccurrences(of: "\\", with: "/")
        } else {
            inArchive = false
            currentDir = URL(fileURLWithPath: address)
            refreshLocal()
        }
        selected.removeAll()
    }

    private func handleDrop(_ urls: [URL]) {
        if inArchive {
            if canEditArchive { model.add(sources: urls, password: consumePassword()) }
        } else if let first = urls.first, Self.archiveExtensions.contains(first.pathExtension.lowercased()),
                  urls.count == 1 {
            openArchive(first)
        } else {
            for url in urls {
                let target = currentDir.appendingPathComponent(url.lastPathComponent)
                try? FileManager.default.copyItem(at: url, to: target)
            }
            refreshLocal()
        }
    }

    // MARK: - Toolbar actions

    private func addAction() {
        if inArchive {
            guard canEditArchive else { return }
            let panel = NSOpenPanel()
            panel.title = "向压缩包添加文件"
            panel.canChooseFiles = true
            panel.canChooseDirectories = true
            panel.allowsMultipleSelection = true
            if panel.runModal() == .OK { model.add(sources: panel.urls, password: consumePassword()) }
        } else {
            if actionableSelection.isEmpty {
                chooseSourcesForCompression()
            } else {
                sourcesForCompression = selectedLocalURLs
                batchCompression = false
                options = CompressionOptions()
                showCompressionSheet = true
            }
        }
    }

    private func extractAction() {
        chooseDestination(paths: expandedArchiveSelection)
    }

    private func copyAction() {
        if inArchive {
            chooseDestination(paths: expandedArchiveSelection)
        } else {
            guard let destination = chooseFolderPanel(title: "复制所选文件到…") else { return }
            for url in selectedLocalURLs {
                try? FileManager.default.copyItem(at: url, to: destination.appendingPathComponent(url.lastPathComponent))
            }
            model.announce("已复制 \(selectedLocalURLs.count) 个项目到 \(destination.path)")
        }
    }

    private func moveAction() {
        if inArchive {
            guard canEditArchive else { return }
            let targets = expandedArchiveSelection
            guard !targets.isEmpty, let destination = chooseFolderPanel(title: "从归档移出到…") else { return }
            // Serial queue: extraction completes before the entries are deleted.
            model.extract(to: destination, paths: targets, conflict: conflict, password: consumePassword())
            model.delete(paths: targets, password: nil)
            selected.removeAll()
        } else {
            guard let destination = chooseFolderPanel(title: "移动所选文件到…") else { return }
            var failed = 0
            for url in selectedLocalURLs {
                do {
                    try FileManager.default.moveItem(at: url, to: destination.appendingPathComponent(url.lastPathComponent))
                } catch { failed += 1 }
            }
            if failed > 0 { model.warn("\(failed) 个项目移动失败（目标可能已存在同名文件）。") }
            selected.removeAll()
            refreshLocal()
        }
    }

    private func performDelete() {
        if inArchive {
            model.delete(paths: expandedArchiveSelection, password: consumePassword())
        } else {
            for url in selectedLocalURLs {
                try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
            }
            refreshLocal()
        }
        selected.removeAll()
    }

    private func performRename() {
        guard let id = actionableSelection.first, !renamedPath.isEmpty else { return }
        if inArchive {
            model.rename(path: id, to: renamedPath, password: consumePassword())
        } else {
            let source = URL(fileURLWithPath: id)
            let target = source.deletingLastPathComponent().appendingPathComponent(renamedPath)
            do {
                try FileManager.default.moveItem(at: source, to: target)
                refreshLocal()
            } catch {
                model.warn("重命名失败：\(error.localizedDescription)")
            }
        }
    }

    // MARK: - Panels

    private func chooseArchivePanel() {
        let panel = NSOpenPanel()
        panel.title = "选择压缩包"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url { openArchive(url) }
    }

    private func chooseSourcesForCompression() {
        let panel = NSOpenPanel()
        panel.title = "选择要压缩的文件或文件夹（同一父目录）"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        sourcesForCompression = panel.urls
        batchCompression = false
        options = CompressionOptions()
        showCompressionSheet = true
    }

    private func chooseBatchCompression() {
        let panel = NSOpenPanel()
        panel.title = "选择批量压缩项目（每个项目单独生成归档）"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        sourcesForCompression = panel.urls
        batchCompression = true
        options = CompressionOptions()
        showCompressionSheet = true
    }

    private func chooseBatchExtraction() {
        let panel = NSOpenPanel()
        panel.title = "选择需要批量解压的压缩包"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        guard let directory = chooseFolderPanel(title: "选择所有压缩包的输出父目录") else { return }
        model.batchExtract(archives: panel.urls, to: directory, conflict: conflict, password: consumePassword())
    }

    private func chooseConversion() {
        guard let source = model.archiveURL else { return }
        let outputFormat: ArchiveFormat = source.pathExtension.lowercased() == "7z" ? .zip : .sevenZip
        let panel = NSSavePanel()
        panel.title = "将归档转换为 7z / ZIP / TAR"
        panel.nameFieldStringValue = source.deletingPathExtension().lastPathComponent + "." + outputFormat.rawValue
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        guard let format = ArchiveFormat(rawValue: destination.pathExtension.lowercased()) else {
            model.warn("目标格式仅支持 7z、ZIP 或 TAR。")
            return
        }
        model.convert(to: destination, format: format, password: consumePassword())
    }

    private func chooseFolderPanel(title: String) -> URL? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func chooseDestination(paths: [String]) {
        guard let url = chooseFolderPanel(title: "选择解压目标目录") else { return }
        model.extract(to: url, paths: paths, conflict: conflict, password: consumePassword())
    }

    private func finalizeCompression() {
        if batchCompression {
            guard let destination = chooseFolderPanel(title: "选择批量压缩包输出文件夹") else { return }
            model.batchCompress(sources: sourcesForCompression, to: destination, options: options)
            options.password = ""
            showCompressionSheet = false
            return
        }
        let save = NSSavePanel()
        save.title = "保存新压缩包"
        save.nameFieldStringValue = sourcesForCompression[0].lastPathComponent + "." + options.format.rawValue
        save.canCreateDirectories = true
        guard save.runModal() == .OK, let url = save.url else { return }
        model.compress(sources: sourcesForCompression, destination: url, options: options)
        options.password = ""
        showCompressionSheet = false
    }

    private func consumePassword() -> String? {
        let password = archivePassword
        archivePassword = ""
        return password.isEmpty ? nil : password
    }

    // MARK: - Menu bridge

    private func installMenuActions() {
        actions.openArchive = chooseArchivePanel
        actions.createArchive = chooseSourcesForCompression
        actions.closeArchive = closeArchive
        actions.refresh = refreshCurrent
        actions.goUp = goUpAction
        actions.renameSelection = {
            guard let id = actionableSelection.first, actionableSelection.count == 1 else { return }
            renamedPath = inArchive ? id : URL(fileURLWithPath: id).lastPathComponent
            showRenameDialog = true
        }
        actions.deleteSelection = { if !actionableSelection.isEmpty { showDeleteConfirmation = true } }
        actions.selectAll = { selected = Set(rows.map(\.id)) }
        actions.deselectAll = { selected.removeAll() }
        actions.invertSelection = {
            let all = Set(rows.map(\.id))
            selected = all.subtracting(selected)
        }
        actions.batchExtract = chooseBatchExtraction
        actions.batchCompress = chooseBatchCompression
        actions.convert = chooseConversion
        actions.checksum = { [model] algorithm in if inArchive { model.checksum(algorithm: algorithm) } }
        actions.toggleLog = { showLog.toggle() }
        actions.enterPassword = { manualPasswordPrompt = true }
        actions.fileAssociation = { showAssociation = true }
        actions.about = { showAbout = true }

        // Finder 服务与双击打开（由 AppDelegate 转发到 AppActions.shared）。
        actions.openFiles = { urls in
            let archives = urls.filter { Self.archiveExtensions.contains($0.pathExtension.lowercased()) }
            guard let first = archives.first ?? urls.first else { return }
            openArchive(first)
            if urls.count > 1 { model.announce("已打开 \(first.lastPathComponent)；其余 \(urls.count - 1) 个文件未处理。") }
        }
        actions.extractInPlace = { [model] urls in
            let archives = urls.filter { Self.archiveExtensions.contains($0.pathExtension.lowercased()) }
            guard !archives.isEmpty else {
                model.warn("所选项目不包含支持的压缩包（7z/zip/rar/tar/gz/xz）。")
                return
            }
            for archive in archives {
                model.extract(to: archive.deletingLastPathComponent(), paths: [],
                              conflict: conflict, password: nil)
            }
            model.announce("已加入解压队列：\(archives.count) 个压缩包，解压到各自所在目录。")
        }
        actions.compressInPlace = { [model] urls in
            guard let first = urls.first else { return }
            let parent = first.deletingLastPathComponent()
            let base = urls.count == 1 ? first.deletingPathExtension().lastPathComponent : "Archive"
            var zipOptions = CompressionOptions()
            zipOptions.format = .zip
            var destination = parent.appendingPathComponent(base + ".zip")
            var suffix = 2
            while FileManager.default.fileExists(atPath: destination.path) {
                destination = parent.appendingPathComponent("\(base)-\(suffix).zip")
                suffix += 1
            }
            model.compress(sources: urls, destination: destination, options: zipOptions)
            model.announce("已加入压缩队列：\(destination.lastPathComponent)")
        }
        actions.handlersInstalled = true
    }
}
