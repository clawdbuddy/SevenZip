import AppKit
import Foundation

/// 通过 GitHub Releases API 检查新版本。启动时静默检查（仅发现新版才弹窗），
/// 「帮助 → 检查更新…」手动检查时总是给出结论。
enum UpdateChecker {
    private static let apiURL = URL(string: "https://api.github.com/repos/clawdbuddy/SevenZip/releases/latest")!
    private static let releasesPage = URL(string: "https://github.com/clawdbuddy/SevenZip/releases/latest")!

    /// 应用启动后调用；用户关闭「启动时检查更新」则直接返回。
    @MainActor
    static func checkInBackground() {
        guard AppActions.shared.checkUpdates else { return }
        check(manual: false)
    }

    static func check(manual: Bool) {
        Task.detached {
            do {
                var request = URLRequest(url: apiURL)
                request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
                request.setValue("SevenZip-macOS", forHTTPHeaderField: "User-Agent")
                request.timeoutInterval = 12
                let (data, response) = try await URLSession.shared.data(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 200,
                      let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let tag = json["tag_name"] as? String, !tag.isEmpty else {
                    throw NSError(domain: "UpdateChecker", code: 1,
                                  userInfo: [NSLocalizedDescriptionKey: "未获取到发行信息"])
                }
                let page = (json["html_url"] as? String).flatMap(URL.init) ?? releasesPage
                await MainActor.run { present(latestTag: tag, page: page, manual: manual) }
            } catch {
                // 静默模式（含尚无 Release 的 404）不打扰用户。
                if manual {
                    await MainActor.run {
                        let alert = NSAlert()
                        alert.messageText = "检查更新失败"
                        alert.informativeText = "无法获取最新版本信息（网络不可用或仓库尚未发布 Release）。"
                        alert.runModal()
                    }
                }
            }
        }
    }

    @MainActor
    private static func present(latestTag: String, page: URL, manual: Bool) {
        let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let latest = latestTag.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
        guard isNewer(latest, than: current) else {
            if manual {
                let alert = NSAlert()
                alert.messageText = "已是最新版本"
                alert.informativeText = "当前版本 \(current)。"
                alert.runModal()
            }
            return
        }
        let alert = NSAlert()
        alert.messageText = "发现新版本 \(latest)"
        alert.informativeText = "当前版本 \(current)。是否前往下载页面？"
        alert.addButton(withTitle: "前往下载")
        alert.addButton(withTitle: "稍后")
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(page)
        }
    }

    /// 点分版本号逐段数值比较：1.10.0 > 1.9.9。
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = candidate.split(separator: ".").map { Int($0) ?? 0 }
        let b = current.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(a.count, b.count) {
            let x = index < a.count ? a[index] : 0
            let y = index < b.count ? b[index] : 0
            if x != y { return x > y }
        }
        return false
    }
}
