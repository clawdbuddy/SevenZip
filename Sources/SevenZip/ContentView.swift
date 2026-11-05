import AppKit
import SwiftUI

/// 双窗格外壳（7zFM F9）：承载 1~2 个 PaneView，跟踪焦点窗格，
/// 安装 F5/F6/F9 功能键监听。菜单处理器由焦点窗格自行安装。
struct ContentView: View {
    @EnvironmentObject private var actions: AppActions

    @State private var dualPane = UserDefaults.standard.bool(forKey: "dualPane") {
        didSet { UserDefaults.standard.set(dualPane, forKey: "dualPane") }
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
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // 有 sheet 弹出时不拦截功能键。
            guard NSApp.keyWindow?.attachedSheet == nil else { return event }
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
