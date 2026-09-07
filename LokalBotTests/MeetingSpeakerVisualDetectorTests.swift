import CoreGraphics
import XCTest
@testable import LokalBot

/// Offline drawn shape fixtures. These prove detector rejection rules, not
/// compatibility with a live Meet layout, OCR accuracy, or voice accuracy.
final class MeetingSpeakerVisualDetectorTests: XCTestCase {
    private func tile(border: Bool, equalizer: Bool, light: Bool = false, solidBlue: Bool = false) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: 160, height: 100, bitsPerComponent: 8,
            bytesPerRow: 640, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let blue = CGColor(red: 0.2, green: 0.6, blue: 1, alpha: 1)
        context.setFillColor(solidBlue ? blue : CGColor(gray: light ? 1 : 0.12, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 160, height: 100))
        if border {
            context.setStrokeColor(blue)
            context.setLineWidth(4)
            context.stroke(CGRect(x: 2, y: 2, width: 156, height: 96))
        }
        if equalizer {
            context.setFillColor(blue)
            for (x, height) in [(10, 5), (16, 10), (22, 5)] {
                context.fill(CGRect(x: x, y: 10, width: 2, height: height))
            }
        }
        return try XCTUnwrap(context.makeImage())
    }

    func testBorderAndEqualizerContractWorksOnLightAndDarkCameraOffTiles() throws {
        for light in [true, false] {
            XCTAssertTrue(MeetingSpeakerFrameSource.hasActiveBorderAndEqualizer(try tile(border: true, equalizer: true, light: light)))
        }
    }

    func testPinnedSilentPresenterAndArbitraryBluePixelsAreInsufficient() throws {
        for image in [try tile(border: true, equalizer: false), try tile(border: false, equalizer: true),
                      try tile(border: false, equalizer: false, solidBlue: true), try tile(border: false, equalizer: false)] {
            XCTAssertFalse(MeetingSpeakerFrameSource.hasActiveBorderAndEqualizer(image))
        }
    }
}
