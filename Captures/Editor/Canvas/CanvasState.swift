import AppKit
import CoreImage

/// The image-wide adjustments exposed by the compact native editor.  They are
/// deliberately kept separate from annotations: changing brightness or a
/// filter must not turn into a fake drawn object or disturb annotation
/// coordinates.
enum ImageFilterPreset: String, CaseIterable, Hashable {
    case original
    case mono
    case noir
    case tonal
    case fade
    case chrome
    case process
    case transfer
    case instant
    case sepia

    var displayName: String {
        switch self {
        case .original: return "Original"
        case .mono: return "Mono"
        case .noir: return "Noir"
        case .tonal: return "Tonal"
        case .fade: return "Fade"
        case .chrome: return "Chrome"
        case .process: return "Process"
        case .transfer: return "Transfer"
        case .instant: return "Instant"
        case .sepia: return "Sepia"
        }
    }

    var localizedDisplayName: String {
        Localization.string(displayName)
    }
}

struct RasterAdjustment: Equatable {
    var brightness: CGFloat = 0
    var contrast: CGFloat = 1
    var saturation: CGFloat = 1
    var filter: ImageFilterPreset = .original

    var isIdentity: Bool {
        brightness == 0 && contrast == 1 && saturation == 1 && filter == .original
    }
}

/// Export dimensions are intentionally independent from canvas zoom.  The
/// editor can stay comfortable to inspect while Copy and Save produce the
/// user-selected pixel size.
struct OutputResize: Equatable {
    var width: Int
    var height: Int
    var locksAspectRatio: Bool
}

@Observable
final class CanvasState {
    struct Snapshot {
        let baseImage: CGImage
        let rasterAdjustment: RasterAdjustment
        let outputResize: OutputResize?
        let annotations: [any Annotation]
        let selectedAnnotationID: UUID?
        let selectedAnnotationIDs: Set<UUID>
    }

    var baseImage: CGImage {
        didSet {
            cachedAdjustedImage = nil
            cachedAdjustment = nil
            filterPreviewCache.removeAll(keepingCapacity: true)
        }
    }
    var rasterAdjustment = RasterAdjustment() {
        didSet { cachedAdjustedImage = nil }
    }
    /// nil means export at the current image/crop's native pixel size.
    var outputResize: OutputResize?
    var annotations: [any Annotation] = []
    var isOCRProcessing: Bool
    /// The full text recognized from the screenshot. The OCR workspace binds
    /// directly to this value so a capture has a visible, editable result
    /// instead of requiring a second hidden selection-and-copy gesture.
    var recognizedText: String = ""
    var recognizedTextRegionCount: Int = 0
    var zoomLevel: CGFloat = 1.0
    var panOffset: CGPoint = .zero
    var selectedAnnotationID: UUID?
    var selectedAnnotationIDs: Set<UUID> = []
    let undoManager = UndoRedoManager()
    private var cachedAdjustedImage: CGImage?
    private var cachedAdjustment: RasterAdjustment?
    private var filterPreviewCache: [FilterPreviewCacheKey: CGImage] = [:]
    private static let imageContext = CIContext(options: [.cacheIntermediates: true])

    private struct FilterPreviewCacheKey: Hashable {
        let preset: ImageFilterPreset
        let brightness: CGFloat
        let contrast: CGFloat
        let saturation: CGFloat
        let width: Int
        let height: Int
    }

    var imageWidth: Int { baseImage.width }
    var imageHeight: Int { baseImage.height }
    var outputWidth: Int { Int(resolvedOutputSize(for: exportSourceSize).width.rounded()) }
    var outputHeight: Int { Int(resolvedOutputSize(for: exportSourceSize).height.rounded()) }
    var outputAspectRatioLocked: Bool { outputResize?.locksAspectRatio ?? true }

    init(image: CGImage) {
        self.baseImage = image
        self.isOCRProcessing = false
    }

    func addAnnotation(_ annotation: any Annotation) {
        annotations.append(annotation)
        undoManager.recordAdd(annotation: annotation, state: self)
    }

    func removeAnnotation(id: UUID) {
        if let idx = annotations.firstIndex(where: { $0.id == id }) {
            let annotation = annotations.remove(at: idx)
            selectedAnnotationIDs.remove(id)
            if selectedAnnotationID == id {
                selectedAnnotationID = selectedAnnotationIDs.first
            }
            undoManager.recordRemove(annotation: annotation, state: self)
        }
    }

