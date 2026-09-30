import SwiftUI

enum AppTheme: String, CaseIterable, Identifiable {
    case colorful
    case boringLight = "boring-light"
    case boringDark = "boring-dark"

    var id: String {
        rawValue
    }

    var label: String {
        switch self {
        case .colorful:
            return "Colorful"
        case .boringLight:
            return "Boring Light"
        case .boringDark:
            return "Boring Dark"
        }
    }

    var preferredColorScheme: ColorScheme? {
        switch self {
        case .colorful:
            return nil
        case .boringLight:
            return .light
        case .boringDark:
            return .dark
        }
    }

    var palette: AppThemePalette {
        switch self {
        case .colorful:
            return AppThemePalette(
                background: Color(red: 0.97, green: 0.96, blue: 0.99),
                surface: .white.opacity(0.92),
                surfaceRaised: .white,
                toolbar: Color(red: 0.94, green: 0.92, blue: 1.0),
                accent: Color(red: 0.49, green: 0.36, blue: 1.0),
                text: Color(red: 0.11, green: 0.09, blue: 0.16),
                secondaryText: Color(red: 0.43, green: 0.39, blue: 0.52),
                icon: Color(red: 0.31, green: 0.24, blue: 0.63),
                destructive: Color(red: 0.78, green: 0.17, blue: 0.17),
                border: Color(red: 0.31, green: 0.25, blue: 0.47).opacity(0.14),
                separator: Color(red: 0.31, green: 0.25, blue: 0.47).opacity(0.12)
            )
        case .boringLight:
            return AppThemePalette(
                background: Color(red: 0.95, green: 0.95, blue: 0.96),
                surface: .white,
                surfaceRaised: .white,
                toolbar: Color(red: 0.98, green: 0.98, blue: 0.985),
                accent: Color(red: 0.0, green: 0.36, blue: 0.84),
                text: Color(red: 0.10, green: 0.10, blue: 0.11),
                secondaryText: Color(red: 0.39, green: 0.39, blue: 0.42),
                icon: Color(red: 0.23, green: 0.23, blue: 0.25),
                destructive: Color(red: 0.74, green: 0.12, blue: 0.12),
                border: .black.opacity(0.12),
                separator: .black.opacity(0.08)
            )
        case .boringDark:
            return AppThemePalette(
                background: Color(red: 0.11, green: 0.11, blue: 0.12),
                surface: Color(red: 0.17, green: 0.17, blue: 0.18),
                surfaceRaised: Color(red: 0.20, green: 0.20, blue: 0.21),
                toolbar: Color(red: 0.14, green: 0.14, blue: 0.15),
                accent: Color(red: 0.35, green: 0.62, blue: 1.0),
                text: Color(red: 0.96, green: 0.96, blue: 0.97),
                secondaryText: Color(red: 0.64, green: 0.64, blue: 0.67),
                icon: Color(red: 0.82, green: 0.82, blue: 0.86),
                destructive: Color(red: 1.0, green: 0.45, blue: 0.43),
                border: .white.opacity(0.12),
                separator: .white.opacity(0.10)
            )
        }
    }
}

struct AppThemePalette {
    let background: Color
    let surface: Color
    let surfaceRaised: Color
    let toolbar: Color
    let accent: Color
    let text: Color
    let secondaryText: Color
    let icon: Color
    let destructive: Color
    let border: Color
    let separator: Color
}
