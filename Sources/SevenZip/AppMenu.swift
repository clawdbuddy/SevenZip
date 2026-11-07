import AppKit

/// 纯 AppKit 菜单栏。
/// 为什么不用 SwiftUI Commands：菜单必须依附场景，而任何可见场景都会在启动时
/// 自动开窗（WindowGroup 开主窗口、唯一 Settings 场景会开设置小窗），命令 URL
/// 冷启动因此必然带出多余窗口且无法清除。空场景 body + 手工 NSMenu 后，
/// 菜单栏完全脱离场景生命周期。
@MainActor
final class AppMenuBuilder: NSObject {
    static let shared = AppMenuBuilder()
    private let actions = AppActions.shared

    /// 用 toolTip 标记需要动态勾选状态的菜单项。
    enum StateKey: String {
        case flatView, gridLines, checkUpdates
        case viewList, viewIcons
        case appearanceSystem, appearanceLight, appearanceDark
    }

    func install() {
        let mainMenu = NSMenu()
        mainMenu.addItem(makeAppMenu())
        mainMenu.addItem(makeFileMenu())
        mainMenu.addItem(makeEditMenu())
        mainMenu.addItem(makeViewMenu())
        mainMenu.addItem(makeToolsMenu())
        mainMenu.addItem(makeWindowMenu())
        mainMenu.addItem(makeHelpMenu())
        NSApp.mainMenu = mainMenu
    }

    // MARK: - 各菜单

