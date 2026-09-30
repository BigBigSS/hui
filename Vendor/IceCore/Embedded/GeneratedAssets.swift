import SwiftUI

extension ImageResource {
    static let iceCubeStroke = ImageResource(name: "IceCubeStroke", bundle: .main)
}
extension NSImage {
    static var warning: NSImage {
        NSImage(named: "Warning") ?? NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)!
    }
}
extension Color {
    static let defaultLayoutBar = Color("DefaultLayoutBarColor", bundle: .main)
}
