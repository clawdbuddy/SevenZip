import Foundation

public struct ArchiveEntry: Identifiable, Hashable {
    /// Display name shown in the UI.
    public let path: String
    /// Name as the 7zz engine sees it; differs from `path` only for legacy
    /// non-UTF-8 ZIP names (see `LegacyZipName`). Defaults to `path`.
    public let enginePath: String
    public let size: Int64?
    /// Packed (compressed) size inside the archive; nil for folders or when
    /// the engine does not report it (e.g. header-encrypted 7z listings).
    public let packedSize: Int64?
    public let modified: String
    public let isDirectory: Bool
    /// 属性面板扩展信息（来自 7zz l -slt 的对应字段，可能为空）。
    public let crc: String
    public let method: String
    public let attributes: String
    public let encrypted: Bool

    public var id: String { path }
    public var sizeLabel: String {
        if isDirectory { return "文件夹" }
        guard let size else { return "—" }
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }
    public var packedLabel: String {
        if isDirectory { return "" }
        guard let packedSize else { return "—" }
        return ByteCountFormatter.string(fromByteCount: packedSize, countStyle: .file)
    }

    public init(path: String, size: Int64?, modified: String, isDirectory: Bool, enginePath: String? = nil,
                packedSize: Int64? = nil, crc: String = "", method: String = "",
                attributes: String = "", encrypted: Bool = false) {
        self.path = path
        self.enginePath = enginePath ?? path
        self.size = size
        self.packedSize = packedSize
        self.modified = modified
        self.isDirectory = isDirectory
        self.crc = crc
        self.method = method
        self.attributes = attributes
        self.encrypted = encrypted
    }
}

/// 7-Zip on macOS maps filename bytes that are not valid UTF-8 into the Unicode
/// Private Use Area (U+EF00 + byte) when reading archives. Legacy Windows ZIP
/// archives store Chinese names in GBK without the UTF-8 flag, so they surface
/// as PUA glyphs ("乱码"). The mapping is lossless: the original bytes — and the
/// real name — can be recovered. There is no engine-side switch for this: the
/// `cp` option only exists in the ZIP *write* handler.
public enum LegacyZipName {
    private static let gb18030 = String.Encoding(rawValue:
        CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
    private static let cp437 = String.Encoding(rawValue:
        CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.dosLatinUS.rawValue)))

    private static func isPUA(_ scalar: Unicode.Scalar) -> Bool { (0xEF00 ... 0xEFFF).contains(scalar.value) }
    private static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        (0x4E00 ... 0x9FFF).contains(scalar.value) || (0x3400 ... 0x4DBF).contains(scalar.value)
    }

    /// Rebuilds the exact filename bytes stored in the archive for an engine-visible name.
    public static func bytes(of engineName: String) -> [UInt8] {
        var bytes: [UInt8] = []
        for scalar in engineName.unicodeScalars {
            if isPUA(scalar) {
                bytes.append(UInt8(scalar.value - 0xEF00))
            } else {
                bytes.append(contentsOf: String(scalar).utf8)
            }
        }
        return bytes
    }

    /// Recovers the display name for a legacy-encoded ZIP entry, or returns the
    /// input unchanged when it does not look like a legacy name.
    public static func recover(_ engineName: String) -> String {
        let puaCount = engineName.unicodeScalars.lazy.filter(isPUA).count
        guard puaCount > 0 else { return engineName }
        let bytes = self.bytes(of: engineName)
        // GBK/GB18030 covers Simplified Chinese Windows archives. Require at
        // least one CJK ideograph so Western legacy names are not misconverted;
        // a single Chinese character already costs two PUA scalars.
        if puaCount >= 2,
           let decoded = String(data: Data(bytes), encoding: gb18030),
           decoded.unicodeScalars.contains(where: isCJK) {
            return decoded
        }
        // Western legacy archives are stored in CP437, which is a total mapping.
        if let decoded = String(data: Data(bytes), encoding: cp437) {
            return decoded
        }
        return engineName
    }
}

public enum ArchiveFormat: String, CaseIterable, Identifiable {
    case sevenZip = "7z", zip = "zip", tar = "tar"
    public var id: String { rawValue }
    public var title: String { rawValue.uppercased() }
}

public enum ConflictPolicy: String, CaseIterable, Identifiable {
    case skip, rename, overwrite
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .skip: return "跳过已有文件"
        case .rename: return "自动重命名"
        case .overwrite: return "覆盖已有文件"
        }
    }
    public var switchValue: String {
        switch self {
        case .skip: return "-aos"
        case .rename: return "-aou"
        case .overwrite: return "-aoa"
        }
    }
}

public enum ExtractPathMode: String, CaseIterable, Identifiable {
    /// x：保留归档内的目录结构。
    case full
    /// e：丢弃目录结构，所有文件平铺到目标目录（同名冲突按覆盖策略处理）。
    case flat
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .full: return "完整路径"
        case .flat: return "无路径（平铺）"
        }
    }
    var command: String { self == .flat ? "e" : "x" }
}

