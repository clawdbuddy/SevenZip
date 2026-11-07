import Foundation

/// posix_spawn-based process runner. Foundation's `Process` encodes argv via
/// `fileSystemRepresentation`, which normalizes Unicode to NFD — that silently
/// corrupts the engine-visible names of legacy-encoded ZIP entries (their
/// archived bytes may passthrough as precomposed characters such as ļ, and
/// 7-Zip matches names byte-exactly). Spawning directly preserves the exact
/// UTF-8 bytes of every argument.
struct SpawnedProcess {
    enum SpawnError: LocalizedError {
        case pipeFailed
        case setupFailed
        case spawnFailed(Int32)

        var errorDescription: String? {
            switch self {
            case .pipeFailed: return "创建进程管道失败。"
            case .setupFailed: return "初始化进程启动参数失败（内存不足）。"
            case .spawnFailed(let code): return "posix_spawn 失败（错误码 \(code)）。"
            }
        }
    }

    let pid: pid_t
    let stdoutRead: FileHandle
    let stdinWrite: FileHandle

    static func launch(executable: URL, arguments: [String], directory: URL?,
                       environment: [String: String]) throws -> SpawnedProcess {
        var outPipe: [Int32] = [-1, -1]
        var inPipe: [Int32] = [-1, -1]
        guard pipe(&outPipe) == 0 else { throw SpawnError.pipeFailed }
        // 第二根 pipe 失败时必须关掉已打开的 fds，否则泄漏。
        guard pipe(&inPipe) == 0 else {
            close(outPipe[0])
            close(outPipe[1])
            throw SpawnError.pipeFailed
        }

        var actions: posix_spawn_file_actions_t? = nil
        // 失败清理的公共路径：销毁 actions、关闭全部已开 fd（不重复 spawnFailed 分支的关闭逻辑）。
        let closeAllFds = {
            close(outPipe[0]); close(outPipe[1])
            close(inPipe[0]); close(inPipe[1])
        }
        // OOM 等极端场景下 file_actions 系列调用会返回非 0：必须检查并走清理路径，
        // 否则子进程 fd 重定向残缺，行为不可预期。
        guard posix_spawn_file_actions_init(&actions) == 0 else {
            closeAllFds()
            throw SpawnError.setupFailed
        }
        defer { posix_spawn_file_actions_destroy(&actions) }
        var actionsOK = posix_spawn_file_actions_adddup2(&actions, outPipe[1], STDOUT_FILENO) == 0
        actionsOK = actionsOK && posix_spawn_file_actions_adddup2(&actions, outPipe[1], STDERR_FILENO) == 0
        actionsOK = actionsOK && posix_spawn_file_actions_adddup2(&actions, inPipe[0], STDIN_FILENO) == 0
        actionsOK = actionsOK && posix_spawn_file_actions_addclose(&actions, outPipe[0]) == 0
        actionsOK = actionsOK && posix_spawn_file_actions_addclose(&actions, inPipe[1]) == 0
        if let directory {
            actionsOK = actionsOK && posix_spawn_file_actions_addchdir_np(&actions, directory.path) == 0
        }
        guard actionsOK else {
            closeAllFds()
            throw SpawnError.setupFailed
        }

        // strdup(String) encodes as UTF-8 without any Unicode normalization.
        var argv: [UnsafeMutablePointer<CChar>?] = ([executable.path] + arguments).map { strdup($0) }
        var envp: [UnsafeMutablePointer<CChar>?] = environment.map { strdup("\($0.key)=\($0.value)") }
        // strdup 失败（OOM）返回 nil：nil 混入 argv/envp 会被当作数组结尾，
        // 静默截断参数，必须释放已分配内存后抛错。
        guard !argv.contains(nil), !envp.contains(nil) else {
            for pointer in argv + envp { free(pointer) }   // free(nil) 安全
            closeAllFds()
            throw SpawnError.setupFailed
        }
        argv.append(nil)
        envp.append(nil)
        defer {
            for pointer in argv + envp { free(pointer) }
        }

        var pid = pid_t()
        let status = posix_spawn(&pid, executable.path, &actions, nil, &argv, &envp)
        // Parent closes the child's ends either way.
        close(outPipe[1])
        close(inPipe[0])
        guard status == 0 else {
            close(outPipe[0])
            close(inPipe[1])
            throw SpawnError.spawnFailed(status)
        }
        return SpawnedProcess(pid: pid,
                              stdoutRead: FileHandle(fileDescriptor: outPipe[0], closeOnDealloc: true),
                              stdinWrite: FileHandle(fileDescriptor: inPipe[1], closeOnDealloc: true))
    }

    /// Blocks until the child exits and returns its exit code (128 + signal on
    /// termination by signal, mirroring shell conventions).
    func waitForExit() -> Int32 {
        var status: Int32 = 0
        while waitpid(pid, &status, 0) == -1 {
            if errno != EINTR { return -1 }
        }
        if (status & 0x7F) == 0 { return (status >> 8) & 0xFF }   // WIFEXITED / WEXITSTATUS
        return 128 + (status & 0x7F)                              // killed by signal
    }
}