    func selectedAnnotation() -> (any Annotation)? {
        guard let selectedAnnotationID else { return nil }
        return annotations.first(where: { $0.id == selectedAnnotationID })
    }

    func selectedAnnotations() -> [any Annotation] {
        let ids = effectiveSelectedAnnotationIDs()
        guard !ids.isEmpty else { return [] }
        return annotations.filter { ids.contains($0.id) }
    }

    func replaceAnnotation(_ updatedAnnotation: any Annotation, recordUndo: Bool = true) {
        guard let index = annotations.firstIndex(where: { $0.id == updatedAnnotation.id }) else { return }

        let previous = annotations[index].duplicate()
        annotations[index] = updatedAnnotation
        selectedAnnotationID = updatedAnnotation.id
        selectedAnnotationIDs.insert(updatedAnnotation.id)

        if recordUndo {
            undoManager.recordModify(
                oldAnnotation: previous,
                newAnnotation: updatedAnnotation.duplicate(),
                state: self
            )
        }
    }

    @discardableResult
    func bringAnnotationToFront(id: UUID, recordUndo: Bool = true) -> Bool {
        guard let index = annotations.firstIndex(where: { $0.id == id }) else { return false }

        if index == annotations.count - 1 {
            selectedAnnotationID = id
            selectedAnnotationIDs = [id]
            return true
        }

        let oldSnapshot = recordUndo ? makeSnapshot() : nil

        let annotation = annotations.remove(at: index)
        let maxZOrder = annotations.map(\.zOrder).max() ?? 0
        annotation.zOrder = max(maxZOrder + 1, annotation.zOrder + 1)
        annotations.append(annotation)
        selectedAnnotationID = id
        selectedAnnotationIDs = [id]

        if recordUndo, let oldSnapshot {
            let newSnapshot = makeSnapshot()
            undoManager.recordSnapshot(oldState: oldSnapshot, newState: newSnapshot, state: self)
        }

        return true
    }

    func makeSnapshot(excludingActiveCrop: Bool = false) -> Snapshot {
        let snapshotAnnotations = annotations.filter { annotation in
            !excludingActiveCrop || !(annotation is CropAnnotation)
        }
        let snapshotIDs = Set(snapshotAnnotations.map(\.id))
        return Snapshot(
            baseImage: baseImage,
            rasterAdjustment: rasterAdjustment,
            outputResize: outputResize,
            annotations: snapshotAnnotations.map { $0.duplicate() },
            selectedAnnotationID: selectedAnnotationID.flatMap { snapshotIDs.contains($0) ? $0 : nil },
            selectedAnnotationIDs: selectedAnnotationIDs.intersection(snapshotIDs)
        )
    }

    func restore(from snapshot: Snapshot) {
        baseImage = snapshot.baseImage
        rasterAdjustment = snapshot.rasterAdjustment
        outputResize = snapshot.outputResize
        annotations = snapshot.annotations.map { $0.duplicate() }
        selectedAnnotationID = snapshot.selectedAnnotationID
        selectedAnnotationIDs = snapshot.selectedAnnotationIDs
    }

