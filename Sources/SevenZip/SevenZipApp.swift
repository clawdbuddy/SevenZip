import SwiftUI

@main
struct SevenZipApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var archiveModel = ArchiveModel()
    @StateObject private var actions = AppActions.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(archiveModel)
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
                Toggle("平铺视图", isOn: $actions.flatView)
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
                Button("文件类型关联…") { actions.fileAssociation() }
            }
            // 7zFM: 帮助(H)
            CommandGroup(replacing: .help) {
                Button("关于七压") { actions.about() }
            }
        }
    }
}
