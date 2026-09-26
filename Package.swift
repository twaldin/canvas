// swift-tools-version: 6.0
import PackageDescription

// Command Line Tools ship swift-testing outside the default search and runtime paths, and
// `swift test`'s helper does not discover tests with it. Tests therefore build as an executable
// that calls swift-testing's entry point directly: `swift run CanvasCoreTests`.
let cltFrameworks = "/Library/Developer/CommandLineTools/Library/Developer/Frameworks"
let cltLibs = "/Library/Developer/CommandLineTools/Library/Developer/usr/lib"

let package = Package(
    name: "Canvas",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Canvas", targets: ["CanvasApp"]),
    ],
    dependencies: [
        // Pinned: binary, headers and wrapper must move together (docs/design.md).
        .package(url: "https://github.com/Lakr233/libghostty-spm.git", exact: "1.6.20260922"),
        // Note tiles: CommonMark + GFM (tables, strikethrough, task lists) AST. Apache-2.0.
        .package(url: "https://github.com/swiftlang/swift-markdown.git", exact: "0.9.0"),
    ],
    targets: [
        .target(name: "CanvasCore"),
        .executableTarget(
            name: "CanvasApp",
            dependencies: [
                "CanvasCore",
                .product(name: "GhosttyTerminal", package: "libghostty-spm"),
                .product(name: "Markdown", package: "swift-markdown"),
            ]
        ),
        .executableTarget(
            name: "CanvasCoreTests",
            dependencies: ["CanvasCore"],
            path: "Tests/CanvasCoreTests",
            swiftSettings: [.unsafeFlags(["-F", cltFrameworks])],
            linkerSettings: [.unsafeFlags(["-F", cltFrameworks, "-framework", "Testing", "-Xlinker", "-rpath", "-Xlinker", cltFrameworks, "-Xlinker", "-rpath", "-Xlinker", cltLibs])]
        ),
    ]
)
