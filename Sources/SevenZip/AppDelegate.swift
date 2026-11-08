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
        // Dock 启动没有任何 URL 事件，稍后兜底开主窗口；命令 URL 冷启动由
        // 路由决定要不要主窗口，「添加到压缩包」类对话框命令则永远不开。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            if !self.receivedURLOpen {
                // 兜底开的主窗口先算「临时」：URL 事件的投递时延不可控
                // （实测可达数秒），固定等待必然先开窗，随后到达的命令
                // URL 又走「主窗口已开」分支，破坏「右键只有『用七压打开』
                // 才开主窗口」的规则。命令 URL 到达时把临时窗口关掉。
                Task { @MainActor in AppActions.shared.requestProvisionalMainScene() }
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

    /// 遍历 Contents/PlugIns 下的 appex：
    /// - 当前这份路径没在册的，补注册（pluginkit -a，幂等）；
    /// - 已登记但用户没勾选（pluginkit 输出没有 '+' 标记）的，提示用户去哪里开启。
    ///
    /// 只按标识符判断「是否已注册」是不够的：系统里可能还留着旧副本
    /// （换了 bundle id 或换过 app 位置），那会让当前这份永远不被登记，
    /// 而 Finder 右键菜单照样不出现——正是历史上遇到的问题。
    private nonisolated static func reregisterMissingExtensions() {
        let plugIns = Bundle.main.builtInPlugInsURL
        guard let appexes = try? FileManager.default.contentsOfDirectory(
            at: plugIns ?? URL(fileURLWithPath: "/"), includingPropertiesForKeys: nil
        ).filter({ $0.pathExtension == "appex" }) else { return }
        let pluginkit = URL(fileURLWithPath: "/usr/bin/pluginkit")

        // 一次性拿到全部登记信息（按路径判断当前这份在不在册）。
        var registry: [String: String] = [:]   // appex 绝对路径 → 用户选举标记
        if let query = try? SpawnedProcess.launch(
            executable: pluginkit, arguments: ["-mAv"], directory: nil, environment: [:]) {
            let text = String(decoding: query.stdoutRead.readDataToEndOfFile(), as: UTF8.self)
            _ = query.waitForExit()
            for line in text.split(separator: "\n") {
                // 格式：<标记><tab>id(version)<tab>uuid<tab>日期<tab>路径
                let fields = line.split(separator: "\t", maxSplits: 4, omittingEmptySubsequences: false)
                guard fields.count == 5 else { continue }
                let path = String(fields[4])
                guard path.hasSuffix(".appex") else { continue }
                registry[path] = String(line.prefix(while: { $0 == "+" || $0 == "-" || $0 == "!" || $0 == "=" || $0 == "?" }))
            }
        }

        var notElected: [String] = []
        for appex in appexes {
            guard let id = Bundle(url: appex)?.bundleIdentifier else { continue }
            let path = appex.path
            if registry[path] == nil {
                // 当前这份没在册（换了 bundle id / 换了 app 位置时最常见）。
                if let add = try? SpawnedProcess.launch(
                    executable: pluginkit, arguments: ["-a", path],
                    directory: nil, environment: [:]) {
                    _ = add.waitForExit()
                }
                continue
            }
            // 已登记：标记 '+' 表示用户勾选了使用；没有标记 = 未被启用。
            if registry[path] != "+" {
                notElected.append(id)
            }
        }

        if !notElected.isEmpty {
            Task { @MainActor in
                Self.notifyExtensionsDisabled(notElected)
            }
        }
    }

    /// 提示用户去系统设置里勾选扩展。
    ///
    /// pluginkit -a 只能「登记」扩展，改不了用户的选举（-e use 会强行覆盖
    /// 用户的选择，不该由程序替用户做），所以只能告知去哪里开。
    @MainActor
    private static func notifyExtensionsDisabled(_ identifiers: [String]) {
        let defaults = UserDefaults.standard
        let key = "extensionsDisabledNoticeShown"
        guard !defaults.bool(forKey: key) else { return }
        defaults.set(true, forKey: key)
        let names = identifiers
            .map { id -> String in
                if id.contains("findersync") { return "Finder 右键菜单" }
                if id.contains("quicklook") { return "快速查看预览" }
                if id.contains("qa") { return "快速操作" }
                return id
            }
        .joined(separator: "、")
        let alert = NSAlert()
        alert.messageText = "部分系统扩展尚未启用"
        alert.informativeText = """
        \(names) 需要在「系统设置 → 通用 → 登录项与扩展 → 扩展」里勾选启用，\
        否则右键菜单与快速查看不会出现。

        （程序只能替扩展登记，无法代替你在系统设置里做选择。）
        """
        alert.addButton(withTitle: "打开系统设置")
        alert.addButton(withTitle: "稍后再说")
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!)
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
            // 只有命令 URL（没有「用七压打开」）时，兜底开出的临时主窗口
            // 就不该留下——产品规则是「右键只有『用七压打开』才开主窗口」。
            if fileURLs.isEmpty {
                MainWindowController.shared.closeIfProvisional()
            }
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
