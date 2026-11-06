import AppKit
import FinderSync

/// Finder 右键一级菜单（七压 SevenZip 子菜单），全量对齐 Windows 7-Zip 右键菜单：
/// 归档：使用七压打开 / 解压到… / 解压到当前目录 / 解压到 "名称/" / 测试压缩包
/// 任意：添加到压缩包… / 压缩并邮件… / 添加到 "名称.7z" / 压缩为 "名称.7z" 并邮件 /
///       添加到 "名称.zip" / 压缩为 "名称.zip" 并邮件 / CRC SHA 子菜单
/// 所有操作经 sevenzip:// URL scheme 回传主程序（AppDelegate → AppActions 路由）。
/// 用户需在 系统设置 → 隐私与安全性 → 扩展 → Finder 中勾选启用（macOS 强制）。
final class ArchiveFinderSync: FIFinderSync {

    private static let archiveExtensions: Set<String> =
        ["7z", "zip", "tar", "gz", "tgz", "bz2", "xz", "rar", "001"]

    override init() {
        super.init()
        // 全盘监控使右键菜单在任意目录可用；不打角标（badge），开销极小。
        FIFinderSyncController.default().directoryURLs = [URL(fileURLWithPath: "/")]
    }

    override func menu(for menuKind: FIMenuKind) -> NSMenu {
        let menu = NSMenu(title: "七压 SevenZip")
        guard menuKind == .contextualMenuForItems || menuKind == .contextualMenuForContainer else {
            return menu
        }
        let urls = targetURLs()
        let archives = urls.filter { Self.archiveExtensions.contains($0.pathExtension.lowercased()) }
        let base = Self.baseName(for: urls)

        // 归档专属操作（仅当所选全部为归档时显示）。
        if !archives.isEmpty, archives.count == urls.count {
            addItem(to: menu, title: "使用七压打开", action: #selector(openSelected))
            addItem(to: menu, title: "解压到…", action: #selector(extractChoose))
            addItem(to: menu, title: "解压到当前目录", action: #selector(extractHere))
            if archives.count == 1 {
                addItem(to: menu, title: "解压到 \"\(base)/\"", action: #selector(extractToFolder))
            }
            addItem(to: menu, title: "测试压缩包", action: #selector(testArchive))
            menu.addItem(.separator())
        }

        // 压缩与邮件（任意文件/文件夹）。
        addItem(to: menu, title: "添加到压缩包…", action: #selector(addToArchiveDialog))
        addItem(to: menu, title: "压缩并邮件…", action: #selector(compressAndEmailDialog))
        addItem(to: menu, title: "添加到 \"\(base).7z\"", action: #selector(addTo7z))
        addItem(to: menu, title: "压缩为 \"\(base).7z\" 并邮件", action: #selector(compress7zAndEmail))
        addItem(to: menu, title: "添加到 \"\(base).zip\"", action: #selector(addToZip))
        addItem(to: menu, title: "压缩为 \"\(base).zip\" 并邮件", action: #selector(compressZipAndEmail))
        menu.addItem(.separator())

        // CRC SHA 子菜单。
        let checksumMenu = NSMenu()
        for (title, algo) in [("CRC32", "CRC32"), ("CRC64", "CRC64"),
                              ("SHA-1", "SHA1"), ("SHA-256", "SHA256")] {
            let item = NSMenuItem(title: title, action: #selector(checksum(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = algo
            checksumMenu.addItem(item)
        }
        let checksumItem = NSMenuItem(title: "CRC SHA", action: nil, keyEquivalent: "")
        checksumItem.submenu = checksumMenu
        menu.addItem(checksumItem)
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

    /// 基础名：单选取文件名（剥离 .tar.gz 等复合扩展名），多选统一为 Archive。
    private static func baseName(for urls: [URL]) -> String {
        guard let first = urls.first, urls.count == 1 else { return "Archive" }
        let name = first.lastPathComponent
        let lower = name.lowercased()
        for compound in [".tar.gz", ".tar.bz2", ".tar.xz", ".tgz"] where lower.hasSuffix(compound) {
            return String(name.dropLast(compound.count))
        }
        return first.deletingPathExtension().lastPathComponent
    }

    /// 主程序 bundle：本扩展位于 <app>/Contents/PlugIns/*.appex。
    private func parentAppURL() -> URL {
        Bundle.main.bundleURL
            .deletingLastPathComponent()   // PlugIns
            .deletingLastPathComponent()   // Contents
            .deletingLastPathComponent()   // SevenZip.app
    }

    // MARK: - 菜单动作

    @objc private func openSelected() {
        let urls = targetURLs()
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.open(urls, withApplicationAt: parentAppURL(),
                                configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
    }

    @objc private func extractHere() { sendCommand(host: "extract") }
    @objc private func extractToFolder() { sendCommand(host: "extract-folder") }
    @objc private func extractChoose() { sendCommand(host: "extract-choose") }
    @objc private func testArchive() { sendCommand(host: "test") }
    @objc private func addToArchiveDialog() { sendCommand(host: "add-dialog") }
    @objc private func compressAndEmailDialog() { sendCommand(host: "compress-email-dialog") }
    @objc private func addTo7z() { sendCommand(host: "compress", extra: [URLQueryItem(name: "format", value: "7z")]) }
    @objc private func addToZip() { sendCommand(host: "compress", extra: [URLQueryItem(name: "format", value: "zip")]) }
    @objc private func compress7zAndEmail() { sendCommand(host: "compress-email", extra: [URLQueryItem(name: "format", value: "7z")]) }
    @objc private func compressZipAndEmail() { sendCommand(host: "compress-email", extra: [URLQueryItem(name: "format", value: "zip")]) }

    @objc private func checksum(_ sender: NSMenuItem) {
        guard let algo = sender.representedObject as? String else { return }
        sendCommand(host: "checksum", extra: [URLQueryItem(name: "algo", value: algo)])
    }

    /// sevenzip://<action>?path=…&path=… 回传主程序；主程序 Info.plist 声明了该 scheme。
    private func sendCommand(host: String, extra: [URLQueryItem] = []) {
        let urls = targetURLs()
        guard !urls.isEmpty else { return }
        var components = URLComponents()
        components.scheme = "sevenzip"
        components.host = host
        components.queryItems = urls.map { URLQueryItem(name: "path", value: $0.path) } + extra
        guard let commandURL = components.url else { return }
        NSWorkspace.shared.open([commandURL], withApplicationAt: parentAppURL(),
                                configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
    }
}
