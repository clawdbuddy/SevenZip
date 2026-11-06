import AppKit
import Foundation

/// Bridge between the macOS menu bar (owned by the App) and ContentView.
/// ContentView installs its handlers on appear; menu commands invoke them.
/// Handlers are no-ops until installed, and each guards its own preconditions.
@MainActor
final class AppActions: ObservableObject {
    /// AppDelegate（Finder 服务、双击打开）无法拿到 @StateObject，
    /// 应用统一使用此共享实例。
    static let shared = AppActions()

    var openArchive: () -> Void = {}
    var createArchive: () -> Void = {}
    var closeArchive: () -> Void = {}
    var refresh: () -> Void = {}
    var goUp: () -> Void = {}
    var renameSelection: () -> Void = {}
    var deleteSelection: () -> Void = {}
    var selectAll: () -> Void = {}
    var deselectAll: () -> Void = {}
    var invertSelection: () -> Void = {}
    var batchExtract: () -> Void = {}
    var batchCompress: () -> Void = {}
    var convert: () -> Void = {}
    var checksum: (String) -> Void = { _ in }
    var toggleLog: () -> Void = {}
    var enterPassword: () -> Void = {}
    var fileAssociation: () -> Void = {}
    var about: () -> Void = {}

    // 双窗格（阶段2）：外壳安装开关，焦点窗格安装跨窗格传输。
    var toggleDualPane: () -> Void = {}
    var switchPane: () -> Void = {}
    var copyToOtherPane: () -> Void = {}
    var moveToOtherPane: () -> Void = {}
    /// 由非焦点窗格安装：返回其磁盘目录（在归档内则为 nil）。
    var otherPaneDiskLocation: () -> URL? = { nil }
    /// 由非焦点窗格安装：接收另一窗格复制过来的本地文件（加入其归档）。
    var receiveFilesFromOtherPane: ([URL]) -> Void = { _ in }

    /// 文件列表视图模式：详细资料（表格）/ 大图标（网格）。
    enum ViewMode: String, CaseIterable, Identifiable {
        case list, icons
        var id: String { rawValue }
        var title: String { self == .list ? "详细资料" : "大图标" }
    }

    @Published var viewMode: ViewMode = ViewMode(
        rawValue: UserDefaults.standard.string(forKey: "viewMode") ?? "") ?? .list {
        didSet { UserDefaults.standard.set(viewMode.rawValue, forKey: "viewMode") }
    }

    /// 平铺视图（归档内不折叠目录，显示全部条目）。菜单开关与列表共用此状态。
    @Published var flatView = UserDefaults.standard.bool(forKey: "flatView") {
        didSet { UserDefaults.standard.set(flatView, forKey: "flatView") }
    }

    /// 文件列表网格线（对标参考项目 Options → macOS 的「Show grid lines」）。
    @Published var showGridLines = UserDefaults.standard.bool(forKey: "showGridLines") {
        didSet { UserDefaults.standard.set(showGridLines, forKey: "showGridLines") }
    }

    /// 启动时检查更新（默认开启；对标「Check for updates at startup」）。
    @Published var checkUpdates = UserDefaults.standard.object(forKey: "checkUpdates") as? Bool ?? true {
        didSet { UserDefaults.standard.set(checkUpdates, forKey: "checkUpdates") }
    }