    @discardableResult
    func applyActiveCrop() -> Bool {
        // Crop handles are transient UI state. Restoring them while the tool
        // has already switched away from Crop leaves an invisible crop that
        // renderFinalImage still applies after Undo.
        let oldSnapshot = makeSnapshot(excludingActiveCrop: true)
        let visibleBaseImage = renderedBaseImage()
        let imageBounds = CGRect(x: 0, y: 0, width: visibleBaseImage.width, height: visibleBaseImage.height)
        guard let cropRect = annotations
            .compactMap({ $0 as? CropAnnotation })
            .last?
            .rect
            .standardized
            .intersection(imageBounds),
            cropRect.width > 1,
            cropRect.height > 1 else {
            return false
        }

        let outputWidth = max(1, Int(cropRect.width.rounded()))
        let outputHeight = max(1, Int(cropRect.height.rounded()))

        guard let context = CGContext(
            data: nil,
            width: outputWidth,
            height: outputHeight,
            bitsPerComponent: visibleBaseImage.bitsPerComponent,
            bytesPerRow: 0,
            space: visibleBaseImage.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return false }

        // A crop must preserve transparent source pixels rather than letting
        // an implementation-defined bitmap background become opaque.
        context.clear(CGRect(x: 0, y: 0, width: outputWidth, height: outputHeight))
        context.saveGState()
        context.translateBy(x: -cropRect.minX, y: -cropRect.minY)
        context.draw(visibleBaseImage, in: imageBounds)
        context.restoreGState()

        guard let croppedBaseImage = context.makeImage() else { return false }

        let translation = CGPoint(x: -cropRect.minX, y: -cropRect.minY)
        var translatedAnnotations: [any Annotation] = []

        for annotation in annotations where !(annotation is CropAnnotation) {
            guard let translated = AnnotationGeometry.translated(annotation, by: translation) else { continue }
            translated.zOrder = annotation.zOrder
            translated.isVisible = annotation.isVisible

            if let blur = translated as? BlurAnnotation {
                let updated = BlurAnnotation(
                    id: blur.id,
                    rect: blur.rect,
                    intensity: blur.intensity,
                    sourceImage: croppedBaseImage
                )
                updated.zOrder = blur.zOrder
                updated.isVisible = blur.isVisible
                translatedAnnotations.append(updated)
                continue
            }

            if let pixelate = translated as? PixelateAnnotation {
                let updated = PixelateAnnotation(
                    id: pixelate.id,
                    rect: pixelate.rect,
                    blockSize: pixelate.blockSize,
                    sourceImage: croppedBaseImage
                )
                updated.zOrder = pixelate.zOrder
                updated.isVisible = pixelate.isVisible
                translatedAnnotations.append(updated)
                continue
            }

            translatedAnnotations.append(translated)
        }

        baseImage = croppedBaseImage
        rasterAdjustment = RasterAdjustment()
        annotations = translatedAnnotations
        selectedAnnotationID = nil
        selectedAnnotationIDs = []
        let newSnapshot = makeSnapshot()
        undoManager.recordSnapshot(oldState: oldSnapshot, newState: newSnapshot, state: self)
        return true
    }

    private func effectiveSelectedAnnotationIDs() -> Set<UUID> {
        if selectedAnnotationIDs.isEmpty, let selectedAnnotationID {
            return [selectedAnnotationID]
        }
        return selectedAnnotationIDs
    }

