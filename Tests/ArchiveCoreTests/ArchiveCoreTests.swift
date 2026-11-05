import ArchiveCore
import Foundation
import XCTest

final class ArchiveCoreTests: XCTestCase {
    func testListingParser() {
        let sample = """
        7-Zip 26.05
        Path = example.7z
        Type = 7z
        ----------
        Path = folder
        Size = 0
        Folder = +

        Path = folder/你好.txt
        Size = 123
        Modified = 2026-11-05 10:00:00
        Folder = -

        """
        let entries = ArchiveListing.parse(sample)
        XCTAssertEqual(entries.count, 2)
        XCTAssertTrue(entries[0].isDirectory)
        XCTAssertEqual(entries[1].path, "folder/你好.txt")
        XCTAssertEqual(entries[1].size, 123)
    }

    func testRejectsUnsafePaths() {
        XCTAssertFalse(ArchivePath.isSafe("../etc/passwd"))
        XCTAssertFalse(ArchivePath.isSafe("abc/../../secret"))
        XCTAssertFalse(ArchivePath.isSafe("/etc/passwd"))
        XCTAssertFalse(ArchivePath.isSafe("C:\\Windows\\system32"))
        XCTAssertFalse(ArchivePath.isSafe("bad\nname"))
        XCTAssertTrue(ArchivePath.isSafe("dir/中文文件.txt"))
    }

    func testNoPasswordInCommandArguments() throws {
        let source = URL(fileURLWithPath: "/tmp/archive-fixtures/source.txt")
        let destination = URL(fileURLWithPath: "/tmp/archive-fixtures/output.7z")
        var options = CompressionOptions()
        options.password = "TOP_SECRET_IN_MEMORY_ONLY"
        options.encryptFileNames = true
        let invocation = try ArchiveCommands.create(sources: [source], archive: destination, options: options)
        XCTAssertEqual(invocation.password, options.password)
        XCTAssertTrue(invocation.arguments.contains("-p"))
        XCTAssertTrue(invocation.arguments.contains("-mhe=on"))
        XCTAssertFalse(invocation.arguments.joined().contains(options.password))
    }

    func testSelectedExtractionUsesLiteralPaths() throws {
        let invocation = try ArchiveCommands.extract(URL(fileURLWithPath: "/tmp/a.7z"),
                                                     to: URL(fileURLWithPath: "/tmp/out"),
                                                     paths: ["dir/-example.txt"])
        XCTAssertTrue(invocation.arguments.contains("-spd"))
        XCTAssertTrue(invocation.arguments.contains("--"))
        XCTAssertEqual(invocation.arguments.last, "dir/-example.txt")
        XCTAssertThrowsError(try ArchiveCommands.extract(URL(fileURLWithPath: "/tmp/a.7z"),
                                                         to: URL(fileURLWithPath: "/tmp/out"),
                                                         paths: ["../../outside"]))
    }
}

extension ArchiveCoreTests {
    /// GBK 字节经 7-Zip 的 PUA 映射后，应还原为原始中文名。
    func testLegacyZipNameRecoveryGBK() {
        // "中文文件.txt" 的 GBK 字节流：D6D0 CEC4 CEC4 BCFE。
        // 引擎行为：恰好构成合法 UTF-8 的字节对原样透传（CE C4 → Ą，出现两次），
        // 其余非 ASCII 字节映射到 U+EF00+byte（D6、D0、BC、FE）。
        let engineName = "\u{EFD6}\u{EFD0}ĄĄ\u{EFBC}\u{FEFE}.txt"
        XCTAssertEqual(LegacyZipName.recover(engineName), "中文文件.txt")
    }

    /// 没有 PUA 字符的正常 UTF-8 名称必须原样返回。
    func testLegacyZipNameRecoveryLeavesUTF8Alone() {
        XCTAssertEqual(LegacyZipName.recover("报告2026.txt"), "报告2026.txt")
        XCTAssertEqual(LegacyZipName.recover("plain.txt"), "plain.txt")
    }

    /// ZIP 清单恢复应同时保留显示名与引擎名。
    func testRecoveringLegacyZipNamesKeepsEnginePath() {
        let mangled = String(Unicode.Scalar(UInt32(0xEFB1))!) + String(Unicode.Scalar(UInt32(0xEFA8))!)
                    + String(Unicode.Scalar(UInt32(0xEFB8))!) + String(Unicode.Scalar(UInt32(0xEFE6))!) + ".txt"
        let entry = ArchiveEntry(path: mangled, size: 1, modified: "", isDirectory: false)
        let recovered = ArchiveListing.recoveringLegacyZipNames([entry])
        XCTAssertEqual(recovered[0].path, "报告.txt")
        XCTAssertEqual(recovered[0].enginePath, mangled)
        XCTAssertEqual(ArchiveListing.legacyNameRestoreMap(recovered), [mangled: "报告.txt"])
    }
}
