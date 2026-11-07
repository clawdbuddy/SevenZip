import AppKit
import Foundation
import ArchiveCore

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

    /// 双窗格是否开启（ContentView 同步；菜单据此门控 F5/F6 与「切换到另一窗格」）。
    var dualPaneActive = false

    /// 焦点窗格是否有打开的归档（PaneView 同步；菜单据此门控「关闭压缩包 ⌘W」，
    /// 无归档时禁用该键等价才会落到窗口菜单的「关闭」）。
    var archiveOpen = false

    // MARK: - 原生工具栏（macOS 风格：工具栏在标题栏内，与标题一体）

    /// 窗口工具栏上的操作（对应原 SwiftUI 工具栏行）。
    enum PaneTool: String, CaseIterable {
        case add, extract, test, copy, move, delete, info
    }

    /// 各工具的可用状态（由焦点窗格同步；工具栏据此置灰）。
    struct PaneToolState: Equatable {
        var add = true
        var extract = false
        var test = false
        var copy = false
        var move = false
        var delete = false
        var info = false

        func isEnabled(_ tool: PaneTool) -> Bool {
            switch tool {
            case .add: return add
            case .extract: return extract
            case .test: return test
            case .copy: return copy
            case .move: return move
            case .delete: return delete
            case .info: return info
            }
        }
    }

    /// 焦点窗格安装的工具栏动作。
    var paneToolAction: (PaneTool) -> Void = { _ in }
    /// 工具栏可用状态（AppKit 工具栏不走 SwiftUI 渲染，需手动刷新）。
    var paneToolState = PaneToolState()

    /// 文件冲突策略（工具栏弹出按钮 ↔ 焦点窗格的 @State）。
    var conflictPolicy: ConflictPolicy = .skip
    var conflictPolicyChanged: (ConflictPolicy) -> Void = { _ in }

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
        case compress([URL], format: String)
        case compressEmail([URL], format: String)
        case checksum([URL], algorithm: String)
    }
    var handlersInstalled = false
    var pendingServices: [PendingService] = []
    /// 需要主窗口的路径（Dock 启动/重开、双击归档、解压等命令）调用：
    /// 主窗口由 MainWindowController 手动管理，不用 WindowGroup 场景（场景
    /// 自动开出的窗口事后无法清除，见 MainWindowController 注释）。
    func requestMainScene() { MainWindowController.shared.show() }
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
        // 唯一允许弹出主窗口的命令路径（「用七压打开」/双击归档）。
        requestMainScene()
        if handlersInstalled { openFiles(urls) } else { pendingServices.append(.open(urls)) }
    }
    // 以下命令：主窗口已开则就地执行（进度显示在窗格里），未开则交给独立
    // 执行器小窗，绝不主动弹出主程序（用户规则：右键只有「用七压打开」开主窗口）。
    func routeExtractInPlace(_ urls: [URL]) {
        if handlersInstalled { extractInPlace(urls) } else { StandaloneOperationController.run(.extractHere(urls)) }
    }
    func routeExtractToNamedFolder(_ urls: [URL]) {
        if handlersInstalled { extractToNamedFolder(urls) } else { StandaloneOperationController.run(.extractToNamedFolders(urls)) }
    }
    func routeExtractChooseDestination(_ urls: [URL]) {
        if handlersInstalled { extractChooseDestination(urls) } else { StandaloneOperationController.run(.extractChoosing(urls)) }
    }
    func routeTestArchives(_ urls: [URL]) {
        if handlersInstalled { testArchives(urls) } else { StandaloneOperationController.run(.test(urls)) }
    }
    func routeAddToArchiveDialog(_ urls: [URL], email: Bool = false) {
        // 主窗口未开时直接弹独立对话框——缓冲等待主窗口会让陈旧请求在日后
        // 主窗口打开时莫名弹出（且按用户规则该命令本来就不该开主窗口）。
        if handlersInstalled { addToArchiveDialog(urls, email) }
        else { CompressDialogController.shared.show(sources: urls, email: email) }
    }
    func routeCompressInPlace(_ urls: [URL], format: String = "zip") {
        if handlersInstalled { compressInPlace(urls, format) } else { StandaloneOperationController.run(.compress(urls, format: format)) }
    }
    func routeCompressAndEmail(_ urls: [URL], format: String) {
        if handlersInstalled { compressAndEmail(urls, format) } else { StandaloneOperationController.run(.compressAndEmail(urls, format: format)) }
    }
    func routeChecksumFiles(_ urls: [URL], algorithm: String) {
        if handlersInstalled { checksumFiles(urls, algorithm) } else { StandaloneOperationController.run(.checksum(urls, algorithm: algorithm)) }
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
        case "add-dialog", "compress-email-dialog":
            // 独立对话框承载，不需要主窗口（主窗口只在「用七压打开」时创建，
            // 见 MainWindowController）。
            CompressDialogController.shared.show(sources: files, email: url.host == "compress-email-dialog")
        case "extract": routeExtractInPlace(files)
        case "extract-folder": routeExtractToNamedFolder(files)
        case "extract-choose": routeExtractChooseDestination(files)
        case "test": routeTestArchives(files)
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
            case .compress(let urls, let format): compressInPlace(urls, format)
            case .compressEmail(let urls, let format): compressAndEmail(urls, format)
            case .checksum(let urls, let algorithm): checksumFiles(urls, algorithm)
            }
        }
    }
}
