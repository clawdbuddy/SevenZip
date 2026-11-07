import AppKit
import SwiftUI

enum FileListRowKind: Hashable { case up, folder, file }

struct FileListRow: Identifiable, Hashable {
    let id: String           // local: file path; archive: entry.path; up: sentinel ".."
    let kind: FileListRowKind
    let name: String
    let sizeText: String
    let packedText: String
    let modified: String
    let isArchiveFile: Bool
    /// 创建时间（本地文件与部分归档格式提供）。
    var createdText = ""
    /// 条目注释（归档格式支持时提供）。
    var commentText = ""
    /// 文件夹行：内部包含的子文件夹 / 文件数量（归档内即时统计）。
    var subfoldersText = ""
    var subfilesText = ""
    // 排序键（展示文本无法数值比较，单独携带）
    var sizeKey: Int64 = -1
    var packedKey: Int64 = -1
    var modifiedKey: String = ""   // ISO 风格字符串可直接字典序比较
    var createdKey: String = ""
}

struct FileListMenuAction {
    let title: String
    var destructive = false
    var enabled = true
    var isSeparator = false
    var action: () -> Void = {}

    static func separator() -> FileListMenuAction { FileListMenuAction(title: "", isSeparator: true) }
}

/// NSTableView-backed file list: SwiftUI's `Table` cannot reliably deliver
/// double-click activation or right-click context menus on macOS, both of
/// which are core to the 7-Zip File Manager interaction model.
struct FileListView: NSViewRepresentable {
    let rows: [FileListRow]
    @Binding var selection: Set<String>
    let onActivate: (FileListRow) -> Void
    let menuProvider: (FileListRow?) -> [FileListMenuAction]
    /// 点击表头排序时回调（空数组 = 恢复默认顺序）。
    var onSortChange: ([NSSortDescriptor]) -> Void = { _ in }
    /// 用户与列表发生交互（点击/选择/双击）时回调，双窗格模式下用于切换焦点。
    var onInteraction: () -> Void = {}
    /// 显示网格线（参考 7-Zip Options → Show grid lines）。
    var gridLines: Bool = false

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        // NSTableView 的右键菜单走 NSView.menu(for:)（delegate 没有对应回调），
        // 用 MenuTableView 子类转发给 Coordinator，同 IconListView 的 MenuCollectionView。
        let table = MenuTableView()
        table.menuProvider = { [weak coordinator = context.coordinator, weak table] event in
            guard let table else { return nil }
            return coordinator?.menu(for: event, in: table)
        }
        table.headerView = NSTableHeaderView()
        // Automatic row heights measure our constraint-built cells as ~2pt,
        // rendering every row invisible. A fixed row height is both correct
        // and faithful to 7zFM's compact list.
        table.usesAutomaticRowHeights = false
        table.rowHeight = 22
        table.intercellSpacing = NSSize(width: 12, height: 2)
        table.allowsMultipleSelection = true
        table.allowsEmptySelection = true
        // macOS 惯例（Finder/访达列表）：不画键盘焦点蓝环，焦点靠选中行
        // 颜色表达；否则列表一旦成为 first responder 四周就出现一圈蓝边。
        table.focusRingType = .none
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle

