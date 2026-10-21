import AppKit

enum CaptureSelectionFrameStyle {
    static let edgeLineWidth: CGFloat = 0
    /// A fuller, rounded arm echoes the app icon without enlarging the crop.
    static let cornerLineWidth: CGFloat = 6
    /// A crisp one-point surround keeps either corner color visible without
    /// the fuzzy fringe produced by a shadow.
    static let cornerOutlineLineWidth: CGFloat = 8
    static let cornerLength: CGFloat = 18
    static let cornerRadius: CGFloat = 6
    /// Matches the outer silhouette of both strokes so the dimming cutout
    /// never exposes a competing square corner underneath.
    static let cutoutCornerRadius: CGFloat = cornerRadius + cornerOutlineLineWidth / 2

    static func cornerColor(for appearance: NSAppearance) -> NSColor {
        if isDark(appearance) {
            return NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.96)
        }
        return NSColor(
            srgbRed: 31.0 / 255.0,
            green: 31.0 / 255.0,
            blue: 33.0 / 255.0,
            alpha: 0.92
        )
    }

    static func cornerOutlineColor(for appearance: NSAppearance) -> NSColor {
        if isDark(appearance) {
            return NSColor(
                srgbRed: 31.0 / 255.0,
                green: 31.0 / 255.0,
                blue: 33.0 / 255.0,
                alpha: 0.92
            )
        }
        return NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.96)
    }

    private static func isDark(_ appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    static func cutoutPath(for rect: CGRect) -> CGPath {
        let radius = min(
            cutoutCornerRadius,
            max(0, min(rect.width, rect.height) / 2)
        )
        return CGPath(
            roundedRect: rect,
            cornerWidth: radius,
            cornerHeight: radius,
            transform: nil
        )
    }

    static func drawCorners(
        context: CGContext,
        rect: NSRect,
        appearance: NSAppearance
    ) {
        let inset = cornerLineWidth / 2
        let cornerRect = rect.insetBy(dx: inset, dy: inset)
        let length = min(
            cornerLength,
            max(0, min(cornerRect.width, cornerRect.height) / 2)
        )
        guard length > 0 else { return }
        let radius = min(cornerRadius, length)
        let halfPi = CGFloat.pi / 2
        let path = CGMutablePath()

        path.move(to: NSPoint(x: cornerRect.minX, y: cornerRect.minY + length))
        path.addLine(to: NSPoint(x: cornerRect.minX, y: cornerRect.minY + radius))
        path.addArc(
            center: NSPoint(x: cornerRect.minX + radius, y: cornerRect.minY + radius),
            radius: radius,
            startAngle: .pi,
            endAngle: .pi + halfPi,
            clockwise: false
        )
        path.addLine(to: NSPoint(x: cornerRect.minX + length, y: cornerRect.minY))

        path.move(to: NSPoint(x: cornerRect.maxX - length, y: cornerRect.minY))
        path.addLine(to: NSPoint(x: cornerRect.maxX - radius, y: cornerRect.minY))
        path.addArc(
            center: NSPoint(x: cornerRect.maxX - radius, y: cornerRect.minY + radius),
            radius: radius,
            startAngle: .pi + halfPi,
            endAngle: .pi * 2,
            clockwise: false
        )
        path.addLine(to: NSPoint(x: cornerRect.maxX, y: cornerRect.minY + length))

        path.move(to: NSPoint(x: cornerRect.maxX, y: cornerRect.maxY - length))
        path.addLine(to: NSPoint(x: cornerRect.maxX, y: cornerRect.maxY - radius))
        path.addArc(
            center: NSPoint(x: cornerRect.maxX - radius, y: cornerRect.maxY - radius),
            radius: radius,
            startAngle: 0,
            endAngle: halfPi,
            clockwise: false
        )
        path.addLine(to: NSPoint(x: cornerRect.maxX - length, y: cornerRect.maxY))

        path.move(to: NSPoint(x: cornerRect.minX + length, y: cornerRect.maxY))
        path.addLine(to: NSPoint(x: cornerRect.minX + radius, y: cornerRect.maxY))
        path.addArc(
            center: NSPoint(x: cornerRect.minX + radius, y: cornerRect.maxY - radius),
            radius: radius,
            startAngle: halfPi,
            endAngle: .pi,
            clockwise: false
        )
        path.addLine(to: NSPoint(x: cornerRect.minX, y: cornerRect.maxY - length))

        context.saveGState()
        context.setAllowsAntialiasing(true)
        context.setShouldAntialias(true)
        context.setLineDash(phase: 0, lengths: [])
        context.setLineCap(.round)
        context.setLineJoin(.round)

        context.setLineWidth(cornerOutlineLineWidth)
        context.setStrokeColor(cornerOutlineColor(for: appearance).cgColor)
        context.addPath(path)
        context.strokePath()

        context.setLineWidth(cornerLineWidth)
        context.setStrokeColor(cornerColor(for: appearance).cgColor)
        context.addPath(path)
        context.strokePath()
        context.restoreGState()
    }
}

