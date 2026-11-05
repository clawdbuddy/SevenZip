import AppKit

// Generates Resources/AppIcon.icns: macOS-style rounded rectangle with a
// zipper-document glyph. Run: swiftc make-icon.swift -o make-icon && ./make-icon
// Icon geometry follows the macOS "Big Sur" grid: ~824/1024 content area.

let sizes: [(String, Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]

let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)

func drawIcon(pixelSize: Int) -> NSImage {
    let side = CGFloat(pixelSize)
    let image = NSImage(size: NSSize(width: side, height: side))
    image.lockFocus()
    defer { image.unlockFocus() }
    guard let context = NSGraphicsContext.current?.cgContext else { return image }

    // Content area: 824/1024 of the canvas, centered.
    let inset = side * 100.0 / 1024.0
    let bodyRect = CGRect(x: inset, y: inset, width: side - 2 * inset, height: side - 2 * inset)
    let radius = bodyRect.width * 0.2237

    // Background: deep blue gradient, top lighter.
    let path = CGPath(roundedRect: bodyRect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    context.saveGState()
    context.addPath(path)
    context.clip()
    let colors = [CGColor(red: 0.20, green: 0.45, blue: 0.90, alpha: 1),
                  CGColor(red: 0.08, green: 0.28, blue: 0.68, alpha: 1)] as CFArray
    if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                 colors: colors, locations: [0, 1]) {
        context.drawLinearGradient(gradient,
                                   start: CGPoint(x: bodyRect.midX, y: bodyRect.maxY),
                                   end: CGPoint(x: bodyRect.midX, y: bodyRect.minY),
                                   options: [])
    }
    context.restoreGState()

    // Glyph: white zipper document, ~52% of the body, optically centered.
    let glyphName = pixelSize >= 64 ? "doc.zipper" : "archivebox.fill"
    if let symbol = NSImage(systemSymbolName: glyphName, accessibilityDescription: nil) {
        let config = NSImage.SymbolConfiguration(pointSize: bodyRect.width * 0.52,
                                                 weight: .medium)
        let glyph = symbol.withSymbolConfiguration(config) ?? symbol
        let glyphSize = glyph.size
        // Symbol images ignore the current fill color; tint via sourceAtop.
        let tinted = NSImage(size: glyphSize)
        tinted.lockFocus()
        glyph.draw(in: CGRect(origin: .zero, size: glyphSize),
                   from: .zero, operation: .sourceOver, fraction: 1)
        NSColor.white.set()
        CGRect(origin: .zero, size: glyphSize).fill(using: .sourceAtop)
        tinted.unlockFocus()
        let glyphRect = CGRect(x: bodyRect.midX - glyphSize.width / 2,
                               y: bodyRect.midY - glyphSize.height / 2,
                               width: glyphSize.width, height: glyphSize.height)
        tinted.draw(in: glyphRect, from: .zero, operation: .sourceOver, fraction: 1)
    }
    return image
}

for (name, pixels) in sizes {
    let image = drawIcon(pixelSize: pixels)
    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else {
        FileHandle.standardError.write("生成失败: \(name)\n".data(using: .utf8)!)
        continue
    }
    try png.write(to: URL(fileURLWithPath: output).appendingPathComponent(name))
}
print("iconset 已生成: \(output)")
