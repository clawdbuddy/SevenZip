import AppKit
import UniformTypeIdentifiers

/// 文件类型关联（对标 Windows 7-Zip「选项 → 文件关联」页）：
/// 列出各归档格式及当前由哪个应用打开，可把归属改成七压 / 其他应用 / 系统默认。
enum FileAssociation {
    struct Entry: Identifiable {
        var id: String { ext }
        let ext: String
        /// 当前处理该格式的应用名（「未设置」= 系统没指定）。
        let handlerName: String
        /// 当前处理者是不是七压自己。
        let isOurs: Bool
        /// 当前处理者的图标。
        let handlerIcon: NSImage?
        /// 当前处理者的完整路径（判断「是否已是归档实用工具」要用，
        /// 只看名字会随系统语言变化）。
        let handlerURL: URL?

        /// 已经由系统自带的「归档实用工具」处理：再点「恢复系统默认」没有意义。
        var isSystemDefault: Bool {
            handlerURL?.standardizedFileURL.path == FileAssociation.archiveUtilityURL?.path
        }
    }

    /// 七压能处理的格式（与 Windows 7-Zip「文件关联」页的清单对齐）。
    static let supported: [(ext: String, uti: String)] = [
        ("7z", "org.7-zip.7-zip-archive"),
        ("zip", "com.pkware.zip-archive"),
        ("rar", "com.rarlab.rar-archive"),
        ("001", "org.7-zip.7-zip-archive"),
        ("cab", "public.cab-archive"),
        ("iso", "public.iso-image"),
        ("xz", "org.tukaani.xz-archive"),
        ("txz", "org.tukaani.xz-archive"),
        ("lzh", "com.lha.lzh-archive"),
        ("tar", "public.tar-archive"),
        ("cpio", "public.cpio-archive"),
        ("bz2", "org.gnu.gnu-zip-archive"),
        ("tbz2", "org.gnu.gnu-zip-archive"),
        ("tbz", "org.gnu.gnu-zip-archive"),
        ("gz", "org.gnu.gnu-zip-archive"),
        ("gzip", "org.gnu.gnu-zip-archive"),
        ("tgz", "org.gnu.gnu-zip-archive"),
        ("tpz", "org.gnu.gnu-zip-archive"),
        ("zst", "org.7-zip.7-zip-archive"),
        ("z", "public.compress-archive"),
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

    /// 「归档实用工具」的固定位置（系统自带，两个路径按系统版本二选一）。
    /// 「恢复系统默认」就是把它设回默认打开方式。
    static var archiveUtilityURL: URL? {
        [
            "/System/Library/CoreServices/Applications/Archive Utility.app",
            "/System/Library/CoreServices/Archive Utility.app",
        ].first { FileManager.default.fileExists(atPath: $0) }.map(URL.init(fileURLWithPath:))
    }

    /// 用户在「+ 添加类型」里手动追加的格式。必须持久化：否则刷新后
    /// status() 只遍历内置清单，刚添加的格式立刻从列表里消失，
    /// 「添加类型」清单又会把它列出来，造成「加了却没生效」的假象。
    static var extraExts: [String] {
        get { UserDefaults.standard.stringArray(forKey: "associationExtraExts") ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: "associationExtraExts") }
    }

    static func status() -> [Entry] {
        let ownPath = Bundle.main.bundleURL.standardizedFileURL.path
        // 内置清单 + 用户手动追加的格式（追加的只需扩展名，查询靠探针文件）。
        // 去重：UserDefaults 里可能混进与内置清单重复的项（手工改过、旧版本
        // 写入），Table 的 Identifiable 以扩展名为 id，重复行会让选中态错乱。
        let builtIns = supported.map { $0.ext }
        let all = builtIns + extraExts.filter { !builtIns.contains($0) }
        return all.map { ext in
            let handler = currentHandler(ext: ext)
            // 必须比对完整路径：只看 app 名会把用户机器上任何同名副本
            // （下载目录里的另一份构建）误判为「已关联」，「移除」也会改错对象。
            let isOurs = handler?.standardizedFileURL.path == ownPath
            return Entry(ext: ext,
                         handlerName: handler?.deletingPathExtension().lastPathComponent ?? "未设置",
                         isOurs: isOurs,
                         handlerIcon: handler.map { NSWorkspace.shared.icon(forFile: $0.path) },
                         handlerURL: handler)
        }
    }

    /// 把清单外的格式纳入列表（「+ 添加类型」）。幂等。
    static func addExt(_ ext: String) {
        let lower = ext.lowercased()
        guard !supported.contains(where: { $0.ext == lower }),
              !extraExts.contains(lower) else { return }
        extraExts = extraExts + [lower]
    }

    /// 绑定为默认打开方式。macOS 12+ 系统会弹确认框，属于正常流程。
    static func bind(ext: String, completion: @escaping @MainActor (Bool) -> Void) {
        setDefault(Bundle.main.bundleURL, ext: ext, completion: completion)
    }

    /// 移除关联 = 恢复系统默认打开方式（归档实用工具）。
    /// macOS 没有“解绑为空”的 API，这是与 Windows 取消勾选等效的做法。
    static func remove(ext: String, completion: @escaping @MainActor (Bool) -> Void) {
        guard let utility = archiveUtilityURL else {
            Task { @MainActor in completion(false) }
            return
        }
        setDefault(utility, ext: ext, completion: completion)
    }

    /// 可供该格式打开的应用（macOS「打开方式」里的候选）。
    static func candidateHandlers(ext: String) -> [URL] {
        guard let type = UTType(filenameExtension: ext) else { return [] }
        // 机器上可能有多份同名副本（/Applications 里的、下载目录里的），
        // 按标准化路径去重，避免候选列表出现两行一模一样的「SevenZip」。
        var seen = Set<String>()
        let apps = NSWorkspace.shared.urlsForApplications(toOpen: type).filter {
            seen.insert($0.standardizedFileURL.path).inserted
        }
        // 系统自带的「归档实用工具」排在前面——它是最合理的兜底。
        return apps.sorted { lhs, rhs in
            let l = lhs.lastPathComponent == "Archive Utility.app"
            let r = rhs.lastPathComponent == "Archive Utility.app"
            return l == r ? lhs.lastPathComponent < rhs.lastPathComponent : l
        }
    }

    /// 把该格式的归属改成指定应用。
    static func setHandler(app: URL, ext: String,
                           completion: @escaping @MainActor (Bool) -> Void) {
        setDefault(app, ext: ext, completion: completion)
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
