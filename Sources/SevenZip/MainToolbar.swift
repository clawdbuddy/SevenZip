import AppKit
import ArchiveCore

/// 原生窗口工具栏（macOS 风格）。
///
/// 为什么用 AppKit NSToolbar 而不是 SwiftUI 视图：窗口本体是手动管理的
/// NSWindow（不用 WindowGroup，理由见 MainWindowController），SwiftUI 的
/// .toolbar 只在 SwiftUI 场景里生效，NSHostingView 里拿不到真正的标题栏
/// 工具栏。原生 NSToolbar 才能与标题栏融为一体（unified 风格）、拿到系统
/// 的毛玻璃底、正确的工具栏项悬停高亮、右键菜单与拖拽重排行为。
///
/// 动作全部经 AppActions 转发到焦点窗格（与菜单同一套处理器），工具栏
/// 只是入口的第二种呈现。
@MainActor
final class MainToolbarController: NSObject, NSToolbarDelegate {

    /// 工具栏项标识（AppKit 用它做状态恢复与 item 复用）。
    private enum ID {
        static let add = NSToolbarItem.Identifier("SevenZip.add")
        static let extract = NSToolbarItem.Identifier("SevenZip.extract")
        static let test = NSToolbarItem.Identifier("SevenZip.test")
        static let copy = NSToolbarItem.Identifier("SevenZip.copy")
        static let move = NSToolbarItem.Identifier("SevenZip.move")
        static let delete = NSToolbarItem.Identifier("SevenZip.delete")
        static let info = NSToolbarItem.Identifier("SevenZip.info")
        static let flexible = NSToolbarItem.Identifier("SevenZip.flexible")
        static let conflict = NSToolbarItem.Identifier("SevenZip.conflict")
        static let dualPane = NSToolbarItem.Identifier("SevenZip.dualPane")
    }

    /// 工具项与 AppActions.PaneTool 的对应关系。
    private static let toolIdentifiers: [(id: NSToolbarItem.Identifier, tool: AppActions.PaneTool)] = [
        (ID.add, .add), (ID.extract, .extract), (ID.test, .test),
        (ID.copy, .copy), (ID.move, .move), (ID.delete, .delete), (ID.info, .info),
    ]

    /// 文件冲突策略弹出按钮（需要自定义视图，标准工具项放不下）。
    private final class ConflictItem: NSToolbarItem {
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)

        override init(itemIdentifier: NSToolbarItem.Identifier) {
            super.init(itemIdentifier: itemIdentifier)
            for policy in ConflictPolicy.allCases {
                popup.addItem(withTitle: policy.title)
            }
            popup.target = self
            popup.action = #selector(changed)
            view = popup
            paletteLabel = "文件冲突"
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) 未实现") }

