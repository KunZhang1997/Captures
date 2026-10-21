import AppKit
import CoreImage

final class PixelateAnnotation: Annotation {
    private static let ciContext = CIContext(options: [.cacheIntermediates: true])

    let id: UUID
    let type: ToolType = .pixelate
    var zOrder: Int = 0
    var isVisible: Bool = true

    let rect: CGRect
    let blockSize: CGFloat
    let sourceImage: CGImage
    private var cachedProcessedImage: CGImage?

    var boundingRect: CGRect { rect }

    init(id: UUID = UUID(), rect: CGRect, blockSize: CGFloat, sourceImage: CGImage) {
        self.id = id
        self.rect = rect
        self.blockSize = blockSize
        self.sourceImage = sourceImage
    }

    func render(in context: CGContext) {
        context.saveGState()
        defer { context.restoreGState() }

        let normalizedRect = rect.standardized.integral
        guard normalizedRect.width > 1, normalizedRect.height > 1 else { return }
        let imageBounds = CGRect(x: 0, y: 0, width: sourceImage.width, height: sourceImage.height)
        let visibleRect = normalizedRect.intersection(imageBounds)
        guard !visibleRect.isNull, visibleRect.width > 1, visibleRect.height > 1 else { return }

        if cachedProcessedImage == nil {
            // Annotation geometry is bottom-left; CGImage crops are top-left.
            let cropRect = CGRect(x: visibleRect.minX, y: CGFloat(sourceImage.height) - visibleRect.maxY,
                                  width: visibleRect.width, height: visibleRect.height)
            guard let croppedSource = sourceImage.cropping(to: cropRect) else { return }
            cachedProcessedImage = Self.processedCroppedImage(for: croppedSource, blockSize: blockSize)
        }
        guard let processedImage = cachedProcessedImage else { return }

        context.clip(to: visibleRect)
        context.draw(processedImage, in: visibleRect)
    }

    func duplicate() -> any Annotation {
        let copy = PixelateAnnotation(
            id: id,
            rect: rect,
            blockSize: blockSize,
            sourceImage: sourceImage
        )
        copy.zOrder = zOrder
        copy.isVisible = isVisible
        return copy
    }

    private static func processedCroppedImage(for croppedSource: CGImage, blockSize: CGFloat) -> CGImage? {
        let ciInput = CIImage(cgImage: croppedSource)
        guard let filter = CIFilter(name: "CIPixellate") else { return nil }
        filter.setValue(ciInput, forKey: kCIInputImageKey)
        filter.setValue(max(1, blockSize), forKey: kCIInputScaleKey)
        filter.setValue(CIVector(x: ciInput.extent.midX, y: ciInput.extent.midY), forKey: kCIInputCenterKey)

        guard let output = filter.outputImage?.cropped(to: ciInput.extent) else { return nil }
        guard let processedImage = Self.ciContext.createCGImage(output, from: ciInput.extent) else {
            return nil
        }

        return processedImage
    }
}
