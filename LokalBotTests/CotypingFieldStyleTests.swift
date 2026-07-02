import AppKit
import XCTest
@testable import LokalBot

// MARK: - Ghost styling (host font/color match)

final class CotypingFieldStyleTests: XCTestCase {
    func testIsEmpty() {
        XCTAssertTrue(CotypingFieldStyle().isEmpty)
        XCTAssertFalse(CotypingFieldStyle(fontName: "Helvetica").isEmpty)
        XCTAssertFalse(CotypingFieldStyle(colorHex: "336699").isEmpty)
        XCTAssertFalse(CotypingFieldStyle(backgroundColorHex: "000000").isEmpty)
    }

    func testHexRoundTrip() {
        let color = NSColor(srgbRed: 0.2, green: 0.4, blue: 0.6, alpha: 1)
        let hex = CotypingTextColorCodec.hexString(from: color)
        XCTAssertEqual(hex, "336699")
        let back = CotypingTextColorCodec.nsColor(fromHex: hex)
        XCTAssertEqual(back?.redComponent ?? 0, 51.0 / 255, accuracy: 0.001)
        XCTAssertEqual(back?.greenComponent ?? 0, 102.0 / 255, accuracy: 0.001)
        XCTAssertEqual(back?.blueComponent ?? 0, 153.0 / 255, accuracy: 0.001)
    }

    func testHexParseRejectsInvalid() {
        XCTAssertNil(CotypingTextColorCodec.nsColor(fromHex: nil))
        XCTAssertNil(CotypingTextColorCodec.nsColor(fromHex: "xyz"))
        XCTAssertNil(CotypingTextColorCodec.nsColor(fromHex: "12345"))   // 5 digits
        XCTAssertNil(CotypingTextColorCodec.nsColor(fromHex: "GGGGGG"))
        XCTAssertNotNil(CotypingTextColorCodec.nsColor(fromHex: "FFFFFF"))
    }

    func testClampedPointSize() {
        XCTAssertEqual(CotypingGhostStyle.clampedPointSize(nil), 13)
        XCTAssertEqual(CotypingGhostStyle.clampedPointSize(8), 9)      // below floor
        XCTAssertEqual(CotypingGhostStyle.clampedPointSize(50), 28)    // above ceiling
        XCTAssertEqual(CotypingGhostStyle.clampedPointSize(16), 16)    // in range
    }

    func testFontFromStyleClampsSize() {
        // "Helvetica" is always present on macOS.
        let font = CotypingGhostStyle.font(from: CotypingFieldStyle(fontName: "Helvetica", fontPointSize: 50))
        XCTAssertEqual(font?.pointSize, 28)
        XCTAssertEqual(font?.fontName, "Helvetica")
    }

    func testFontNilForUnknownNameOrNoStyle() {
        XCTAssertNil(CotypingGhostStyle.font(from: nil))
        XCTAssertNil(CotypingGhostStyle.font(from: CotypingFieldStyle(fontName: "Definitely-Not-A-Font")))
    }

    func testMeasuredTextSizeCoversLeadingSpaceSuggestion() {
        let size = CotypingGhostStyle.measuredTextSize(
            " up on this",
            style: CotypingFieldStyle(fontName: "Helvetica", fontPointSize: 12))

        XCTAssertGreaterThan(size.width, 20)
        XCTAssertGreaterThan(size.height, 8)
    }

    func testGhostColorDimsHostColor() {
        let color = CotypingGhostStyle.ghostColor(from: CotypingFieldStyle(colorHex: "336699"))
        XCTAssertEqual(color?.alphaComponent ?? 0, CotypingGhostStyle.ghostOpacity, accuracy: 0.001)
        XCTAssertEqual(color?.redComponent ?? 0, 51.0 / 255, accuracy: 0.001)
    }

    func testGhostColorNilWithoutHex() {
        XCTAssertNil(CotypingGhostStyle.ghostColor(from: nil))
        XCTAssertNil(CotypingGhostStyle.ghostColor(from: CotypingFieldStyle(fontName: "Helvetica")))
    }

    func testMatchHostStyleDefaultsOn() {
        XCTAssertTrue(AppSettings().cotypingMatchHostStyle)
    }

