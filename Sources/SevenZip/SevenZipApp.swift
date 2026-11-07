import SwiftUI

@main
struct SevenZipApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    // 空的场景集合：主窗口与「添加到压缩包」等对话框全部由 AppKit 手动管理。
    // 任何可见场景都会在启动/URL 事件时自动开窗，且 WindowServer 上的窗口
    // 事后无法清除（幽灵窗口）；唯一 Settings 场景也会在启动时自动弹出。
    // 菜单栏因此也不能用 SwiftUI Commands（必须依附场景），由 AppMenuBuilder
    // 以纯 AppKit NSMenu 构建。
    var body: some Scene {
    }
}
