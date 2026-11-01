// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OpenBookMobile",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "OpenBookCore", targets: ["OpenBookCore"])],
    targets: [
        .target(name: "OpenBookCore"),
        .executableTarget(name: "OpenBookDesktop", dependencies: ["OpenBookCore"], path: "App", exclude: ["Info.plist", "OpenBook.entitlements", "Assets.xcassets"]),
        .testTarget(name: "OpenBookCoreTests", dependencies: ["OpenBookCore"], resources: [.copy("Fixtures")])
    ],
    swiftLanguageModes: [.v6]
)
