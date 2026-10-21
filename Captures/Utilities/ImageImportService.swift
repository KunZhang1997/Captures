import AppKit
import CoreImage
import ImageIO
import UniformTypeIdentifiers

enum ImageImportError: LocalizedError {
    case unreadable(URL)

    var errorDescription: String? {
        switch self {
        case .unreadable(let url):
            return String(
                format: Localization.string("Unable to open “%@”. Make sure it is a readable image file."),
                url.lastPathComponent
            )
        }
    }
}

struct ImportedImage {
    let image: CGImage
    let sourceScale: CGFloat
}

/// Converts a user-selected image file into the native editor's working
/// `CGImage`. ImageIO handles raster formats at their original pixel size;
/// AppKit is the fallback that rasterizes SVG and other image representations
/// that ImageIO does not decode directly.
enum ImageImportService {
    private static let svgType = UTType(filenameExtension: "svg")
    private static let maximumDimension: CGFloat = 100_000
    private static let maximumPixelCount: CGFloat = 64_000_000

    static var supportedContentTypes: [UTType] {
        var contentTypes: [UTType] = [.image]
        if let svgType, !svgType.conforms(to: .image) {
            contentTypes.append(svgType)
        }
        return contentTypes
    }

    static func loadImage(at url: URL) throws -> CGImage {
        try loadDocument(at: url).image
    }

    static func loadDocument(at url: URL) throws -> ImportedImage {
        guard url.isFileURL else { throw ImageImportError.unreadable(url) }

        let imageSourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        if let source = CGImageSourceCreateWithURL(url as CFURL, imageSourceOptions) {
            guard sourceDimensionsAreSafe(source) else {
                throw ImageImportError.unreadable(url)
            }
            if let image = loadOrientedImage(from: source),
               let normalizedImage = normalizeForEditor(image) {
                let appKitImage = NSImage(contentsOf: url)
                return ImportedImage(
                    image: normalizedImage,
                    sourceScale: inferredSourceScale(for: normalizedImage, appKitImage: appKitImage)
                )
            }
        }

        // NSImage provides macOS-native SVG rendering without routing the
        // document through the retired WebView editor. Its CGImage is a
        // raster working copy, which is the editor's existing document model.
        if let image = NSImage(contentsOf: url),
           let rasterizedImage = rasterizeForEditor(image) {
            return ImportedImage(image: rasterizedImage, sourceScale: 1)
        }

        throw ImageImportError.unreadable(url)
    }

    /// ImageIO's ordinary decoder leaves EXIF orientation as metadata, but the
    /// editor works with bare CGImage pixels. Apply that metadata explicitly
    /// without downsampling the source image.
    private static func loadOrientedImage(from source: CGImageSource) -> CGImage? {
        let options = [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, options) else {
            return nil
        }

        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let orientation = (properties?[kCGImagePropertyOrientation] as? NSNumber)?.int32Value ?? 1
        guard orientation != 1 else { return image }

        let orientedImage = CIImage(cgImage: image).oriented(forExifOrientation: orientation)
        let extent = orientedImage.extent.integral
        guard !extent.isEmpty else { return nil }
        let translatedImage = orientedImage.transformed(
            by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY)
        )
        return CIContext().createCGImage(
            translatedImage,
            from: CGRect(origin: .zero, size: extent.size)
        )
    }

    /// Canvas rendering uses an 8-bit premultiplied RGBA bitmap. Normalize at
    /// the import boundary so CMYK/gray/float source formats cannot make the
    /// editor's Copy, Save, or OCR render path return nil.
    private static func normalizeForEditor(_ image: CGImage) -> CGImage? {
        guard dimensionsAreSafe(width: CGFloat(image.width), height: CGFloat(image.height)),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil,
                  width: image.width,
                  height: image.height,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            return nil
        }

        context.clear(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage()
    }

    /// Vector/AppKit-only formats do not have a decodable ImageIO frame. Draw
    /// them at their intrinsic point dimensions instead of accepting a Retina
    /// backing representation whose pixel size varies with the test/display.
    private static func rasterizeForEditor(_ image: NSImage) -> CGImage? {
        let roundedWidth = image.size.width.rounded(.up)
        let roundedHeight = image.size.height.rounded(.up)
        guard dimensionsAreSafe(width: roundedWidth, height: roundedHeight) else {
            return nil
        }
        // Bounds validation above makes these conversions non-trapping.
        let width = Int(roundedWidth)
        let height = Int(roundedHeight)
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil,
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            return nil
        }

        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        image.draw(
            in: NSRect(x: 0, y: 0, width: width, height: height),
            from: .zero,
            operation: .copy,
            fraction: 1
        )
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage()
    }

    private static func sourceDimensionsAreSafe(_ source: CGImageSource) -> Bool {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue else {
            // Some decoders do not expose dimensions until they create the
            // frame; normalizeForEditor performs the same check afterward.
            return true
        }
        return dimensionsAreSafe(width: CGFloat(width), height: CGFloat(height))
    }

    private static func dimensionsAreSafe(width: CGFloat, height: CGFloat) -> Bool {
        guard width.isFinite, height.isFinite,
              width >= 1, height >= 1,
              width <= maximumDimension, height <= maximumDimension else {
            return false
        }
        return width <= maximumPixelCount / height
    }

    private static func inferredSourceScale(for image: CGImage, appKitImage: NSImage?) -> CGFloat {
        guard let appKitImage,
              appKitImage.size.width.isFinite,
              appKitImage.size.height.isFinite,
              appKitImage.size.width > 0,
              appKitImage.size.height > 0 else {
            return 1
        }

        let widthScale = CGFloat(image.width) / appKitImage.size.width
        let heightScale = CGFloat(image.height) / appKitImage.size.height
        let largestScale = max(widthScale, heightScale)
        guard widthScale.isFinite, heightScale.isFinite,
              widthScale >= 0.25, heightScale >= 0.25,
              largestScale <= 8,
              abs(widthScale - heightScale) <= largestScale * 0.05 else {
            return 1
        }
        return (widthScale + heightScale) / 2
    }
}
