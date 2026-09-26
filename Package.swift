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
        // Syntax trees for code tiles. Grammar versions are the newest whose manifests depend on
        // ChimeHQ/SwiftTreeSitter, so the graph holds a single SwiftTreeSitter.
        .package(url: "https://github.com/ChimeHQ/SwiftTreeSitter", exact: "0.25.0"),
        .package(url: "https://github.com/alex-pinkus/tree-sitter-swift", exact: "0.7.3-with-generated-files"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-typescript", exact: "0.23.2"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-javascript", exact: "0.23.1"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-python", exact: "0.23.6"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-json", exact: "0.24.8"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-bash", exact: "0.23.3"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-go", exact: "0.23.4"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-rust", exact: "0.24.2"),
    ],
    targets: [
        .target(
            name: "CanvasCore",
            dependencies: [
                .product(name: "SwiftTreeSitter", package: "SwiftTreeSitter"),
                .product(name: "TreeSitterSwift", package: "tree-sitter-swift"),
                .product(name: "TreeSitterTypeScript", package: "tree-sitter-typescript"),
                .product(name: "TreeSitterJavaScript", package: "tree-sitter-javascript"),
                .product(name: "TreeSitterPython", package: "tree-sitter-python"),
                .product(name: "TreeSitterJSON", package: "tree-sitter-json"),
                .product(name: "TreeSitterBash", package: "tree-sitter-bash"),
                .product(name: "TreeSitterGo", package: "tree-sitter-go"),
                .product(name: "TreeSitterRust", package: "tree-sitter-rust"),
            ]
        ),
        .executableTarget(
            name: "CanvasApp",
            dependencies: [
                "CanvasCore",
                .product(name: "GhosttyTerminal", package: "libghostty-spm"),
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
