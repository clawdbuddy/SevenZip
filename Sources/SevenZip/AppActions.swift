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
    var checksum: () -> Void = {}
    var toggleLog: () -> Void = {}
    var enterPassword: () -> Void = {}
    var fileAssociation: () -> Void = {}
    var about: () -> Void = {}

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
