import AppKit
import Foundation
import UniformTypeIdentifiers

@MainActor
final class ClipboardMonitor: NSObject {
    private let store: ClipboardHistoryStore
    private let pasteboard: ClipboardPasteboard
    private var timer: Timer?
    private var lastChangeCount: Int

    init(
        store: ClipboardHistoryStore,
        pasteboard: ClipboardPasteboard = SystemClipboardPasteboard.general
    ) {
        self.store = store
        self.pasteboard = pasteboard
        lastChangeCount = pasteboard.changeCount
    }

    func start() {
        stop()
        timer = Timer.scheduledTimer(
            timeInterval: 0.5,
            target: self,
            selector: #selector(checkClipboard),
            userInfo: nil,
            repeats: true
        )
        timer?.tolerance = 0.08
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    @objc func checkClipboard() {
        guard pasteboard.changeCount != lastChangeCount else { return }

        lastChangeCount = pasteboard.changeCount

        if pasteboard.containsType(ClipboardHistoryStore.internalPasteboardWriteType) {
            return
        }

        if let visualContent = readVisualContent() {
            store.addImage(
                visualContent.data,
                kind: visualContent.kind,
                fileExtension: visualContent.fileExtension,
                pasteboardType: visualContent.pasteboardType
            )
            return
        }

        let fileURLs = readFileURLs()
        if !fileURLs.isEmpty {
            store.addFiles(fileURLs)
            return
        }

        guard let text = pasteboard.string(forType: .string) else { return }
        store.addText(text)
    }

    private func readFileURLs() -> [URL] {
        pasteboard.readFileURLs()
    }

    private func readVisualContent() -> VisualClipboardContent? {
        for candidate in Self.visualPasteboardTypes {
            if let data = pasteboard.data(forType: candidate.type) {
                return VisualClipboardContent(
                    data: data,
                    kind: candidate.kind,
                    fileExtension: candidate.fileExtension,
                    pasteboardType: candidate.pasteboardType
                )
            }
        }

        guard
            let tiffData = pasteboard.data(forType: NSPasteboard.PasteboardType(UTType.tiff.identifier)),
            let image = NSImage(data: tiffData),
            let pngData = image.pngData()
        else {
            return nil
        }

        return VisualClipboardContent(
            data: pngData,
            kind: .image,
            fileExtension: "png",
            pasteboardType: UTType.png.identifier
        )
    }

    private struct VisualClipboardContent {
        let data: Data
        let kind: ClipboardHistoryItem.Kind
        let fileExtension: String
        let pasteboardType: String
    }

    private struct VisualPasteboardCandidate {
        let type: NSPasteboard.PasteboardType
        let kind: ClipboardHistoryItem.Kind
        let fileExtension: String
        let pasteboardType: String
    }

    private static let visualPasteboardTypes: [VisualPasteboardCandidate] = [
        VisualPasteboardCandidate(
            type: NSPasteboard.PasteboardType(UTType.gif.identifier),
            kind: .gif,
            fileExtension: "gif",
            pasteboardType: UTType.gif.identifier
        ),
        VisualPasteboardCandidate(
            type: NSPasteboard.PasteboardType(UTType.png.identifier),
            kind: .image,
            fileExtension: "png",
            pasteboardType: UTType.png.identifier
        ),
        VisualPasteboardCandidate(
            type: NSPasteboard.PasteboardType(UTType.jpeg.identifier),
            kind: .image,
            fileExtension: "jpg",
            pasteboardType: UTType.jpeg.identifier
        )
    ]
}

private extension NSImage {
    func pngData() -> Data? {
        guard
            let tiffRepresentation,
            let bitmap = NSBitmapImageRep(data: tiffRepresentation)
        else {
            return nil
        }

        return bitmap.representation(using: .png, properties: [:])
    }
}
