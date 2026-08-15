// swift-tools-version: 5.9
import PackageDescription

// Lint tooling graph, resolved independently of the application/test graph in
// the repository root. SwiftLint pins an exact swift-syntax version, while
// swift-snapshot-testing (root Package.swift) constrains swift-syntax
// differently; sharing one graph let an unrelated test dependency silently
// downgrade the linter (issue #677). Keeping SwiftLint here gives it its own
// resolution, recorded in Tooling/Package.resolved.
//
// To upgrade the lint toolchain intentionally, run:
//
//     swift package --package-path Tooling update
//
// and commit the resulting Tooling/Package.resolved. CI fails if resolving
// this graph drifts from the checked-in pin.
let package = Package(
    name: "SpeakTooling",
    dependencies: [
        .package(url: "https://github.com/realm/SwiftLint.git", from: "0.65.0")
    ]
)
