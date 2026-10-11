// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "OCRHarness",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/microsoft/onnxruntime-swift-package-manager", exact: "1.24.2"),
    ],
    targets: [
        .executableTarget(
            name: "OCRHarness",
            dependencies: [.product(name: "onnxruntime", package: "onnxruntime-swift-package-manager")],
            swiftSettings: [.defaultIsolation(MainActor.self), .enableUpcomingFeature("NonisolatedNonsendingByDefault"), .enableUpcomingFeature("InferIsolatedConformances"), .enableUpcomingFeature("MemberImportVisibility")]
        ),
    ]
)
