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
        window.contentView = NSHostingView(rootView: root)
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = self
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    nonisolated func windowWillClose(_ notification: Notification) {
        Task { @MainActor in
            self.window = nil
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
            // 窗口关闭即放弃该窗口发起的后台任务（如转换），其暂存目录
            // 一并删除——任务随后的收尾写入会失败并落入错误分支，无副作用。
            TempDirectoryRegistry.cleanupAll()
        }
    }

    /// ContentView 安装的本地功能键监视器；关窗时必须移除，否则重开窗口
    /// 会累积多个监视器（F9 触发两次净效果为零，F5/F6 重复执行）。
    var keyMonitor: Any?
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
        HSplitView {
            PaneView(isFocused: !dualPane || focusedPane == 0) { focusedPane = 0 }
            if dualPane {
                PaneView(isFocused: focusedPane == 1) { focusedPane = 1 }
            }
        }
        .frame(minWidth: 940, minHeight: 560)
        .onAppear {
            actions.dualPaneActive = dualPane
            installShellActions()
            installFunctionKeyMonitor()
        }
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