    /// 重置所有设置（对标「Reset All Settings…」）：清空本应用的 UserDefaults
    /// 域并把内存中的选项复位。窗口布局等 SwiftUI 自管状态在重启后复原。
    func resetAllSettings() {
        if let id = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: id)
        }
        viewMode = .list
        flatView = false
        appearance = .system
        showGridLines = false
        checkUpdates = true
    }

    /// 外观主题：system / light / dark，作用于整个 app 的 NSApp.appearance。
    enum Appearance: String, CaseIterable, Identifiable {
        case system, light, dark
        var id: String { rawValue }
        var title: String {
            switch self {
            case .system: return "跟随系统"
            case .light: return "浅色"
            case .dark: return "深色"
            }
        }
        var nsAppearance: NSAppearance? {
            switch self {
            case .system: return nil
            case .light: return NSAppearance(named: .aqua)
            case .dark: return NSAppearance(named: .darkAqua)
            }
        }
    }

    @Published var appearance: Appearance = Appearance(
        rawValue: UserDefaults.standard.string(forKey: "appearance") ?? "") ?? .system {
        didSet {
            UserDefaults.standard.set(appearance.rawValue, forKey: "appearance")
            NSApp.appearance = appearance.nsAppearance
        }
    }

    /// App 启动时恢复上次的外观设置（didSet 不会在初始化时触发）。
    func applyAppearanceOnLaunch() {
        NSApp.appearance = appearance.nsAppearance
    }

    // Finder 集成：由 AppDelegate 转发，ContentView 安装实现。
    // 冷启动时文件打开事件先于界面就绪，未安装处理器时先缓冲，待 onAppear 后回放。
    enum PendingService {
        case open([URL])
        case extract([URL])
        case extractFolder([URL])          // 解压到 "名称/"（同名子目录）
        case extractChoose([URL])          // 解压到…（弹窗选目录）
        case test([URL])                   // 测试压缩包
        case addDialog([URL], email: Bool) // 添加到压缩包…（弹选项；email=压缩并邮件…）
        case compress([URL], format: String)
        case compressEmail([URL], format: String)
        case checksum([URL], algorithm: String)
    }
    var handlersInstalled = false
    var pendingServices: [PendingService] = []
    var openFiles: ([URL]) -> Void = { _ in }
    var extractInPlace: ([URL]) -> Void = { _ in }
    var extractToNamedFolder: ([URL]) -> Void = { _ in }
    var extractChooseDestination: ([URL]) -> Void = { _ in }
    var testArchives: ([URL]) -> Void = { _ in }
    var addToArchiveDialog: ([URL], Bool) -> Void = { _, _ in }
    var compressInPlace: ([URL], String) -> Void = { _, _ in }
    var compressAndEmail: ([URL], String) -> Void = { _, _ in }
    var checksumFiles: ([URL], String) -> Void = { _, _ in }

    func routeOpenFiles(_ urls: [URL]) {
        if handlersInstalled { openFiles(urls) } else { pendingServices.append(.open(urls)) }
    }
    func routeExtractInPlace(_ urls: [URL]) {
        if handlersInstalled { extractInPlace(urls) } else { pendingServices.append(.extract(urls)) }
    }
    func routeExtractToNamedFolder(_ urls: [URL]) {
        if handlersInstalled { extractToNamedFolder(urls) } else { pendingServices.append(.extractFolder(urls)) }
    }
    func routeExtractChooseDestination(_ urls: [URL]) {
        if handlersInstalled { extractChooseDestination(urls) } else { pendingServices.append(.extractChoose(urls)) }
    }
    func routeTestArchives(_ urls: [URL]) {
        if handlersInstalled { testArchives(urls) } else { pendingServices.append(.test(urls)) }
    }
    func routeAddToArchiveDialog(_ urls: [URL], email: Bool = false) {
        if handlersInstalled { addToArchiveDialog(urls, email) } else { pendingServices.append(.addDialog(urls, email: email)) }
    }
    func routeCompressInPlace(_ urls: [URL], format: String = "zip") {
        if handlersInstalled { compressInPlace(urls, format) } else { pendingServices.append(.compress(urls, format: format)) }
    }
    func routeCompressAndEmail(_ urls: [URL], format: String) {
        if handlersInstalled { compressAndEmail(urls, format) } else { pendingServices.append(.compressEmail(urls, format: format)) }
    }
    func routeChecksumFiles(_ urls: [URL], algorithm: String) {
        if handlersInstalled { checksumFiles(urls, algorithm) } else { pendingServices.append(.checksum(urls, algorithm: algorithm)) }
    }

    /// 解析 sevenzip://<action>?path=… 命令 URL 并路由（AppDelegate 与
    /// SwiftUI .onOpenURL 两条投递路径共用；冷启动时自动缓冲）。
    func routeCommandURL(_ url: URL) {
        guard url.scheme == "sevenzip",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
        let files = (components.queryItems ?? [])
            .filter { $0.name == "path" }
            .compactMap(\.value)
            .map { URL(fileURLWithPath: $0) }
        guard !files.isEmpty else { return }
        let format = components.queryItems?.first { $0.name == "format" }?.value ?? "zip"
        let algorithm = components.queryItems?.first { $0.name == "algo" }?.value ?? "SHA256"
        switch url.host {
        case "extract": routeExtractInPlace(files)
        case "extract-folder": routeExtractToNamedFolder(files)
        case "extract-choose": routeExtractChooseDestination(files)
        case "test": routeTestArchives(files)
        case "add-dialog": routeAddToArchiveDialog(files)
        case "compress-email-dialog": routeAddToArchiveDialog(files, email: true)
        case "compress": routeCompressInPlace(files, format: format)
        case "compress-email": routeCompressAndEmail(files, format: format)
        case "checksum": routeChecksumFiles(files, algorithm: algorithm)
        default: routeOpenFiles(files)
        }
    }

    /// ContentView.onAppear 在 installMenuActions 之后调用，回放缓冲的服务请求。
    func drainPendingServices() {
        let pending = pendingServices
        pendingServices.removeAll()
        for item in pending {
            switch item {
            case .open(let urls): openFiles(urls)
            case .extract(let urls): extractInPlace(urls)
            case .extractFolder(let urls): extractToNamedFolder(urls)
            case .extractChoose(let urls): extractChooseDestination(urls)
            case .test(let urls): testArchives(urls)
            case .addDialog(let urls, let email): addToArchiveDialog(urls, email)
            case .compress(let urls, let format): compressInPlace(urls, format)
            case .compressEmail(let urls, let format): compressAndEmail(urls, format)
            case .checksum(let urls, let algorithm): checksumFiles(urls, algorithm)
            }
        }
    }
}
