import AppKit

// Generates Resources/TypeIcons/<Type>Icon.icns: Finder document icons for each
// archive type we claim (referenced by CFBundleTypeIconFile in Info.plist).
// Design: white page with folded corner + colored band carrying the extension,
// echoing 7-Zip's per-format icons. Run:
//   swiftc -O make-type-icons.swift -o make-type-icons
//   ./make-type-icons ../Resources/TypeIcons   # then iconutil is invoked per type

let types: [(file: String, ext: String, color: NSColor)] = [
    ("SevenZipIcon", "7z",  NSColor(red: 0.13, green: 0.42, blue: 0.85, alpha: 1)),
    ("ZipIcon",      "zip", NSColor(red: 0.85, green: 0.60, blue: 0.10, alpha: 1)),
    ("RarIcon",      "rar", NSColor(red: 0.62, green: 0.30, blue: 0.78, alpha: 1)),
    ("TarIcon",      "tar", NSColor(red: 0.60, green: 0.42, blue: 0.25, alpha: 1)),
    ("GzIcon",       "gz",  NSColor(red: 0.20, green: 0.62, blue: 0.35, alpha: 1)),
    ("XzIcon",       "xz",  NSColor(red: 0.10, green: 0.55, blue: 0.60, alpha: 1)),
]

let sizes: [(String, Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]

let outputRoot = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "TypeIcons"

func drawIcon(ext: String, color: NSColor, pixelSize: Int) -> NSImage {
    let side = CGFloat(pixelSize)
    let image = NSImage(size: NSSize(width: side, height: side))
    image.lockFocus()
    defer { image.unlockFocus() }
    guard let context = NSGraphicsContext.current?.cgContext else { return image }

    // Page body: classic document proportions, folded top-right corner.
    let pageW = side * 0.72
    let pageH = side * 0.88
    let pageX = (side - pageW) / 2
    let pageY = (side - pageH) / 2
    let fold = pageW * 0.26
    let page = CGMutablePath()
    page.move(to: CGPoint(x: pageX, y: pageY))
    page.addLine(to: CGPoint(x: pageX, y: pageY + pageH))
    page.addLine(to: CGPoint(x: pageX + pageW - fold, y: pageY + pageH))
    page.addLine(to: CGPoint(x: pageX + pageW, y: pageY + pageH - fold))
    page.addLine(to: CGPoint(x: pageX + pageW, y: pageY))
    page.closeSubpath()

    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -side * 0.008),
                      blur: side * 0.02, color: CGColor(gray: 0, alpha: 0.35))
    context.addPath(page)
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.fillPath()
    context.restoreGState()

    // Fold triangle.
    let flap = CGMutablePath()
    flap.move(to: CGPoint(x: pageX + pageW - fold, y: pageY + pageH))
    flap.addLine(to: CGPoint(x: pageX + pageW - fold, y: pageY + pageH - fold))
    flap.addLine(to: CGPoint(x: pageX + pageW, y: pageY + pageH - fold))
    flap.closeSubpath()
    context.addPath(flap)
    context.setFillColor(CGColor(gray: 0.82, alpha: 1))
    context.fillPath()

    // Colored band with the extension label, bottom third of the page.
    let bandH = pageH * 0.30
    let bandRect = CGRect(x: pageX + pageW * 0.06, y: pageY + pageH * 0.10,
                          width: pageW * 0.88, height: bandH)
    let bandPath = CGPath(roundedRect: bandRect, cornerWidth: bandH * 0.22,
                          cornerHeight: bandH * 0.22, transform: nil)
    context.addPath(bandPath)
    context.setFillColor(color.cgColor)
    context.fillPath()

    let fontSize = bandH * 0.62
    let label = ext.uppercased() as NSString
    let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.boldSystemFont(ofSize: fontSize),
        .foregroundColor: NSColor.white,
    ]
    let labelSize = label.size(withAttributes: attributes)
    // Shrink to fit at small sizes.
    let scale = min(1, (bandRect.width * 0.9) / labelSize.width)
    let scaledAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.boldSystemFont(ofSize: fontSize * scale),
        .foregroundColor: NSColor.white,
    ]
    let scaledSize = label.size(withAttributes: scaledAttributes)
    label.draw(at: NSPoint(x: bandRect.midX - scaledSize.width / 2,
                           y: bandRect.midY - scaledSize.height / 2),
               withAttributes: scaledAttributes)
    return image
}

for type in types {
    let iconset = (outputRoot as NSString).appendingPathComponent("\(type.file).iconset")
    try? FileManager.default.createDirectory(atPath: iconset, withIntermediateDirectories: true)
    for (name, pixels) in sizes {
        let image = drawIcon(ext: type.ext, color: type.color, pixelSize: pixels)
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            FileHandle.standardError.write("生成失败: \(type.file)/\(name)\n".data(using: .utf8)!)
            continue
        }
        try png.write(to: URL(fileURLWithPath: iconset).appendingPathComponent(name))
    }
    // iconutil converts iconset → icns.
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    task.arguments = ["-c", "icns", iconset, "-o",
                      (outputRoot as NSString).appendingPathComponent("\(type.file).icns")]
    try task.run()
    task.waitUntilExit()
    try? FileManager.default.removeItem(atPath: iconset)
    print("\(type.file).icns ✓")
}
print("类型图标已生成: \(outputRoot)")
