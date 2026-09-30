import AppKit
import ImageIO
import SwiftUI

// CGImage is immutable. The wrapper lets decoded pixels cross from the
// background cache to the main actor without transferring mutable AppKit state.
final class ClipboardThumbnailImage: @unchecked Sendable {
    let image: CGImage
    init(_ image: CGImage) { self.image = image }
}

actor ClipboardThumbnailCache {
    private let cache: NSCache<NSString, ClipboardThumbnailImage> = {
        let cache = NSCache<NSString, ClipboardThumbnailImage>()
        cache.countLimit = 200
        cache.totalCostLimit = 32 * 1024 * 1024
        return cache
    }()

    func clear() { cache.removeAllObjects() }

    // Decode requests execute serially on this actor, never on the main actor.
    // Offscreen SwiftUI tasks are cancelled before queued work starts.
    func image(at url: URL, pixels requestedPixels: Int, fit: Bool = false) -> ClipboardThumbnailImage? {
        guard !Task.isCancelled else { return nil }
        let pixels = max(1, min(2048, requestedPixels))
        let key = "\(url.path)#\(pixels)#\(fit)" as NSString
        if let image = cache.object(forKey: key) { return image }

        return autoreleasepool {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, [
                kCGImageSourceShouldCache: false
            ] as CFDictionary), !Task.isCancelled else { return nil }
            var decodePixels = pixels
            if !fit,
               let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
               let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
               let height = properties[kCGImagePropertyPixelHeight] as? NSNumber {
                let shortSide = max(1, min(width.doubleValue, height.doubleValue))
                let longSide = max(width.doubleValue, height.doubleValue)
                decodePixels = Int(min(2048, ceil(Double(pixels) * longSide / shortSide)))
            }
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: decodePixels,
                kCGImageSourceShouldCacheImmediately: true
            ] as CFDictionary), !Task.isCancelled else { return nil }
            let decoded = ClipboardThumbnailImage(image)
            cache.setObject(decoded, forKey: key, cost: image.bytesPerRow * image.height)
            return decoded
        }
    }
}

struct ClipboardThumbnail: View {
    let item: ClipboardHistoryItem
    let store: ClipboardHistoryStore
    let side: CGFloat
    var fit = false

    @Environment(\.displayScale) private var displayScale
    @State private var loaded: LoadedImage?

    private struct Request: Hashable {
        let id: UUID
        let pixels: Int
        let fit: Bool
    }
    private struct LoadedImage {
        let request: Request
        let pixels: ClipboardThumbnailImage
    }
    private var request: Request {
        Request(id: item.id, pixels: max(1, Int(ceil(side * displayScale))), fit: fit)
    }

    var body: some View {
        let current = request
        Group {
            if let loaded, loaded.request == current {
                Image(decorative: loaded.pixels.image, scale: displayScale)
                    .resizable()
                    .aspectRatio(contentMode: fit ? .fit : .fill)
            } else {
                Image(systemName: "photo")
                    .font(.system(size: min(24, side * 0.42), weight: .regular))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.primary.opacity(0.035))
            }
        }
        .frame(width: side, height: side)
        .clipped()
        .accessibilityHidden(true)
        .task(id: current) {
            let decoded = await store.thumbnailImage(for: item, pixels: current.pixels, fit: current.fit)
            guard !Task.isCancelled else { return }
            loaded = decoded.map { LoadedImage(request: current, pixels: $0) }
        }
    }
}
