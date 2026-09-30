import AppKit
import Combine
import Foundation
import UniformTypeIdentifiers

@MainActor
final class ClipboardHistoryStore: ObservableObject {
    static let internalPasteboardWriteType = NSPasteboard.PasteboardType(
        "com.macliphistory.internal-write"
    )

    @Published private(set) var items: [ClipboardHistoryItem] = []
    @Published private(set) var storageSizeBytes: UInt64 = 0

    private let settings: AppSettings
    private let imageDirectory: URL
    private let storedFileDirectory: URL
    private let fileURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let thumbnailCache = ClipboardThumbnailCache()
    private let storageScanner = ClipboardStorageScanner()
    private var storageRefreshTask: Task<Void, Never>?
    private var storageRefreshGeneration = 0
    private var cancellables = Set<AnyCancellable>()

    init(settings: AppSettings, supportDirectory: URL? = nil) {
        self.settings = settings

#if DEBUG
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
#endif
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601

        let supportDirectory = supportDirectory ?? FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
            .appendingPathComponent("Shiyi", isDirectory: true)

        imageDirectory = supportDirectory.appendingPathComponent("Images", isDirectory: true)
        storedFileDirectory = supportDirectory.appendingPathComponent("Files", isDirectory: true)
        fileURL = supportDirectory.appendingPathComponent("clipboard-history-native.json")
        createSupportDirectoryIfNeeded(at: supportDirectory)
        createSupportDirectoryIfNeeded(at: imageDirectory)
        createSupportDirectoryIfNeeded(at: storedFileDirectory)
        load()
        pruneToMaxItems()
        save()
        refreshStorageSize()
        observeSettings()
    }

    var storageLocation: URL {
        fileURL
    }

    func addText(_ text: String) {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }

        items.removeAll { $0.isText && $0.content == normalized }
        items.insert(ClipboardHistoryItem(content: normalized), at: 0)

        pruneToMaxItems()

