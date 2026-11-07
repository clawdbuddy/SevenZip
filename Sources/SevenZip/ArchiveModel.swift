import ArchiveCore
import Combine
import Foundation

@MainActor
final class ArchiveModel: ObservableObject {
    @Published private(set) var archiveURL: URL?
    @Published private(set) var entries: [ArchiveEntry] = []
    @Published private(set) var listingComplete = false
    @Published private(set) var status = "就绪"
    @Published private(set) var output = "请选择压缩包，或创建一个新压缩包。"
    @Published private(set) var busy = false
    @Published private(set) var progress: Double?
    @Published private(set) var queueCount = 0
    @Published private(set) var errorMessage: String?
    /// Set when the engine refused to list an archive because it needs a password.
    @Published private(set) var passwordNeededFor: URL?
    @Published var previewURL: URL?

    private var runningPID: pid_t?
    private var pending: [Job] = []
    private var progressFragment = ""
    private var activeRunID: UUID?
    private var previewFolders: [URL] = []

    /// 解压完成后的收尾信息：落地目录、旧编码文件名修复表、可选的根目录去重。
    private struct ExtractCompletion {
        let destination: URL
        let restoreMap: [String: String]
        /// 非空时：解压后若目标目录下只剩该同名根目录，把其内容上移一层
        /// （对应 7-Zip「Eliminate duplication of root folder」）。
        var eliminateRoot: String? = nil
    }

    private enum Completion {
        case listing(URL), created(URL), createdSilent(URL), createdForEmail(URL), batchCreated(URL), extracted(ExtractCompletion), preview(URL, String, [String: String]),
             nested(URL, String, [String: String]),
             batchPreflight(URL, URL, ConflictPolicy, String?, ExtractPathMode),
             conversionExtracted(URL, URL, ArchiveFormat, String?), converted(URL, URL), tested(URL?), edited(URL), hash
    }

    private struct Job {
        let invocation: ArchiveInvocation
        let completion: Completion
    }

    func dismissError() { errorMessage = nil }
    func warn(_ message: String) { report(message) }
    /// Non-error feedback that does not flag the status as a failure.
    func announce(_ message: String) {
        status = message
        output = message
    }

    func open(_ url: URL, password: String? = nil) {
        archiveURL = url
        entries = []
        listingComplete = false
        passwordNeededFor = nil
        nestedArchiveURL = nil
        nestedEntryPath = nil
        enqueue(ArchiveCommands.list(url, password: password), completion: .listing(url))
    }

    func dismissPasswordRequest() { passwordNeededFor = nil }

