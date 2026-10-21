import CoreGraphics
import XCTest
@testable import Captures

final class ScrollCaptureTests: XCTestCase {
    func testScrollMotionEstimatorDetectsVerticalShift() {
        let base = makePatternImage(width: 280, height: 720)
        let previous = crop(base, x: 0, y: 0, width: 280, height: 240)
        let current = crop(base, x: 0, y: 70, width: 280, height: 240)
        let estimator = ScrollMotionEstimator()

        guard let estimate = estimator.estimate(previous: previous, current: current) else {
            XCTFail("Expected a motion estimate")
            return
        }

        XCTAssertEqual(estimate.verticalShift, 70, accuracy: 8)
        XCTAssertGreaterThan(estimate.confidence, 0.45)
    }

    func testScrollMotionEstimatorIgnoresStickyHeaderBias() {
        let base = makePatternImage(width: 280, height: 720)
        let previous = overlayStickyHeader(
            crop(base, x: 0, y: 0, width: 280, height: 240),
            height: 32
        )
        let current = overlayStickyHeader(
            crop(base, x: 0, y: 64, width: 280, height: 240),
            height: 32
        )
        let estimator = ScrollMotionEstimator()

        guard let estimate = estimator.estimate(previous: previous, current: current) else {
            XCTFail("Expected a motion estimate")
            return
        }

        XCTAssertEqual(estimate.verticalShift, 64, accuracy: 8)
        XCTAssertGreaterThan(estimate.confidence, 0.40)
    }

    func testScrollMotionEstimatorRejectsAnUnchangedFrame() {
        let frame = makePatternImage(width: 280, height: 240)

        XCTAssertNil(
            ScrollMotionEstimator().estimate(previous: frame, current: frame),
            "An unchanged stream frame must not be stitched as a minimum scroll shift."
        )
    }

    func testScrollMotionEstimatorRejectsAmbiguousRepeatingContent() {
        let repeatingFrame = makeRepeatingPatternImage(
            width: 280,
            height: 240,
            period: 40
        )
        // Only a small marker moves. The repeating page itself is stationary,
        // so a periodic 40 px match must not be accepted as page movement.
        let previous = overlayMarker(repeatingFrame, y: 120)
        let current = overlayMarker(repeatingFrame, y: 80)
        let estimator = ScrollMotionEstimator(minShift: 6, maxShiftRatio: 0.78)

        XCTAssertNil(
            estimator.estimate(previous: previous, current: current),
            "A moving patch over repetitive content must not append another copy of the viewport."
        )
    }

    func testScrollMotionEstimatorRejectsReverseMovement() {
        let base = makePatternImage(width: 280, height: 720)
        let previous = crop(base, x: 0, y: 70, width: 280, height: 240)
        let current = crop(base, x: 0, y: 0, width: 280, height: 240)
        let estimator = ScrollMotionEstimator(minShift: 6, maxShiftRatio: 0.78)

        XCTAssertNil(
            estimator.estimate(previous: previous, current: current),
            "Reverse scrolling must not be misread as new downward content."
        )
    }

    func testScrollStitcherAppendsNewBottomStrip() {
        let base = makePatternImage(width: 220, height: 520)
        let first = crop(base, x: 0, y: 0, width: 220, height: 180)
        let second = crop(base, x: 0, y: 55, width: 220, height: 180)
        let stitcher = ScrollStitcher(initialImage: first)

        XCTAssertTrue(stitcher.append(frame: second, verticalShift: 55))
        XCTAssertEqual(stitcher.image.width, 220)
        XCTAssertEqual(stitcher.image.height, 235)
        XCTAssertEqual(stitcher.appendedHeight, 55)
    }

