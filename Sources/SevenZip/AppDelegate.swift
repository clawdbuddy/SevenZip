import AppKit

/// Finder 深度集成入口：
/// - NSServices（右键「服务」菜单：打开 / 解压到当前目录 / 压缩所选项目）
/// - 双击压缩包、「打开方式」触发的文件打开事件
/// 统一转发给 AppActions.shared，由 ContentView 安装的实际处理器执行。
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// 本次启动是否已收到 URL 打开事件（命令 URL 或双击归档）。
    private var receivedURLOpen = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 7zz 快速失败退出后，向其 stdin 写密码行会触发 EPIPE；
        // 全局忽略 SIGPIPE，让写入以错误返回而不是信号杀死整个 App。
        signal(SIGPIPE, SIG_IGN)
        NSApp.servicesProvider = self
        Task { @MainActor in
            AppActions.shared.applyAppearanceOnLaunch()
            AppMenuBuilder.shared.install()
        }
        // 主窗口按需创建（AppActions.requestMainScene → MainWindowController）。
        // Dock 启动没有任何 URL 事件，0.5s 后兜底开主窗口；命令 URL 冷启动由
        // 路由决定要不要主窗口，「添加到压缩包」类对话框命令则永远不开。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            if !self.receivedURLOpen {
                Task { @MainActor in AppActions.shared.requestMainScene() }
            }
        }
        // 启动后延迟静默检查更新（可在 帮助 → 启动时检查更新 关闭）。
        Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            UpdateChecker.checkInBackground()
        }
        // 替换 app 后立即启动时，系统可能尚未注册内置扩展（Finder 菜单/Quick Look/
        // 快速操作消失）：延迟几秒复查，未注册则手工补注册（对齐参考项目 1.2.1 的修复）。
        Task.detached(priority: .utility) {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            Self.reregisterMissingExtensions()
        }
    }

    /// 遍历 Contents/PlugIns 下的 appex，pluginkit 查不到的重新注册。
    private nonisolated static func reregisterMissingExtensions() {
        let plugIns = Bundle.main.builtInPlugInsURL
        guard let appexes = try? FileManager.default.contentsOfDirectory(
            at: plugIns ?? URL(fileURLWithPath: "/"), includingPropertiesForKeys: nil
        ).filter({ $0.pathExtension == "appex" }) else { return }
        let pluginkit = URL(fileURLWithPath: "/usr/bin/pluginkit")
        for appex in appexes {
            guard let id = Bundle(url: appex)?.bundleIdentifier else { continue }
            guard let check = try? SpawnedProcess.launch(
                executable: pluginkit, arguments: ["-mAD", "-i", id],
                directory: nil, environment: [:]) else { continue }
            let found = String(decoding: check.stdoutRead.readDataToEndOfFile(), as: UTF8.self)
            _ = check.waitForExit()
            guard found.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            if let add = try? SpawnedProcess.launch(
                executable: pluginkit, arguments: ["-a", appex.path],
                directory: nil, environment: [:]) {
                _ = add.waitForExit()
            }
        }
    }

    /// 所有 URL 打开的统一入口：Finder 双击归档（文件）与 sevenzip:// 命令。
    /// 场景侧刻意不挂 .onOpenURL / handlesExternalEvents（会让系统为命令新建
    /// 主窗口），因此两类 URL 都会送达本回调。
    func application(_ application: NSApplication, open urls: [URL]) {
        // 只认可能产生实际动作的 URL：文件 URL，或带非空 path 查询项的
        // sevenzip:// 命令。无 path 的命令 URL 会被 routeCommandURL 静默丢弃，
        // 若也置 receivedURLOpen 会吞掉 0.5s 兜底开窗，冷启动后一个窗口都没有。
        let fileURLs = urls.filter { $0.isFileURL }
        let commandURLs = urls.filter { $0.scheme == "sevenzip" && Self.isValidCommandURL($0) }
        guard !fileURLs.isEmpty || !commandURLs.isEmpty else { return }
        receivedURLOpen = true
        NSApp.activate(ignoringOtherApps: true)
        Task { @MainActor in
            if !fileURLs.isEmpty { AppActions.shared.routeOpenFiles(fileURLs) }
            for url in commandURLs {
                AppActions.shared.routeCommandURL(url)
            }
        }
    }

    /// 与 AppActions.routeCommandURL 的合法性判定对齐（保守规则）：
    /// 必须带至少一个非空 path 查询项，否则路由层 guard 静默返回、无任何动作。
    private nonisolated static func isValidCommandURL(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        return (components.queryItems ?? []).contains { $0.name == "path" && !($0.value ?? "").isEmpty }
    }

    /// Dock 图标点击（无可见窗口时重开主窗口）。
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        Task { @MainActor in AppActions.shared.requestMainScene() }
        return false
    }

    /// 退出前兜底清理所有已登记的临时目录（预览/嵌套/转换暂存）。
    /// 正常路径在任务完成时已删除并注销，这里只清残留（如窗口被直接关闭）。
    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { TempDirectoryRegistry.cleanupAll() }
    }

    @objc func serviceOpenArchives(_ pboard: NSPasteboard, userData: String?,
                                   error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        forward(pboard, error: error) { AppActions.shared.routeOpenFiles($0) }
    }

    @objc func serviceExtractInPlace(_ pboard: NSPasteboard, userData: String?,
                                     error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        forward(pboard, error: error) { AppActions.shared.routeExtractInPlace($0) }
    }

    @objc func serviceCompressInPlace(_ pboard: NSPasteboard, userData: String?,
                                      error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        forward(pboard, error: error) { AppActions.shared.routeCompressInPlace($0) }
    }

    private func forward(_ pboard: NSPasteboard,
                         error: AutoreleasingUnsafeMutablePointer<NSString?>,
                         action: @escaping @MainActor ([URL]) -> Void) {
        let urls = serviceURLs(from: pboard)
        guard !urls.isEmpty else {
            error.pointee = "未能读取所选文件。" as NSString
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        Task { @MainActor in action(urls) }
    }

    /// 服务剪贴板同时携带新式 fileURL 条目与旧式 NSFilenamesPboardType，两者都要兼容。
    private func serviceURLs(from pboard: NSPasteboard) -> [URL] {
        if let urls = pboard.readObjects(forClasses: [NSURL.self],
                                         options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            return urls
        }
        if let names = pboard.propertyList(forType: NSPasteboard.PasteboardType("NSFilenamesPboardType")) as? [String] {
            return names.map { URL(fileURLWithPath: $0) }
        }
        return []
    }
}
