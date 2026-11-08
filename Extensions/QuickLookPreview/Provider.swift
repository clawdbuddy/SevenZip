import AppKit
import Foundation
import Quartz

/// Quick Look 预览扩展：空格预览压缩包内容。
/// 对齐 7-Zip macOS 1.2.x 的预览设计：
/// - 顶部摘要行：`7z · LZMA2:12 · Solid · 文件 2 · 209829 → 172759 字节 (82%)`
/// - 其下注释行：加密 / 分卷 / 条目截断（2 秒或 10000 条上限）
/// - 树形清单（文件夹在前，可展开），列：名称/大小/压缩后/修改时间
/// 运行内嵌的 7zz `l -slt`，复用 ArchiveCore 的清单解析与 GBK 名称恢复。
final class Provider: NSViewController, QLPreviewingController {

    /// 预览生成上限：超过 2 秒或 10000 条则截断并提示（参考项目同款策略）。
    private static let timeLimit: TimeInterval = 2
    private static let entryLimit = 10_000
    /// 硬超时：后台读线程可能被不可中断 I/O（SMB/NFS 卡死）永久阻塞，
    /// 两级看门狗（SIGTERM→SIGKILL）对它无效 → completion handler 永不
    /// 调用 → Quick Look 一直转圈。到点无条件完成，宁可空预览也不挂起。
    private static let hardTimeout: TimeInterval = 8

    private let outline = NSOutlineView()
    private let summaryLabel = NSTextField(labelWithString: "")
    private let noteLabel = NSTextField(labelWithString: "")
    private var rootNodes: [Node] = []
    /// 递增请求序号：Quick Look 复用同一 Provider 连续预览时，
    /// 慢请求的结果不得覆盖新请求的界面（结果乱序）。
    private var requestID = 0

    /// 树节点：目录持有子节点；文件即叶子。
    private final class Node {
        let name: String
        let isFolder: Bool
        let entry: ArchiveEntry?
        var children: [Node] = []
        init(name: String, isFolder: Bool, entry: ArchiveEntry?) {
            self.name = name
            self.isFolder = isFolder
            self.entry = entry
        }
    }