    func testScrollStitcherBuildsABoundedLivePreview() {
        let base = makePatternImage(width: 220, height: 520)
        let first = crop(base, x: 0, y: 0, width: 220, height: 180)
        let second = crop(base, x: 0, y: 55, width: 220, height: 180)
        let stitcher = ScrollStitcher(initialImage: first)

        XCTAssertTrue(stitcher.append(frame: second, verticalShift: 55))
        let preview = stitcher.previewImage(maxPixelWidth: 44, maxPixelHeight: 80)

        XCTAssertNotNil(preview)
        XCTAssertLessThanOrEqual(preview?.width ?? .max, 44)
        XCTAssertLessThanOrEqual(preview?.height ?? .max, 80)
        XCTAssertGreaterThan(preview?.height ?? 0, preview?.width ?? .max)
    }

    func testScrollStitcherRejectsNearDuplicateTailStrip() {
        let frame = makePatternImage(width: 280, height: 240)
        let previous = overlayMarker(frame, y: 30)
        let current = overlayMarker(frame, y: 34)
        let stitcher = ScrollStitcher(initialImage: previous)

        XCTAssertFalse(
            stitcher.append(frame: current, verticalShift: 40),
            "A tiny live update on a stationary viewport must not duplicate its tail."
        )
        XCTAssertEqual(stitcher.currentHeight, 240)
    }

    func testScrollStitcherRejectsContentAlreadyPresentHigherInPreviousViewport() {
        let base = makePatternImage(width: 280, height: 720)
        let previous = crop(base, x: 0, y: 80, width: 280, height: 240)
        let reverseFrame = crop(base, x: 0, y: 20, width: 280, height: 240)
        let stitcher = ScrollStitcher(initialImage: previous)

        XCTAssertFalse(
            stitcher.append(frame: reverseFrame, verticalShift: 60),
            "A proposed bottom strip that is already visible higher in the prior viewport must not be appended again."
        )
        XCTAssertEqual(stitcher.currentHeight, 240)
    }

    private func makePatternImage(width: Int, height: Int) -> CGImage {
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var data = [UInt8](repeating: 0, count: height * bytesPerRow)

        for y in 0..<height {
            for x in 0..<width {
                let index = y * bytesPerRow + (x * bytesPerPixel)
                let base = UInt8((y * 37 + x * 13) % 255)
                data[index] = base
                data[index + 1] = UInt8((y * 19 + x * 7) % 255)
                data[index + 2] = UInt8((y * 11 + x * 23) % 255)
                data[index + 3] = 255
            }
        }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let provider = CGDataProvider(data: Data(data) as CFData)!
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )!
    }

    private func makeRepeatingPatternImage(
        width: Int,
        height: Int,
        period: Int
    ) -> CGImage {
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var data = [UInt8](repeating: 0, count: height * bytesPerRow)

        for y in 0..<height {
            for x in 0..<width {
                let index = y * bytesPerRow + (x * bytesPerPixel)
                let row = y % max(1, period)
                data[index] = UInt8((row * 11 + x * 3) % 255)
                data[index + 1] = UInt8((row * 7 + x * 5) % 255)
                data[index + 2] = UInt8((row * 13 + x * 2) % 255)
                data[index + 3] = 255
            }
        }

        let provider = CGDataProvider(data: Data(data) as CFData)!
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )!
    }

    private func crop(_ image: CGImage, x: Int, y: Int, width: Int, height: Int) -> CGImage {
        image.cropping(to: CGRect(x: x, y: y, width: width, height: height))!
    }

    private func overlayStickyHeader(_ image: CGImage, height: Int) -> CGImage {
        guard let context = CGContext(
            data: nil,
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: image.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return image
        }

        // Draw upright (no CTM flip — CGContext.draw under a flipped transform
        // mirrors the image) and paint the header over the visual top rows,
        // which in CG bottom-left space is the high-y band.
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        context.setFillColor(CGColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1))
        context.fill(CGRect(x: 0, y: image.height - height, width: image.width, height: height))
        return context.makeImage() ?? image
    }

    private func overlayMarker(_ image: CGImage, y: Int) -> CGImage {
        guard let context = CGContext(
            data: nil,
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: image.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return image
        }

        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 112, y: y, width: 28, height: 12))
        return context.makeImage() ?? image
    }
}
