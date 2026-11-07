import AppKit
import Combine
import SwiftUI

/// 「工具 → 性能测试」：驱动内置 7zz 的 `b`（Benchmark）命令。
/// 独立于各窗格的 ArchiveModel 任务队列——Benchmark 是全局工具，
/// 与归档浏览互不阻塞；进程输出实时滚动，结束时解析总评分。
@MainActor
final class BenchmarkRunner: ObservableObject {
    @Published private(set) var running = false
    @Published private(set) var output = ""
    @Published private(set) var totalRating = ""
    @Published private(set) var startedAt: Date?

    /// 0 = 引擎自动（全部可用线程）。
    var threads = 0
    var dictionaryMB = 32

    private var pid: pid_t?
    /// 「重新启动」请求标志：stop() 是异步的（要等读循环 EOF + waitForExit 回主线程
    /// finish 才置 running=false），同步连调 stop();start() 会被 guard !running 吞掉。
    private var restartPending = false

    func start() {
        guard !running else { return }
        guard let engine = Bundle.main.resourceURL?.appendingPathComponent("bin/7zz"),
              FileManager.default.isExecutableFile(atPath: engine.path) else {
            output = "找不到内置 7zz 引擎。"
            return
        }
        var args = ["b", "-md\(dictionaryMB)m"]
        if threads > 0 { args.append("-mmt\(threads)") }
        var environment = ProcessInfo.processInfo.environment
        environment["LC_ALL"] = "C"

        let spawned: SpawnedProcess
        do {
            spawned = try SpawnedProcess.launch(executable: engine, arguments: args,
                                                directory: nil, environment: environment)
        } catch {
            output = "启动 7zz 失败：\(error.localizedDescription)"
            return
        }
        running = true
        output = "7zz \(args.joined(separator: " "))\n\n"
        totalRating = ""
        startedAt = Date()
        pid = spawned.pid
        // Benchmark 不读 stdin；写空行后关闭，避免引擎等待输入。
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            try? spawned.stdinWrite.write(contentsOf: Data("\n".utf8))
            try? spawned.stdinWrite.close()
            var captured = Data()
            while true {
                let chunk = spawned.stdoutRead.availableData
                if chunk.isEmpty { break }
                captured.append(chunk)
                let text = String(decoding: chunk, as: UTF8.self)
                Task { @MainActor [weak self] in self?.append(text) }
            }
            let code = spawned.waitForExit()
            let full = String(decoding: captured, as: UTF8.self)
            Task { @MainActor [weak self] in self?.finish(code: code, text: full) }
        }
    }

    func stop() {
        if let pid { kill(pid, SIGTERM) }
    }

    /// 停止当前运行并在其结束后自动重启（供「重新启动」按钮）。
    func restart() {
        if running {
            restartPending = true
            stop()
        } else {
            start()
        }
    }

    private func append(_ text: String) {
        guard running else { return }
        output = String((output + text).suffix(120_000))
    }

    private func finish(code: Int32, text: String) {
        running = false
        pid = nil
        if let rating = Self.parseTotalRating(text) {
            totalRating = rating
        } else if code != 0 {
            totalRating = ""
        }
        if restartPending {
            restartPending = false
            start()
        }
    }

    /// 7zz 输出的总评行形如 `Tot:      385%  26.793 GIPS`，取最后一条。
    static func parseTotalRating(_ text: String) -> String? {
        text.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { $0.hasPrefix("Tot:") }
            .map { String($0.dropFirst(4)).trimmingCharacters(in: .whitespaces) }
    }

    var elapsedText: String {
        guard let startedAt else { return "" }
        return String(format: "%.1f s", Date().timeIntervalSince(startedAt))
    }
}

struct BenchmarkView: View {
    @StateObject private var runner = BenchmarkRunner()
    /// 定时刷新已用时间显示。
    @State private var tick = Date()
    private let timer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 16) {
                Picker("字典大小", selection: $runner.dictionaryMB) {
                    ForEach([8, 16, 32, 64, 128], id: \.self) { Text("\($0) MB").tag($0) }
                }
                .frame(width: 160)
                Picker("CPU 线程", selection: $runner.threads) {
                    Text("自动").tag(0)
                    ForEach(1...ProcessInfo.processInfo.processorCount, id: \.self) { Text("\($0)").tag($0) }
                }
                .frame(width: 140)
                Spacer()
                if runner.running {
                    Text("已用 \(runner.elapsedText)")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .disabled(runner.running)

            ScrollViewReader { proxy in
                ScrollView {
                    Text(runner.output)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .id("log")
                }
                .background(Color(nsColor: .textBackgroundColor))
                .onChange(of: runner.output) { _ in
                    withAnimation(.linear(duration: 0.05)) { proxy.scrollTo("log", anchor: .bottom) }
                }
            }
            .frame(minHeight: 320)

            HStack {
                if !runner.totalRating.isEmpty {
                    Label("总评：\(runner.totalRating)", systemImage: "gauge.with.needle")
                        .font(.headline)
                }
                Spacer()
                if runner.running {
                    Button("停止") { runner.stop() }
                    Button("重新启动") { runner.restart() }
                } else {
                    Button("开始") { runner.start() }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(16)
        .frame(minWidth: 720, minHeight: 480)
        .onReceive(timer) { tick = $0 }
        .onDisappear { runner.stop() }
    }
}

/// Benchmark 是应用级工具而非某个窗格的状态，用独立窗口承载
/// （WindowGroup 场景下新 Scene 会扰乱 .onOpenURL 的焦点路由，故走 AppKit 窗口）。
@MainActor
final class BenchmarkWindowController {
    static let shared = BenchmarkWindowController()
    private var window: NSWindow?

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 540),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = "性能测试 Benchmark"
        window.contentView = NSHostingView(rootView: BenchmarkView())
        window.center()
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
    }
}
