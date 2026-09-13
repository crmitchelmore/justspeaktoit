import Foundation
import XCTest

// Structural readers for `Project.swift`, shared by the tests that guard build
// identity (bundle ids, feature flags, what each target links and compiles).

/// The body of one `.target(name: ...)` declaration.
func targetBlock(named name: String, in manifest: String) throws -> Substring {
    // Targets are declared as top-level `let xTarget: Target = .target(...)`
    // statements (the manifest exceeded the type-checker's limit when the
    // conditional targets were assembled inline in one array literal).
    let topLevelMarker = ".target(\n    name: \"\(name)\""
    let nestedMarker = ".target(\n            name: \"\(name)\""
    let start = try XCTUnwrap(
        manifest.range(of: topLevelMarker)?.lowerBound
            ?? manifest.range(of: nestedMarker)?.lowerBound,
        "No target block found for \(name)"
    )
    let remainder = manifest[start...]
    let end = ["\n)\n"]
        .compactMap { remainder.range(of: $0)?.upperBound }
        .min() ?? manifest.endIndex
    return manifest[start..<end]
}

/// The declaration of a target-dependency array plus the conditional
/// `append` statements that extend it, which together determine what a
/// target links.
func dependencyBlock(named name: String, in manifest: String) throws -> Substring {
    let start = try XCTUnwrap(
        manifest.range(of: "var \(name): [TargetDependency] = [")?.lowerBound,
        "No dependency list found for \(name)"
    )
    let remainder = manifest[start...]
    // The list ends at the next top-level declaration.
    let end = ["\nlet ", "\nvar "]
        .compactMap { remainder.range(of: $0)?.lowerBound }
        .min() ?? manifest.endIndex
    return manifest[start..<end]
}

/// The iOS app's Info.plist dictionary, which is declared next to the target
/// rather than inside it so the optional export-compliance code can be added
/// after the literal.
func iosAppInfoPlistBlock(in manifest: String) throws -> Substring {
    let start = try XCTUnwrap(
        manifest.range(of: "var iosAppInfoPlist: [String: Plist.Value] = [")?.lowerBound,
        "No iOS Info.plist dictionary found"
    )
    let remainder = manifest[start...]
    let end = remainder.range(of: "\n]\n")?.upperBound ?? manifest.endIndex
    return manifest[start..<end]
}
