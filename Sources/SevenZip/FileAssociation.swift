import AppKit
import UniformTypeIdentifiers

/// 文件类型关联（对标 Windows 7-Zip「工具 → 选项 → 系统」页）：
/// 查询/设置各归档格式的默认打开应用。
enum FileAssociation {
    struct Entry: Identifiable {
        var id: String { ext }
        let ext: String
        let handlerName: String
        let isOurs: Bool
    }

    static let supported: [(ext: String, uti: String)] = [
        ("7z", "org.7-zip.7-zip-archive"),
        ("zip", "com.pkware.zip-archive"),
        ("rar", "com.rarlab.rar-archive"),
        ("tar", "public.tar-archive"),
        ("gz", "org.gnu.gzipped-archive"),
        ("xz", "org.tukaani.xz-archive"),
    ]

    /// 每种扩展名建一个探针文件，问系统它的默认打开应用。
    /// NSWorkspace 只认真实存在的文件，不能直接用 UTI 查询。
    static func currentHandler(ext: String) -> URL? {
        let probe = FileManager.default.temporaryDirectory
            .appendingPathComponent("sevenzip-probe-\(UUID().uuidString).\(ext)")
        FileManager.default.createFile(atPath: probe.path, contents: Data())
        defer { try? FileManager.default.removeItem(at: probe) }
        return NSWorkspace.shared.urlForApplication(toOpen: probe)
    }

    static func status() -> [Entry] {
        let ownPath = Bundle.main.bundleURL.standardizedFileURL.path
        return supported.map { item in
            let handler = currentHandler(ext: item.ext)
            // 必须比对完整路径：只看 app 名会把用户机器上任何同名副本
            // （下载目录里的另一份构建）误判为「已关联」，「移除」也会改错对象。
            let isOurs = handler?.standardizedFileURL.path == ownPath
            return Entry(ext: item.ext,
                         handlerName: handler?.deletingPathExtension().lastPathComponent ?? "未设置",
                         isOurs: isOurs)
        }
    }

    /// 绑定为默认打开方式。macOS 12+ 系统会弹确认框，属于正常流程。
    static func bind(ext: String, completion: @escaping @MainActor (Bool) -> Void) {
        setDefault(Bundle.main.bundleURL, ext: ext, completion: completion)
    }

    /// 移除关联 = 恢复系统默认打开方式（归档实用工具）。
    /// macOS 没有“解绑为空”的 API，这是与 Windows 取消勾选等效的做法。
    static func remove(ext: String, completion: @escaping @MainActor (Bool) -> Void) {
        let candidates = [
            "/System/Library/CoreServices/Applications/Archive Utility.app",
            "/System/Library/CoreServices/Archive Utility.app",
        ]
        guard let path = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
            Task { @MainActor in completion(false) }
            return
        }
        setDefault(URL(fileURLWithPath: path), ext: ext, completion: completion)
    }

    private static func setDefault(_ appURL: URL, ext: String,
                                   completion: @escaping @MainActor (Bool) -> Void) {
        guard let type = UTType(filenameExtension: ext) else {
            Task { @MainActor in completion(false) }
            return
        }
        Task { @MainActor in
            do {
                try await NSWorkspace.shared.setDefaultApplication(at: appURL, toOpen: type)
                completion(true)
            } catch {
                completion(false)
            }
        }
    }
}
