import AppKit
import SwiftUI

/// 大图标视图（7zFM 查看菜单的视图模式之一）：NSCollectionView 网格。
/// 与 FileListView 共用 FileListRow / FileListMenuAction 协议，
/// 双击进入、右键菜单、多选行为保持一致。
struct IconListView: NSViewRepresentable {
    let rows: [FileListRow]
    @Binding var selection: Set<String>
    let onActivate: (FileListRow) -> Void
    let menuProvider: (FileListRow?) -> [FileListMenuAction]
    /// 用户与视图交互时回调（双窗格焦点切换）。
    var onInteraction: () -> Void = {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let layout = NSCollectionViewGridLayout()
        layout.maximumItemSize = NSSize(width: 96, height: 84)
        layout.minimumItemSize = NSSize(width: 96, height: 84)
        layout.minimumInteritemSpacing = 8
        layout.minimumLineSpacing = 8
        layout.margins = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)

        let collection = MenuCollectionView()
        collection.collectionViewLayout = layout
        collection.isSelectable = true
        collection.allowsMultipleSelection = true
        collection.allowsEmptySelection = true
        collection.backgroundColors = [.textBackgroundColor]
        collection.register(IconItem.self, forItemWithIdentifier: IconItem.identifier)

        collection.dataSource = context.coordinator
        collection.delegate = context.coordinator
        // 闭包存回 collection 自身，必须弱引用捕获，否则循环泄漏
        // （同 FileListView 的 [weak table]）。
        collection.menuProvider = { [weak coordinator = context.coordinator, weak collection] event in
            guard let collection else { return nil }
            return coordinator?.menu(for: event, in: collection)
        }

        let scroll = NSScrollView()
        scroll.documentView = collection
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        context.coordinator.collection = collection

        // 双击 = 激活（进入文件夹 / 打开文件）。
        let doubleClick = NSClickGestureRecognizer(target: context.coordinator,
                                                   action: #selector(Coordinator.doubleClick(_:)))
        doubleClick.numberOfClicksRequired = 2
        collection.addGestureRecognizer(doubleClick)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let collection = context.coordinator.collection else { return }
        collection.reloadData()
        let indexes = rows.indices.filter { selection.contains(rows[$0].id) }
        // 程序化选择同步也会触发 didSelect/didDeselect 回调，加标志位避免
        // 状态刷新被误认为用户交互（双窗格下会盗取焦点）。
        context.coordinator.isSyncingSelection = true
        collection.selectionIndexPaths = Set(indexes.map { IndexPath(item: $0, section: 0) })
        context.coordinator.isSyncingSelection = false
    }

    @MainActor
    final class Coordinator: NSObject, NSCollectionViewDataSource, NSCollectionViewDelegate {
        var parent: IconListView
        weak var collection: NSCollectionView?
        /// updateNSView 程序化同步选择期间为 true：跳过 onInteraction（防焦点盗取）。
        var isSyncingSelection = false

        init(_ parent: IconListView) { self.parent = parent }

        func collectionView(_ collectionView: NSCollectionView,
                            numberOfItemsInSection section: Int) -> Int { parent.rows.count }

        func collectionView(_ collectionView: NSCollectionView,
                            itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
            let item = collectionView.makeItem(withIdentifier: IconItem.identifier,
                                               for: indexPath) as! IconItem
            let row = parent.rows[indexPath.item]
            item.configure(row)
            return item
        }

        func collectionView(_ collectionView: NSCollectionView,
                            didSelectItemsAt indexPaths: Set<IndexPath>) {
            if !isSyncingSelection { parent.onInteraction() }
            syncSelection(collectionView)
        }

        func collectionView(_ collectionView: NSCollectionView,
                            didDeselectItemsAt indexPaths: Set<IndexPath>) {
            if !isSyncingSelection { parent.onInteraction() }
            syncSelection(collectionView)
        }

        private func syncSelection(_ collectionView: NSCollectionView) {
            let ids = collectionView.selectionIndexPaths
                .filter { $0.item < parent.rows.count }
                .map { parent.rows[$0.item].id }
            let newSelection = Set(ids)
            if newSelection != parent.selection { parent.selection = newSelection }
        }