        save()
    }

    func addFiles(_ urls: [URL]) {
        for url in urls.reversed() {
            addFile(url, shouldSave: false)
        }

        pruneToMaxItems()
        save()
    }

    func addFile(_ sourceURL: URL) {
        addFile(sourceURL, shouldSave: true)
    }

    func addImage(
        _ data: Data,
        kind: ClipboardHistoryItem.Kind,
        fileExtension: String,
        pasteboardType: String
    ) {
        guard !data.isEmpty, kind.isVisualKind else { return }

        removeDuplicateVisualItems(matching: data, kind: kind)

        let id = UUID()
        let fileName = "\(id.uuidString).\(fileExtension)"
        let fileURL = imageDirectory.appendingPathComponent(fileName, isDirectory: false)

        do {
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            NSLog("Failed to save clipboard image: \(error.localizedDescription)")
            return
        }

        items.insert(
            ClipboardHistoryItem(
                id: id,
                kind: kind,
                content: kind == .gif ? "Animated GIF" : "Image",
                fileName: fileName,
                pasteboardType: pasteboardType
            ),
            at: 0
        )

        pruneToMaxItems()
        save()
    }

    @discardableResult
    func copy(
        _ item: ClipboardHistoryItem,
        to pasteboard: ClipboardPasteboard = SystemClipboardPasteboard.general
    ) -> Bool {
        let didWrite: Bool
        switch item.kind {
        case .text:
            pasteboard.clearContents()
            didWrite = pasteboard.setString(item.content, forType: .string)
        case .image, .gif:
            guard
                let pasteboardType = item.pasteboardType,
                let url = mediaFileURL(for: item),
                let data = try? Data(contentsOf: url)
            else {
                return false
            }

            pasteboard.clearContents()
            didWrite = pasteboard.setData(
                data,
                forType: NSPasteboard.PasteboardType(pasteboardType)
            )
        case .file:
            guard let url = mediaFileURL(for: item) else { return false }
            pasteboard.clearContents()
            didWrite = pasteboard.writeFileURL(url)
        }

        guard didWrite else { return false }
        return pasteboard.setString(
            item.id.uuidString,
            forType: Self.internalPasteboardWriteType
        )
    }

    func delete(_ item: ClipboardHistoryItem) {
        deleteMediaFile(for: item)
        items.removeAll { $0.id == item.id }
        save()
    }

    func clear() {
        items.forEach(deleteMediaFile)
        deleteStoredImageFiles()
        Task { await thumbnailCache.clear() }
        items.removeAll()
        save()
    }

    func revealStorageInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([fileURL])
    }

    func thumbnailImage(for item: ClipboardHistoryItem, pixels: Int, fit: Bool = false) async -> ClipboardThumbnailImage? {
        guard !Task.isCancelled, item.isVisualContent, let url = mediaFileURL(for: item) else { return nil }
        return await thumbnailCache.image(at: url, pixels: pixels, fit: fit)
    }

    func storageSizeDescription() -> String {
        ByteCountFormatter.string(
            fromByteCount: Int64(storageSizeBytes),
            countStyle: .file
        )
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            items = []
            save()
            return
        }

        do {
            let data = try Data(contentsOf: fileURL)
            items = try decoder.decode([ClipboardHistoryItem].self, from: data)
            items.removeAll { item in
                (item.isVisualContent || item.isStoredFile) && mediaFileURL(for: item) == nil
            }
            deleteUnreferencedMediaFiles()
            refreshStorageSize()
        } catch {
            items = []
            refreshStorageSize()
        }
    }

    private func save() {
        do {
            let data = try encoder.encode(items)
            try data.write(to: fileURL, options: [.atomic])
            refreshStorageSize()
        } catch {
            NSLog("Failed to save clipboard history: \(error.localizedDescription)")
        }
    }

    private func pruneToMaxItems() {
        pruneToMaxItems(maxItems: settings.maxHistoryItems)
    }

    private func pruneToMaxItems(maxItems: Int) {
        guard items.count > maxItems else { return }

        let removedItems = items.dropFirst(maxItems)
        removedItems.forEach(deleteMediaFile)
        items = Array(items.prefix(maxItems))
    }

    private func observeSettings() {
        settings.$maxHistoryItems
            .dropFirst()
            .sink { [weak self] maxHistoryItems in
                guard let self else { return }

                self.pruneToMaxItems(maxItems: maxHistoryItems)
                self.save()
            }
            .store(in: &cancellables)
    }

    private func addFile(_ sourceURL: URL, shouldSave: Bool) {
        guard
            sourceURL.isFileURL,
            let fileInfo = fileCaptureInfo(for: sourceURL),
            fileInfo.size > 0,
            fileInfo.size <= settings.maxFileCaptureBytes
        else {
            return
        }

        let originalName = sourceURL.lastPathComponent
        removeDuplicateFiles(sourceURL: sourceURL, originalName: originalName, fileSize: fileInfo.size)

        let id = UUID()
        let itemDirectory = storedFileDirectory.appendingPathComponent(id.uuidString, isDirectory: true)
        let storedName = Self.sanitizedFileName(originalName)
        let storedPath = "\(id.uuidString)/\(storedName)"
        let destinationURL = itemDirectory.appendingPathComponent(storedName, isDirectory: false)

        do {
            try FileManager.default.createDirectory(
                at: itemDirectory,
                withIntermediateDirectories: true
            )
            try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
        } catch {
            NSLog("Failed to save clipboard file: \(error.localizedDescription)")
            return
        }

        items.insert(
            ClipboardHistoryItem(
                id: id,
                kind: .file,
                content: originalName,
                fileName: storedPath,
                pasteboardType: fileInfo.contentType,
                fileSizeBytes: fileInfo.size
            ),
            at: 0
        )

        if shouldSave {
            pruneToMaxItems()
            save()
        }
    }

    private func fileCaptureInfo(for url: URL) -> (size: Int64, contentType: String?)? {
        guard
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
            attributes[.type] as? FileAttributeType == .typeRegular,
            let fileSize = attributes[.size] as? NSNumber
        else {
            return nil
        }

        let contentType = UTType(filenameExtension: url.pathExtension)?.identifier
        return (fileSize.int64Value, contentType)
    }

    private func removeDuplicateVisualItems(matching data: Data, kind: ClipboardHistoryItem.Kind) {
        let duplicateItems = items.filter { item in
            guard item.kind == kind, let url = mediaFileURL(for: item) else { return false }
            // A different byte count cannot be a duplicate. Avoid loading every
            // historical image each time the clipboard receives a new image.
            guard fileSize(at: url) == UInt64(data.count) else { return false }
            return (try? Data(contentsOf: url)) == data
        }

        duplicateItems.forEach(deleteMediaFile)
        let duplicateIDs = Set(duplicateItems.map(\.id))
        items.removeAll { duplicateIDs.contains($0.id) }
    }

    private func removeDuplicateFiles(sourceURL: URL, originalName: String, fileSize: Int64) {
        let duplicateItems = items.filter { item in
            guard
                item.kind == .file,
                item.content == originalName,
                item.fileSizeBytes == fileSize,
                let storedURL = mediaFileURL(for: item)
            else {
                return false
            }

            return filesHaveSameContents(sourceURL, storedURL)
        }

        duplicateItems.forEach(deleteMediaFile)
        let duplicateIDs = Set(duplicateItems.map(\.id))
        items.removeAll { duplicateIDs.contains($0.id) }
    }

    private func filesHaveSameContents(_ firstURL: URL, _ secondURL: URL) -> Bool {
        guard
            let firstData = try? Data(contentsOf: firstURL),
            let secondData = try? Data(contentsOf: secondURL)
        else {
            return false
        }

        return firstData == secondData
    }

    private func mediaFileURL(for item: ClipboardHistoryItem) -> URL? {
        guard let fileName = item.fileName else { return nil }

        let baseDirectory = item.kind == .file ? storedFileDirectory : imageDirectory
        let unvalidatedURL = if item.kind == .file {
            storedFileURL(for: fileName)
        } else {
            imageFileURL(for: fileName)
        }

        guard
            let unvalidatedURL,
            let url = validatedURL(unvalidatedURL, containedIn: baseDirectory),
            FileManager.default.fileExists(atPath: url.path)
        else {
            return nil
        }

        return url
    }

    private func imageFileURL(for fileName: String) -> URL? {
        guard fileName == URL(fileURLWithPath: fileName).lastPathComponent else {
            return nil
        }

        return imageDirectory.appendingPathComponent(fileName, isDirectory: false)
    }

    private func validatedURL(_ url: URL, containedIn directory: URL) -> URL? {
        let standardizedURL = url.standardizedFileURL
        let standardizedDirectory = directory.standardizedFileURL
        let directoryPath = standardizedDirectory.path
        let urlPath = standardizedURL.path

        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard urlPath == directoryPath || urlPath.hasPrefix(directoryPath + "/") else { return nil }

        return standardizedURL
    }

    private func deleteMediaFile(for item: ClipboardHistoryItem) {
        guard let fileName = item.fileName else { return }

        let baseDirectory = item.kind == .file ? storedFileDirectory : imageDirectory
        let unvalidatedURL = if item.kind == .file {
            storedFileURL(for: fileName)
        } else {
            imageFileURL(for: fileName)
        }
        guard let unvalidatedURL, let url = validatedURL(unvalidatedURL, containedIn: baseDirectory) else {
            return
        }

        do {
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
            if item.kind == .file {
                let itemDirectory = url.deletingLastPathComponent()
                if itemDirectory != storedFileDirectory {
                    try? FileManager.default.removeItem(at: itemDirectory)
                }
            }
        } catch {
            NSLog("Failed to delete clipboard media: \(error.localizedDescription)")
        }
    }

    private func deleteStoredImageFiles() {
        deleteStoredFiles(in: imageDirectory, logName: "images")
        deleteStoredFiles(in: storedFileDirectory, logName: "files")
    }

    private func deleteUnreferencedMediaFiles() {
        let referencedMediaURLs = Set(items.compactMap { mediaFileURL(for: $0)?.standardizedFileURL })
        deleteUnreferencedFiles(in: imageDirectory, referencedMediaURLs: referencedMediaURLs)
        deleteUnreferencedFiles(in: storedFileDirectory, referencedMediaURLs: referencedMediaURLs)
        deleteEmptyDirectories(in: storedFileDirectory)
    }

    private func deleteUnreferencedFiles(in directory: URL, referencedMediaURLs: Set<URL>) {
        guard
            let enumerator = FileManager.default.enumerator(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey]
            )
        else {
            return
        }

        for case let url as URL in enumerator {
            guard
                let values = try? url.resourceValues(forKeys: [.isRegularFileKey]),
                values.isRegularFile == true
            else {
                continue
            }

            let standardizedURL = url.standardizedFileURL
            guard !referencedMediaURLs.contains(standardizedURL) else { continue }

            do {
                try FileManager.default.removeItem(at: standardizedURL)
            } catch {
                NSLog("Failed to delete unreferenced clipboard media: \(error.localizedDescription)")
            }
        }
    }

    private func deleteEmptyDirectories(in directory: URL) {
        guard
            let enumerator = FileManager.default.enumerator(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
        else {
            return
        }

        let directories = enumerator
            .compactMap { $0 as? URL }
            .filter { url in
                (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            }
            .sorted { $0.path.count > $1.path.count }

        for url in directories {
            guard url.standardizedFileURL != directory.standardizedFileURL else { continue }

            do {
                let contents = try FileManager.default.contentsOfDirectory(atPath: url.path)
                if contents.isEmpty {
                    try FileManager.default.removeItem(at: url)
                }
            } catch {
                NSLog("Failed to delete empty clipboard media directory: \(error.localizedDescription)")
            }
        }
    }

    private func refreshStorageSize() {
        storageRefreshGeneration += 1
        let generation = storageRefreshGeneration
        storageRefreshTask?.cancel()
        let scanner = storageScanner
        let history = fileURL
        let directories = [imageDirectory, storedFileDirectory]
        storageRefreshTask = Task(priority: .utility) { [weak self] in
            guard let size = await scanner.size(history: history, directories: directories),
                  !Task.isCancelled, let self,
                  generation == self.storageRefreshGeneration else { return }
            if self.storageSizeBytes != size { self.storageSizeBytes = size }
        }
    }

    private func deleteStoredFiles(in directory: URL, logName: String) {
        do {
            let urls = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            )
            for url in urls {
                try FileManager.default.removeItem(at: url)
            }
        } catch {
            NSLog("Failed to clear clipboard \(logName): \(error.localizedDescription)")
        }
    }

    private func fileSize(at url: URL) -> UInt64 {
        guard
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
            attributes[.type] as? FileAttributeType == .typeRegular,
            let fileSize = attributes[.size] as? NSNumber
        else {
            return 0
        }

        return fileSize.uint64Value
    }

    private func createSupportDirectoryIfNeeded(at url: URL) {
        do {
            try FileManager.default.createDirectory(
                at: url,
                withIntermediateDirectories: true
            )
        } catch {
            NSLog("Failed to create Application Support directory: \(error.localizedDescription)")
        }
    }

    private static func sanitizedFileName(_ fileName: String) -> String {
        let invalidCharacters = CharacterSet(charactersIn: "/:\\")
            .union(.newlines)
            .union(.controlCharacters)
        let components = fileName.components(separatedBy: invalidCharacters)
        let sanitized = components.joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return sanitized.isEmpty ? "file" : sanitized
    }

    private func storedFileURL(for fileName: String) -> URL? {
        let pathComponents = fileName.split(separator: "/", omittingEmptySubsequences: true)
        guard pathComponents.allSatisfy({ $0 != "." && $0 != ".." }) else {
            return nil
        }

        guard pathComponents.count == 2 else {
            guard fileName == URL(fileURLWithPath: fileName).lastPathComponent else {
                return nil
            }

            return storedFileDirectory.appendingPathComponent(fileName, isDirectory: false)
        }

        return storedFileDirectory
            .appendingPathComponent(String(pathComponents[0]), isDirectory: true)
            .appendingPathComponent(String(pathComponents[1]), isDirectory: false)
    }
}

private actor ClipboardStorageScanner {
    func size(history: URL, directories: [URL]) -> UInt64? {
        guard !Task.isCancelled else { return nil }
        var total = fileSize(at: history)
        for directory in directories {
            guard !Task.isCancelled else { return nil }
            guard let enumerator = FileManager.default.enumerator(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]
            ) else { continue }
            for case let url as URL in enumerator {
                guard !Task.isCancelled else { return nil }
                total += fileSize(at: url)
            }
        }
        return total
    }

    private func fileSize(at url: URL) -> UInt64 {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true, let size = values.fileSize else { return 0 }
        return UInt64(max(0, size))
    }
}

private extension ClipboardHistoryItem.Kind {
    var isVisualKind: Bool {
        self == .image || self == .gif
    }
}
