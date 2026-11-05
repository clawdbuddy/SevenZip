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
        // "中文文件.txt" 的 GBK 字节，其中 C4 BC 恰好是合法 UTF-8（ļ），按引擎行为原样保留
        let gbkBytes: [UInt8] = [0xD6, 0xD0, 0xCE, 0xC4, 0xC4, 0xBC, 0xFE, 0x2E, 0x74, 0x78, 0x74]
        var engineName = ""
        var index = 0
        while index < gbkBytes.count {
            let byte = gbkBytes[index]
            if byte == 0xC4, index + 1 < gbkBytes.count, gbkBytes[index + 1] == 0xBC {
                engineName.append("ļ") // 引擎会把合法 UTF-8 序列直接透传
                index += 2
            } else if byte < 0x80 {
                engineName.append(Character(Unicode.Scalar(byte)))
                index += 1
            } else {
                engineName.append(Character(Unicode.Scalar(0xEF00 + UInt32(byte))!))
                index += 1
            }
        }
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
