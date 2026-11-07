import AppKit
import UniformTypeIdentifiers

/// 文件列表图标（macOS 风格）。
///
/// 为什么不用「SF Symbol + 颜色 tint」那一套：那不是访达的样子——访达的
/// 文件夹与压缩包用的是系统真实图标（蓝色渐层文件夹、纸箱式压缩包图标），
/// 符号加棕色 tint 会显得很「非 macOS」。这里的规则：
/// - 文件夹：系统真实文件夹图标；
/// - 压缩包：按扩展名取该格式的系统图标（7z/rar/tar 各有自己的徽标），
///   认不出才用通用归档箱；
/// - 普通文件：按扩展名取系统真实文档图标（访达同款），认不出时才用符号；
/// - 「..」：次级文字色的符号。
enum FileIcons {
    /// 图标 + 可选着色（系统真实图标自带颜色，无需着色）。
    struct Icon {
        let image: NSImage
        let tint: NSColor?
    }

    /// 系统图标获取有开销（磁盘读取），缓存复用。
    private static var cache: [String: NSImage] = [:]

    static func icon(for row: FileListRow) -> Icon {
        switch row.kind {
        case .up:
            return Icon(image: symbol("arrow.turn.left.up"), tint: .secondaryLabelColor)
        case .folder:
            return Icon(image: folderIcon(), tint: nil)
        case .file:
            if row.isArchiveFile { return archiveIcon(row) }
            return fileIcon(row)
        }
    }

    /// 普通文件：按扩展名取系统真实文档图标（访达同款）；
    /// 认不出的类型退回次级文字色的文档符号。
    private static func fileIcon(_ row: FileListRow) -> Icon {
        let ext = (row.name as NSString).pathExtension.lowercased()
        guard !ext.isEmpty, let type = UTType(filenameExtension: ext), type != .data else {
            return Icon(image: symbol("doc"), tint: .secondaryLabelColor)
        }
        return Icon(image: systemIcon(type), tint: nil)
    }

    /// 压缩包图标：按扩展名取该格式的系统图标。
    ///
    /// macOS 为 7z/rar/tar 等格式注册了各自的 UTI 与图标（7Z 徽标、TAR 徽标），
    /// 按扩展名查就能拿到对应的品牌化图标；查不到才退回通用的归档箱图标。
    ///
    /// 不用 SF Symbol 的 archivebox：那是空心描边图形，和系统实心归档箱
    /// 并排放会显得不是一套。
    private static func archiveIcon(_ row: FileListRow) -> Icon {
        let ext = (row.name as NSString).pathExtension.lowercased()
        if !ext.isEmpty, let type = UTType(filenameExtension: ext), type != .data {
            let image = systemIcon(type)
            // 通用归档类型（.archive/.data）没有专属图标，退回归档箱。
            if type.conforms(to: .archive), type != .archive { return Icon(image: image, tint: nil) }
        }
        return Icon(image: systemIcon(.archive), tint: nil)
    }

    /// 文件夹：系统真实文件夹图标（访达的蓝色渐层文件夹）。
    private static func folderIcon() -> NSImage {
        systemIcon(.folder)
    }

    /// 系统真实图标（带缓存）。
    private static func systemIcon(_ type: UTType) -> NSImage {
        let key = type.identifier
        if let cached = cache[key] { return cached }
        let image = NSWorkspace.shared.icon(for: type)
        cache[key] = image
        return image
    }

    /// 系统符号图标（模板图，由调用方着色）。
    private static func symbol(_ name: String) -> NSImage {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil) ?? NSImage()
        image.isTemplate = true
        return image
    }
}