    private func makeAppMenu() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "七压")
        menu.addItem(title: "关于七压", key: "", tag: "about")
        menu.addItem(.separator())
        menu.addItem(withTitle: "隐藏七压", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = menu.addItem(withTitle: "隐藏其他", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(withTitle: "全部显示", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出七压", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.submenu = menu
        return item
    }

    private func makeFileMenu() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "文件")
        menu.addItem(title: "打开压缩包…", key: "o", tag: "openArchive")
        menu.addItem(title: "创建压缩包…", key: "n", tag: "createArchive")
        menu.addItem(.separator())
        menu.addItem(title: "关闭压缩包", key: "w", tag: "closeArchive")
        item.submenu = menu
        return item
    }

    private func makeEditMenu() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "编辑")
        // 标准编辑项：走响应链（target=nil），供对话框/文本框使用。
        menu.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = menu.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(.separator())
        menu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        menu.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        menu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        menu.addItem(withTitle: "粘贴并匹配样式", action: Selector(("pasteAsPlainText:")), keyEquivalent: "")
        menu.addItem(withTitle: "删除", action: #selector(NSText.delete(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        menu.addItem(.separator())
        // 7zFM 文件列表编辑（原 SwiftUI 菜单项，作用于焦点窗格）。
        menu.addItem(title: "全选文件", key: "", tag: "selectAll")
        let deselect = menu.addItem(title: "取消选择", key: "a", tag: "deselectAll")
        deselect.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(title: "反向选择", key: "", tag: "invertSelection")
        menu.addItem(.separator())
        let rename = menu.addItem(title: "重命名…", key: "\r", tag: "renameSelection")
        rename.keyEquivalentModifierMask = [.command]
        let delete = menu.addItem(title: "删除…", key: "\u{7f}", tag: "deleteSelection")
        delete.keyEquivalentModifierMask = [.command]
        item.submenu = menu
        return item
    }

    private func makeViewMenu() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "查看")
        menu.addItem(title: "刷新", key: "r", tag: "refresh")
        let up = menu.addItem(title: "返回上级目录", key: String(Character(UnicodeScalar(NSUpArrowFunctionKey)!)), tag: "goUp")
        up.keyEquivalentModifierMask = [.command]
        menu.addItem(.separator())
        menu.addItem(title: "平铺视图", key: "", tag: "toggleFlatView", stateKey: .flatView)
        // 视图模式（单选）
        let viewMenu = NSMenu(title: "视图")
        viewMenu.addItem(title: "详细资料", key: "", tag: "viewList", stateKey: .viewList)
        viewMenu.addItem(title: "大图标", key: "", tag: "viewIcons", stateKey: .viewIcons)
        let viewItem = NSMenuItem(title: "视图", action: nil, keyEquivalent: "")
        viewItem.submenu = viewMenu
        menu.addItem(viewItem)
        menu.addItem(.separator())
        menu.addItem(title: "双窗格", key: "", tag: "toggleDualPane")
        // ⌘⇥ 会被系统应用切换器在 WindowServer 层拦截，永不触发；改用 ⌃⇥。
        let switchPane = menu.addItem(title: "切换窗格", key: "\t", tag: "switchPane")
        switchPane.keyEquivalentModifierMask = [.control]
        menu.addItem(title: "复制到另一窗格", key: "", tag: "copyToOtherPane")
        menu.addItem(title: "移动到另一窗格", key: "", tag: "moveToOtherPane")
        menu.addItem(.separator())
        // 外观（单选）
        let appearanceMenu = NSMenu(title: "外观")
        appearanceMenu.addItem(title: "跟随系统", key: "", tag: "appearanceSystem", stateKey: .appearanceSystem)
        appearanceMenu.addItem(title: "浅色", key: "", tag: "appearanceLight", stateKey: .appearanceLight)
        appearanceMenu.addItem(title: "深色", key: "", tag: "appearanceDark", stateKey: .appearanceDark)
        let appearanceItem = NSMenuItem(title: "外观", action: nil, keyEquivalent: "")
        appearanceItem.submenu = appearanceMenu
        menu.addItem(appearanceItem)
        menu.addItem(title: "显示网格线", key: "", tag: "toggleGridLines", stateKey: .gridLines)
        menu.addItem(.separator())
        menu.addItem(title: "运行日志", key: "l", tag: "toggleLog")
        menu.delegate = self
        viewMenu.delegate = self
        appearanceMenu.delegate = self
        item.submenu = menu
        return item
    }

    private func makeToolsMenu() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "工具")
        menu.addItem(title: "批量解压…", key: "", tag: "batchExtract")
        menu.addItem(title: "批量压缩…", key: "", tag: "batchCompress")
        menu.addItem(title: "格式转换…", key: "", tag: "convert")
        menu.addItem(.separator())
        let checksumMenu = NSMenu(title: "计算校验和")
        for algo in ["CRC32", "CRC64", "SHA1", "SHA256", "SHA512", "BLAKE2sp"] {
            checksumMenu.addItem(title: algo, key: "", tag: "checksum:\(algo)")
        }
        let checksumItem = NSMenuItem(title: "计算校验和", action: nil, keyEquivalent: "")
        checksumItem.submenu = checksumMenu
        menu.addItem(checksumItem)
        menu.addItem(title: "输入压缩包密码…", key: "", tag: "enterPassword")
        menu.addItem(.separator())
        menu.addItem(title: "性能测试（Benchmark）…", key: "", tag: "benchmark")
        menu.addItem(.separator())
        menu.addItem(title: "文件类型关联…", key: "", tag: "fileAssociation")
        item.submenu = menu
        return item
    }

    private func makeWindowMenu() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "窗口")
        // 关闭走响应链（target=nil → key window performClose）。文件菜单的
        // 「关闭压缩包 ⌘W」在主窗口为 key 时优先匹配；其他窗口在前时
        // 它被 validateMenuItem 禁用，⌘W 自然落到本项关掉当前窗口。
        menu.addItem(withTitle: "关闭", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        menu.addItem(withTitle: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        menu.addItem(withTitle: "缩放", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        item.submenu = menu
        NSApp.windowsMenu = menu   // 系统自动追加窗口列表与「全部移到前面」
        return item
    }

    private func makeHelpMenu() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "帮助")
        menu.addItem(title: "检查更新…", key: "", tag: "checkUpdate")
        menu.addItem(title: "启动时检查更新", key: "", tag: "toggleCheckUpdates", stateKey: .checkUpdates)
        menu.addItem(.separator())
        menu.addItem(title: "重置所有设置…", key: "", tag: "resetSettings")
        menu.addItem(.separator())
        menu.addItem(title: "关于七压", key: "", tag: "about")
        menu.delegate = self
        item.submenu = menu
        return item
    }

    // MARK: - 菜单项构造与派发

    @objc fileprivate func dispatched(_ sender: NSMenuItem) {
        guard let tag = sender.representedObject as? String else { return }
        switch tag {
        case "about": actions.about()
        case "openArchive": actions.openArchive()
        case "createArchive": actions.createArchive()
        case "closeArchive": actions.closeArchive()
        case "selectAll": actions.selectAll()
        case "deselectAll": actions.deselectAll()
        case "invertSelection": actions.invertSelection()
        case "renameSelection": actions.renameSelection()
        case "deleteSelection": actions.deleteSelection()
        case "refresh": actions.refresh()
        case "goUp": actions.goUp()
        case "toggleFlatView": actions.flatView.toggle()
        case "viewList": actions.viewMode = .list
        case "viewIcons": actions.viewMode = .icons
        case "toggleDualPane": actions.toggleDualPane()
        case "switchPane": actions.switchPane()
        case "copyToOtherPane": actions.copyToOtherPane()
        case "moveToOtherPane": actions.moveToOtherPane()
        case "appearanceSystem": actions.appearance = .system
        case "appearanceLight": actions.appearance = .light
        case "appearanceDark": actions.appearance = .dark
        case "toggleGridLines": actions.showGridLines.toggle()
        case "toggleLog": actions.toggleLog()
        case "batchExtract": actions.batchExtract()
        case "batchCompress": actions.batchCompress()
        case "convert": actions.convert()
        case "enterPassword": actions.enterPassword()
        case "benchmark": BenchmarkWindowController.shared.show()
        case "fileAssociation": actions.fileAssociation()
        case "checkUpdate": UpdateChecker.check(manual: true)
        case "toggleCheckUpdates": actions.checkUpdates.toggle()
        case "resetSettings": confirmResetSettings()
        default:
            if tag.hasPrefix("checksum:") {
                actions.checksum(String(tag.dropFirst("checksum:".count)))
            }
        }
    }

    private func confirmResetSettings() {
        let alert = NSAlert()
        alert.messageText = "重置所有设置？"
        alert.informativeText = "视图模式、外观、网格线、双窗格等偏好将恢复默认；窗口布局在重启后复原。"
        alert.addButton(withTitle: "重置")
        alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn {
            actions.resetAllSettings()
        }
    }
}