    func compress(sources: [URL], destination: URL, options: CompressionOptions,
                  emailAfter: Bool = false, openAfter: Bool = true) {
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            report("目标文件已存在；请更换压缩包名称，以免意外修改已有文件。")
            return
        }
        do {
            let command = try ArchiveCommands.create(sources: sources, archive: destination, options: options)
            // openAfter=false（独立「添加到压缩包」对话框）：完成后不再把新归档
            // 载入列表——无主窗口可显示，且清单状态会覆盖「已创建」，破坏
            // 对话框「创建成功 → 自动关窗」的判定。
            let completion: Completion = emailAfter ? .createdForEmail(destination)
                : (openAfter ? .created(destination) : .createdSilent(destination))
            enqueue(command, completion: completion)
        } catch { report(error.localizedDescription) }
    }

    func extract(to directory: URL, paths: [String] = [],
                 conflict: ConflictPolicy = .skip, password: String? = nil,
                 pathMode: ExtractPathMode = .full, eliminateRoot: String? = nil) {
        guard let url = archiveURL else { return }
        guard listingComplete else { report("归档清单尚未完整读取，拒绝解压。") ; return }
        guard entries.allSatisfy({ ArchivePath.isSafe($0.path) }) else {
            report("归档包含绝对路径或上级目录跳转条目，安全模式已拒绝解压。")
            return
        }
        do {
            let targets = enginePaths(for: expandedPaths(paths))
            let command = try ArchiveCommands.extract(url, to: directory, paths: targets,
                                                      conflict: conflict, password: password,
                                                      pathMode: pathMode)
            let map = ArchiveListing.legacyNameRestoreMap(entries, flat: pathMode == .flat)
            enqueue(command, completion: .extracted(ExtractCompletion(
                destination: directory, restoreMap: map,
                eliminateRoot: pathMode == .full ? eliminateRoot : nil)))
        } catch { report(error.localizedDescription) }
    }

    func batchExtract(archives: [URL], to destination: URL,
                      conflict: ConflictPolicy = .skip, password: String? = nil) {
        guard !archives.isEmpty else { return }
        var used = Set<String>()
        for archive in archives {
            // Give every archive its own output directory to limit collisions.
            let name = archive.lastPathComponent.replacingOccurrences(of: ".", with: "_")
            guard used.insert(name.lowercased()).inserted else {
                report("压缩包同名，批量解压已中止：\(name)")
                return
            }
            let target = destination.appendingPathComponent(name, isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
                let list = ArchiveCommands.list(archive, password: password)
                enqueue(list, completion: .batchPreflight(archive, target, conflict, password, .full))
            } catch { report(error.localizedDescription); return }
        }
    }

    func batchCompress(sources: [URL], to destination: URL, options: CompressionOptions) {
        guard !sources.isEmpty else { return }
        var used = Set<String>()
        for source in sources {
            let archive = destination.appendingPathComponent(source.lastPathComponent + "." + options.format.rawValue)
            guard used.insert(archive.lastPathComponent.lowercased()).inserted else {
                report("批量压缩输入存在重名项目：\(source.lastPathComponent)")
                return
            }
            if FileManager.default.fileExists(atPath: archive.path) {
                report("批量压缩目标已存在：\(archive.lastPathComponent)")
                return
            }
            do {
                let invocation = try ArchiveCommands.create(sources: [source], archive: archive, options: options)
                enqueue(invocation, completion: .batchCreated(archive))
            } catch { report(error.localizedDescription); return }
        }
    }

    func test(password: String? = nil) {
        guard let url = archiveURL else { return }
        enqueue(ArchiveCommands.test(url, password: password), completion: .tested(url))
    }

    /// 测试任意归档（无需先在界面打开），供 Finder 扩展「测试压缩包」使用。
    func testArchive(_ url: URL, password: String? = nil) {
        enqueue(ArchiveCommands.test(url, password: password), completion: .tested(url))
    }

    /// 解压任意归档到精确目录（无需先在界面打开）：先列清单做路径安全检查，再解压。
    /// Extract Here = 归档所在目录；Extract to "名称/" = 同名子目录。
    func extractArchive(_ archive: URL, to destination: URL, createDirectory: Bool,
                        conflict: ConflictPolicy = .skip, password: String? = nil,
                        pathMode: ExtractPathMode = .full) {
        do {
            if createDirectory {
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            }
            let list = ArchiveCommands.list(archive, password: password)
            enqueue(list, completion: .batchPreflight(archive, destination, conflict, password, pathMode))
        } catch { report(error.localizedDescription) }
    }

    /// 计算任意磁盘文件的校验和（无需打开归档），结果写入运行日志。
    func checksumFiles(_ urls: [URL], algorithm: String) {
        for url in urls {
            enqueue(ArchiveInvocation(["h", "-scrc\(algorithm)", url.path]), completion: .hash)
        }
        if !urls.isEmpty { announce("已加入校验和队列：\(urls.count) 个文件（\(algorithm)）。") }
    }

    /// 压缩完成后需调出邮件分享时，经此 @Published 通知界面。
    @Published var emailShareURL: URL?

    func checksum(algorithm: String = "SHA256") {
        guard let url = archiveURL else { return }
        enqueue(ArchiveInvocation(["h", "-scrc\(algorithm)", url.path]), completion: .hash)
    }

    /// 嵌套归档：把归档内的一个归档条目解压到临时目录，
    /// 完成后通过 `nestedArchiveURL` 通知界面打开。
    @Published var nestedArchiveURL: URL?
    /// 嵌套条目在外层归档中的完整路径（地址栏显示用）。
    @Published var nestedEntryPath: String?

    func openNested(path: String, password: String? = nil) {
        guard let url = archiveURL else { return }
        guard let entry = entries.first(where: { $0.path == path }), !entry.isDirectory else {
            report("请选择归档内的单个压缩包文件。")
            return
        }
        guard ArchivePath.isSafe(path) else { report("不安全的归档路径，已拒绝打开。") ; return }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SevenZip-nested-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let invocation = try ArchiveCommands.extract(url, to: directory,
                                                         paths: [entry.enginePath], conflict: .skip, password: password)
            previewFolders.append(directory)
            enqueue(invocation, completion: .nested(directory, path, ArchiveListing.legacyNameRestoreMap(entries)))
        } catch { report(error.localizedDescription) }
    }

    func convert(to destination: URL, format: ArchiveFormat, password: String? = nil) {
        guard let source = archiveURL else { return }
        guard listingComplete else { report("归档清单尚未完整读取，拒绝格式转换。") ; return }
        guard destination.pathExtension.lowercased() == format.rawValue else {
            report("转换的目标扩展名应为 .\(format.rawValue)")
            return
        }
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            report("转换目标已存在，为避免覆盖原始文件，请换一个文件名。")
            return
        }
        guard entries.allSatisfy({ ArchivePath.isSafe($0.path) }) else {
            report("转换中止：源归档包含不安全路径。")
            return
        }
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("SevenZip-convert-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            let command = try ArchiveCommands.extract(source, to: staging, password: password)
            enqueue(command, completion: .conversionExtracted(staging, destination, format, password))
        } catch { report(error.localizedDescription) }
    }

    func preview(path: String, password: String? = nil) {
        guard let url = archiveURL else { return }
        guard let entry = entries.first(where: { $0.path == path }), !entry.isDirectory else {
            report("请选择单个普通文件进行预览。")
            return
        }
        guard ArchivePath.isSafe(path) else { report("不安全的归档路径，已拒绝预览。") ; return }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SevenZip-preview-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let invocation = try ArchiveCommands.extract(url, to: directory,
                                                         paths: [entry.enginePath], conflict: .skip, password: password)
            previewFolders.append(directory)
            enqueue(invocation, completion: .preview(directory, path, ArchiveListing.legacyNameRestoreMap(entries)))
        } catch { report(error.localizedDescription) }
    }

    func delete(paths: [String], password: String? = nil) {
        guard let archive = editableArchive() else { return }
        do {
            enqueue(try ArchiveCommands.delete(archive, paths: enginePaths(for: expandedPaths(paths)), password: password),
                    completion: .edited(archive))
        } catch { report(error.localizedDescription) }
    }

    func rename(path: String, to newPath: String, password: String? = nil) {
        guard let archive = editableArchive() else { return }
        guard !entries.contains(where: { $0.path == newPath }) else {
            report("压缩包中已有同名条目，无法重命名。")
            return
        }
        do {
            enqueue(try ArchiveCommands.rename(archive, from: enginePaths(for: [path]).first ?? path,
                                               to: newPath, password: password),
                    completion: .edited(archive))
        } catch { report(error.localizedDescription) }
    }

    func add(sources: [URL], password: String? = nil) {
        guard let archive = editableArchive() else { return }
        let collisions = sources.filter { file in entries.contains(where: { $0.path == file.lastPathComponent }) }
        guard collisions.isEmpty else {
            report("存在与归档同名的文件，请先重命名以避免意外覆盖。")
            return
        }
        do {
            enqueue(try ArchiveCommands.add(archive, sources: sources, password: password),
                    completion: .edited(archive))
        } catch { report(error.localizedDescription) }
    }

    func cancel() {
        pending.removeAll()
        queueCount = 0
        if let pid = runningPID { kill(pid, SIGTERM) }
    }

    private func editableArchive() -> URL? {
        guard let archive = archiveURL else { return nil }
        guard listingComplete else { report("尚未完整读取归档清单，禁止修改。") ; return nil }
        guard ["7z", "zip"].contains(archive.pathExtension.lowercased()) else {
            report("当前只支持修改 7z、ZIP 压缩包。")
            return nil
        }
        return archive
    }

    private func expandedPaths(_ paths: [String]) -> [String] {
        guard !paths.isEmpty else { return [] }
        var targets = Set(paths)
        for path in paths {
            if entries.contains(where: { $0.path == path && $0.isDirectory }) {
                let prefix = path.hasSuffix("/") ? path : path + "/"
                for entry in entries where entry.path.hasPrefix(prefix) { targets.insert(entry.path) }
            }
        }
        return targets.sorted()
    }

    /// Translates display paths to the names the 7zz engine actually sees.
    /// Only differs for legacy non-UTF-8 ZIP entries (see `LegacyZipName`).
    private func enginePaths(for displayPaths: [String]) -> [String] {
        displayPaths.map { path in entries.first(where: { $0.path == path })?.enginePath ?? path }
    }

    /// Renames extracted files whose engine-visible names were recovered from
    /// legacy encodings, deepest paths first so children move before parents.
    private func restoreRecoveredNames(in directory: URL, map: [String: String]) {
        guard !map.isEmpty else { return }
        let sorted = map.sorted { $0.key.split(separator: "/").count > $1.key.split(separator: "/").count }
        for (engineRel, displayRel) in sorted {
            let source = directory.appendingPathComponent(engineRel)
            let target = directory.appendingPathComponent(displayRel)
            guard FileManager.default.fileExists(atPath: source.path),
                  !FileManager.default.fileExists(atPath: target.path) else { continue }
            try? FileManager.default.createDirectory(at: target.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            try? FileManager.default.moveItem(at: source, to: target)
        }
        // Best-effort cleanup of legacy-named directories left empty by the moves.
        guard let iterator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isDirectoryKey],
                                                    options: [.skipsHiddenFiles]) else { return }
        var folders: [URL] = []
        while let url = iterator.nextObject() as? URL {
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { folders.append(url) }
        }
        for folder in folders.sorted(by: { $0.path.count > $1.path.count }) {
            if (try? FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty) == true {
                try? FileManager.default.removeItem(at: folder)
            }
        }
    }

    /// 「消除根目录重复」：解压到「名称/」后，若归档自身还包着一层同名根目录
    /// （得到 名称/名称/…），把内层内容上移并移除空壳。仅在目标目录下仅此一个
    /// 同名文件夹时触发，避免误伤正常内容。
    private func eliminateDuplicateRoot(in directory: URL, rootName: String) {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(atPath: directory.path),
              contents == [rootName] else { return }
        let root = directory.appendingPathComponent(rootName, isDirectory: true)
        guard let children = try? fm.contentsOfDirectory(atPath: root.path) else { return }
        for child in children {
            try? fm.moveItem(at: root.appendingPathComponent(child),
                             to: directory.appendingPathComponent(child))
        }
        try? fm.removeItem(at: root)
    }

    private func enqueue(_ invocation: ArchiveInvocation, completion: Completion) {
        pending.append(Job(invocation: invocation, completion: completion))
        queueCount = pending.count
        if !busy { launchNext() }
    }

    private func launchNext() {
        guard !busy, !pending.isEmpty else { return }
        let job = pending.removeFirst()
        queueCount = pending.count

        guard let resourceRoot = Bundle.main.resourceURL else { report("应用资源目录不存在。") ; return }
        let binary = resourceRoot.appendingPathComponent("bin/7zz")
        guard FileManager.default.isExecutableFile(atPath: binary.path) else {
            report("找不到内置 7zz，请在 Mac 上运行 scripts/build-macos.sh。")
            return
        }

        var environment = ProcessInfo.processInfo.environment
        environment["LC_ALL"] = "C"

        let spawned: SpawnedProcess
        do {
            spawned = try SpawnedProcess.launch(executable: binary,
                                                arguments: job.invocation.arguments,
                                                directory: job.invocation.directory,
                                                environment: environment)
        } catch {
            busy = false
            report("启动 7zz 失败：\(error.localizedDescription)")
            launchNext()
            return
        }

        busy = true
        progress = nil
        progressFragment = ""
        let runID = UUID()
        activeRunID = runID
        status = "执行中：\(job.invocation.arguments.first ?? "")（队列 \(queueCount)）"
        output = "正在运行官方 7zz 引擎…"
        runningPID = spawned.pid

        // Passwords travel over an anonymous stdin pipe, never argv, logs or env.
        // Sending a blank line makes encrypted archives fail instead of hanging.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            spawned.stdinWrite.write(Data(((job.invocation.password ?? "") + "\n").utf8))
            spawned.stdinWrite.closeFile()
            var captured = Data()
            let maximumBytes = 64 * 1024 * 1024
            var truncated = false
            while true {
                let chunk = spawned.stdoutRead.availableData
                if chunk.isEmpty { break }
                let remaining = max(0, maximumBytes - captured.count)
                if chunk.count > remaining { truncated = true }
                if remaining > 0 { captured.append(contentsOf: chunk.prefix(remaining)) }
                let fragment = String(decoding: chunk, as: UTF8.self)
                Task { @MainActor [weak self] in self?.consumeProgress(fragment, runID: runID) }
            }
            let code = spawned.waitForExit()
            let text = String(decoding: captured, as: UTF8.self)
            Task { @MainActor [weak self] in
                self?.complete(job, code: code, text: text, truncated: truncated, runID: runID)
            }
        }
    }

    private func consumeProgress(_ fragment: String, runID: UUID) {
        guard activeRunID == runID else { return }
        progressFragment = String((progressFragment + fragment).suffix(500))
        guard let expression = try? NSRegularExpression(pattern: #"(\d{1,3})%"#) else { return }
        let range = NSRange(progressFragment.startIndex..<progressFragment.endIndex, in: progressFragment)
        guard let match = expression.matches(in: progressFragment, range: range).last else { return }
        let digits = (progressFragment as NSString).substring(with: match.range(at: 1))
        if let value = Double(digits), value <= 100 { progress = value / 100 }
    }

    private func complete(_ job: Job, code: Int32, text: String, truncated: Bool, runID: UUID) {
        guard activeRunID == runID else { return }
        activeRunID = nil
        busy = false
        runningPID = nil
        progress = nil
        output = String(text.suffix(60_000))
        guard code == 0 else {
            switch job.completion {
            case .conversionExtracted(let staging, _, _, _), .converted(_, let staging):
                try? FileManager.default.removeItem(at: staging)
            default: break
            }
            // Encrypted archives fail listing with a password error: ask instead of erroring.
            if case .listing(let archive) = job.completion,
               text.localizedCaseInsensitiveContains("password") {
                passwordNeededFor = archive
                status = "需要密码：\(archive.lastPathComponent)"
                launchNext()
                return
            }
            let details = text.split(separator: "\n").suffix(8).joined(separator: "\n")
            report("操作失败（退出码 \(code)）：\n\(details)")
            launchNext()
            return
        }
        switch job.completion {
        case .listing(let archive):
            guard !truncated else { report("归档清单超过 64 MiB 限制，请使用 CLI 处理。") ; return }
            var parsed = ArchiveListing.parse(text)
            if archive.pathExtension.lowercased() == "zip" {
                parsed = ArchiveListing.recoveringLegacyZipNames(parsed)
            }
            entries = parsed
            listingComplete = true
            status = "\(archive.lastPathComponent)：\(entries.count) 项"
        case .createdForEmail(let archive):
            // 不打开归档，仅通知界面发起邮件分享（Finder「压缩并邮件」）。
            emailShareURL = archive
            status = "已创建 \(archive.lastPathComponent)，正在调出邮件…"
        case .createdSilent(let archive):
            // 独立对话框场景：只报状态，不载入归档（对话框据此自动关窗）。
            status = "已创建 \(archive.lastPathComponent)"
        case .created(let archive):
            status = "已创建 \(archive.lastPathComponent)"
            let firstVolume = archive.appendingPathExtension("001")
            if FileManager.default.fileExists(atPath: archive.path) {
                open(archive)
            } else if FileManager.default.fileExists(atPath: firstVolume.path) {
                open(firstVolume)
            }
        case .batchCreated(let archive):
            status = "批量归档已创建：\(archive.lastPathComponent)"
        case .extracted(let completion):
            restoreRecoveredNames(in: completion.destination, map: completion.restoreMap)
            if let root = completion.eliminateRoot {
                eliminateDuplicateRoot(in: completion.destination, rootName: root)
            }
            status = "已解压到 \(completion.destination.path)"
        case .batchPreflight(let archive, let target, let conflict, let password, let pathMode):
            guard !truncated else { report("批量解压安全检查中止：清单被截断。") ; return }
            var paths = ArchiveListing.parse(text)
            if archive.pathExtension.lowercased() == "zip" {
                paths = ArchiveListing.recoveringLegacyZipNames(paths)
            }
            guard paths.allSatisfy({ ArchivePath.isSafe($0.path) }) else {
                report("批量任务中止：\(archive.lastPathComponent) 包含不安全路径。")
                pending.removeAll()
                queueCount = 0
                return
            }
            do {
                let command = try ArchiveCommands.extract(archive, to: target,
                                                          conflict: conflict, password: password,
                                                          pathMode: pathMode)
                let map = ArchiveListing.legacyNameRestoreMap(paths, flat: pathMode == .flat)
                enqueue(command, completion: .extracted(ExtractCompletion(destination: target, restoreMap: map)))
            } catch { report(error.localizedDescription) }
        case .preview(let folder, let displayPath, let restoreMap):
            restoreRecoveredNames(in: folder, map: restoreMap)
            let resolved = folder.appendingPathComponent(displayPath).resolvingSymlinksInPath().standardizedFileURL
            let root = folder.resolvingSymlinksInPath().standardizedFileURL.path + "/"
            guard resolved.path.hasPrefix(root),
                  FileManager.default.isReadableFile(atPath: resolved.path) else {
                report("预览文件无效，或包含指向目标目录以外的链接。")
                launchNext()
                return
            }
            previewURL = resolved
            status = "已准备预览：\(displayPath.components(separatedBy: "/").last ?? displayPath)"
            if previewFolders.count > 3 {
                let old = previewFolders.removeFirst()
                try? FileManager.default.removeItem(at: old)
            }
        case .nested(let folder, let displayPath, let restoreMap):
            restoreRecoveredNames(in: folder, map: restoreMap)
            let resolved = folder.appendingPathComponent(displayPath).resolvingSymlinksInPath().standardizedFileURL
            let root = folder.resolvingSymlinksInPath().standardizedFileURL.path + "/"
            guard resolved.path.hasPrefix(root),
                  FileManager.default.isReadableFile(atPath: resolved.path) else {
                report("嵌套归档文件无效，或包含指向目标目录以外的链接。")
                launchNext()
                return
            }
            nestedArchiveURL = resolved
            nestedEntryPath = displayPath
            status = "已准备嵌套归档：\(resolved.lastPathComponent)"
        case .conversionExtracted(let staging, let destination, let format, let password):
            guard !containsSymlinks(staging) else {
                report("转换中止：临时解压内容包含符号链接，需在隔离环境中手工处理。")
                try? FileManager.default.removeItem(at: staging)
                launchNext()
                return
            }
            restoreRecoveredNames(in: staging, map: ArchiveListing.legacyNameRestoreMap(entries))
            do {
                let files = try FileManager.default.contentsOfDirectory(at: staging,
                                                                         includingPropertiesForKeys: nil)
                guard !files.isEmpty else {
                    report("空归档的格式转换暂不支持。")
                    try? FileManager.default.removeItem(at: staging)
                    launchNext()
                    return
                }
                var options = CompressionOptions()
                options.format = format
                // Preserve protection when the source required a password.
                options.password = password ?? ""
                let invocation = try ArchiveCommands.create(sources: files, archive: destination, options: options)
                enqueue(invocation, completion: .converted(destination, staging))
            } catch {
                report(error.localizedDescription)
                try? FileManager.default.removeItem(at: staging)
            }
        case .converted(let destination, let staging):
            try? FileManager.default.removeItem(at: staging)
            status = "格式转换完成：\(destination.lastPathComponent)"
        case .tested(let url):
            status = url.map { "完整性校验通过：\($0.lastPathComponent)" } ?? "归档完整性校验通过"
        case .edited(let archive):
            status = "归档已更新"
            open(archive)
        case .hash:
            status = "校验和已计算，详见日志"
        }
        launchNext()
    }

    private func report(_ message: String) {
        status = "操作失败"
        errorMessage = message
        output = message
    }

    private func containsSymlinks(_ folder: URL) -> Bool {
        guard let iterator = FileManager.default.enumerator(at: folder,
                                                            includingPropertiesForKeys: [.isSymbolicLinkKey]) else {
            return true
        }
        while let url = iterator.nextObject() as? URL {
            if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                return true
            }
        }
        return false
    }
}
