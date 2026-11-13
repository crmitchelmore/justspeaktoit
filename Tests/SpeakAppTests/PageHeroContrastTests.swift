import XCTest

@testable import SpeakApp

/// Every page header draws `SpeakTextStyle` on-tint text on its palette, and on
/// chips filled with `onTintFill` over that palette. Each combination must keep
/// WCAG AA text contrast (4.5:1) at every gradient stop, so a new or restyled
/// palette cannot ship unreadable header text.
final class PageHeroContrastTests: XCTestCase {
    private struct Pairing {
        let name: String
        let text: HeroColorStop
        let background: HeroColorStop
    }

    private let white = HeroColorStop(1, 1, 1)

    func testOnTintText_meetsAAContrastOnEveryPaletteStop() {
        let secondary = SpeakTextStyle.onTintSecondaryOpacity

        for palette in PageHeroPalette.allCases {
            for surface in palette.stops {
                let chip = composite(white, alpha: SpeakTextStyle.onTintFillOpacity, over: surface)
                let pairings = [
                    Pairing(name: "primary on surface", text: white, background: surface),
                    Pairing(
                        name: "secondary on surface",
                        text: composite(white, alpha: secondary, over: surface),
                        background: surface
                    ),
                    Pairing(name: "primary on chip", text: white, background: chip),
                    Pairing(
                        name: "secondary on chip",
                        text: composite(white, alpha: secondary, over: chip),
                        background: chip
                    )
                ]
                for pairing in pairings {
                    let ratio = contrast(pairing.text, pairing.background)
                    XCTAssertGreaterThanOrEqual(
                        ratio, 4.5, "\(palette) \(pairing.name) at \(surface): \(String(format: "%.2f", ratio)):1"
                    )
                }
            }
        }
    }

    private func composite(
        _ foreground: HeroColorStop, alpha: Double, over background: HeroColorStop
    ) -> HeroColorStop {
        HeroColorStop(
            alpha * foreground.red + (1 - alpha) * background.red,
            alpha * foreground.green + (1 - alpha) * background.green,
            alpha * foreground.blue + (1 - alpha) * background.blue
        )
    }

    private func luminance(_ color: HeroColorStop) -> Double {
        func linear(_ channel: Double) -> Double {
            channel <= 0.040_45 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(color.red) + 0.7152 * linear(color.green) + 0.0722 * linear(color.blue)
    }

    private func contrast(_ first: HeroColorStop, _ second: HeroColorStop) -> Double {
        let lighter = max(luminance(first), luminance(second))
        let darker = min(luminance(first), luminance(second))
        return (lighter + 0.05) / (darker + 0.05)
    }
}
