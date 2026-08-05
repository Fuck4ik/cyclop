// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Cyclop",
    // macOS 15 for Translation.framework, which the translate tab runs on.
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "Cyclop", targets: ["Cyclop"])
    ],
    targets: [
        // Dictation logic lives apart from the executable so it can be tested:
        // an executable target cannot be imported by a test target.
        .target(
            name: "CyclopDictation",
            path: "Sources/CyclopDictation",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "Cyclop",
            dependencies: ["CyclopDictation"],
            path: "Sources/Cyclop",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "CyclopDictationTests",
            dependencies: ["CyclopDictation"],
            path: "Tests/CyclopDictationTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
