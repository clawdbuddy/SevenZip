import AppKit
import Foundation

/// Finder 快速操作（预览面板 / 右键「快速操作」子菜单 / Touch Bar）：
/// com.apple.ui-services Action 扩展。同一源码构建两个 appex——
/// 「用七压解压」与「用七压压缩」——行为由各自 Info.plist 的
/// QACommandHost / QACommandFormat 配置，命令经 sevenzip:// 交给主程序。
/// 界面永不显示：拿到文件 URL 后立即转发并完成请求（最接近于无头运行）。
final class Controller: NSViewController {

    override func loadView() {
        view = NSView(frame: .zero)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        let items = (extensionContext?.inputItems as? [NSExtensionItem]) ?? []
        let providers = items.flatMap { $0.attachments ?? [] }
        // extensionContext 强引用带走：VC 在异步取回期间被释放也必须完成请求，
        // 否则 completeRequest 永不被调用，Finder 快速操作转圈到系统超时。
        let context = extensionContext
        Self.collectFileURLs(from: providers) { [weak self] urls in
            guard let self else {
                context?.completeRequest(returningItems: nil)
                return
            }
            self.handOff(urls)
        }
    }

    private func handOff(_ urls: [URL]) {
        let finish = { self.extensionContext?.completeRequest(returningItems: nil) }
        guard !urls.isEmpty else {
            finish()
            return
        }
        let host = Bundle.main.object(forInfoDictionaryKey: "QACommandHost") as? String
            ?? "extract-folder"
        var components = URLComponents()
        components.scheme = "sevenzip"
        components.host = host
        var query = urls.map { URLQueryItem(name: "path", value: $0.path) }
        if let format = Bundle.main.object(forInfoDictionaryKey: "QACommandFormat") as? String {
            query.append(URLQueryItem(name: "format", value: format))
        }
        components.queryItems = query
        guard let url = components.url else {
            finish()
            return
        }
        // appex → PlugIns → Contents → SevenZip.app
        let parentApp = Bundle.main.bundleURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        // 等系统确认接管后再完成请求，否则扩展进程可能在 open 完成前被销毁。
        NSWorkspace.shared.open([url], withApplicationAt: parentApp,
                                configuration: NSWorkspace.OpenConfiguration()) { _, _ in
            finish()
        }
    }

    /// 附件以 NSItemProvider 形式到达，逐个异步取回 file URL。
    private static func collectFileURLs(from providers: [NSItemProvider],
                                        completion: @escaping ([URL]) -> Void) {
        var urls: [URL] = []
        let lock = NSLock()
        let group = DispatchGroup()
        for provider in providers
        where provider.hasItemConformingToTypeIdentifier("public.file-url") {
            group.enter()
            provider.loadItem(forTypeIdentifier: "public.file-url") { item, _ in
                defer { group.leave() }
                let url = (item as? URL)
                    ?? (item as? Data).flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
                if let url {
                    lock.lock()
                    urls.append(url)
                    lock.unlock()
                }
            }
        }
        // 兜底：某个提供方永不回调时（iCloud 占位文件、网络卷、已删除条目），
        // group.notify 不会触发，Finder 的快速操作一直转圈。
        // 到点用已取到的 urls 继续。
        var delivered = false
        let deliver: ([URL]) -> Void = { result in
            lock.lock()
            let already = delivered
            delivered = true
            lock.unlock()
            if !already { completion(result) }
        }
        group.notify(queue: .main) {
            lock.lock()
            let snapshot = urls
            lock.unlock()
            deliver(snapshot)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
            lock.lock()
            let snapshot = urls
            lock.unlock()
            deliver(snapshot)
        }
    }
}
