import AppKit
import Combine

// Updates belong to the containing application, never to the embedded menu core.
@MainActor
final class UpdatesManager: NSObject, ObservableObject {
    @Published var canCheckForUpdates = false
    @Published var lastUpdateCheckDate: Date?
    @Published var automaticallyChecksForUpdates = false
    @Published var automaticallyDownloadsUpdates = false
    func performSetup(with appState: AppState) {}
    @objc func checkForUpdates() {}
}
