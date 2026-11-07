import AppKit
import ArchiveCore

/// 原生窗口工具栏（macOS 风格）。
///
/// 为什么用 AppKit NSToolbar 而不是 SwiftUI 视图：窗口本体是手动管理的
/// NSWindow（不用 WindowGroup，理由见 MainWindowController），SwiftUI 的
/// .toolbar 只在 SwiftUI 场景里生效，NSHostingView 里拿不到真正的标题栏
/// 工具栏。原生 NSToolbar 才能与标题栏融为一体（unified 风格）、拿到系统
/// 的毛玻璃底、正确的悬停高亮、右键菜单与拖拽重排行为。
///
/// 形态对齐 macOS 系统应用（访达 / Xcode / Keka）：
/// - 一律使用标准 NSToolbarItem + SF Symbols，不用自定义按钮，保证
///   尺寸、间距、悬停高亮与系统一致；
/// - 图标即按钮，文字说明走悬停提示；
/// - 右侧用弹性空间分隔「设置类」控件；
/// - 可用性由焦点窗格状态决定（macOS 不会自动回调 validateToolbarItem，
///   故主动写 item.isEnabled，并在动作侧二次校验）。
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
        static let conflict = NSToolbarItem.Identifier("SevenZip.conflict")
        static let dualPane = NSToolbarItem.Identifier("SevenZip.dualPane")
    }

    /// 工具项定义：标识、SF Symbol、名称、悬停说明。
    ///
    /// 符号一律取 macOS 系统工具栏的线性（描边）家族，语义与访达/Xcode
    /// 一致：加号 = 添加，方框箭头 = 释放到…，对勾 = 测试，副本 = 复制，
    /// 箭头 = 移动到…，垃圾桶 = 删除，i = 信息。不混用填充型符号，
    /// 否则整排图标风格不统一。
    private static let tools: [(id: NSToolbarItem.Identifier, tool: AppActions.PaneTool,
                                symbol: String, title: String, help: String)] = [
        (ID.add, .add, "plus", "添加", "把所选文件加入压缩包"),
        (ID.extract, .extract, "square.and.arrow.down", "释放", "从归档中释放所选项目"),
        (ID.test, .test, "checkmark.seal", "测试", "测试归档完整性"),
        (ID.copy, .copy, "doc.on.doc", "复制", "复制所选项目"),
        (ID.move, .move, "arrow.up.forward.app", "移动", "移动所选项目"),
        (ID.delete, .delete, "trash", "删除", "删除所选项目"),
        (ID.info, .info, "info.circle", "信息", "查看详细信息"),
    ]

    /// 文件冲突策略弹出按钮（macOS 工具栏里的设置类控件，用紧凑弹出菜单）。
    private final class ConflictItem: NSToolbarItem {
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)

        override init(itemIdentifier: NSToolbarItem.Identifier) {
            super.init(itemIdentifier: itemIdentifier)
            for policy in ConflictPolicy.allCases {
                popup.addItem(withTitle: policy.title)
            }
            popup.bezelStyle = .rounded
            popup.controlSize = .regular
            popup.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            popup.target = self
            popup.action = #selector(changed)
            view = popup
            paletteLabel = "文件冲突"
            toolTip = "解压遇到同名文件时的处理方式"
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

    /// 双窗格开关：标准工具项，图标随开合切换（macOS 侧边栏开关的常见做法）。
    @MainActor
    private final class DualPaneTarget: NSObject {
        @objc func fire() { AppActions.shared.toggleDualPane() }
    }

    /// 工具项 → 动作接收者的映射（NSToolbarItem 的 target 是弱引用，须强持有）。
    private var targets: [NSToolbarItem.Identifier: NSObject] = [:]

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
        // 左侧是主操作（添加/释放/测试/复制/移动/删除/信息），右侧是设置类
        // 控件（冲突策略、双窗格）——与 macOS 应用把「设置」放尾端的惯例一致。
        //
        // 分隔用系统内置的 .space（固定间距）而不是自定义标识符：自定义标识符
        // 不会被 AppKit 当成间隔项处理（delegate 回调返回 nil → 项被丢弃）。
        // 也不用 .flexibleSpace：窗口标题会占用工具栏的前导区域，弹性空间
        // 在这个位置无处可伸展，实测会塌成 1pt。
        [ID.add, ID.extract, ID.test, ID.copy, ID.move, ID.delete, ID.info,
         .space, ID.conflict, ID.dualPane]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch identifier {
        case .flexibleSpace, .space:
            return nil
        case ID.conflict:
            return ConflictItem(itemIdentifier: identifier)
        case ID.dualPane:
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.image = Self.dualPaneSymbol()
            item.label = "双窗格"
            item.paletteLabel = "双窗格"
            item.toolTip = "双窗格（⌃⌥T / F9）"
            item.isEnabled = true
            let target = DualPaneTarget()
            targets[identifier] = target
            item.target = target
            item.action = #selector(DualPaneTarget.fire)
            return item
        default:
            guard let entry = Self.tools.first(where: { $0.id == identifier }) else { return nil }
            let item = NSToolbarItem(itemIdentifier: identifier)
            // SF Symbol 用模板图：系统按工具栏规则着色（正常/高亮/置灰）。
            if let image = NSImage(systemSymbolName: entry.symbol, accessibilityDescription: entry.title) {
                image.isTemplate = true
                item.image = image
            }
            item.label = entry.title
            item.paletteLabel = entry.title
            item.toolTip = entry.help
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
            if let entry = Self.tools.first(where: { $0.id == item.itemIdentifier }) {
                item.isEnabled = state.isEnabled(entry.tool)
            } else if let conflict = item as? ConflictItem {
                conflict.popup.selectItem(withTitle: AppActions.shared.conflictPolicy.title)
                conflict.popup.isEnabled = state.extract
            } else if item.itemIdentifier == ID.dualPane {
                item.image = Self.dualPaneSymbol()
            }
        }
    }

    /// AppKit 原生校验入口（系统偶尔会问，返回当前状态）。
    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        let state = AppActions.shared.paneToolState
        if let entry = Self.tools.first(where: { $0.id == item.itemIdentifier }) {
            return state.isEnabled(entry.tool)
        }
        return true
    }

    /// 双窗格开合用不同图标（macOS 侧边栏开关惯例）。
    private static func dualPaneSymbol() -> NSImage? {
        let name = AppActions.shared.dualPaneActive ? "rectangle.split.2x1.fill" : "rectangle.split.2x1"
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "双窗格")
        image?.isTemplate = true
        return image
    }
}
