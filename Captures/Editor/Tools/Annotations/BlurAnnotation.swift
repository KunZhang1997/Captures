import AppKit
import CoreImage

final class BlurAnnotation: Annotation {
    private static let ciContext = CIContext(options: [.cacheIntermediates: true])

    let id: UUID
    let type: ToolType = .blur
    var zOrder: Int = 0
    var isVisible: Bool = true

    let rect: CGRect
    let intensity: CGFloat
    let sourceImage: CGImage
    private var cachedProcessedImage: CGImage?

    var boundingRect: CGRect { rect }

    init(id: UUID = UUID(), rect: CGRect, intensity: CGFloat, sourceImage: CGImage) {
        self.id = id
        self.rect = rect
        self.intensity = intensity
        self.sourceImage = sourceImage
    }

    func render(in context: CGContext) {
        context.saveGState()
        defer { context.restoreGState() }

        let normalizedRect = rect.standardized.integral
        guard normalizedRect.width > 1, normalizedRect.height > 1 else { return }

        if cachedProcessedImage == nil {
            let imageBounds = CGRect(x: 0, y: 0, width: sourceImage.width, height: sourceImage.height)
            let cropRect = normalizedRect.intersection(imageBounds)
            guard cropRect.width > 1, cropRect.height > 1,
                  let croppedSource = sourceImage.cropping(to: cropRect) else { return }
            cachedProcessedImage = Self.processedCroppedImage(for: croppedSource, intensity: intensity)
        }
        guard let processedImage = cachedProcessedImage else { return }

        context.clip(to: normalizedRect)
        context.draw(processedImage, in: normalizedRect)
    }

    func duplicate() -> any Annotation {
        let copy = BlurAnnotation(
            id: id,
            rect: rect,
            intensity: intensity,
            sourceImage: sourceImage
        )
        copy.zOrder = zOrder
        copy.isVisible = isVisible
        return copy
    }

    private static func processedCroppedImage(for croppedSource: CGImage, intensity: CGFloat) -> CGImage? {
        let ciInput = CIImage(cgImage: croppedSource)
        guard let filter = CIFilter(name: "CIGaussianBlur") else { return nil }
        // A tight crop has transparent pixels beyond its extent. Clamp the
        // edge before blurring so the result stays opaque and cannot reveal
        // the original text around a redaction's border.
        filter.setValue(ciInput.clampedToExtent(), forKey: kCIInputImageKey)
        filter.setValue(max(0.5, intensity), forKey: kCIInputRadiusKey)

        guard let output = filter.outputImage?.cropped(to: ciInput.extent) else { return nil }
        guard let processedImage = Self.ciContext.createCGImage(output, from: ciInput.extent) else {
            return nil
        }

        return processedImage
    }
}
