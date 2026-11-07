import AppKit
import ArchiveCore
import QuickLook
import SwiftUI

/// 7-Zip File Manager (Windows) interaction paradigm, on macOS:
/// single-pane file list, large-icon toolbar, address bar, status bar.
/// Archives open like folders; ".." climbs back out to the disk.
/// 双窗格模式下由 ContentView 外壳承载两个实例，焦点窗格安装菜单处理器。
struct PaneView: View {
    /// 是否焦点窗格（菜单、快捷键、Finder 服务都作用于焦点窗格）。
    let isFocused: Bool
    /// 用户与本窗格交互（点击列表等）时回调，外壳据此移动焦点。
    let onFocus: () -> Void

    @StateObject private var model = ArchiveModel()
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
    /// 嵌套打开的密码暂存：activate 时 consumePassword() 已清空输入框，
    /// 而 nestedArchiveURL 回调在解压完成后才异步到达，密码必须先存下。
    @State private var pendingNestedPassword: String?
    @State private var conflict: ConflictPolicy = .skip
    @State private var options = CompressionOptions()
    @State private var sourcesForCompression: [URL] = []
    @State private var batchCompression = false
    /// 「压缩并邮件…」：压缩选项确认后，创建完成自动调出邮件分享。
    @State private var emailAfterCreate = false
    @State private var showCompressionSheet = false
    @State private var showCompressPassword = false
    @State private var passwordConfirm = ""
    /// 压缩对话框中的目标归档路径（双栏布局版，替代创建后再弹保存面板）。
    @State private var archiveDestPath = ""
    // 解压对话框（对齐 7-Zip Extract 窗口：目标目录/子文件夹/路径模式/覆盖模式/密码）
    @State private var showExtractionSheet = false
    @State private var extractionPaths: [String] = []
    @State private var extractionDest = ""
    @State private var extractToSubfolder = true
    @State private var extractSubfolderName = ""
    @State private var extractPathMode: ExtractPathMode = .full
    @State private var extractEliminateDup = false
    @State private var extractConflict: ConflictPolicy = .skip
    @State private var extractPassword = ""
    @State private var showExtractPassword = false
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
        let password: String?   // 外层归档的密码（".." 返回外层时重列清单需要）
    }
    @State private var nestingStack: [NestedContext] = []

    /// 嵌套条目可能带子目录（folder/sub/inner.7z），deletingLastPathComponent
    /// 只会得到 folder/sub——必须向上找到 SevenZip-nested- 根目录才能真正清理。
    private static func nestedTempRoot(of nested: URL) -> URL {
        var url = nested.deletingLastPathComponent()
        while !url.lastPathComponent.hasPrefix("SevenZip-nested-") {
            let parent = url.deletingLastPathComponent()
            if parent == url { return nested.deletingLastPathComponent() }  // 兜底：绝不返回根目录
            url = parent
        }
        return url
    }

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
            case "created":
                result = lhs.createdKey.compare(rhs.createdKey)
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
            let values = try? file.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey,
                                                            .contentModificationDateKey, .creationDateKey])
            let isDirectory = values?.isDirectory == true
            let modified = values?.contentModificationDate.map {
                $0.formatted(date: .numeric, time: .shortened)
            } ?? ""
            let created = values?.creationDate.map {
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
            row.createdText = created
            row.createdKey = values?.creationDate
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
                    let dirEntry = model.entries.first { $0.path == fullPath && $0.isDirectory }
                    var row = FileListRow(id: fullPath, kind: .folder, name: name, sizeText: "文件夹",
                                          packedText: "", modified: dirEntry?.modified ?? "",
                                          isArchiveFile: false)
                    row.modifiedKey = row.modified
                    row.createdText = dirEntry?.created ?? ""
                    row.createdKey = row.createdText
                    let counts = archiveChildCounts(of: fullPath)
                    row.subfoldersText = "\(counts.folders)"
                    row.subfilesText = "\(counts.files)"
                    folders.append(row)
                }
            } else if entry.isDirectory {
                if foldersSeen.insert(rest).inserted {
                    var row = FileListRow(id: entry.path, kind: .folder, name: rest, sizeText: "文件夹",
                                          packedText: "", modified: entry.modified, isArchiveFile: false)
                    row.modifiedKey = entry.modified
                    row.createdText = entry.created
                    row.createdKey = entry.created
                    let counts = archiveChildCounts(of: entry.path)
                    row.subfoldersText = "\(counts.folders)"
                    row.subfilesText = "\(counts.files)"
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
        row.createdText = entry.created
        row.createdKey = entry.created
        row.commentText = entry.comment
        return row
    }

    /// 统计归档内某文件夹（按路径前缀）递归包含的子文件夹与文件数量。
    private func archiveChildCounts(of folderPath: String) -> (folders: Int, files: Int) {
        let prefix = folderPath + "/"
        var folders = 0, files = 0
        for entry in model.entries where entry.path.hasPrefix(prefix) {
            if entry.isDirectory { folders += 1 } else { files += 1 }
        }
        return (folders, files)
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
        .frame(minWidth: 420, minHeight: 480)
        // 焦点窗格高亮边框（双窗格模式下区分作用目标）。
        .overlay(RoundedRectangle(cornerRadius: 2)
            .stroke(isFocused ? Color.accentColor : Color.clear, lineWidth: 2))
        .environmentObject(model)   // 子视图与 sheet 统一取本窗格自己的 model
        .contentShape(Rectangle())
        .onTapGesture { if !isFocused { onFocus() } }
        .sheet(isPresented: $showCompressionSheet) { compressionSheet }
        .sheet(isPresented: $showExtractionSheet) { extractionSheet }
        .sheet(isPresented: $showInfo) { infoSheet }
        .sheet(isPresented: $showAbout) { aboutSheet }
        .sheet(isPresented: $showAssociation) { AssociationSheet() }
        .sheet(isPresented: $manualPasswordPrompt) { passwordSheet }
        .sheet(isPresented: Binding(get: { model.passwordNeededFor != nil },
                                    set: { if !$0 { model.dismissPasswordRequest() } })) {
            retryPasswordSheet
        }
        .quickLookPreview($model.previewURL)
        // URL 打开（文件与 sevenzip:// 命令）全部由 AppDelegate → AppActions 路由；
        // 场景侧挂 .onOpenURL 会让系统为命令 URL 新建主窗口，故此处不挂。
        .onAppear {
            refreshLocal()
            // 只有焦点窗格安装菜单处理器；非焦点窗格安装跨窗格接收钩子。
            if isFocused { installMenuActions() } else { installOtherPaneHooks() }
            // Finder 双击/服务启动时，事件可能先于界面就绪：回放缓冲的请求。
            if isFocused { actions.drainPendingServices() }
        }
        .onChange(of: isFocused) { focused in
            if focused { installMenuActions() } else { installOtherPaneHooks() }
        }
        .onChange(of: inArchive) { open in
            // 同步给菜单门控（「关闭压缩包 ⌘W」无归档时禁用，见 AppMenu）。
            if isFocused { actions.archiveOpen = open }
        }
        .onChange(of: model.emailShareURL) { url in
            // 「压缩并邮件」：压缩完成后调出系统邮件分享；未配置邮件则回退到 Finder 选中。
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
        .onChange(of: model.archiveURL) { _ in
            innerFolder = ""
            selected.removeAll()
        }
        .onChange(of: model.nestedArchiveURL) { nested in
            // 嵌套归档已解压到临时目录：压栈并切换进去（model.open 会重置 nestedArchiveURL）。
            guard let nested, let outer = model.archiveURL, inArchive else { return }
            // 密码在 activate 时已被 consume 走，这里取暂存值（见 pendingNestedPassword）。
            let password = pendingNestedPassword ?? consumePassword()
            pendingNestedPassword = nil
            let context = NestedContext(outerURL: outer,
                                        innerFolder: innerFolder,
                                        tempDir: Self.nestedTempRoot(of: nested),
                                        displayPath: model.nestedEntryPath ?? nested.lastPathComponent,
                                        password: password)
            nestingStack.append(context)
            innerFolder = ""
            selected.removeAll()
            model.open(nested, password: password)
        }
        .onChange(of: model.entries) { entries in
            // 仅归档视图：磁盘浏览时后台 .edited 重列完成也会触发本回调，
            // 交集对象是归档路径，会把本地选中清空。
            guard inArchive else { return }
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
        Group {
            if actions.viewMode == .icons {
                IconListView(rows: rows, selection: $selected,
                             onActivate: activate, menuProvider: menuItems,
                             onInteraction: { if !isFocused { onFocus() } })
            } else {
                FileListView(rows: rows, selection: $selected,
                             onActivate: activate, menuProvider: menuItems,
                             onSortChange: { sortDescriptors = $0 },
                             onInteraction: { if !isFocused { onFocus() } },
                             gridLines: actions.showGridLines)
            }
        }
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
            let total = rows.filter { $0.kind != .up }.count
            let picked = actionableSelection.count
            Text(picked > 0 ? "已选 \(picked) / 共 \(total) 个对象" : "\(total) 个对象")
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

    private var passwordsMatch: Bool {
        options.password.isEmpty || options.password == passwordConfirm
    }

    /// 应用内「添加到压缩包」sheet：表单与 Finder 独立对话框共用（CompressFormView）。
    private var compressionSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("添加到压缩包").font(.title2)
            Text("选中 \(sourcesForCompression.count) 个项目").foregroundStyle(.secondary).font(.callout)
            CompressFormView(options: $options, passwordConfirm: $passwordConfirm,
                             showCompressPassword: $showCompressPassword,
                             archiveDestPath: $archiveDestPath,
                             onBrowse: browseArchiveDestination)
            HStack {
                Button("帮助") {
                    if let url = URL(string: "https://github.com/clawdbuddy/SevenZip#readme") {
                        NSWorkspace.shared.open(url)
                    }
                }
                Spacer()
                Button("取消") { showCompressionSheet = false }.keyboardShortcut(.cancelAction)
                Button("创建") { finalizeCompression() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!passwordsMatch || archiveDestPath.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 720, height: 600)
    }

    /// 解压对话框：目标目录（可手输或浏览）、同名子文件夹、路径模式（完整/平铺）、
    /// 消除根目录重复、覆盖模式、密码——对齐 7-Zip 的 Extract 窗口。
    private var extractionSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("解压\(model.archiveURL.map { "：\($0.path)" } ?? "")")
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)
            HStack(spacing: 8) {
                Text("解压到：")
                TextField("目标目录", text: $extractionDest)
                    .textFieldStyle(.roundedBorder)
                Button("…") {
                    if let chosen = chooseFolderPanel(title: "选择解压目标目录") {
                        extractionDest = chosen.path
                    }
                }
            }
            HStack(spacing: 8) {
                Toggle("", isOn: $extractToSubfolder).toggleStyle(.checkbox).labelsHidden()
                TextField("子文件夹名称", text: $extractSubfolderName)
                    .textFieldStyle(.roundedBorder)
                    .disabled(!extractToSubfolder)
            }
            Form {
                Picker("路径模式", selection: $extractPathMode) {
                    ForEach(ExtractPathMode.allCases) { mode in Text(mode.title).tag(mode) }
                }
                Toggle("消除根目录重复", isOn: $extractEliminateDup)
                    .disabled(!extractToSubfolder || extractPathMode != .full)
                Picker("覆盖模式", selection: $extractConflict) {
                    ForEach(ConflictPolicy.allCases) { value in Text(value.title).tag(value) }
                }
            }
            GroupBox("密码") {
                HStack {
                    if showExtractPassword {
                        TextField("密码", text: $extractPassword)
                    } else {
                        SecureField("密码", text: $extractPassword)
                    }
                    Toggle("显示密码", isOn: $showExtractPassword)
                }
                .padding(6)
            }
            HStack {
                Spacer()
                Button("取消") { showExtractionSheet = false }
                Button("确定") { performSheetExtraction() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(extractionDest.trimmingCharacters(in: .whitespaces).isEmpty
                              || (extractToSubfolder && extractSubfolderName.isEmpty))
            }
        }
        .padding(20)
        .frame(width: 560)
    }

    private func performSheetExtraction() {
        var destination = URL(fileURLWithPath: extractionDest)
        var eliminate: String? = nil
        if extractToSubfolder {
            destination = destination.appendingPathComponent(extractSubfolderName, isDirectory: true)
            if extractEliminateDup { eliminate = extractSubfolderName }
        }
        model.extract(to: destination, paths: extractionPaths, conflict: extractConflict,
                      password: extractPassword.isEmpty ? nil : extractPassword,
                      pathMode: extractPathMode, eliminateRoot: eliminate)
        extractPassword = ""
        showExtractionSheet = false
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
                if total > 0 {
                    infoRow("压缩率", String(format: "%.1f%%", Double(packed) / Double(total) * 100))
                }
                if let selectedEntry = singleSelectedEntry {
                    Divider()
                    infoRow("选中条目", selectedEntry.path)
                    infoRow("大小", selectedEntry.sizeLabel)
                    infoRow("压缩后", selectedEntry.packedLabel)
                    infoRow("修改时间", selectedEntry.modified)
                    if !selectedEntry.method.isEmpty { infoRow("压缩方法", selectedEntry.method) }
                    if !selectedEntry.crc.isEmpty { infoRow("CRC", selectedEntry.crc) }
                    if !selectedEntry.attributes.isEmpty { infoRow("属性", selectedEntry.attributes) }
                    infoRow("加密", selectedEntry.encrypted ? "是" : "否")
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
                    // 密码在此 consume，但 nestedArchiveURL 回调异步到达，
                    // 暂存起来供压栈与返回外层时使用。
                    let password = consumePassword()
                    pendingNestedPassword = password
                    model.openNested(path: row.id, password: password)
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
                TempDirectoryRegistry.unregister(context.tempDir)
                try? FileManager.default.removeItem(at: context.tempDir)
                innerFolder = context.innerFolder
                model.open(context.outerURL, password: context.password)
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
            TempDirectoryRegistry.unregister(context.tempDir)
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
        if address.contains("\\") {
            // 历史里的归档地址：[磁盘归档路径]\[归档内路径\]。嵌套层级
            // （…\inner.7z\…）不可直接恢复，退回到最外层归档根目录。
            let diskPath = String(address.split(separator: "\\", maxSplits: 1).first ?? "")
            let url = URL(fileURLWithPath: diskPath)
            guard FileManager.default.fileExists(atPath: url.path) else {
                model.warn("归档已不存在：\(diskPath)")
                return
            }
            // 校验通过后才清嵌套：先清会删掉仍在展示的嵌套临时目录，
            // 界面停在嵌套视图但数据已没了。
            clearNesting()
            inArchive = true
            innerFolder = ""
            selected.removeAll()
            if model.archiveURL == url {
                // 当前归档：尽量恢复归档内目录位置。
                innerFolder = String(address.dropFirst(diskPath.count + 1))
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\\"))
                    .replacingOccurrences(of: "\\", with: "/")
            } else {
                model.open(url)
            }
            return
        }
        // 磁盘地址：指向归档文件则打开（历史里回到磁盘后再点归档地址的场景），
        // 指向目录则进入；两者都失效时保持现状并提示，绝不把窗格打进错误态。
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: address, isDirectory: &isDirectory) else {
            model.warn("地址已失效：\(address)")
            return
        }
        // 同上：目标有效后才清嵌套（openArchive 内部也会清，幂等）。
        clearNesting()
        if isDirectory.boolValue {
            inArchive = false
            currentDir = URL(fileURLWithPath: address)
            refreshLocal()
        } else {
            openArchive(URL(fileURLWithPath: address))
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
            var failed = 0
            for url in urls {
                let target = currentDir.appendingPathComponent(url.lastPathComponent)
                do { try FileManager.default.copyItem(at: url, to: target) }
                catch { failed += 1 }
            }
            if failed > 0 { model.warn("\(failed) 个项目复制失败（目标可能已存在同名文件）。") }
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
                passwordConfirm = ""
                showCompressPassword = false
                archiveDestPath = defaultArchiveDestination()
                showCompressionSheet = true
            }
        }
    }

    private func extractAction() {
        guard inArchive, let archive = model.archiveURL else { return }
        extractionPaths = expandedArchiveSelection
        extractionDest = archive.deletingLastPathComponent().path
        extractSubfolderName = Self.baseName(for: [archive])
        extractToSubfolder = true
        extractPathMode = .full
        extractEliminateDup = false
        extractConflict = conflict
        extractPassword = ""
        showExtractPassword = false
        showExtractionSheet = true
    }

    private func copyAction() {
        if inArchive {
            chooseDestination(paths: expandedArchiveSelection)
        } else {
            guard let destination = chooseFolderPanel(title: "复制所选文件到…") else { return }
            var failed = 0
            for url in selectedLocalURLs {
                do {
                    try FileManager.default.copyItem(at: url, to: destination.appendingPathComponent(url.lastPathComponent))
                } catch { failed += 1 }
            }
            if failed > 0 {
                model.warn("\(failed) 个项目复制失败（目标可能已存在同名文件）。")
            } else {
                model.announce("已复制 \(selectedLocalURLs.count) 个项目到 \(destination.path)")
            }
        }
    }

    private func moveAction() {
        if inArchive {
            guard canEditArchive else { return }
            let targets = expandedArchiveSelection
            guard !targets.isEmpty, let destination = chooseFolderPanel(title: "从归档移出到…") else { return }
            // 依赖组：解压失败时删除必须取消（否则「移动」在失败路径退化成「删除」）。
            // extract 前置校验不过会拒绝入队并返回 false——此时绝不能调 delete。
            let group = UUID()
            if model.extract(to: destination, paths: targets, conflict: conflict,
                             password: consumePassword(), group: group) {
                model.delete(paths: targets, password: nil, group: group)
            }
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
        passwordConfirm = ""
        showCompressPassword = false
        archiveDestPath = defaultArchiveDestination()
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
        passwordConfirm = ""
        showCompressPassword = false
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

    /// 对话框默认归档路径：源文件父目录 + 基础名 + 当前格式扩展名。
    private func defaultArchiveDestination() -> String {
        CompressDestination.defaultPath(sources: sourcesForCompression, format: options.format)
    }

    private func browseArchiveDestination() {
        let panel = NSSavePanel()
        panel.title = "保存新压缩包"
        panel.nameFieldStringValue = URL(fileURLWithPath: archiveDestPath).lastPathComponent
        panel.directoryURL = URL(fileURLWithPath: archiveDestPath).deletingLastPathComponent()
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url { archiveDestPath = url.path }
    }

    private func finalizeCompression() {
        guard passwordsMatch else { return }
        if batchCompression {
            guard let destination = chooseFolderPanel(title: "选择批量压缩包输出文件夹") else { return }
            model.batchCompress(sources: sourcesForCompression, to: destination, options: options)
            options.password = ""
            passwordConfirm = ""
            showCompressionSheet = false
            return
        }
        guard let url = CompressDestination.normalize(archiveDestPath, format: options.format) else {
            model.warn("请填写归档保存路径。")
            return
        }
        // ArchiveModel 出于安全拒绝覆盖已有文件：用户确认后先移除再创建。
        if FileManager.default.fileExists(atPath: url.path) {
            guard CompressDestination.confirmOverwrite(url) else { return }
            try? FileManager.default.removeItem(at: url)
        }
        model.compress(sources: sourcesForCompression, destination: url, options: options,
                       emailAfter: emailAfterCreate)
        emailAfterCreate = false
        options.password = ""
        passwordConfirm = ""
        showCompressionSheet = false
    }

    private func consumePassword() -> String? {
        let password = archivePassword
        archivePassword = ""
        return password.isEmpty ? nil : password
    }

    // MARK: - Menu bridge

    private func installMenuActions() {
        // 焦点切换后归档开关状态以本窗格为准（菜单「关闭压缩包 ⌘W」门控用）。
        actions.archiveOpen = inArchive
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
        actions.copyToOtherPane = { transferToOtherPane(move: false) }
        actions.moveToOtherPane = { transferToOtherPane(move: true) }
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
        // 解压到当前目录（Extract Here）：直接对所选归档操作，不要求先打开。
        actions.extractInPlace = { [model] urls in
            let archives = urls.filter { Self.archiveExtensions.contains($0.pathExtension.lowercased()) }
            guard !archives.isEmpty else {
                model.warn("所选项目不包含支持的压缩包（7z/zip/rar/tar/gz/xz）。")
                return
            }
            for archive in archives {
                model.extractArchive(archive, to: archive.deletingLastPathComponent(),
                                     createDirectory: false, conflict: conflict)
            }
            model.announce("已加入解压队列：\(archives.count) 个压缩包，解压到各自所在目录。")
        }
        // 解压到 "名称/"（同名子目录）。
        actions.extractToNamedFolder = { [model] urls in
            let archives = urls.filter { Self.archiveExtensions.contains($0.pathExtension.lowercased()) }
            guard !archives.isEmpty else {
                model.warn("所选项目不包含支持的压缩包（7z/zip/rar/tar/gz/xz）。")
                return
            }
            for archive in archives {
                let dest = archive.deletingLastPathComponent()
                    .appendingPathComponent(Self.baseName(for: [archive]), isDirectory: true)
                model.extractArchive(archive, to: dest, createDirectory: true, conflict: conflict)
            }
            model.announce("已加入解压队列：\(archives.count) 个压缩包，解压到各自同名文件夹。")
        }
        // 解压到…（弹窗选目录）。
        actions.extractChooseDestination = { [model] urls in
            let archives = urls.filter { Self.archiveExtensions.contains($0.pathExtension.lowercased()) }
            guard !archives.isEmpty, let dest = chooseFolderPanel(title: "选择解压目标目录") else { return }
            for archive in archives {
                model.extractArchive(archive, to: dest, createDirectory: false, conflict: conflict)
            }
            model.announce("已加入解压队列：\(archives.count) 个压缩包 → \(dest.path)")
        }
        // 测试压缩包。
        actions.testArchives = { [model] urls in
            let archives = urls.filter { Self.archiveExtensions.contains($0.pathExtension.lowercased()) }
            guard !archives.isEmpty else {
                model.warn("所选项目不包含支持的压缩包（7z/zip/rar/tar/gz/xz）。")
                return
            }
            for archive in archives { model.testArchive(archive) }
            showLog = true
        }
        // 添加到压缩包…（弹压缩选项；email=true 即「压缩并邮件…」）。
        actions.addToArchiveDialog = { urls, email in
            sourcesForCompression = urls
            batchCompression = false
            options = CompressionOptions()
            passwordConfirm = ""
            showCompressPassword = false
            archiveDestPath = defaultArchiveDestination()
            emailAfterCreate = email
            showCompressionSheet = true
        }
        // 添加到 "名称.7z" / "名称.zip"（免确认，默认选项）。
        actions.compressInPlace = { [model] urls, format in
            guard let first = urls.first else { return }
            let parent = first.deletingLastPathComponent()
            let base = Self.baseName(for: urls)
            var compressOptions = CompressionOptions()
            compressOptions.format = ArchiveFormat(rawValue: format) ?? .zip
            var destination = parent.appendingPathComponent("\(base).\(compressOptions.format.rawValue)")
            var suffix = 2
            while FileManager.default.fileExists(atPath: destination.path) {
                destination = parent.appendingPathComponent("\(base)-\(suffix).\(compressOptions.format.rawValue)")
                suffix += 1
            }
            model.compress(sources: urls, destination: destination, options: compressOptions)
            model.announce("已加入压缩队列：\(destination.lastPathComponent)")
        }
        // 压缩为 "名称.7z/zip" 并邮件。
        actions.compressAndEmail = { [model] urls, format in
            guard let first = urls.first else { return }
            let parent = first.deletingLastPathComponent()
            let base = Self.baseName(for: urls)
            var compressOptions = CompressionOptions()
            compressOptions.format = ArchiveFormat(rawValue: format) ?? .sevenZip
            var destination = parent.appendingPathComponent("\(base).\(compressOptions.format.rawValue)")
            var suffix = 2
            while FileManager.default.fileExists(atPath: destination.path) {
                destination = parent.appendingPathComponent("\(base)-\(suffix).\(compressOptions.format.rawValue)")
                suffix += 1
            }
            model.compress(sources: urls, destination: destination, options: compressOptions, emailAfter: true)
            model.announce("已加入压缩队列：\(destination.lastPathComponent)（完成后调出邮件）")
        }
        // CRC SHA：计算所选文件的校验和，结果显示在运行日志。
        actions.checksumFiles = { [model] urls, algorithm in
            guard !urls.isEmpty else { return }
            model.checksumFiles(urls, algorithm: algorithm)
            showLog = true
        }
        actions.handlersInstalled = true
    }

    /// 右键菜单基础名：单选取其文件名（剥离 .tar.gz 等复合扩展名），多选统一为 Archive。
    private static func baseName(for urls: [URL]) -> String {
        guard let first = urls.first, urls.count == 1 else { return "Archive" }
        let name = first.lastPathComponent
        let lower = name.lowercased()
        for compound in [".tar.gz", ".tar.bz2", ".tar.xz", ".tgz"] where lower.hasSuffix(compound) {
            return String(name.dropLast(compound.count))
        }
        return first.deletingPathExtension().lastPathComponent
    }

    /// 非焦点窗格安装：向焦点窗格暴露自己的位置与「接收文件」能力。
    private func installOtherPaneHooks() {
        actions.otherPaneDiskLocation = { inArchive ? nil : currentDir }
        actions.receiveFilesFromOtherPane = { [model] urls in
            if inArchive, canEditArchive {
                model.add(sources: urls, password: nil)
            } else {
                model.warn("另一窗格当前位置为只读，无法接收文件。")
            }
        }
    }

    /// F5/F6 跨窗格复制/移动（7zFM 行为）：目标是另一窗格的当前位置。
    private func transferToOtherPane(move: Bool) {
        guard !actionableSelection.isEmpty else { return }
        if let destination = actions.otherPaneDiskLocation() {
            // 另一窗格在磁盘目录：归档侧解压（移动 = 解压后从归档删除），本地侧拷贝/移动。
            if inArchive {
                let targets = expandedArchiveSelection
                // 只读归档（嵌套/rar）无法删除：「移动」必须明示拒绝，
                // 否则静默退化成复制（用户以为源已删除）。
                if move, !canEditArchive {
                    model.warn("当前归档为只读，无法移动；请使用复制。")
                    return
                }
                // 依赖组：解压失败时删除必须取消（移动退化成删除的数据丢失路径）。
                // extract 前置校验不过会拒绝入队并返回 false——此时绝不能调 delete。
                let group = move ? UUID() : nil
                if model.extract(to: destination, paths: targets, conflict: conflict,
                                 password: consumePassword(), group: group), move {
                    model.delete(paths: targets, password: nil, group: group)
                }
                selected.removeAll()
            } else {
                var failed = 0
                for url in selectedLocalURLs {
                    let target = destination.appendingPathComponent(url.lastPathComponent)
                    do {
                        if move {
                            try FileManager.default.moveItem(at: url, to: target)
                        } else {
                            try FileManager.default.copyItem(at: url, to: target)
                        }
                    } catch { failed += 1 }
                }
                if failed > 0 { model.warn("\(failed) 个项目操作失败（目标可能已存在同名文件）。") }
                selected.removeAll()
                refreshLocal()
            }
        } else if !inArchive {
            // 另一窗格在归档内：把本地选中文件加入其归档（由对方校验可写性）。
            actions.receiveFilesFromOtherPane(selectedLocalURLs)
        } else {
            model.warn("归档到归档的跨窗格操作暂不支持；请先释放到磁盘再操作。")
        }
    }
}