        @objc func doubleClick(_ gesture: NSClickGestureRecognizer) {
            guard let collection else { return }
            let point = gesture.location(in: collection)
            guard let indexPath = collection.indexPathForItem(at: point),
                  indexPath.item < parent.rows.count else { return }
            parent.onActivate(parent.rows[indexPath.item])
        }

        // MARK: Context menu（与 FileListView 同一套 FileListMenuAction）

        func menu(for event: NSEvent, in collectionView: NSCollectionView) -> NSMenu? {
            let point = collectionView.convert(event.locationInWindow, from: nil)
            var target: FileListRow?
            if let indexPath = collectionView.indexPathForItem(at: point),
               indexPath.item < parent.rows.count {
                let row = parent.rows[indexPath.item]
                target = row
                if row.kind != .up, !parent.selection.contains(row.id) {
                    parent.selection = [row.id]
                    collectionView.selectionIndexPaths = [indexPath]
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
                    // 危险操作红色显示（与 FileListView 一致）。
                    menuItem.attributedTitle = NSAttributedString(
                        string: spec.title,
                        attributes: [.foregroundColor: NSColor.systemRed])
                }
                menu.addItem(menuItem)
            }
            return menu
        }

        final class Box: NSObject {
            let action: () -> Void
            init(_ action: @escaping () -> Void) { self.action = action }
        }

        @objc private func runMenuAction(_ sender: NSMenuItem) {
            (sender.representedObject as? Box)?.action()
        }
    }

    /// NSCollectionView 的右键菜单走 NSView.menu(for:)，用子类转发给 Coordinator。
    private final class MenuCollectionView: NSCollectionView {
        var menuProvider: ((NSEvent) -> NSMenu?)?
        override func menu(for event: NSEvent) -> NSMenu? {
            menuProvider?(event) ?? super.menu(for: event)
        }
    }

    /// 网格单元：大图标 + 名称（两行截断）。
    final class IconItem: NSCollectionViewItem {
        static let identifier = NSUserInterfaceItemIdentifier("icon-item")

        private let iconView = NSImageView()
        private let nameLabel = NSTextField(labelWithString: "")

        override func loadView() {
            let container = NSView()
            iconView.translatesAutoresizingMaskIntoConstraints = false
            iconView.imageScaling = .scaleProportionallyUpOrDown
            nameLabel.translatesAutoresizingMaskIntoConstraints = false
            nameLabel.alignment = .center
            nameLabel.lineBreakMode = .byTruncatingTail
            nameLabel.maximumNumberOfLines = 2
            nameLabel.font = .systemFont(ofSize: 11)
            container.addSubview(iconView)
            container.addSubview(nameLabel)
            NSLayoutConstraint.activate([
                iconView.topAnchor.constraint(equalTo: container.topAnchor, constant: 4),
                iconView.centerXAnchor.constraint(equalTo: container.centerXAnchor),
                iconView.widthAnchor.constraint(equalToConstant: 40),
                iconView.heightAnchor.constraint(equalToConstant: 40),
                nameLabel.topAnchor.constraint(equalTo: iconView.bottomAnchor, constant: 2),
                nameLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 2),
                nameLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -2),
                nameLabel.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -2),
            ])
            view = container
        }

        func configure(_ row: FileListRow) {
            nameLabel.stringValue = row.name
            let symbol: String
            let color: NSColor
            switch row.kind {
            case .up: symbol = "arrow.turn.left.up"; color = .secondaryLabelColor
            case .folder: symbol = "folder.fill"; color = .systemBrown
            case .file:
                symbol = row.isArchiveFile ? "doc.zipper" : "doc.fill"
                color = row.isArchiveFile ? .controlAccentColor : .secondaryLabelColor
            }
            iconView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            iconView.contentTintColor = color
        }

        override var isSelected: Bool {
            didSet {
                view.wantsLayer = true
                view.layer?.cornerRadius = 6
                view.layer?.backgroundColor = isSelected
                    ? NSColor.selectedContentBackgroundColor.withAlphaComponent(0.35).cgColor
                    : NSColor.clear.cgColor
            }
        }
    }
}
