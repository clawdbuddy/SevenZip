import AppKit
import SwiftUI

@main
struct SevenZipApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var actions = AppActions.shared

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

    var body: some Scene {
        WindowGroup {
            // 每个 PaneView 自带 ArchiveModel（双窗格各自浏览不同归档）。
            ContentView()
                .environmentObject(actions)
                .frame(minWidth: 940, minHeight: 560)
        }
        .commands {
            // 7zFM: 文件(F)
            CommandGroup(replacing: .newItem) {
                Button("打开压缩包…") { actions.openArchive() }
                    .keyboardShortcut("o")
                Button("创建压缩包…") { actions.createArchive() }
                    .keyboardShortcut("n")
                Divider()
                Button("关闭压缩包") { actions.closeArchive() }
                    .keyboardShortcut("w")
            }
            // 7zFM: 编辑(E)
            CommandGroup(after: .pasteboard) {
                Divider()
                Button("全选") { actions.selectAll() }
                    .keyboardShortcut("a")
                Button("取消选择") { actions.deselectAll() }
                    .keyboardShortcut("a", modifiers: [.command, .shift])
                Button("反向选择") { actions.invertSelection() }
                Divider()
                Button("重命名…") { actions.renameSelection() }
                    .keyboardShortcut(.return, modifiers: .command)
                Button("删除…") { actions.deleteSelection() }
                    .keyboardShortcut(.delete, modifiers: .command)
            }
            // 7zFM: 查看(V)
            CommandGroup(after: .toolbar) {
                Button("刷新") { actions.refresh() }
                    .keyboardShortcut("r")
                Button("返回上级目录") { actions.goUp() }
                    .keyboardShortcut(.upArrow, modifiers: .command)
                Divider()
                Toggle("平铺视图", isOn: $actions.flatView)
                Picker("视图", selection: $actions.viewMode) {
                    ForEach(AppActions.ViewMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                Divider()
                Button("双窗格") { actions.toggleDualPane() }   // F9（菜单快捷键不支持 F 键，事件监听补齐）
                Button("切换窗格") { actions.switchPane() }
                    .keyboardShortcut(.tab, modifiers: [])
                Button("复制到另一窗格") { actions.copyToOtherPane() }     // F5
                Button("移动到另一窗格") { actions.moveToOtherPane() }   // F6
                Divider()
                Picker("外观", selection: $actions.appearance) {
                    ForEach(AppActions.Appearance.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                Toggle("显示网格线", isOn: $actions.showGridLines)
                Divider()
                Button("运行日志") { actions.toggleLog() }
                    .keyboardShortcut("l")
            }
            // 7zFM: 收藏 → 由地址栏历史下拉承担，不单设菜单
            // 7zFM: 工具(T)
            CommandGroup(after: .importExport) {
                Divider()
                Button("批量解压…") { actions.batchExtract() }
                Button("批量压缩…") { actions.batchCompress() }
                Button("格式转换…") { actions.convert() }
                Divider()
                Menu("计算校验和") {
                    ForEach(["CRC32", "CRC64", "SHA1", "SHA256", "SHA512", "BLAKE2sp"], id: \.self) { algo in
                        Button(algo) { actions.checksum(algo) }
                    }
                }
                Button("输入压缩包密码…") { actions.enterPassword() }
                Divider()
                Button("性能测试（Benchmark）…") { BenchmarkWindowController.shared.show() }
                Divider()
                Button("文件类型关联…") { actions.fileAssociation() }
            }
            // 7zFM: 帮助(H)
            CommandGroup(replacing: .help) {
                Button("检查更新…") { UpdateChecker.check(manual: true) }
                Toggle("启动时检查更新", isOn: $actions.checkUpdates)
                Divider()
                Button("重置所有设置…") { confirmResetSettings() }
                Divider()
                Button("关于七压") { actions.about() }
            }
        }
    }
}