    override func loadView() {
        let container = NSView()

        summaryLabel.font = .systemFont(ofSize: 12, weight: .medium)
        summaryLabel.lineBreakMode = .byTruncatingMiddle
        summaryLabel.translatesAutoresizingMaskIntoConstraints = false
        noteLabel.font = .systemFont(ofSize: 11)
        noteLabel.textColor = .secondaryLabelColor
        noteLabel.lineBreakMode = .byTruncatingMiddle
        noteLabel.translatesAutoresizingMaskIntoConstraints = false

        let columns: [(String, String, CGFloat)] = [
            ("name", "名称", 320),
            ("size", "大小", 90),
            ("packed", "压缩后", 90),
            ("modified", "修改时间", 150),
        ]
        for (index, spec) in columns.enumerated() {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(spec.0))
            column.title = spec.1
            column.width = spec.2
            outline.addTableColumn(column)
            if index == 0 { outline.outlineTableColumn = column }
        }
        outline.headerView = NSTableHeaderView()
        outline.usesAutomaticRowHeights = false
        outline.rowHeight = 20
        outline.indentationPerLevel = 14
        outline.dataSource = self
        outline.delegate = self

        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(summaryLabel)
        container.addSubview(noteLabel)
        container.addSubview(scroll)
        NSLayoutConstraint.activate([
            summaryLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
            summaryLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            summaryLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            noteLabel.topAnchor.constraint(equalTo: summaryLabel.bottomAnchor, constant: 2),
            noteLabel.leadingAnchor.constraint(equalTo: summaryLabel.leadingAnchor),
            noteLabel.trailingAnchor.constraint(equalTo: summaryLabel.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: noteLabel.bottomAnchor, constant: 6),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        view = container
    }

    func preparePreviewOfFile(at url: URL, completionHandler handler: @escaping (Error?) -> Void) {
        summaryLabel.stringValue = "正在读取 \(url.lastPathComponent) …"
        noteLabel.stringValue = ""
        // 新请求开始时清空旧归档的树，避免旧内容在新摘要行下方闪现到新结果到达。
        rootNodes = []
        outline.reloadData()
        requestID += 1
        let id = requestID
        // 完成回调的一次性闸门：保证 handler 恰好被调用一次
        // （后台线程可能永不返回，硬超时是唯一兜底）。
        let gate = CompletionGate()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Self.listArchive(url)
            DispatchQueue.main.async { [weak self] in
                // 过期请求（用户已切换到另一个文件）：完成回调但不得更新界面。
                // self 已释放时也必须调 handler，否则 Quick Look 挂起。
                guard let self, self.requestID == id else { gate.fire(handler); return }
                // 硬超时已经触发：Quick Look 已经收尾，不再更新界面。
                guard !gate.hasFired else { return }
                self.summaryLabel.stringValue = result.summary
                self.noteLabel.stringValue = result.note
                self.rootNodes = result.nodes
                self.outline.reloadData()
                // 默认展开第一层，让用户立刻看到结构。
                for node in self.rootNodes where !node.children.isEmpty {
                    self.outline.expandItem(node)
                }
                gate.fire(handler)   // 即使失败也返回成功，避免 Quick Look 显示系统错误页
            }
        }
        // 硬超时兜底：后台线程被不可中断 I/O 卡死时，本回调是唯一的出口。
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.hardTimeout) {
            gate.fire(handler)
        }
    }

    /// 完成回调的一次性闸门（线程安全）。
    private final class CompletionGate: @unchecked Sendable {
        private let lock = NSLock()
        private var fired = false
        var hasFired: Bool {
            lock.lock(); defer { lock.unlock() }; return fired
        }
        /// 返回 true 表示本次调用赢得了闸门（此前未触发）。
        @discardableResult
        func fire(_ handler: @escaping (Error?) -> Void) -> Bool {
            lock.lock()
            let won = !fired
            fired = true
            lock.unlock()
            if won { handler(nil) }
            return won
        }
    }

    // MARK: - 清单读取与树构建

    private struct ListResult {
        var summary = ""
        var note = ""
        var nodes: [Node] = []
    }

    /// 沙箱扩展只能执行自身 bundle 内的程序：优先用内嵌在扩展里的 7zz，
    /// 兜底再尝试主 app 的 Contents/Resources/bin/7zz。
    private static func engineURL() -> URL? {
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/bin/7zz")
        if FileManager.default.isExecutableFile(atPath: bundled.path) { return bundled }
        let hostApp = Bundle.main.bundleURL
            .deletingLastPathComponent()   // PlugIns
            .deletingLastPathComponent()   // Contents
        let engine = hostApp.appendingPathComponent("Resources/bin/7zz")
        return FileManager.default.isExecutableFile(atPath: engine.path) ? engine : nil
    }

    private static func listArchive(_ url: URL) -> ListResult {
        var result = ListResult()
        guard let engine = engineURL() else {
            result.summary = "未找到内置 7zz 引擎"
            return result
        }
        // 必须用 posix_spawn：Foundation Process 经 fileSystemRepresentation 会把
        // argv 归一化为 NFD，NFC 文件名（é、日韩音节）在 ExFAT/SMB 卷上直接打不开。
        var environment = ProcessInfo.processInfo.environment
        environment["LC_ALL"] = "C"
        let spawned: SpawnedProcess
        do {
            spawned = try SpawnedProcess.launch(executable: engine,
                                                arguments: ["l", "-slt", url.path],
                                                directory: nil,
                                                environment: environment)
        } catch {
            result.summary = "无法启动 7zz：\(error.localizedDescription)"
            return result
        }
        // 此路径不需要密码输入，立即关闭 stdin：文件名加密（-mhe）时 7zz 会阻塞
        // 等待密码输入，stdin 一直开着必撑满超时被杀；读到 EOF 则 7zz 以非零码
        // 退出且输出含 password，正好落入下方的加密提示分支。
        spawned.stdinWrite.closeFile()
        // 限时读取：超过 timeLimit 杀掉进程，用已捕获的部分输出解析。
        let finished = NSLock()
        var didFinish = false
        var timedOut = false
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + timeLimit) {
            finished.lock()
            let done = didFinish
            if !done { timedOut = true }
            finished.unlock()
            if !done {
                kill(spawned.pid, SIGTERM)
                // 二级看门狗：SIGTERM 被忽略或进程处于不可中断 I/O 时升级 SIGKILL，
                // 否则 availableData 永久阻塞，本队列线程随之泄漏。
                DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.5) {
                    finished.lock()
                    let stillRunning = !didFinish
                    finished.unlock()
                    if stillRunning { kill(spawned.pid, SIGKILL) }
                }
            }
        }
        var captured = Data()
        // 字节上限：条目极多的归档（几十万~百万条）会让清单文本达到几百 MB，
        // 扩展进程被 jetsam 掉——崩的是 Quick Look 宿主，用户侧非常显眼。
        let maximumBytes = 16 * 1024 * 1024
        while true {
            let chunk = spawned.stdoutRead.availableData
            if chunk.isEmpty { break }
            let remaining = max(0, maximumBytes - captured.count)
            if remaining == 0 { break }
            captured.append(contentsOf: chunk.prefix(remaining))
        }
        // EOF 意味着进程已关闭 stdout（基本退出完成），此时先置"无需再杀"标记，
        // 避免"进程已正常退出但 waitpid 尚未返回"的窗口期被看门狗误标超时。
        finished.lock()
        didFinish = true
        finished.unlock()
        let code = spawned.waitForExit()
        finished.lock()
        let wasTimedOut = timedOut
        finished.unlock()

        let text = String(decoding: captured, as: UTF8.self)

        // 文件名加密的归档无法在无密码状态下列表——这不是错误，如实提示。
        // 超时被杀的退出码必非零（143），但部分输出仍然有效，照常解析。
        guard wasTimedOut || code == 0, !text.isEmpty else {
            if text.localizedCaseInsensitiveContains("password") {
                result.summary = url.lastPathComponent
                result.note = "文件名已加密，请在七压中输入密码查看。"
            } else {
                result.summary = "无法读取压缩包（7zz 退出码 \(code)）"
            }
            return result
        }

        var entries = ArchiveListing.parse(text)
        if url.pathExtension.lowercased() == "zip" {
            entries = ArchiveListing.recoveringLegacyZipNames(entries)
        }
        let totalCount = entries.count
        if entries.count > entryLimit {
            entries = Array(entries.prefix(entryLimit))
        }

        // 摘要行：类型 · 方法 · Solid · 文件/文件夹计数 · 原始 → 物理大小 (压缩率)
        let header = ArchiveListing.parseSummary(text)
        let files = entries.filter { !$0.isDirectory }
        let folders = entries.count - files.count
        var parts: [String] = []
        if !header.type.isEmpty { parts.append(header.type) }
        if !header.method.isEmpty { parts.append(header.method) }
        if header.solid { parts.append("Solid") }
        parts.append("文件 \(files.count)" + (folders > 0 ? " · 文件夹 \(folders)" : ""))
        let totalSize = files.compactMap(\.size).reduce(0, +)
        if let physical = header.physicalSize, totalSize > 0 {
            let ratio = Int((Double(physical) / Double(totalSize)) * 100)
            parts.append("\(totalSize) → \(physical) 字节 (\(ratio)%)")
        } else if totalSize > 0 {
            parts.append("共 \(ByteCountFormatter.string(fromByteCount: totalSize, countStyle: .file))")
        }
        result.summary = parts.joined(separator: " · ")

        // 注释行：分卷 / 截断提示。
        var notes: [String] = []
        if header.multivolume { notes.append("属于分卷压缩包") }
        if totalCount > entryLimit {
            notes.append("…另有 \(totalCount - entryLimit) 项 — 在七压中打开")
        } else if wasTimedOut {
            notes.append("预览超时，仅显示前 \(entries.count) 项 — 在七压中打开")
        }
        result.note = notes.joined(separator: "；")

        result.nodes = buildTree(entries)
        return result
    }

    /// 由完整相对路径构建树；每层文件夹在前、按名称排序。
    private static func buildTree(_ entries: [ArchiveEntry]) -> [Node] {
        let root = Node(name: "", isFolder: true, entry: nil)
        for entry in entries {
            let components = entry.path.split(separator: "/").map(String.init)
            guard !components.isEmpty else { continue }
            var parent = root
            for (index, component) in components.enumerated() {
                let isLeaf = index == components.count - 1
                let isFolderNode = !isLeaf || entry.isDirectory
                if let existing = parent.children.first(where: {
                    $0.name == component && $0.isFolder == isFolderNode
                }) {
                    parent = existing
                    continue
                }
                let node = Node(name: component, isFolder: isFolderNode,
                                entry: isFolderNode ? (isLeaf ? entry : nil) : entry)
                parent.children.append(node)
                parent = node
            }
        }
        func sortLevel(_ nodes: [Node]) {
            for node in nodes {
                node.children.sort { lhs, rhs in
                    if lhs.isFolder != rhs.isFolder { return lhs.isFolder }
                    return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
                }
                sortLevel(node.children)
            }
        }
        sortLevel(root.children)
        return root.children
    }
}