final class AreaSelectorOverlayView: NSView {
    static let selectionEdgeLineWidth = CaptureSelectionFrameStyle.edgeLineWidth
    static let selectionCornerLineWidth = CaptureSelectionFrameStyle.cornerLineWidth
    static let selectionCornerOutlineLineWidth = CaptureSelectionFrameStyle.cornerOutlineLineWidth
    static let selectionCornerLength = CaptureSelectionFrameStyle.cornerLength
    static let selectionCornerRadius = CaptureSelectionFrameStyle.cornerRadius

    static func selectionAccentColor(for appearance: NSAppearance) -> NSColor {
        CaptureSelectionFrameStyle.cornerColor(for: appearance)
    }

    static func selectionOutlineColor(for appearance: NSAppearance) -> NSColor {
        CaptureSelectionFrameStyle.cornerOutlineColor(for: appearance)
    }

    var frozenImage: CGImage?
    var showsMagnifier = false

    private var selectionRect: NSRect?
    private(set) var windowHoverRect: NSRect?
    private var selectionPixelSize: CGSize?
    private(set) var heldSelectionDestinationRect: NSRect?
    private var magnifierView: MagnifierView?
    private var readyFeedbackDismissal: DispatchWorkItem?
    private(set) var isShowingReadyFeedback = false
    private(set) var isAwaitingResultChoice = false