    func testResolvedGhostColorDimsReadableForeground() {
        let style = CotypingFieldStyle(colorHex: "FFFFFF", backgroundColorHex: "000000")
        let color = CotypingGhostStyle.resolvedGhostColor(from: style, isDarkEnvironment: false)
        XCTAssertEqual(color.alphaComponent, CotypingGhostStyle.ghostOpacity, accuracy: 0.001)
        XCTAssertGreaterThan(CotypingGhostStyle.relativeLuminance(of: color), 0.9) // stays white
    }

    func testResolvedGhostColorUsesBackgroundWhenNoForeground() {
        let onDark = CotypingGhostStyle.resolvedGhostColor(
            from: CotypingFieldStyle(backgroundColorHex: "1E1E1E"), isDarkEnvironment: false)
        XCTAssertGreaterThan(CotypingGhostStyle.relativeLuminance(of: onDark), 0.9)  // light hint
        let onLight = CotypingGhostStyle.resolvedGhostColor(
            from: CotypingFieldStyle(backgroundColorHex: "FFFFFF"), isDarkEnvironment: true)
        XCTAssertLessThan(CotypingGhostStyle.relativeLuminance(of: onLight), 0.1)    // dark hint
    }

    func testResolvedGhostColorFallsBackToEnvironmentWithoutHostColors() {
        let dark = CotypingGhostStyle.resolvedGhostColor(from: nil, isDarkEnvironment: true)
        let light = CotypingGhostStyle.resolvedGhostColor(from: nil, isDarkEnvironment: false)
        XCTAssertGreaterThan(CotypingGhostStyle.relativeLuminance(of: dark), 0.9)
        XCTAssertLessThan(CotypingGhostStyle.relativeLuminance(of: light), 0.1)
    }

    func testResolvedGhostColorOverridesForegroundIndistinguishableFromBackground() {
        // A host fg flattened to the background color (wrong-appearance capture)
        // must not paint invisible text — synthesize a legible hint instead.
        let style = CotypingFieldStyle(colorHex: "000000", backgroundColorHex: "000000")
        let color = CotypingGhostStyle.resolvedGhostColor(from: style, isDarkEnvironment: false)
        XCTAssertGreaterThan(CotypingGhostStyle.relativeLuminance(of: color), 0.9) // light, not black
    }

    func testLuminanceAndContrastExtremes() {
        let white = NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
        let black = NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
        XCTAssertEqual(CotypingGhostStyle.relativeLuminance(of: white), 1, accuracy: 0.001)
        XCTAssertEqual(CotypingGhostStyle.relativeLuminance(of: black), 0, accuracy: 0.001)
        XCTAssertGreaterThan(CotypingGhostStyle.contrastRatio(white, black), 20)
        XCTAssertEqual(CotypingGhostStyle.contrastRatio(white, white), 1, accuracy: 0.001)
    }

    func testMeasuredLuminanceDrivesGhostContrast() {
        let style = CotypingFieldStyle(colorHex: "111111")  // near-black host fg, no bg reported
        // Measured-dark background → flip to a light hint (the reported bug).
        let onDark = CotypingGhostStyle.resolvedGhostColor(
            from: style, isDarkEnvironment: false, measuredLuminance: 0.03)
        XCTAssertGreaterThan(CotypingGhostStyle.relativeLuminance(of: onDark), 0.9)
        // Measured-light background → keep the legible dark host color.
        let onLight = CotypingGhostStyle.resolvedGhostColor(
            from: style, isDarkEnvironment: true, measuredLuminance: 0.97)
        XCTAssertLessThan(CotypingGhostStyle.relativeLuminance(of: onLight), 0.2)
    }

    func testAverageLuminanceOfSolidImages() {
        XCTAssertGreaterThan(
            CotypingBackgroundSampler.averageLuminance(of: solidImage(white: 1)) ?? 0, 0.95)
        XCTAssertLessThan(
            CotypingBackgroundSampler.averageLuminance(of: solidImage(white: 0)) ?? 1, 0.05)
    }

    private func solidImage(white: CGFloat) -> CGImage {
        let ctx = CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(red: white, green: white, blue: white, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        return ctx.makeImage()!
    }
}
