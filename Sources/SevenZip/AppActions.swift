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
        case compress([URL])
    }
    var handlersInstalled = false
    var pendingServices: [PendingService] = []
    var openFiles: ([URL]) -> Void = { _ in }
    var extractInPlace: ([URL]) -> Void = { _ in }
    var compressInPlace: ([URL]) -> Void = { _ in }

    func routeOpenFiles(_ urls: [URL]) {
        if handlersInstalled { openFiles(urls) } else { pendingServices.append(.open(urls)) }
    }
    func routeExtractInPlace(_ urls: [URL]) {
        if handlersInstalled { extractInPlace(urls) } else { pendingServices.append(.extract(urls)) }
    }
    func routeCompressInPlace(_ urls: [URL]) {
        if handlersInstalled { compressInPlace(urls) } else { pendingServices.append(.compress(urls)) }
    }

    /// ContentView.onAppear 在 installMenuActions 之后调用，回放缓冲的服务请求。
    func drainPendingServices() {
        let pending = pendingServices
        pendingServices.removeAll()
        for item in pending {
            switch item {
            case .open(let urls): openFiles(urls)
            case .extract(let urls): extractInPlace(urls)
            case .compress(let urls): compressInPlace(urls)
            }
        }
    }
}