public struct CompressionOptions {
    public var format: ArchiveFormat = .sevenZip
    public var level: Int = 5
    public var threads: Int = 0
    public var volumeMB: Int = 0
    public var encryptFileNames = true
    public var excludeMacMetadata = true
    public var password = ""

    public init() {}
}

public struct ArchiveInvocation {
    public let arguments: [String]
    public let directory: URL?
    /// Passed via the child's stdin, never through Process.arguments.
    public let password: String?

    public init(_ arguments: [String], directory: URL? = nil, password: String? = nil) {
        self.arguments = arguments
        self.directory = directory
        self.password = password
    }
}

public enum ArchiveCommandError: LocalizedError {
    case emptySelection, mixedParents, unsafePath(String), formatMismatch, invalidOptions

    public var errorDescription: String? {
        switch self {
        case .emptySelection: return "未选择文件。"
        case .mixedParents: return "请从同一父文件夹中选择文件，避免产生不一致的归档路径。"
        case .unsafePath(let path): return "拒绝不安全的归档路径：\(path)"
        case .formatMismatch: return "输出扩展名与压缩格式不匹配。"
        case .invalidOptions: return "压缩级别、线程数或分卷大小无效。"
        }
    }
}

public enum ArchivePath {
    /// Defensive check for selection and preview. The 7zz engine must still
    /// be kept up to date: a valid name can contain hostile symlink targets.
    public static func isSafe(_ path: String) -> Bool {
        if path.isEmpty || path.hasPrefix("/") || path.hasPrefix("\\") || path.hasPrefix("~") { return false }
        if path.contains("\0") || path.contains("\n") || path.contains("\r") { return false }
        let normalized = path.replacingOccurrences(of: "\\", with: "/")
        if normalized.count >= 2 && normalized.dropFirst().first == ":" { return false }
        return !normalized.split(separator: "/").contains("..")
    }
}

public enum ArchiveCommands {
    public static func list(_ archive: URL, password: String? = nil) -> ArchiveInvocation {
        ArchiveInvocation(["l", "-slt", "-bd", archive.path], password: password)
    }

    public static func test(_ archive: URL, password: String? = nil) -> ArchiveInvocation {
        ArchiveInvocation(["t", "-bsp1", archive.path], password: password)
    }

    public static func create(sources: [URL], archive: URL, options: CompressionOptions) throws -> ArchiveInvocation {
        guard let first = sources.first else { throw ArchiveCommandError.emptySelection }
        let parent = first.deletingLastPathComponent().standardizedFileURL
        guard sources.allSatisfy({ $0.deletingLastPathComponent().standardizedFileURL == parent }) else {
            throw ArchiveCommandError.mixedParents
        }
        guard archive.pathExtension.lowercased() == options.format.rawValue else {
            throw ArchiveCommandError.formatMismatch
        }
        guard (0...9).contains(options.level) && options.threads >= 0 && options.volumeMB >= 0 else {
            throw ArchiveCommandError.invalidOptions
        }
        var args = ["a", "-t\(options.format.rawValue)", "-bsp1", "-y", "-sse"]
        if options.format != .tar {
            args += ["-mx\(options.level)"]
            if options.threads > 0 { args += ["-mmt\(options.threads)"] }
        }
        if options.volumeMB > 0 { args += ["-v\(options.volumeMB)m"] }
        if options.excludeMacMetadata { args += ["-xr!__MACOSX", "-xr!.DS_Store"] }
        let password = options.password.isEmpty ? nil : options.password
        if password != nil {
            guard options.format != .tar else { throw ArchiveCommandError.invalidOptions }
            args += ["-p"] // prompt, then read the password on stdin
            if options.format == .sevenZip && options.encryptFileNames { args += ["-mhe=on"] }
            if options.format == .zip { args += ["-mem=AES256"] }
        }
        args.append(archive.path)
        args.append("--")
        args += sources.map { "./" + $0.lastPathComponent }
        return ArchiveInvocation(args, directory: parent, password: password)
    }

    public static func extract(_ archive: URL, to destination: URL, paths: [String] = [],
                               conflict: ConflictPolicy = .skip, password: String? = nil,
                               pathMode: ExtractPathMode = .full) throws -> ArchiveInvocation {
        for path in paths where !ArchivePath.isSafe(path) { throw ArchiveCommandError.unsafePath(path) }
        var args = [pathMode.command, conflict.switchValue, "-y", "-bsp1", "-spd", "-o\(destination.path)", archive.path]
        if !paths.isEmpty { args += ["--"] + paths }
        return ArchiveInvocation(args, password: password)
    }

    public static func delete(_ archive: URL, paths: [String], password: String? = nil) throws -> ArchiveInvocation {
        guard !paths.isEmpty else { throw ArchiveCommandError.emptySelection }
        for path in paths where !ArchivePath.isSafe(path) { throw ArchiveCommandError.unsafePath(path) }
        return ArchiveInvocation(["d", "-y", "-spd", "-bsp1", archive.path, "--"] + paths, password: password)
    }