        @objc private func changed() {
            guard let title = popup.titleOfSelectedItem,
                  let policy = ConflictPolicy.allCases.first(where: { $0.title == title }) else { return }
            AppActions.shared.conflictPolicyChanged(policy)
        }
    }

    /// 工具项动作接收者：把标准工具项的点击转成 AppActions 调用。
    @MainActor
    private final class ToolTarget: NSObject {
        let tool: AppActions.PaneTool
        init(tool: AppActions.PaneTool) { self.tool = tool }

        @objc func fire() {
            // 双重保险：即使系统没把置灰状态同步到工具项，也不会误触发动作。
            guard AppActions.shared.paneToolState.isEnabled(tool) else { return }
            AppActions.shared.paneToolAction(tool)
        }
    }

    /// 工具项 → 动作接收者的映射（NSToolbarItem 的 target 是弱引用，须强持有）。
    private var targets: [NSToolbarItem.Identifier: ToolTarget] = [:]

    /// 双窗格开关（7zFM F9）——需要开/关两种状态，用自定义按钮。
    private final class DualPaneItem: NSToolbarItem {
        let button = NSButton(image: NSImage(systemSymbolName: "rectangle.split.2x1",
                                             accessibilityDescription: "双窗格") ?? NSImage(),
                              target: nil, action: nil)

        override init(itemIdentifier: NSToolbarItem.Identifier) {
            super.init(itemIdentifier: itemIdentifier)
            button.bezelStyle = .inline
            button.setButtonType(.toggle)
            button.toolTip = "双窗格（⌃⌥T / F9）"
            button.target = self
            button.action = #selector(fire)
            view = button
            paletteLabel = "双窗格"
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) 未实现") }

        @objc private func fire() {
            AppActions.shared.toggleDualPane()
        }
    }


    // MARK: - 构造

    func makeToolbar() -> NSToolbar {
        let toolbar = NSToolbar(identifier: "SevenZip.MainToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        // 不开放自定义与布局持久化：工具项是核心操作入口，固定排列更可预期
        // （也避免用户误删后无法恢复）。
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = false
        return toolbar
    }

    // MARK: - NSToolbarDelegate

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [ID.add, ID.extract, ID.test, ID.copy, ID.move, ID.delete, ID.info,
         ID.flexible, ID.conflict, ID.dualPane]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch identifier {
        case ID.conflict:
            return ConflictItem(itemIdentifier: identifier)
        case ID.dualPane:
            return DualPaneItem(itemIdentifier: identifier)
        default:
            guard let entry = Self.toolIdentifiers.first(where: { $0.id == identifier }) else { return nil }
            let symbol: String
            let title: String
            let help: String
            switch entry.tool {
            case .add:
                symbol = "plus"; title = "添加"; help = "把所选文件加入压缩包"
            case .extract:
                symbol = "arrow.up.doc"; title = "释放"; help = "从归档中释放所选项目"
            case .test:
                symbol = "checkmark.circle"; title = "测试"; help = "测试归档完整性"
            case .copy:
                symbol = "doc.on.doc"; title = "复制"; help = "复制所选项目"
            case .move:
                symbol = "rectangle.portrait.and.arrow.right"; title = "移动"; help = "移动所选项目"
            case .delete:
                symbol = "trash"; title = "删除"; help = "删除所选项目"
            case .info:
                symbol = "info.circle"; title = "信息"; help = "查看详细信息"
            }
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
            item.label = title
            item.paletteLabel = title
            item.toolTip = help
            // 项是延迟创建的：创建时即按当前状态置灰，避免先亮后暗。
            item.isEnabled = AppActions.shared.paneToolState.isEnabled(entry.tool)
            let target = ToolTarget(tool: entry.tool)
            targets[identifier] = target
            item.target = target
            item.action = #selector(ToolTarget.fire)
            return item
        }
    }

    /// 工具栏可用性由焦点窗格状态决定。
    ///
    /// 注意：macOS 上 NSToolbar 并不会自动回调 validateToolbarItem
    /// （实测 validateVisibleItems 也不触发），所以可用性必须由
    /// applyState(toolbar:) 主动写进 item.isEnabled。
    func applyState(toolbar: NSToolbar) {
        let state = AppActions.shared.paneToolState
        for item in toolbar.items {
            if let entry = Self.toolIdentifiers.first(where: { $0.id == item.itemIdentifier }) {
                item.isEnabled = state.isEnabled(entry.tool)
            } else if let conflict = item as? ConflictItem {
                conflict.popup.selectItem(withTitle: AppActions.shared.conflictPolicy.title)
                conflict.popup.isEnabled = state.extract
            } else if let dual = item as? DualPaneItem {
                dual.button.state = AppActions.shared.dualPaneActive ? .on : .off
            }
        }
    }

    /// AppKit 原生校验入口（系统偶尔会问，返回当前状态）。
    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        let state = AppActions.shared.paneToolState
        if let entry = Self.toolIdentifiers.first(where: { $0.id == item.itemIdentifier }) {
            return state.isEnabled(entry.tool)
        }
        return true
    }
}