        let columns: [(String, String, CGFloat)] = [
            ("name", "名称", 300),
            ("size", "大小", 90),
            ("packed", "压缩后", 90),
            ("modified", "修改时间", 140),
            ("created", "创建时间", 140),
            ("comment", "注释", 110),
            ("folders", "文件夹", 60),
            ("files", "文件", 60),
        ]
        for (identifier, title, width) in columns {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier))
            column.title = title
            column.width = width
            column.minWidth = 50
            column.sortDescriptorPrototype = NSSortDescriptor(key: identifier, ascending: true)
            table.addTableColumn(column)
        }

        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        table.target = context.coordinator
        table.doubleAction = #selector(Coordinator.doubleClick(_:))

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        // macOS 11+ 样式：滚动条覆盖在内容上（Finder 同款），而非占位的老式滚动条。
        scroll.scrollerStyle = .overlay
        // 焦点环由外层滚动视图绘制（表格获焦时，环画在列表区四周），一并关掉。
        scroll.focusRingType = .none
        context.coordinator.table = table
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let table = context.coordinator.table else { return }
        table.gridStyleMask = gridLines ? [.solidHorizontalGridLineMask, .solidVerticalGridLineMask] : []
        table.reloadData()
        let indexes = rows.indices.filter { selection.contains(rows[$0].id) }
        // 程序化选择同步也会触发 SelectionDidChange 通知，加标志位避免
        // 状态刷新被误认为用户交互（双窗格下会盗取焦点）。
        context.coordinator.isSyncingSelection = true
        table.selectRowIndexes(IndexSet(indexes), byExtendingSelection: false)
        context.coordinator.isSyncingSelection = false
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var parent: FileListView
        weak var table: NSTableView?
        /// updateNSView 程序化同步选择期间为 true：跳过 onInteraction（防焦点盗取）。
        var isSyncingSelection = false

        init(_ parent: FileListView) { self.parent = parent }

        func numberOfRows(in tableView: NSTableView) -> Int { parent.rows.count }

        func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?,
                       row: Int) -> NSView? {
            guard let column, row < parent.rows.count else { return nil }
            let item = parent.rows[row]
            let identifier = NSUserInterfaceItemIdentifier("cell-\(column.identifier.rawValue)")
            let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? NSTableCellView
                ?? makeCell(identifier: identifier)
            switch column.identifier.rawValue {
            case "name":
                cell.textField?.stringValue = item.name
                cell.imageView?.image = NSImage(systemSymbolName: iconName(item),
                                                accessibilityDescription: nil)
                cell.imageView?.contentTintColor = iconColor(item)
                cell.imageView?.isHidden = false
            case "size":
                cell.textField?.stringValue = item.sizeText
                cell.imageView?.isHidden = true
            case "packed":
                cell.textField?.stringValue = item.packedText
                cell.imageView?.isHidden = true
            case "created":
                cell.textField?.stringValue = item.createdText
                cell.imageView?.isHidden = true
            case "comment":
                cell.textField?.stringValue = item.commentText
                cell.imageView?.isHidden = true
            case "folders":
                cell.textField?.stringValue = item.subfoldersText
                cell.imageView?.isHidden = true
            case "files":
                cell.textField?.stringValue = item.subfilesText
                cell.imageView?.isHidden = true
            default:
                cell.textField?.stringValue = item.modified
                cell.imageView?.isHidden = true
            }
            return cell
        }

        private func makeCell(identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
            let cell = NSTableCellView()
            cell.identifier = identifier
            let image = NSImageView()
            image.translatesAutoresizingMaskIntoConstraints = false
            let text = NSTextField(labelWithString: "")
            text.translatesAutoresizingMaskIntoConstraints = false
            text.lineBreakMode = .byTruncatingMiddle
            cell.addSubview(image)
            cell.addSubview(text)
            cell.imageView = image
            cell.textField = text
            NSLayoutConstraint.activate([
                image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                image.widthAnchor.constraint(equalToConstant: 16),
                image.heightAnchor.constraint(equalToConstant: 16),
                text.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 6),
                text.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -2),
                text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return cell
        }

        private func iconName(_ row: FileListRow) -> String {
            switch row.kind {
            case .up: return "arrow.turn.left.up"
            case .folder: return "folder"
            case .file: return row.isArchiveFile ? "doc.zipper" : "doc"
            }
        }

        private func iconColor(_ row: FileListRow) -> NSColor {
            switch row.kind {
            case .up: return .secondaryLabelColor
            case .folder: return .systemBrown
            case .file: return row.isArchiveFile ? .controlAccentColor : .secondaryLabelColor
            }
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard let table else { return }
            if !isSyncingSelection { parent.onInteraction() }
            let selected = table.selectedRowIndexes
                .filter { $0 < parent.rows.count }
                .map { parent.rows[$0].id }
            let newSelection = Set(selected)
            if newSelection != parent.selection { parent.selection = newSelection }
        }

        @objc func doubleClick(_ sender: NSTableView) {
            let row = sender.clickedRow
            guard row >= 0, row < parent.rows.count else { return }
            parent.onActivate(parent.rows[row])
        }

        func tableView(_ tableView: NSTableView,
                       sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            parent.onSortChange(tableView.sortDescriptors)
        }

        // MARK: Context menu

        /// 由 MenuTableView.menu(for:) 转发而来（NSTableViewDelegate 并没有
        /// menuFor 回调，直接挂在 Coordinator 上永远不会被系统调用）。
        func menu(for event: NSEvent, in tableView: NSTableView) -> NSMenu? {
            let point = tableView.convert(event.locationInWindow, from: nil)
            let row = tableView.row(at: point)
            var target: FileListRow?
            if row >= 0, row < parent.rows.count {
                let item = parent.rows[row]
                target = item
                // Right-clicking an unselected row moves the selection to it,
                // matching Finder and 7zFM behavior.
                if item.kind != .up, !parent.selection.contains(item.id) {
                    parent.selection = [item.id]
                    tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                }
            }
            let actions = parent.menuProvider(target)
            guard !actions.isEmpty else { return nil }
            let menu = NSMenu()
            for spec in actions {
                if spec.isSeparator {
                    menu.addItem(.separator())
                    continue
                }
                let menuItem = NSMenuItem(title: spec.title, action: #selector(runMenuAction(_:)),
                                          keyEquivalent: "")
                menuItem.target = self
                menuItem.isEnabled = spec.enabled
                menuItem.representedObject = Box(spec.action)
                if spec.destructive, spec.enabled {
                    // 危险操作红色显示（原代码 attributedTitle = nil 是空操作）。
                    menuItem.attributedTitle = NSAttributedString(
                        string: spec.title,
                        attributes: [.foregroundColor: NSColor.systemRed])
                }
                menu.addItem(menuItem)
            }
            return menu
        }

        /// NSMenuItem.representedObject requires an NSObject; box the closure.
        final class Box: NSObject {
            let action: () -> Void
            init(_ action: @escaping () -> Void) { self.action = action }
        }

        @objc private func runMenuAction(_ sender: NSMenuItem) {
            (sender.representedObject as? Box)?.action()
        }
    }

    /// 右键菜单走 NSView.menu(for:)，子类转发给 Coordinator（同 IconListView）。
    private final class MenuTableView: NSTableView {
        var menuProvider: ((NSEvent) -> NSMenu?)?
        override func menu(for event: NSEvent) -> NSMenu? {
            menuProvider?(event) ?? super.menu(for: event)
        }
    }
}