extension Provider: NSOutlineViewDataSource, NSOutlineViewDelegate {
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let node = item as? Node else { return rootNodes.count }
        return node.children.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let node = item as? Node else { return rootNodes[index] }
        return node.children[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let node = item as? Node else { return false }
        return !node.children.isEmpty
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor column: NSTableColumn?,
                     item: Any) -> NSView? {
        guard let column, let node = item as? Node else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("cell-\(column.identifier.rawValue)")
        let cell = outlineView.makeView(withIdentifier: identifier, owner: nil) as? NSTableCellView
            ?? {
                let cell = NSTableCellView()
                cell.identifier = identifier
                let label = NSTextField(labelWithString: "")
                label.translatesAutoresizingMaskIntoConstraints = false
                label.lineBreakMode = .byTruncatingMiddle
                cell.addSubview(label)
                cell.textField = label
                NSLayoutConstraint.activate([
                    label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                    label.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -2),
                    label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                ])
                return cell
            }()
        switch column.identifier.rawValue {
        case "name": cell.textField?.stringValue = node.name
        case "size": cell.textField?.stringValue = node.entry?.sizeLabel ?? ""
        case "packed": cell.textField?.stringValue = node.entry?.packedLabel ?? ""
        default: cell.textField?.stringValue = node.entry?.modified ?? ""
        }
        return cell
    }
}
