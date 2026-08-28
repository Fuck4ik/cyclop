// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Cyclop",
    // macOS 15 for Translation.framework, which the translate tab runs on.
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "Cyclop", targets: ["Cyclop"]),
        // The Finder context-menu item. Not something anyone runs by hand:
        // bundle.sh wraps this binary into Cyclop.app/Contents/PlugIns as an
        // .appex, and Finder is what launches it.
        .executable(name: "CyclopFinderMenu", targets: ["CyclopFinderMenu"]),
    ],
    targets: [
        // Dictation logic lives apart from the executable so it can be tested:
        // an executable target cannot be imported by a test target.
        .target(
            name: "CyclopDictation",
            path: "Sources/CyclopDictation",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Same reason as above, for the Finder extension: an app extension
        // is an executable too, so the part worth testing lives beside it.
        .target(
            name: "CyclopFinderPath",
            path: "Sources/CyclopFinderPath",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "Cyclop",
            dependencies: ["CyclopDictation"],
            path: "Sources/Cyclop",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "CyclopFinderMenu",
            dependencies: ["CyclopFinderPath"],
            path: "Sources/CyclopFinderMenu",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "CyclopDictationTests",
            dependencies: ["CyclopDictation"],
            path: "Tests/CyclopDictationTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "CyclopFinderPathTests",
            dependencies: ["CyclopFinderPath"],
            path: "Tests/CyclopFinderPathTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