    private let overlayColor = NSColor.black.withAlphaComponent(0.3)
    private let dimensionFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .medium)
    private let readyFeedbackFont = NSFont.systemFont(ofSize: 14, weight: .medium)
    private let magnifierInset: CGFloat = 16

    override var acceptsFirstResponder: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        if let frozenImage {
            context.draw(frozenImage, in: bounds)
        }

        // Entering region capture must be obvious even before the first drag.
        // The source image was captured before this view appears, so the dim
        // treatment communicates capture state without entering the result.
        context.setFillColor(overlayColor.cgColor)
        context.fill(bounds)

        if let rect = selectionRect ?? windowHoverRect {
            let isWindowHover = selectionRect == nil && windowHoverRect != nil
            // Reveal the source pixels at the current selection coordinates.
            // In the result-choice state this is still an editable crop area,
            // not a screenshot image being carried around the desktop.
            let cutoutPath = CaptureSelectionFrameStyle.cutoutPath(for: rect)
            if frozenImage != nil {
                context.saveGState()
                context.addPath(cutoutPath)
                context.clip()
                if let frozenImage {
                    context.draw(frozenImage, in: bounds)
                }
                context.restoreGState()
            } else {
                context.saveGState()
                context.addPath(cutoutPath)
                context.clip()
                context.clear(bounds)
                context.restoreGState()
            }

            let outlineRect = isAwaitingResultChoice
                ? (heldSelectionDestinationRect ?? rect)
                : rect
            CaptureSelectionFrameStyle.drawCorners(
                context: context,
                rect: outlineRect,
                appearance: effectiveAppearance
            )

            if !isAwaitingResultChoice && !isWindowHover {
                drawDimensionLabel(context: context, rect: rect)
            }
        } else {
            if isShowingReadyFeedback {
                drawReadyFeedback(context: context)
            }
        }
    }

    private func drawDimensionLabel(context: CGContext, rect: CGRect) {
        let scale = window?.backingScaleFactor ?? 2.0
        let w: Int
        let h: Int
        if let selectionPixelSize {
            w = Int(selectionPixelSize.width.rounded())
            h = Int(selectionPixelSize.height.rounded())
        } else {
            w = Int(rect.width * scale)
            h = Int(rect.height * scale)
        }
        let text = "\(w) × \(h)"

        let attrs: [NSAttributedString.Key: Any] = [
            .font: dimensionFont,
            .foregroundColor: NSColor.white,
        ]
        let size = (text as NSString).size(withAttributes: attrs)

        // Position below selection rect
        let labelX = rect.midX - size.width / 2
        let labelY = rect.minY - size.height - 8

        let bgRect = NSRect(x: labelX - 6, y: labelY - 2, width: size.width + 12, height: size.height + 4)
        context.setFillColor(NSColor.black.withAlphaComponent(0.7).cgColor)
        let bgPath = CGPath(roundedRect: bgRect, cornerWidth: 4, cornerHeight: 4, transform: nil)
        context.addPath(bgPath)
        context.fillPath()

        (text as NSString).draw(at: NSPoint(x: labelX, y: labelY), withAttributes: attrs)
    }

    private func drawReadyFeedback(context: CGContext) {
        let text = Localization.string("Drag to select")
        let attributes: [NSAttributedString.Key: Any] = [
            .font: readyFeedbackFont,
            .foregroundColor: NSColor.white,
        ]
        let textSize = (text as NSString).size(withAttributes: attributes)
        let backgroundRect = NSRect(
            x: bounds.midX - textSize.width / 2 - 13,
            y: bounds.midY - textSize.height / 2 - 8,
            width: textSize.width + 26,
            height: textSize.height + 16
        )
        context.setFillColor(NSColor.black.withAlphaComponent(0.58).cgColor)
        context.addPath(CGPath(
            roundedRect: backgroundRect,
            cornerWidth: CapturesWindowStyle.cornerRadius,
            cornerHeight: CapturesWindowStyle.cornerRadius,
            transform: nil
        ))
        context.fillPath()

        let textPoint = NSPoint(
            x: backgroundRect.midX - textSize.width / 2,
            y: backgroundRect.midY - textSize.height / 2
        )
        (text as NSString).draw(at: textPoint, withAttributes: attributes)
    }

    @discardableResult
    func clearSelection() -> Bool {
        let hadSelection = selectionRect != nil
        selectionRect = nil
        selectionPixelSize = nil
        heldSelectionDestinationRect = nil
        windowHoverRect = nil
        isAwaitingResultChoice = false
        if hadSelection {
            needsDisplay = true
        }
        return hadSelection
    }

    func setSelectionRect(_ rect: CGRect?, pixelSize: CGSize?) {
        let nextRect = rect
        guard selectionRect != nextRect || selectionPixelSize != pixelSize else { return }
        selectionRect = nextRect
        selectionPixelSize = pixelSize
        if nextRect != nil {
            windowHoverRect = nil
            dismissReadyFeedback()
        }
        needsDisplay = true
    }

    func setWindowHoverRect(_ rect: NSRect?) {
        guard !isAwaitingResultChoice, selectionRect == nil else {
            if windowHoverRect != nil {
                windowHoverRect = nil
                needsDisplay = true
            }
            return
        }
        guard windowHoverRect != rect else { return }
        windowHoverRect = rect
        if rect != nil {
            dismissReadyFeedback()
        }
        needsDisplay = true
    }

    /// Keeps the source screen and an editable crop frame visible while the
    /// user chooses Edit, Keep on Page, or Copy.
    func holdSelectionForResultChoice(
        frozenImage: CGImage?,
        visibleSelectionRect: NSRect?,
        selectionFrame: NSRect
    ) {
        if let frozenImage {
            self.frozenImage = frozenImage
        }
        selectionRect = visibleSelectionRect
        windowHoverRect = nil
        heldSelectionDestinationRect = selectionFrame
        showsMagnifier = false
        magnifierView?.isHidden = true
        isAwaitingResultChoice = true
        dismissReadyFeedback()
        needsDisplay = true
    }

    func updateHeldSelection(
        visibleSelectionRect: NSRect?,
        selectionFrame: NSRect
    ) {
        selectionRect = visibleSelectionRect
        heldSelectionDestinationRect = selectionFrame
        needsDisplay = true
    }

    /// The entry feedback is rendered only after the source snapshot is
    /// taken. It therefore makes the selection state clear without becoming
    /// part of the eventual captured image.
    func showReadyFeedback() {
        readyFeedbackDismissal?.cancel()
        isShowingReadyFeedback = true
        needsDisplay = true

        let dismissal = DispatchWorkItem { [weak self] in
            self?.dismissReadyFeedback()
        }
        readyFeedbackDismissal = dismissal
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.25, execute: dismissal)
    }

    func setMagnifierPointInScreen(_ point: NSPoint?) {
        guard let point else {
            magnifierView?.isHidden = true
            return
        }
        updateMagnifier(atScreenPoint: point)
    }

    private func updateMagnifier(atScreenPoint screenPoint: NSPoint) {
        guard showsMagnifier, let window else {
            magnifierView?.isHidden = true
            return
        }

        let magnifier = ensureMagnifierView()
        let point = NSPoint(
            x: screenPoint.x - window.frame.origin.x,
            y: screenPoint.y - window.frame.origin.y
        )

        if let screen = window.screen {
            magnifier.update(at: screenPoint, on: screen)
        }
        magnifier.isHidden = false

        var frame = magnifier.frame
        frame.origin = NSPoint(
            x: point.x + magnifierInset,
            y: point.y + magnifierInset
        )
        if frame.maxX > bounds.maxX {
            frame.origin.x = point.x - magnifierInset - frame.width
        }
        if frame.maxY > bounds.maxY {
            frame.origin.y = point.y - magnifierInset - frame.height
        }
        frame.origin.x = max(bounds.minX, min(frame.origin.x, bounds.maxX - frame.width))
        frame.origin.y = max(bounds.minY, min(frame.origin.y, bounds.maxY - frame.height))
        magnifier.frame = frame
    }

    private func ensureMagnifierView() -> MagnifierView {
        if let magnifierView {
            return magnifierView
        }
        let magnifier = MagnifierView(frame: .zero)
        magnifier.isHidden = true
        addSubview(magnifier)
        magnifierView = magnifier
        return magnifier
    }

    private func dismissReadyFeedback() {
        guard isShowingReadyFeedback else { return }
        readyFeedbackDismissal?.cancel()
        readyFeedbackDismissal = nil
        isShowingReadyFeedback = false
        needsDisplay = true
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .crosshair)
    }
}
