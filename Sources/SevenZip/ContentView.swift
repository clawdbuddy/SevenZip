import AppKit
import SwiftUI

/// 主窗口控制器（AppKit 承载 ContentView）。
/// 为什么不用 WindowGroup：SwiftUI 场景在启动/URL 事件时自动开窗，事后
/// close/orderOut/dismissWindow 都无法清除 WindowServer 上的窗口（幽灵窗口），
/// 实测「添加到压缩包」命令会带出一到两个主窗口。改为完全手动管理：
/// 只有明确需要主窗口的路径（Dock 启动/重开、双击归档、解压等命令）才调用 show()。
@MainActor
final class MainWindowController: NSObject, NSWindowDelegate {
    static let shared = MainWindowController()
    private(set) var window: NSWindow?
    /// 原生工具栏控制器（动作转发给焦点窗格）。
    private let toolbarController = MainToolbarController()

    func show() {
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        let root = ContentView().environmentObject(AppActions.shared)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 940, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = "七压"
        window.minSize = NSSize(width: 940, height: 560)
        // macOS 标准窗口样式：工具栏与标题一体（unified）、标题栏透明，
        // 工具栏背景由系统绘制毛玻璃，与 Finder / 系统 App 一致。
        window.toolbarStyle = .unified
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .visible
        window.toolbar = toolbarController.makeToolbar()
        // 标签页（macOS 通用窗口行为）。
        window.tabbingMode = .preferred
        // 背景色跟随系统控件色（浅/深色自动切换）。
        window.backgroundColor = .controlBackgroundColor
        window.contentView = NSHostingView(rootView: root)
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = self
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// 工具栏可用状态变化后刷新（AppKit 工具栏不走 SwiftUI 渲染）。
    func refreshToolbar() {
        guard let toolbar = window?.toolbar else { return }
        toolbarController.applyState(toolbar: toolbar)
        toolbar.validateVisibleItems()
        // 工具栏项是延迟创建的：窗格首次 onAppear 同步状态时项可能尚未实例化，
        // 此刻的刷新是空转。等布局完成后再刷一次。
        DispatchQueue.main.async { [weak self] in
            guard let toolbar = self?.window?.toolbar else { return }
            self?.toolbarController.applyState(toolbar: toolbar)
        }
    }

    /// 窗口标题（macOS 惯例：显示当前打开的归档名）。
    func setWindowTitle(_ title: String) {
        window?.title = title
    }

    /// 兜底开的主窗口（还没等到 URL 事件）标记为「临时」：
    /// 若随后到达的是命令 URL（sevenzip://），说明这个窗口不该存在
    /// ——产品规则是「右键只有『用七压打开』才开主窗口」。
    private(set) var isProvisional = false

    /// 兜底开窗：标记为临时，等确认没有 URL 事件后再「转正」。
    func showProvisional() {
        isProvisional = true
        show()
    }

    /// 窗口里打开了归档 → 不再是临时窗口。
    func markAsPermanent() {
        isProvisional = false
    }

    /// 临时窗口且没有任何内容 → 关掉（命令 URL 到达时的清理）。
    func closeIfProvisional() {
        guard isProvisional else { return }
        isProvisional = false
        window?.close()
    }

    nonisolated func windowWillClose(_ notification: Notification) {
        // windowWillClose 本就在主线程，故同步清理（参照 AppMenu.menuNeedsUpdate）。
        // 异步化会留下死路由缝：close 与清理之间到达的 URL 事件看到
        // handlersInstalled==true 会调死窗格闭包；close→show 同一 runloop 时
        // 还会误删新窗口刚安装的 keyMonitor。
        MainActor.assumeIsolated {
            self.window = nil
            // 先取消本窗口各窗格仍在运行的后台任务（解压/压缩/转换）：
            // 否则孤儿 7zz 继续运行，还会重建下面 cleanupAll 删掉的暂存目录
            // （重建出的目录不在登记表 → 永久泄漏）。cancel() 内部有守卫，
            // 对空闲模型调用无副作用。
            for ref in paneModelRefs { ref.model?.cancel() }
            paneModelRefs.removeAll()
            // 窗口销毁后：命令路由层必须复位，否则 Finder 右键命令会路由到
            // 已销毁窗格安装的闭包（操作在不可见的死模型上执行），双击归档
            // 也会把文件开进死窗格、新窗口只剩空壳。
            let actions = AppActions.shared
            actions.handlersInstalled = false
            if let monitor = self.keyMonitor {
                NSEvent.removeMonitor(monitor)
                self.keyMonitor = nil
            }
            // 本窗口的嵌套/预览临时目录随窗口销毁；登记册兜底清理。
            TempDirectoryRegistry.cleanupAll()
        }
    }

    /// ContentView 安装的本地功能键监视器；关窗时必须移除，否则重开窗口
    /// 会累积多个监视器（F9 触发两次净效果为零，F5/F6 重复执行）。
    var keyMonitor: Any?

    /// 本窗口各窗格模型的弱引用（ContentView onAppear 时注册），供
    /// windowWillClose 逐一 cancel()。用弱引用：窗格销毁后模型可能仍被
    /// AppActions 闭包持有，但控制器不应为其续命。
    private var paneModelRefs: [WeakArchiveModel] = []

    func registerPaneModels(_ models: [ArchiveModel]) {
        paneModelRefs = models.map { WeakArchiveModel(model: $0) }
    }
}

/// ArchiveModel 的弱引用盒（数组元素不能直接标 weak）。
private struct WeakArchiveModel {
    weak var model: ArchiveModel?
}

private extension PaneView {
    /// PaneView 未暴露模型访问器（@StateObject 私有），从镜像中取出。
    /// StateObject 的存储盒与 SwiftUI 安装后的持久状态共享，取到的是活实例。
    @MainActor var archiveModel: ArchiveModel? {
        Mirror(reflecting: self).children
            .first { $0.label == "_model" }
            .flatMap { $0.value as? StateObject<ArchiveModel> }?
            .wrappedValue
    }
}

/// 双窗格外壳（7zFM F9）：承载 1~2 个 PaneView，跟踪焦点窗格，
/// 安装 F5/F6/F9 功能键监听。菜单处理器由焦点窗格自行安装。
struct ContentView: View {
    @EnvironmentObject private var actions: AppActions