    public static func rename(_ archive: URL, from old: String, to new: String,
                              password: String? = nil) throws -> ArchiveInvocation {
        guard ArchivePath.isSafe(old) else { throw ArchiveCommandError.unsafePath(old) }
        guard ArchivePath.isSafe(new) else { throw ArchiveCommandError.unsafePath(new) }
        return ArchiveInvocation(["rn", "-y", "-bsp1", archive.path, "--", old, new], password: password)
    }

    public static func add(_ archive: URL, sources: [URL], password: String? = nil) throws -> ArchiveInvocation {
        guard let first = sources.first else { throw ArchiveCommandError.emptySelection }
        let parent = first.deletingLastPathComponent().standardizedFileURL
        guard sources.allSatisfy({ $0.deletingLastPathComponent().standardizedFileURL == parent }) else {
            throw ArchiveCommandError.mixedParents
        }
        return ArchiveInvocation(["a", "-y", "-bsp1", archive.path, "--"] + sources.map { "./" + $0.lastPathComponent },
                                 directory: parent, password: password)
    }
}

public enum ArchiveListing {
    /// `7zz l -slt` 输出中「----------」之前的归档级字段（Quick Look 摘要行用）。
    public struct Summary {
        public var type = ""
        public var method = ""
        public var solid = false
        public var multivolume = false
        public var physicalSize: Int64?
        public init() {}
    }

    public static func parseSummary(_ text: String) -> Summary {
        var summary = Summary()
        for line in text.components(separatedBy: .newlines) {
            let clean = line.trimmingCharacters(in: .newlines)
            if clean.hasPrefix("----------") { break }
            guard let range = clean.range(of: " = ") else { continue }
            let key = String(clean[..<range.lowerBound])
            let value = String(clean[range.upperBound...])
            switch key {
            case "Type": summary.type = value
            case "Method": summary.method = value
            case "Solid": summary.solid = value == "+"
            case "Multivolume": summary.multivolume = value == "+"
            case "Physical Size": summary.physicalSize = Int64(value)
            default: break
            }
        }
        return summary
    }

    public static func parse(_ text: String) -> [ArchiveEntry] {
        var entries: [ArchiveEntry] = []
        var insideEntries = false
        var fields: [String: String] = [:]
        func appendCurrent() {
            guard let path = fields["Path"], !path.isEmpty else { return }
            entries.append(ArchiveEntry(path: path,
                                        size: fields["Size"].flatMap(Int64.init),
                                        modified: fields["Modified"] ?? "",
                                        isDirectory: fields["Folder"] == "+",
                                        packedSize: fields["Packed Size"].flatMap(Int64.init),
                                        crc: fields["CRC"] ?? "",
                                        method: fields["Method"] ?? "",
                                        attributes: fields["Attributes"] ?? "",
                                        encrypted: fields["Encrypted"] == "+"))
        }
        for line in text.components(separatedBy: .newlines) {
            let clean = line.trimmingCharacters(in: .newlines)
            if !insideEntries {
                if clean.hasPrefix("----------") { insideEntries = true }
                continue
            }
            if clean.isEmpty {
                appendCurrent()
                fields = [:]
            } else if let range = clean.range(of: " = ") {
                fields[String(clean[..<range.lowerBound])] = String(clean[range.upperBound...])
            }
        }
        appendCurrent()
        return entries
    }

    /// Recovers legacy (GBK/CP437) ZIP entry names for display while keeping
    /// `enginePath` pointing at the name the 7zz engine expects.
    public static func recoveringLegacyZipNames(_ entries: [ArchiveEntry]) -> [ArchiveEntry] {
        entries.map { entry in
            let recovered = LegacyZipName.recover(entry.path)
            guard recovered != entry.path else { return entry }
            return ArchiveEntry(path: recovered, size: entry.size, modified: entry.modified,
                                isDirectory: entry.isDirectory, enginePath: entry.path,
                                packedSize: entry.packedSize, crc: entry.crc, method: entry.method,
                                attributes: entry.attributes, encrypted: entry.encrypted)
        }
    }

    /// engine-visible path → display path, for entries recovered by
    /// `recoveringLegacyZipNames`. Used to repair filenames after extraction.
    /// `flat`（e 命令平铺解压）时键值都退化为文件本名——目录结构已被丢弃。
    public static func legacyNameRestoreMap(_ entries: [ArchiveEntry], flat: Bool = false) -> [String: String] {
        var map: [String: String] = [:]
        for entry in entries where entry.enginePath != entry.path {
            if flat {
                let key = entry.enginePath.split(separator: "/").last.map(String.init) ?? entry.enginePath
                let value = entry.path.split(separator: "/").last.map(String.init) ?? entry.path
                if key != value { map[key] = value }
            } else {
                map[entry.enginePath] = entry.path
            }
        }
        return map
    }
}
