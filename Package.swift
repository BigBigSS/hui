// swift-tools-version: 6.0
import PackageDescription
let upstream: [SwiftSetting] = [.swiftLanguageMode(.v5), .unsafeFlags(["-enable-bare-slash-regex"])]
let package = Package(
    name: "Shiyi",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Shiyi", targets: ["Shiyi"])],
    targets: [
        .executableTarget(name: "Shiyi", dependencies: ["ShiyiMenuCore"]),
        .target(
            name: "ShiyiMenuCore",
            dependencies: ["AXSwift", "CompactSlider", "Ifrit", "LaunchAtLogin", "Semaphore"],
            path: "Vendor/IceCore",
            exclude: ["Ice/Main/IceApp.swift", "Ice/Main/AppDelegate.swift", "Ice/Main/Updates.swift", "UpstreamPackage.resolved"],
            swiftSettings: upstream
        ),
        .target(name: "AXSwift", path: "Vendor/Dependencies/AXSwift/Sources", exclude: ["AXSwift.h", "Info.plist"], swiftSettings: upstream),
        .target(name: "CompactSlider", path: "Vendor/Dependencies/CompactSlider/Sources/CompactSlider", resources: [.copy("PrivacyInfo.xcprivacy")], swiftSettings: upstream),
        .target(name: "Ifrit", path: "Vendor/Dependencies/Ifrit/Sources/Ifrit", exclude: ["Classes/Fuse_LICENSE"], swiftSettings: upstream),
        .target(name: "LaunchAtLogin", path: "Vendor/Dependencies/LaunchAtLogin/Sources/LaunchAtLogin", swiftSettings: upstream),
        .target(name: "Semaphore", path: "Vendor/Dependencies/Semaphore/Sources/Semaphore", swiftSettings: upstream)
    ]
)