    func renderFinalImage(in region: CGRect? = nil) -> CGImage? {
        let visibleBaseImage = renderedBaseImage()
        let imageBounds = CGRect(x: 0, y: 0, width: visibleBaseImage.width, height: visibleBaseImage.height)
        let activeCropRect = annotations
            .compactMap { $0 as? CropAnnotation }
            .last?
            .rect
            .standardized
            .intersection(imageBounds)

        let exportRect: CGRect
        if let region {
            let clipped = region.standardized.intersection(imageBounds)
            guard !clipped.isNull, clipped.width > 0, clipped.height > 0 else { return nil }
            exportRect = clipped
        } else if let cropRect = activeCropRect, cropRect.width > 1, cropRect.height > 1 {
            exportRect = cropRect
        } else {
            exportRect = imageBounds
        }

        let outputWidth = max(1, Int(exportRect.width.rounded()))
        let outputHeight = max(1, Int(exportRect.height.rounded()))

        guard let context = CGContext(
            data: nil,
            width: outputWidth,
            height: outputHeight,
            bitsPerComponent: visibleBaseImage.bitsPerComponent,
            bytesPerRow: 0,
            space: visibleBaseImage.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        // The editor preview supplies a checkerboard separately. Keep the
        // document render transparent so Copy and PNG export retain alpha.
        context.clear(CGRect(x: 0, y: 0, width: outputWidth, height: outputHeight))
        // Render in annotation coordinate space; when crop is active, shift origin so crop rect becomes output bounds.
        context.saveGState()
        context.translateBy(x: -exportRect.minX, y: -exportRect.minY)
        context.draw(visibleBaseImage, in: imageBounds)

        // Crop is applied as final output bounds, not rendered as overlay pixels.
        for annotation in annotations where annotation.isVisible && !(annotation is CropAnnotation) {
            annotation.render(in: context)
        }
        context.restoreGState()

        guard let composedImage = context.makeImage() else { return nil }
        let targetSize = resolvedOutputSize(
            for: CGSize(width: composedImage.width, height: composedImage.height)
        )
        guard Int(targetSize.width.rounded()) != composedImage.width ||
                Int(targetSize.height.rounded()) != composedImage.height else {
            return composedImage
        }
        return ImageUtils.resize(composedImage, to: targetSize) ?? composedImage
    }

    func setOutputWidth(_ width: Int) {
        let source = exportSourceSize
        let current = outputResize ?? OutputResize(
            width: Int(source.width.rounded()),
            height: Int(source.height.rounded()),
            locksAspectRatio: true
        )
        let updatedWidth = max(1, width)
        let updatedHeight: Int
        if current.locksAspectRatio, source.width > 0 {
            updatedHeight = max(1, Int((CGFloat(updatedWidth) * source.height / source.width).rounded()))
        } else {
            updatedHeight = max(1, current.height)
        }
        updateOutputResize(OutputResize(
            width: updatedWidth,
            height: updatedHeight,
            locksAspectRatio: current.locksAspectRatio
        ))
    }

    func setOutputHeight(_ height: Int) {
        let source = exportSourceSize
        let current = outputResize ?? OutputResize(
            width: Int(source.width.rounded()),
            height: Int(source.height.rounded()),
            locksAspectRatio: true
        )
        let updatedHeight = max(1, height)
        let updatedWidth: Int
        if current.locksAspectRatio, source.height > 0 {
            updatedWidth = max(1, Int((CGFloat(updatedHeight) * source.width / source.height).rounded()))
        } else {
            updatedWidth = max(1, current.width)
        }
        updateOutputResize(OutputResize(
            width: updatedWidth,
            height: updatedHeight,
            locksAspectRatio: current.locksAspectRatio
        ))
    }

    func setOutputAspectRatioLocked(_ locked: Bool) {
        let source = exportSourceSize
        let current = outputResize ?? OutputResize(
            width: Int(source.width.rounded()),
            height: Int(source.height.rounded()),
            locksAspectRatio: locked
        )
        updateOutputResize(OutputResize(
            width: max(1, current.width),
            height: max(1, current.height),
            locksAspectRatio: locked
        ))
    }

    func resetOutputResize() {
        guard outputResize != nil else { return }
        let oldSnapshot = makeSnapshot()
        outputResize = nil
        undoManager.recordSnapshot(oldState: oldSnapshot, newState: makeSnapshot(), state: self)
    }

    /// Store an image-wide adjustment as an undoable document change.  The
    /// renderer is lazy, so sliders remain responsive even for long captures.
    func updateRasterAdjustment(_ update: (inout RasterAdjustment) -> Void) {
        let oldSnapshot = makeSnapshot()
        var next = rasterAdjustment
        update(&next)
        guard next != rasterAdjustment else { return }
        rasterAdjustment = next
        // Local blur/pixelation must sample the same adjusted image the user
        // sees.  Otherwise their region can reveal the unadjusted original.
        refreshEffectAnnotationSources(using: renderedBaseImage())
        undoManager.recordSnapshot(oldState: oldSnapshot, newState: makeSnapshot(), state: self)
    }

    /// Returns the working base image with the active non-destructive
    /// adjustments applied.  This is used by both the canvas and export path,
    /// so what users see is exactly what OCR, copy, and save consume.
    func renderedBaseImage() -> CGImage {
        guard !rasterAdjustment.isIdentity else { return baseImage }
        if let cachedAdjustedImage, cachedAdjustment == rasterAdjustment {
            return cachedAdjustedImage
        }

        let input = CIImage(cgImage: baseImage)
        let output = Self.applying(rasterAdjustment, to: input)
        let extent = CGRect(x: 0, y: 0, width: baseImage.width, height: baseImage.height)
        let rendered = Self.imageContext.createCGImage(output, from: extent) ?? baseImage
        cachedAdjustedImage = rendered
        cachedAdjustment = rasterAdjustment
        return rendered
    }

    /// Produces a small, aspect-fill preview from the real working image for
    /// the native filter gallery. The preview is deliberately separate from
    /// the document render cache: browsing cards must never mutate export
    /// state or annotation coordinates.
    func filterPreviewImage(
        for preset: ImageFilterPreset,
        pixelSize: CGSize = CGSize(width: 200, height: 72)
    ) -> CGImage {
        let width = max(1, Int(pixelSize.width.rounded()))
        let height = max(1, Int(pixelSize.height.rounded()))
        let key = FilterPreviewCacheKey(
            preset: preset,
            brightness: rasterAdjustment.brightness,
            contrast: rasterAdjustment.contrast,
            saturation: rasterAdjustment.saturation,
            width: width,
            height: height
        )
        if let cached = filterPreviewCache[key] {
            return cached
        }

        let source = CIImage(cgImage: baseImage)
        let scale = max(
            CGFloat(width) / max(source.extent.width, 1),
            CGFloat(height) / max(source.extent.height, 1)
        )
        let scaled = source.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let cropRect = CGRect(
            x: scaled.extent.midX - CGFloat(width) / 2,
            y: scaled.extent.midY - CGFloat(height) / 2,
            width: CGFloat(width),
            height: CGFloat(height)
        )
        let cropped = scaled.cropped(to: cropRect)
        var previewAdjustment = rasterAdjustment
        previewAdjustment.filter = preset
        let filtered = Self.applying(previewAdjustment, to: cropped)
        let rendered = Self.imageContext.createCGImage(filtered, from: cropRect) ?? baseImage

        // A few slider changes can create new preview keys. Bound this small
        // UI cache so long editing sessions cannot accumulate indefinitely.
        if filterPreviewCache.count >= ImageFilterPreset.allCases.count * 4 {
            filterPreviewCache.removeAll(keepingCapacity: true)
        }
        filterPreviewCache[key] = rendered
        return rendered
    }

    private static func applying(_ adjustment: RasterAdjustment, to input: CIImage) -> CIImage {
        var output = input
        if let controls = CIFilter(name: "CIColorControls") {
            controls.setValue(output, forKey: kCIInputImageKey)
            controls.setValue(adjustment.brightness, forKey: kCIInputBrightnessKey)
            controls.setValue(adjustment.contrast, forKey: kCIInputContrastKey)
            controls.setValue(adjustment.saturation, forKey: kCIInputSaturationKey)
            if let controlled = controls.outputImage {
                output = controlled
            }
        }

        let filterName: String?
        switch adjustment.filter {
        case .original:
            filterName = nil
        case .mono:
            filterName = "CIPhotoEffectMono"
        case .noir:
            filterName = "CIPhotoEffectNoir"
        case .tonal:
            filterName = "CIPhotoEffectTonal"
        case .fade:
            filterName = "CIPhotoEffectFade"
        case .chrome:
            filterName = "CIPhotoEffectChrome"
        case .process:
            filterName = "CIPhotoEffectProcess"
        case .transfer:
            filterName = "CIPhotoEffectTransfer"
        case .instant:
            filterName = "CIPhotoEffectInstant"
        case .sepia:
            filterName = "CISepiaTone"
        }

        if let filterName, let filter = CIFilter(name: filterName) {
            filter.setValue(output, forKey: kCIInputImageKey)
            if adjustment.filter == .sepia {
                filter.setValue(0.9, forKey: kCIInputIntensityKey)
            }
            if let filtered = filter.outputImage {
                output = filtered
            }
        }
        return output
    }

    private var exportSourceSize: CGSize {
        let imageBounds = CGRect(x: 0, y: 0, width: imageWidth, height: imageHeight)
        guard let cropRect = activeCropRect(in: imageBounds) else {
            return imageBounds.size
        }
        return cropRect.size
    }

    private func activeCropRect(in imageBounds: CGRect) -> CGRect? {
        guard let cropRect = annotations
            .compactMap({ $0 as? CropAnnotation })
            .last?
            .rect
            .standardized
            .intersection(imageBounds),
            cropRect.width > 1,
            cropRect.height > 1 else {
            return nil
        }
        return cropRect
    }

    private func resolvedOutputSize(for sourceSize: CGSize) -> CGSize {
        guard let outputResize else { return sourceSize }
        return CGSize(width: max(1, outputResize.width), height: max(1, outputResize.height))
    }

    private func updateOutputResize(_ next: OutputResize) {
        guard next != outputResize else { return }
        let oldSnapshot = makeSnapshot()
        outputResize = next
        undoManager.recordSnapshot(oldState: oldSnapshot, newState: makeSnapshot(), state: self)
    }

    private func refreshEffectAnnotationSources(using sourceImage: CGImage) {
        annotations = annotations.map { annotation in
            let refreshed: (any Annotation)?
            if let blur = annotation as? BlurAnnotation {
                refreshed = BlurAnnotation(
                    id: blur.id,
                    rect: blur.rect,
                    intensity: blur.intensity,
                    sourceImage: sourceImage
                )
            } else if let pixelate = annotation as? PixelateAnnotation {
                refreshed = PixelateAnnotation(
                    id: pixelate.id,
                    rect: pixelate.rect,
                    blockSize: pixelate.blockSize,
                    sourceImage: sourceImage
                )
            } else {
                refreshed = nil
            }

            guard let refreshed else { return annotation }
            refreshed.zOrder = annotation.zOrder
            refreshed.isVisible = annotation.isVisible
            return refreshed
        }
    }
}
