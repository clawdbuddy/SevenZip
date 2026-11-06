import AppKit

/// Finder 深度集成入口：
/// - NSServices（右键「服务」菜单：打开 / 解压到当前目录 / 压缩所选项目）
/// - 双击压缩包、「打开方式」触发的文件打开事件
/// 统一转发给 AppActions.shared，由 ContentView 安装的实际处理器执行。
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.servicesProvider = self
        Task { @MainActor in AppActions.shared.applyAppearanceOnLaunch() }
    }

    /// Finder 双击已注册的归档类型时由 LaunchServices 投递。
    /// sevenzip:// 命令主要由 SwiftUI .onOpenURL 投递（WindowGroup 场景下
    /// 本回调只会收到空数组）；这里保留兜底以防系统走 AppDelegate 路径。
    func application(_ application: NSApplication, open urls: [URL]) {
        NSApp.activate(ignoringOtherApps: true)
        Task { @MainActor in
            let fileURLs = urls.filter { $0.isFileURL }
            if !fileURLs.isEmpty { AppActions.shared.routeOpenFiles(fileURLs) }
            for url in urls where url.scheme == "sevenzip" {
                AppActions.shared.routeCommandURL(url)
            }
        }
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
