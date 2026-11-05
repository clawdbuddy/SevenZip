// Optional P2 Finder Sync extension source template.
// IMPORTANT: Not built by SwiftPM. Add an Xcode Finder Sync Extension target,
// set its extension point identifier, configure signing/App Group, then test.
import AppKit
import FinderSync

final class ArchiveFinderSync: FIFinderSync {
    override init() {
        super.init()
        // Narrow this URL set for production. Broad monitoring should not be
        // enabled without user awareness and real Finder performance testing.
        FIFinderSyncController.default().directoryURLs = []
    }

    override func menu(for menuKind: FIMenuKind) -> NSMenu {
        let menu = NSMenu(title: "SevenZip")
        let item = NSMenuItem(title: "使用 SevenZip 打开", action: #selector(openSelected), keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        return menu
    }

    @objc private func openSelected() {
        guard let urls = FIFinderSyncController.default().selectedItemURLs(),
              let first = urls.first else { return }
        // The Finder extension lives in Contents/PlugIns/*.appex. Resolve
        // the parent app without hard-coding /Applications (development runs).
        let app = Bundle.main.bundleURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        NSWorkspace.shared.open([first], withApplicationAt: app,
                                configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
    }
}
