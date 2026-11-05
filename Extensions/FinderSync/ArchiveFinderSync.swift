import AppKit
import FinderSync

/// Finder 右键一级菜单（七压 SevenZip 子菜单）：
/// 使用七压打开 / 解压到当前目录 / 压缩所选项目。
/// 解压与压缩通过 sevenzip:// URL scheme 回传主程序处理（复用 AppActions 路由）。
/// 用户需在 系统设置 → 隐私与安全性 → 扩展 → Finder 中勾选启用（macOS 强制）。
final class ArchiveFinderSync: FIFinderSync {

    override init() {
        super.init()
        // 全盘监控使右键菜单在任意目录可用；不打角标（badge），开销极小。
        FIFinderSyncController.default().directoryURLs = [URL(fileURLWithPath: "/")]
    }

    override func menu(for menuKind: FIMenuKind) -> NSMenu {
        let menu = NSMenu(title: "七压 SevenZip")
        switch menuKind {
        case .contextualMenuForItems, .contextualMenuForContainer:
            addItem(to: menu, title: "使用七压打开", action: #selector(openSelected))
            addItem(to: menu, title: "解压到当前目录", action: #selector(extractSelected))
            addItem(to: menu, title: "压缩所选项目", action: #selector(compressSelected))
        default:
            break
        }
        return menu
    }

    private func addItem(to menu: NSMenu, title: String, action: Selector) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
    }

    /// 当前操作的文件集：优先选中项，其次右键点击的容器本身。
    private func targetURLs() -> [URL] {
        if let selected = FIFinderSyncController.default().selectedItemURLs(), !selected.isEmpty {
            return selected
        }
        if let container = FIFinderSyncController.default().targetedURL() {
            return [container]
        }
        return []
    }

    /// 主程序 bundle：本扩展位于 <app>/Contents/PlugIns/*.appex。
    private func parentAppURL() -> URL {
        Bundle.main.bundleURL
            .deletingLastPathComponent()   // PlugIns
            .deletingLastPathComponent()   // Contents
            .deletingLastPathComponent()   // SevenZip.app
    }

    @objc private func openSelected() {
        let urls = targetURLs()
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.open(urls, withApplicationAt: parentAppURL(),
                                configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
    }

    @objc private func extractSelected() {
        sendCommand(host: "extract")
    }

    @objc private func compressSelected() {
        sendCommand(host: "compress")
    }

    /// sevenzip://<action>?path=…&path=… 回传主程序；主程序 Info.plist 声明了该 scheme。
    private func sendCommand(host: String) {
        let urls = targetURLs()
        guard !urls.isEmpty else { return }
        var components = URLComponents()
        components.scheme = "sevenzip"
        components.host = host
        components.queryItems = urls.map { URLQueryItem(name: "path", value: $0.path) }
        guard let commandURL = components.url else { return }
        NSWorkspace.shared.open([commandURL], withApplicationAt: parentAppURL(),
                                configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
    }
}
