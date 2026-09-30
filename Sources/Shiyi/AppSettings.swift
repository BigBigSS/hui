import Foundation

@MainActor
final class AppSettings: ObservableObject {
    static let maxHistoryOptions = [100, 500, 1000, 2500, 5000]
    static let maxFileCaptureOptionsMB = [30, 100, 250, 500, 1000]
    static let defaultMaxFileCaptureMB = 30

    @Published var theme: AppTheme {
        didSet {
            defaults.set(theme.rawValue, forKey: Keys.theme)
        }
    }

    @Published var maxHistoryItems: Int {
        didSet {
            let validatedValue = Self.validMaxHistoryItems(maxHistoryItems)
            if validatedValue != maxHistoryItems {
                maxHistoryItems = validatedValue
                return
            }

            defaults.set(maxHistoryItems, forKey: Keys.maxHistoryItems)
        }
    }

    @Published var maxFileCaptureMB: Int {
        didSet {
            let validatedValue = Self.validMaxFileCaptureMB(maxFileCaptureMB)
            if validatedValue != maxFileCaptureMB {
                maxFileCaptureMB = validatedValue
                return
            }

            defaults.set(maxFileCaptureMB, forKey: Keys.maxFileCaptureMB)
        }
    }

    var maxFileCaptureBytes: Int64 {
        Int64(maxFileCaptureMB) * 1_000_000
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        let savedTheme = defaults.string(forKey: Keys.theme)
        theme = AppTheme(rawValue: savedTheme ?? "") ?? .colorful

        let savedMaxHistoryItems = defaults.integer(forKey: Keys.maxHistoryItems)
        maxHistoryItems = Self.validMaxHistoryItems(savedMaxHistoryItems)

        let savedMaxFileCaptureMB = defaults.integer(forKey: Keys.maxFileCaptureMB)
        maxFileCaptureMB = Self.validMaxFileCaptureMB(savedMaxFileCaptureMB)
    }

    private static func validMaxHistoryItems(_ value: Int) -> Int {
        guard maxHistoryOptions.contains(value) else { return 500 }
        return value
    }

    private static func validMaxFileCaptureMB(_ value: Int) -> Int {
        guard maxFileCaptureOptionsMB.contains(value) else { return defaultMaxFileCaptureMB }
        return value
    }

    private enum Keys {
        static let theme = "theme"
        static let maxHistoryItems = "maxHistoryItems"
        static let maxFileCaptureMB = "maxFileCaptureMB"
    }
}
