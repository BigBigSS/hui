import AppKit
import Foundation

@MainActor
protocol ClipboardPasteboard: AnyObject {
    var changeCount: Int { get }

    func clearContents()
    func setString(_ value: String, forType type: NSPasteboard.PasteboardType) -> Bool
    func setData(_ data: Data, forType type: NSPasteboard.PasteboardType) -> Bool
    func writeFileURL(_ url: URL) -> Bool
    func containsType(_ type: NSPasteboard.PasteboardType) -> Bool
    func string(forType type: NSPasteboard.PasteboardType) -> String?
    func data(forType type: NSPasteboard.PasteboardType) -> Data?
    func readFileURLs() -> [URL]
}

@MainActor
final class SystemClipboardPasteboard: ClipboardPasteboard {
    static let general = SystemClipboardPasteboard(pasteboard: .general)

    private let pasteboard: NSPasteboard

    init(pasteboard: NSPasteboard) {
        self.pasteboard = pasteboard
    }

    var changeCount: Int {
        pasteboard.changeCount
    }

    func clearContents() {
        pasteboard.clearContents()
    }

    func setString(_ value: String, forType type: NSPasteboard.PasteboardType) -> Bool {
        pasteboard.setString(value, forType: type)
    }

    func setData(_ data: Data, forType type: NSPasteboard.PasteboardType) -> Bool {
        pasteboard.setData(data, forType: type)
    }

    func writeFileURL(_ url: URL) -> Bool {
        pasteboard.writeObjects([url as NSURL])
    }

    func containsType(_ type: NSPasteboard.PasteboardType) -> Bool {
        pasteboard.availableType(from: [type]) != nil
    }

    func string(forType type: NSPasteboard.PasteboardType) -> String? {
        pasteboard.string(forType: type)
    }

    func data(forType type: NSPasteboard.PasteboardType) -> Data? {
        pasteboard.data(forType: type)
    }

    func readFileURLs() -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true
        ]

        return pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: options
        ) as? [URL] ?? []
    }
}
