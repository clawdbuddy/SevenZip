import ArchiveCore
import Darwin
import Foundation

/// Headless interface to the same command builder used by the SwiftUI app.
/// Run from Contents/MacOS/SevenZipCLI inside SevenZip.app.
@main
struct SevenZipCLI {
    static func main() {
        do {
            let args = Array(CommandLine.arguments.dropFirst())
            guard let command = args.first else { usage(); exit(2) }
            let others = Array(args.dropFirst())
            let wantsPassword = others.contains("--password-stdin")
            let parameters = others.filter { $0 != "--password-stdin" }
            let password = wantsPassword ? readLine(strippingNewline: true) : nil
            let invocation: ArchiveInvocation

            switch command {
            case "list":
                guard parameters.count == 1 else { usage(); exit(2) }
                invocation = ArchiveCommands.list(URL(fileURLWithPath: parameters[0]), password: password)
            case "test":
                guard parameters.count == 1 else { usage(); exit(2) }
                invocation = ArchiveCommands.test(URL(fileURLWithPath: parameters[0]), password: password)
            case "sha256":
                guard parameters.count == 1 else { usage(); exit(2) }
                invocation = ArchiveInvocation(["h", "-scrcSHA256", URL(fileURLWithPath: parameters[0]).path])
            case "extract":
                guard parameters.count >= 2 else { usage(); exit(2) }
                let archive = URL(fileURLWithPath: parameters[0])
                let destination = URL(fileURLWithPath: parameters[1])
                invocation = try ArchiveCommands.extract(archive, to: destination,
                                                        paths: Array(parameters.dropFirst(2)), password: password)
            case "create":
                guard parameters.count >= 2 else { usage(); exit(2) }
                let archive = URL(fileURLWithPath: parameters[0])
                let sources = parameters.dropFirst().map { URL(fileURLWithPath: $0) }
                var options = CompressionOptions()
                guard let format = ArchiveFormat(rawValue: archive.pathExtension.lowercased()) else {
                    throw ArchiveCommandError.formatMismatch
                }
                options.format = format
                options.password = password ?? ""
                invocation = try ArchiveCommands.create(sources: sources, archive: archive, options: options)
            case "delete":
                guard parameters.count >= 2 else { usage(); exit(2) }
                invocation = try ArchiveCommands.delete(URL(fileURLWithPath: parameters[0]),
                                                        paths: Array(parameters.dropFirst()), password: password)
            case "rename":
                guard parameters.count == 3 else { usage(); exit(2) }
                invocation = try ArchiveCommands.rename(URL(fileURLWithPath: parameters[0]),
                                                        from: parameters[1], to: parameters[2], password: password)
            default:
                usage()
                exit(2)
            }

            let selfPath = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
            let bundleContents = selfPath.deletingLastPathComponent().deletingLastPathComponent()
            let binary = bundleContents.appendingPathComponent("Resources/bin/7zz")
            guard FileManager.default.isExecutableFile(atPath: binary.path) else {
                fputs("找不到捆绑的 7zz 引擎：\(binary.path)\n", stderr)
                exit(1)
            }
            let process = Process()
            process.executableURL = binary
            process.arguments = invocation.arguments
            process.currentDirectoryURL = invocation.directory
            var environment = ProcessInfo.processInfo.environment
            environment["LC_ALL"] = "C"
            process.environment = environment

            if wantsPassword {
                let pipe = Pipe()
                process.standardInput = pipe
                try process.run()
                pipe.fileHandleForWriting.write(Data(((invocation.password ?? "") + "\n").utf8))
                pipe.fileHandleForWriting.closeFile()
            } else {
                try process.run()
            }
            process.waitUntilExit()
            exit(process.terminationStatus == 0 ? 0 : 1)
        } catch {
            fputs("错误：\(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    static func usage() {
        print("""
        SevenZipCLI — 与 GUI 共用 ArchiveCore 命令构造器
        用法：
          SevenZipCLI list ARCHIVE [--password-stdin]
          SevenZipCLI test ARCHIVE [--password-stdin]
          SevenZipCLI sha256 ARCHIVE
          SevenZipCLI extract ARCHIVE DEST [ENTRY ...] [--password-stdin]
          SevenZipCLI create ARCHIVE.7z|ARCHIVE.zip SOURCE... [--password-stdin]
          SevenZipCLI delete ARCHIVE ENTRY... [--password-stdin]
          SevenZipCLI rename ARCHIVE OLD_PATH NEW_PATH [--password-stdin]

        密码由标准输入读取一行，例如：read -s PASSWORD ; printf '%s\\n' "$PASSWORD" | SevenZipCLI test archive.7z --password-stdin
        """)
    }
}
