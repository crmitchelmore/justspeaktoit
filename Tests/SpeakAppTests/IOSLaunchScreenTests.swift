import Foundation
import XCTest

final class IOSLaunchScreenTests: XCTestCase {
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private var launchMarkImageSet: URL {
        repositoryRoot.appendingPathComponent("SpeakiOSApp/Assets.xcassets/LaunchMark.imageset")
    }

    private let launchMarkVariants = ["LaunchMark.svg", "LaunchMark-dark.svg"]

    func testLaunchScreen_usesAnAdaptiveImageWithoutText() throws {
        let storyboard = try String(
            contentsOf: repositoryRoot.appendingPathComponent("SpeakiOSApp/Resources/LaunchScreen.storyboard"),
            encoding: .utf8
        )

        XCTAssertTrue(storyboard.contains("image=\"LaunchMark\""))
        XCTAssertTrue(storyboard.contains("systemColor=\"systemBackgroundColor\""))
        XCTAssertFalse(storyboard.contains("<label"))
    }

    func testLaunchMark_hasLightAndDarkVectorVariants() throws {
        let contents = try String(
            contentsOf: launchMarkImageSet.appendingPathComponent("Contents.json"),
            encoding: .utf8
        )

        XCTAssertTrue(contents.contains("LaunchMark.svg"))
        XCTAssertTrue(contents.contains("LaunchMark-dark.svg"))
        XCTAssertTrue(contents.contains("preserves-vector-representation"))
        for variant in launchMarkVariants {
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: launchMarkImageSet.appendingPathComponent(variant).path),
                "\(variant) should exist"
            )
        }
    }

    func testLaunchMark_waveformSharesTheCentreOfTheCircleAndTheCanvas() throws {
        for variant in launchMarkVariants {
            let geometry = try launchMarkGeometry(ofVariant: variant)

            XCTAssertEqual(
                geometry.waveformCentreX,
                geometry.circleCentreX,
                accuracy: 0.001,
                "\(variant): the waveform should share the centre of the circle"
            )
            XCTAssertEqual(
                geometry.waveformCentreX,
                geometry.canvasWidth / 2,
                accuracy: 0.001,
                "\(variant): the waveform should share the centre of the canvas"
            )
        }
    }

    func testLaunchMark_waveformKeepsAnOddBarCountWithEqualSpacing() throws {
        for variant in launchMarkVariants {
            let geometry = try launchMarkGeometry(ofVariant: variant)
            let spacings = zip(geometry.bars, geometry.bars.dropFirst()).map { $1.originX - $0.originX }

            XCTAssertEqual(geometry.bars.count % 2, 1, "\(variant): the bar count should stay odd")
            XCTAssertEqual(Set(spacings).count, 1, "\(variant): the bars should keep equal spacing")
        }
    }

    func testLaunchMark_variantsShareIdenticalShapeCoordinates() throws {
        let shapes = try launchMarkVariants.map { try launchMarkGeometry(ofVariant: $0) }

        XCTAssertEqual(
            shapes.first,
            shapes.last,
            "Only colour should vary between the light and the dark launch mark"
        )
    }

    // MARK: - Helpers

    private struct Bar: Equatable {
        let originX: Double
        let originY: Double
        let width: Double
        let height: Double
    }

    private struct LaunchMarkGeometry: Equatable {
        let canvasWidth: Double
        let circleCentreX: Double
        let bars: [Bar]

        var waveformCentreX: Double {
            let leadingEdge = bars.map(\.originX).min() ?? 0
            let trailingEdge = bars.map { $0.originX + $0.width }.max() ?? 0
            return (leadingEdge + trailingEdge) / 2
        }
    }

    private func launchMarkGeometry(
        ofVariant variant: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> LaunchMarkGeometry {
        let markup = try String(
            contentsOf: launchMarkImageSet.appendingPathComponent(variant),
            encoding: .utf8
        )

        let canvasWidths = try values(of: "svg", attributes: ["width"], in: markup)
        let circles = try values(of: "circle", attributes: ["cx"], in: markup)
        let rects = try values(of: "rect", attributes: ["x", "y", "width", "height"], in: markup)

        let canvasWidth = try XCTUnwrap(
            canvasWidths.first?.first,
            "\(variant): no canvas width",
            file: file,
            line: line
        )
        let circleCentres = Set(circles.compactMap(\.first))
        XCTAssertEqual(
            circleCentres.count,
            1,
            "\(variant): the circles should share one centre",
            file: file,
            line: line
        )
        let circleCentreX = try XCTUnwrap(circleCentres.first, "\(variant): no circle", file: file, line: line)
        XCTAssertFalse(rects.isEmpty, "\(variant): no waveform bars", file: file, line: line)

        return LaunchMarkGeometry(
            canvasWidth: canvasWidth,
            circleCentreX: circleCentreX,
            bars: rects.map { Bar(originX: $0[0], originY: $0[1], width: $0[2], height: $0[3]) }
        )
    }

    /// Reads the given numeric attributes from every occurrence of an element.
    private func values(of element: String, attributes: [String], in markup: String) throws -> [[Double]] {
        let attributePatterns = attributes.map { "\($0)=\"(-?[0-9.]+)\"" }.joined(separator: "[^>]*?")
        let expression = try NSRegularExpression(pattern: "<\(element)[^>]*?\(attributePatterns)")
        let range = NSRange(markup.startIndex..., in: markup)

        return expression.matches(in: markup, range: range).map { match in
            (1..<match.numberOfRanges).compactMap { index in
                guard let captured = Range(match.range(at: index), in: markup) else { return nil }
                return Double(markup[captured])
            }
        }
    }
}