    @State private var dualPane = UserDefaults.standard.bool(forKey: "dualPane") {
        didSet {
            UserDefaults.standard.set(dualPane, forKey: "dualPane")
            actions.dualPaneActive = dualPane
        }
    }
    @State private var focusedPane = 0

    var body: some View {
        // 窗格先存为局部常量：onAppear 时需把各窗格的 ArchiveModel 注册到
        // MainWindowController（供关窗时取消后台任务），不能只在 HSplitView
        // 里内联构造。第二窗格的 @StateObject 随 dualPane 开启重建，故在
        // onAppear 与 onChange(dualPane) 两处都重新注册当前实例。
        let pane0 = PaneView(isFocused: !dualPane || focusedPane == 0) { focusedPane = 0 }
        let pane1 = PaneView(isFocused: focusedPane == 1) { focusedPane = 1 }
        return HSplitView {
            pane0
            if dualPane {
                pane1
            }
        }
        .frame(minWidth: 940, minHeight: 560)
        .onAppear {
            actions.dualPaneActive = dualPane
            installShellActions()
            installFunctionKeyMonitor()
            registerPaneModels(pane0, dualPane ? pane1 : nil)
        }
        .onChange(of: dualPane) { _ in
            registerPaneModels(pane0, dualPane ? pane1 : nil)
        }
    }

    /// 把当前各窗格模型注册到窗口控制器（关窗时统一 cancel，杀孤儿 7zz）。
    private func registerPaneModels(_ panes: PaneView?...) {
        MainWindowController.shared.registerPaneModels(panes.compactMap { $0?.archiveModel })
    }

    private func installShellActions() {
        actions.toggleDualPane = {
            dualPane.toggle()
            if !dualPane { focusedPane = 0 }
        }
        actions.switchPane = {
            if dualPane { focusedPane = 1 - focusedPane }
        }
    }

    /// SwiftUI 菜单快捷键不支持 F5/F6/F9，用本地事件监听补齐（7zFM 键位）。
    private func installFunctionKeyMonitor() {
        // 重复安装（窗口重开）前先移除旧监视器，避免累积触发。
        if let old = MainWindowController.shared.keyMonitor {
            NSEvent.removeMonitor(old)
        }
        MainWindowController.shared.keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // 有 sheet 弹出时不拦截功能键；主窗口非 key 时（对话框/独立小窗在前）也不拦截。
            guard let key = NSApp.keyWindow, key.attachedSheet == nil,
                  key == MainWindowController.shared.window else { return event }
            switch event.keyCode {
            case 101:  // F9: 双窗格开关
                Task { @MainActor in actions.toggleDualPane() }
                return nil
            case 96 where dualPane:  // F5: 复制到另一窗格
                Task { @MainActor in actions.copyToOtherPane() }
                return nil
            case 97 where dualPane:  // F6: 移动到另一窗格
                Task { @MainActor in actions.moveToOtherPane() }
                return nil
            default:
                return event
            }
        }
    }
}
