import Foundation

@available(macOS 26.0, *)
extension MenuBarItemService {
    final class Connection: Sendable {
        static let shared = Connection()
        private init() {}
        func start() async {
            await MainActor.run { SourcePIDCache.shared.start() }
        }
        @MainActor func stop() { SourcePIDCache.shared.stop() }
        func sourcePID(for window: WindowInfo) async -> pid_t? {
            await withCheckedContinuation { continuation in
                SourcePIDCache.queue.async {
                    continuation.resume(returning: SourcePIDCache.shared.pid(for: window))
                }
            }
        }
    }
}