extension NSMenu {
    @MainActor @discardableResult
    fileprivate func addItem(title: String, key: String, tag: String,
                             stateKey: AppMenuBuilder.StateKey? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(AppMenuBuilder.dispatched(_:)),
                              keyEquivalent: key)
        item.target = AppMenuBuilder.shared
        item.representedObject = tag
        if let stateKey { item.toolTip = stateKey.rawValue }
        addItem(item)
        return item
    }
}

extension AppMenuBuilder: NSMenuItemValidation {
    /// 作用于主窗口窗格内容的动作（删除/重命名/关闭压缩包等）。
    /// 这些菜单项 target 写死为 AppMenuBuilder、不走响应链，若不做门控，
    /// 用户在独立对话框里按 ⌘⌫/⌘W/⌘⏎ 等会越过 key window 直接触发
    /// 主窗口的文件操作（含删除）——必须只在主窗口为 key 时可用。
    /// 窗口销毁后这些 actions 闭包指向已销毁窗格，门控同样挡住误触发。
    private static let paneActionTags: Set<String> = [
        "closeArchive", "selectAll", "deselectAll", "invertSelection",
        "renameSelection", "deleteSelection", "refresh", "goUp", "toggleLog",
        "openArchive", "createArchive", "batchExtract", "batchCompress",
        "convert", "enterPassword", "toggleDualPane",
    ]

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard let tag = menuItem.representedObject as? String else { return true }
        let mainKey = MainWindowController.shared.window?.isKeyWindow == true
        if tag == "closeArchive" {
            // 无打开归档时禁用：⌘W 才会穿过本项落到窗口菜单的「关闭」，
            // 否则键等价被 enabled 的本项消费、PaneView 又静默 return。
            return mainKey && actions.archiveOpen
        }
        // 「计算校验和」子菜单的 tag 带算法后缀（checksum:CRC32 等），按前缀匹配。
        if Self.paneActionTags.contains(tag) || tag.hasPrefix("checksum:") { return mainKey }
        switch tag {
        case "switchPane", "copyToOtherPane", "moveToOtherPane":
            // 跨窗格动作还要求双窗格已开启（单窗格时 F5/F6 无意义，
            // 且另一端可能是已销毁窗格的冻结状态）。
            return actions.dualPaneActive && mainKey
        default:
            return true
        }
    }
}

extension AppMenuBuilder: NSMenuDelegate {
    /// 菜单展开前刷新勾选/单选状态（AppKit 保证在主线程调用）。
    nonisolated func menuNeedsUpdate(_ menu: NSMenu) {
        MainActor.assumeIsolated {
            for item in menu.items {
                guard let raw = item.toolTip,
                      let key = StateKey(rawValue: raw) else { continue }
                let on: Bool
                switch key {
                case .flatView: on = actions.flatView
                case .gridLines: on = actions.showGridLines
                case .checkUpdates: on = actions.checkUpdates
                case .viewList: on = actions.viewMode == .list
                case .viewIcons: on = actions.viewMode == .icons
                case .appearanceSystem: on = actions.appearance == .system
                case .appearanceLight: on = actions.appearance == .light
                case .appearanceDark: on = actions.appearance == .dark
                }
                item.state = on ? .on : .off
            }
        }
    }
}
