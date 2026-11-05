import AppKit
import Foundation
import Quartz

/// Quick Look 预览扩展：空格预览压缩包内容清单。
/// 运行主 app 内打包的 7zz `l -slt`，复用 ArchiveCore 的清单解析与 GBK 名称恢复。
/// 注意：本扩展不带 sandbox entitlement（ad-hoc 签名），否则可能无法 spawn 7zz。
final class Provider: NSViewController, QLPreviewingController {

    private let table = NSTableView()
    private let headerLabel = NSTextField(labelWithString: "")
    private var entries: [ArchiveEntry] = []

    override func loadView() {
        let container = NSView()

        headerLabel.font = .boldSystemFont(ofSize: 13)
        headerLabel.lineBreakMode = .byTruncatingMiddle
        headerLabel.translatesAutoresizingMaskIntoConstraints = false

        let columns: [(String, String, CGFloat)] = [
            ("name", "名称", 320),
            ("size", "大小", 90),
            ("packed", "压缩后", 90),
            ("modified", "修改时间", 150),
        ]
        for (identifier, title, width) in columns {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier))
            column.title = title
            column.width = width
            table.addTableColumn(column)
        }
        table.headerView = NSTableHeaderView()
        table.usesAutomaticRowHeights = false
        table.rowHeight = 20
        table.dataSource = self
        table.delegate = self

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(headerLabel)
        container.addSubview(scroll)
        NSLayoutConstraint.activate([
            headerLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: 10),
            headerLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            headerLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            scroll.topAnchor.constraint(equalTo: headerLabel.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        view = container
    }

    func preparePreviewOfFile(at url: URL, completionHandler handler: @escaping (Error?) -> Void) {
        headerLabel.stringValue = "正在读取 \(url.lastPathComponent) …"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Self.listArchive(url)
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success(let entries):
                    self.entries = entries
                    let files = entries.filter { !$0.isDirectory }
                    let total = files.compactMap(\.size).reduce(0, +)
                    self.headerLabel.stringValue =
                        "\(url.lastPathComponent) — \(files.count) 个文件，共 "
                        + ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
                    self.table.reloadData()
                    handler(nil)
                case .failure(let error):
                    self.headerLabel.stringValue = "无法读取压缩包：\(error.localizedDescription)"
                    handler(nil)   // 仍返回成功，避免 Quick Look 显示系统错误页
                }
            }
        }
    }

    private enum ListError: LocalizedError {
        case engineMissing, engineFailed(String)
        var errorDescription: String? {
            switch self {
            case .engineMissing: return "未找到主程序内置的 7zz 引擎"
            case .engineFailed(let detail): return detail
            }
        }
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

    private static func listArchive(_ url: URL) -> Result<[ArchiveEntry], Error> {
        guard let engine = engineURL() else { return .failure(ListError.engineMissing) }
        let process = Process()
        process.executableURL = engine
        process.arguments = ["l", "-slt", url.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return .failure(error)
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0, let text = String(data: data, encoding: .utf8) else {
            return .failure(ListError.engineFailed("7zz 退出码 \(process.terminationStatus)"))
        }
        return .success(ArchiveListing.recoveringLegacyZipNames(ArchiveListing.parse(text)))
    }
}

extension Provider: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }

    func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?,
                   row: Int) -> NSView? {
        guard let column, row < entries.count else { return nil }
        let entry = entries[row]
        let text: String
        switch column.identifier.rawValue {
        case "name": text = (entry.isDirectory ? "📁 " : "") + entry.path
        case "size": text = entry.sizeLabel
        case "packed": text = entry.packedLabel
        default: text = entry.modified
        }
        let identifier = NSUserInterfaceItemIdentifier("cell-\(column.identifier.rawValue)")
        let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? NSTableCellView
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
        cell.textField?.stringValue = text
        return cell
    }
}
