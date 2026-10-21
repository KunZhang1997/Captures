import AppKit

final class CanvasNSView: NSView, NSTextFieldDelegate {
    var canvasState: CanvasState
    var toolManager: ToolManager
    /// The AppKit chrome owns the selected tool styling and the contextual
    /// parameter strip. Surface selection changes without replacing the
    /// drawing tool the person deliberately chose.
    var onEditingStateChange: (() -> Void)?
    /// Keep the compact zoom percentage in the editor chrome correct for
    /// trackpad, wheel, keyboard, and button-driven zoom alike.
    var onViewportChange: (() -> Void)?
    /// A held screenshot is a crop of a frozen desktop, not a zoomable editor.
    /// All display overlays share the same source-pixel coordinate system.
    var captureSelectionViewport: CGRect? {
        didSet { configureInitialViewportIfNeeded(); needsDisplay = true }
    }
    var onCaptureContentChange: (() -> Void)?

    func commitPendingEdits() {
        finishInlineTextEditing(commit: true)
    }

    /// The selection-stage overlay must leave keyboard delivery with this
    /// field while a quick text annotation is being composed.  It is exposed
    /// to the selection owner so it can avoid treating typing, Return, or
    /// Escape as screenshot-level shortcuts.
    var isInlineTextEditing: Bool {
        inlineTextEditSession != nil
    }

    private var trackingArea: NSTrackingArea?
    private var isDragging = false
    private var isPanning = false
    private var hasInitializedViewport = false
    private var viewportImageSize: CGSize = .zero
    private var wasTextSelectionToolActive = false
    private var wasCropToolActive = false
    private var hasCompletedTextRecognition = false
    private var textRecognitionTask: Task<Void, Never>?
    private var nextTextRecognitionRetryDate: Date = .distantPast
    private var recognizedTextBlocks: [OCRTextBlock] = []
    private var recognizedTextRectsByID: [UUID: CGRect] = [:]
    private var selectedTextBlockIDs: Set<UUID> = []
    private var selectedAnnotationIDs: Set<UUID> = []
    private var textSelectionStartPoint: CGPoint?
    private var textSelectionRect: CGRect?
    private var annotationMarqueeStartPoint: CGPoint?
    private var annotationMarqueeRect: CGRect?
    private var annotationMarqueeBaseSelection: Set<UUID> = []
    private var annotationMarqueeBasePrimaryID: UUID?
    private var contextMenuAnnotationID: UUID?
    private var hoverImagePoint: CGPoint?
    private var annotationEditSession: AnnotationEditSession?
    private var inlineTextEditSession: InlineTextEditSession?
    private var suppressInlineTextEndHandling = false

    private struct AnnotationEditSession {
        enum Mode {
            case move([UUID: any Annotation])
            case resize(AnnotationResizeHandle)
            case rotate(
                initialPointerAngle: CGFloat,
                originalRotationDegrees: CGFloat,
                center: CGPoint,
                anchorCorner: AnnotationResizeHandle
            )
        }

        let annotationID: UUID
        let originalAnnotation: any Annotation
        let originalFrame: CGRect
        let startPoint: CGPoint
        let mode: Mode
    }

    private struct SingleSelectionContext {
        let id: UUID
        let annotation: any Annotation
        let frame: CGRect
    }

    private struct InlineTextEditSession {
        let annotationID: UUID
        let textField: InlineTextField
        let isNewCaptureText: Bool
    }

    private final class InlineTextField: NSTextField {
        var onSubmit: (() -> Void)?
        var onCancel: (() -> Void)?

        /// AppKit keeps an unfinished Chinese/Japanese IME composition in the
        /// field editor as marked text. It is visible while the user is
        /// typing, but it is not content the annotation should own yet.
        var editingStringValue: String {
            (currentEditor() as? NSTextView)?.string ?? stringValue
        }

        /// Keep unfinished marked text out of the value used for committing,
        /// so clicking away cannot save pinyin as final annotation content.
        var committedStringValue: String {
            guard let editor = currentEditor() as? NSTextView,
                  editor.hasMarkedText() else {
                return stringValue
            }

            let value = editor.string as NSString
            let markedRange = editor.markedRange()
            guard markedRange.location != NSNotFound,
                  markedRange.location >= 0,
                  NSMaxRange(markedRange) <= value.length else {
                return stringValue
            }

            return value.replacingCharacters(in: markedRange, with: "")
        }

        override func keyDown(with event: NSEvent) {
            switch event.keyCode {
            case 36, 76: // Return / Enter
                onSubmit?()
            case 53: // Escape
                onCancel?()
            default:
                super.keyDown(with: event)
            }
        }
    }

    private enum HighlightStyle {
        case selected
        case preview

        var fallbackAlpha: CGFloat {
            switch self {
            case .selected: return 0.28
            case .preview: return 0.17
            }
        }
    }

    private static let selectedHighlightGradient = makeHighlightGradient(topAlpha: 0.08, bottomAlpha: 0.28)
    private static let previewHighlightGradient = makeHighlightGradient(topAlpha: 0.05, bottomAlpha: 0.17)

    init(canvasState: CanvasState, toolManager: ToolManager) {
        self.canvasState = canvasState
        self.toolManager = toolManager
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.white.cgColor
        layer?.masksToBounds = true
        viewportImageSize = CGSize(width: canvasState.imageWidth, height: canvasState.imageHeight)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    deinit {
        textRecognitionTask?.cancel()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func resetCursorRects() {
        let cursor: NSCursor
        switch toolManager.currentTool {
        case .textSelect: cursor = .arrow
        case .hand: cursor = .openHand
        case .text, .ocr: cursor = .iBeam
        default: cursor = .crosshair
        }
        addCursorRect(bounds, cursor: cursor)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        resetViewportIfImageChanged()
        configureInitialViewportIfNeeded()
        syncTextSelectionState()
        synchronizeAnnotationSelectionState()
        syncCropModeState()
        if toolManager.currentTool != .textSelect,
           toolManager.currentTool != .text,
           inlineTextEditSession != nil {
            finishInlineTextEditing(commit: true)
        }

        context.setFillColor(NSColor.controlBackgroundColor.cgColor)
        context.fill(bounds)

        context.saveGState()
        context.clip(to: bounds)
        context.translateBy(x: canvasState.panOffset.x, y: canvasState.panOffset.y)
        context.scaleBy(x: canvasState.zoomLevel, y: canvasState.zoomLevel)

        let imageRect = CGRect(x: 0, y: 0, width: canvasState.imageWidth, height: canvasState.imageHeight)
        // Keep the grid at a readable on-screen size while zooming. It lives
        // solely in this preview pass; CanvasState's export path still draws
        // the source image onto a transparent bitmap context.
        TransparencyGridRenderer.draw(
            in: context,
            rect: imageRect,
            tileSize: max(1, 12 / max(canvasState.zoomLevel, 0.01))
        )
        drawBaseAndAnnotations(in: context, imageRect: imageRect, clipRect: nil)
        if toolManager.currentTool == .crop, let cropRect = activeCropPreviewRect() {
            drawCropPreview(in: context, imageRect: imageRect, cropRect: cropRect)
        }

        if toolManager.currentTool == .ocr {
            drawTextSelectionOverlay(in: context, imageRect: imageRect)
        }

        if toolManager.currentTool != .ocr {
            drawAnnotationSelectionOverlay(in: context)
            drawAnnotationMarqueeOverlay(in: context)
        }

        context.restoreGState()
        updateInlineTextEditorFrameAndStyle()
        if captureSelectionViewport != nil {
            CaptureSelectionFrameStyle.drawCorners(context: context, rect: bounds, appearance: effectiveAppearance)
        }
    }

    override func layout() {
        super.layout()
        configureInitialViewportIfNeeded()
        syncTextSelectionState()
    }

    // MARK: - Coordinate Conversion

    private func imagePoint(from viewPoint: NSPoint) -> NSPoint {
        NSPoint(
            x: (viewPoint.x - canvasState.panOffset.x) / canvasState.zoomLevel,
            y: (viewPoint.y - canvasState.panOffset.y) / canvasState.zoomLevel
        )
    }

    private func clampedImagePoint(_ point: CGPoint) -> CGPoint {
        let maxX = CGFloat(canvasState.imageWidth)
        let maxY = CGFloat(canvasState.imageHeight)
        return CGPoint(
            x: min(max(point.x, 0), maxX),
            y: min(max(point.y, 0), maxY)
        )
    }

    private func imageBounds() -> CGRect {
        CGRect(x: 0, y: 0, width: canvasState.imageWidth, height: canvasState.imageHeight)
    }

    private func drawBaseAndAnnotations(
        in context: CGContext,
        imageRect: CGRect,
        clipRect: CGRect?
    ) {
        if let clipRect {
            context.saveGState()
            context.clip(to: clipRect)
        }

        context.draw(canvasState.renderedBaseImage(), in: imageRect)
        for annotation in canvasState.annotations where shouldRender(annotation) {
            annotation.render(in: context)
        }

        if clipRect != nil {
            context.restoreGState()
        }
    }

    /// Crop must remain a direct manipulation surface: the original image is
    /// still visible, the outside area is merely dimmed, and the white grid
    /// and handles show exactly what will remain.  Clipping the base image
    /// made the rest of the canvas look like an unexplained blank block.
    private func drawCropPreview(
        in context: CGContext,
        imageRect: CGRect,
        cropRect: CGRect
    ) {
        let zoom = max(canvasState.zoomLevel, 0.1)
        let borderWidth = max(1 / zoom, 0.75)
        let handleSize = 8 / zoom

        context.saveGState()

        let outside = CGMutablePath()
        outside.addRect(imageRect)
        outside.addRect(cropRect)
        context.addPath(outside)
        context.setFillColor(NSColor.black.withAlphaComponent(0.42).cgColor)
        context.drawPath(using: .eoFill)

        context.setStrokeColor(NSColor.white.withAlphaComponent(0.96).cgColor)
        context.setLineWidth(borderWidth)
        context.stroke(cropRect)

        context.setStrokeColor(NSColor.white.withAlphaComponent(0.42).cgColor)
        context.setLineWidth(max(0.75 / zoom, 0.45))
        for index in 1...2 {
            let x = cropRect.minX + cropRect.width * CGFloat(index) / 3
            context.move(to: CGPoint(x: x, y: cropRect.minY))
            context.addLine(to: CGPoint(x: x, y: cropRect.maxY))
            context.strokePath()

            let y = cropRect.minY + cropRect.height * CGFloat(index) / 3
            context.move(to: CGPoint(x: cropRect.minX, y: y))
            context.addLine(to: CGPoint(x: cropRect.maxX, y: y))
            context.strokePath()
        }

        context.setFillColor(NSColor.white.cgColor)
        for corner in [
            CGPoint(x: cropRect.minX, y: cropRect.minY),
            CGPoint(x: cropRect.maxX, y: cropRect.minY),
            CGPoint(x: cropRect.minX, y: cropRect.maxY),
            CGPoint(x: cropRect.maxX, y: cropRect.maxY),
        ] {
            context.fill(CGRect(
                x: corner.x - handleSize / 2,
                y: corner.y - handleSize / 2,
                width: handleSize,
                height: handleSize
            ))
        }

        context.restoreGState()
    }

    private func shouldRender(_ annotation: any Annotation) -> Bool {
        guard annotation.isVisible else { return false }
        if annotation is CropAnnotation { return false }
        if let inlineSession = inlineTextEditSession,
           inlineSession.annotationID == annotation.id {
            return false
        }
        return true
    }

    // MARK: - Mouse Events

    /// Receives a pointer stream that originated in the selection overlay.
    ///
    /// The overlay sits above this canvas to block interaction with the
    /// captured application, so it has to normalize and forward mouse events
    /// here.  Focus may move to the canvas for a press, but must never be
    /// reclaimed on the following release: a Text press creates an inline
    /// NSTextField, and reclaiming focus on mouse-up immediately ends that
    /// edit before the user can type.
    func handleQuickMarkupPointerEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            mouseDown(with: event)
        case .leftMouseDragged:
            mouseDragged(with: event)
        case .leftMouseUp:
            mouseUp(with: event)
        case .mouseMoved:
            mouseMoved(with: event)
        default:
            break
        }
    }

    override func mouseDown(with event: NSEvent) {
        defer { onCaptureContentChange?() }
        let viewPoint = convert(event.locationInWindow, from: nil)
        hoverImagePoint = imagePoint(from: viewPoint)
        synchronizeAnnotationSelectionState()

        if let session = inlineTextEditSession,
           !session.textField.frame.contains(viewPoint) {
            finishInlineTextEditing(commit: true)
        }
        window?.makeFirstResponder(self)

        if captureSelectionViewport == nil,
           event.modifierFlags.contains(.option) || toolManager.currentTool == .hand {
            isPanning = true
            return
        }

        if toolManager.currentTool == .crop {
            let point = imagePoint(from: viewPoint)
            let cropAnnotation = ensureActiveCropAnnotation()
            setSelectedAnnotationIDs([cropAnnotation.id], primaryID: cropAnnotation.id)
            let hitCrop: (any Annotation)? = cropAnnotation.hitTest(point: point) ? cropAnnotation : nil
            _ = beginAnnotationInteraction(at: point, hitAnnotation: hitCrop)
            needsDisplay = true
            return
        }

        // Overlapping strokes are common in annotation and retouching. A
        // hit on an existing object must not turn the next stroke into a
        // move/resize gesture or silently replace the active drawing tool.
        // Existing objects remain editable through the explicit Mouse tool.
        if toolManager.currentTool == .text,
           event.clickCount >= 2,
           let textAnnotation = topmostAnnotation(at: imagePoint(from: viewPoint)) as? TextAnnotation {
            setSelectedAnnotationIDs([textAnnotation.id], primaryID: textAnnotation.id)
            beginInlineTextEditing(for: textAnnotation)
            needsDisplay = true
            return
        }

        if toolManager.currentTool == .textSelect {
            let point = imagePoint(from: viewPoint)
            let hitAnnotation = topmostAnnotation(at: point)
            let isToggleSelecting = event.modifierFlags.contains(.shift) || event.modifierFlags.contains(.command)

            if event.clickCount >= 2,
               !isToggleSelecting,
               let textAnnotation = hitAnnotation as? TextAnnotation {
                setSelectedAnnotationIDs([textAnnotation.id], primaryID: textAnnotation.id)
                beginInlineTextEditing(for: textAnnotation)
                needsDisplay = true
                return
            }

            if isToggleSelecting, let hitAnnotation {
                toggleSelection(for: hitAnnotation.id)
                clearTextSelection()
                needsDisplay = true
                return
            }

            if let hitAnnotation {
                if selectedAnnotationIDs.isEmpty || !selectedAnnotationIDs.contains(hitAnnotation.id) {
                    setSelectedAnnotationIDs([hitAnnotation.id], primaryID: hitAnnotation.id)
                } else {
                    canvasState.selectedAnnotationID = hitAnnotation.id
                    canvasState.selectedAnnotationIDs = selectedAnnotationIDs
                }
            }

            if beginAnnotationInteraction(at: point, hitAnnotation: hitAnnotation) {
                clearTextSelection()
                needsDisplay = true
                return
            }

            if hitAnnotation == nil {
                beginAnnotationMarqueeSelection(at: point, additive: isToggleSelecting)
                clearTextSelection()
                needsDisplay = true
                return
            }

            setSelectedAnnotationIDs([], primaryID: nil)
            needsDisplay = true
            return
        }

        if toolManager.currentTool == .ocr {
            let point = clampedImagePoint(imagePoint(from: viewPoint))
            beginTextSelection(at: point)
            needsDisplay = true
            return
        }

        isDragging = true
        let point = imagePoint(from: viewPoint)
        toolManager.mouseDown(at: point, canvasState: canvasState)

        if toolManager.currentTool == .text || toolManager.currentTool == .counter,
           let selectedID = canvasState.selectedAnnotationID {
            setSelectedAnnotationIDs([selectedID], primaryID: selectedID)
        }

        if toolManager.currentTool == .text {
            if let textAnnotation = canvasState.selectedAnnotation() as? TextAnnotation {
                beginInlineTextEditing(for: textAnnotation, isNewCaptureText: toolManager.defersTextUndoUntilCommit)
            }
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        defer { onCaptureContentChange?() }
        let viewPoint = convert(event.locationInWindow, from: nil)
        hoverImagePoint = imagePoint(from: viewPoint)

        if isPanning {
            canvasState.panOffset.x += event.deltaX
            canvasState.panOffset.y -= event.deltaY
            clampViewportPanOffset()
            updateInlineTextEditorFrameAndStyle()
            needsDisplay = true
            return
        }

        if toolManager.currentTool == .textSelect {
            let point = imagePoint(from: viewPoint)
            if updateAnnotationInteractionIfNeeded(at: point) { return }

            if annotationMarqueeStartPoint != nil {
                updateAnnotationMarqueeSelection(to: point)
                needsDisplay = true
                return
            }

            return
        }

        if toolManager.currentTool == .crop {
            let point = imagePoint(from: viewPoint)
            _ = updateAnnotationInteractionIfNeeded(at: point)
            return
        }

        if toolManager.currentTool == .ocr {
            let point = clampedImagePoint(imagePoint(from: viewPoint))
            updateTextSelection(to: point)
            needsDisplay = true
            return
        }

        let point = imagePoint(from: viewPoint)
        toolManager.mouseDragged(to: point, canvasState: canvasState)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer { onCaptureContentChange?() }
        if isPanning {
            isPanning = false
            return
        }

        let viewPoint = convert(event.locationInWindow, from: nil)
        hoverImagePoint = imagePoint(from: viewPoint)

        if toolManager.currentTool == .textSelect {
            let point = imagePoint(from: viewPoint)
            if endAnnotationInteractionIfNeeded(at: point) { return }

            if annotationMarqueeStartPoint != nil {
                endAnnotationMarqueeSelection(at: point)
                needsDisplay = true
                return
            }

            needsDisplay = true
            return
        }

        if toolManager.currentTool == .crop {
            let point = imagePoint(from: viewPoint)
            _ = endAnnotationInteractionIfNeeded(at: point)
            return
        }

        if toolManager.currentTool == .ocr {
            let point = clampedImagePoint(imagePoint(from: viewPoint))
            endTextSelection(at: point)
            needsDisplay = true
            return
        }

        let point = imagePoint(from: viewPoint)
        let committedAnnotationID = toolManager.mouseUp(at: point, canvasState: canvasState)
        if let committedAnnotationID {
            setSelectedAnnotationIDs([committedAnnotationID], primaryID: committedAnnotationID)
        } else if let selectedID = canvasState.selectedAnnotationID {
            setSelectedAnnotationIDs([selectedID], primaryID: selectedID)
        }
        isDragging = false
        needsDisplay = true
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        let viewPoint = convert(event.locationInWindow, from: nil)
        hoverImagePoint = imagePoint(from: viewPoint)
        guard toolManager.currentTool == .textSelect else { return }
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        hoverImagePoint = nil
        guard toolManager.currentTool == .textSelect else { return }
        needsDisplay = true
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard toolManager.currentTool != .ocr else {
            return nil
        }

        let viewPoint = convert(event.locationInWindow, from: nil)
        let point = imagePoint(from: viewPoint)
        guard let hitAnnotation = topmostAnnotation(at: point),
              !(hitAnnotation is CropAnnotation) else {
            contextMenuAnnotationID = nil
            return nil
        }

        contextMenuAnnotationID = hitAnnotation.id
        if !selectedAnnotationIDs.contains(hitAnnotation.id) {
            setSelectedAnnotationIDs([hitAnnotation.id], primaryID: hitAnnotation.id)
            needsDisplay = true
        }

        let menu = NSMenu(title: "Annotation")
        let bringToFront = NSMenuItem(
            title: "Bring to Front",
            action: #selector(bringContextMenuAnnotationToFront),
            keyEquivalent: ""
        )
        bringToFront.target = self
        if canvasState.annotations.last?.id == hitAnnotation.id {
            bringToFront.isEnabled = false
        }
        menu.addItem(bringToFront)
        return menu
    }

    override func scrollWheel(with event: NSEvent) {
        guard captureSelectionViewport == nil else { return }
        // A trackpad emits precise scrolling deltas for ordinary two-finger
        // scroll.  Treat it as panning so a tall capture can actually be
        // read; pinch and Cmd+wheel remain the two deliberate zoom gestures.
        if event.modifierFlags.contains(.command) {
            let delta = event.scrollingDeltaY * 0.01
            let viewPoint = convert(event.locationInWindow, from: nil)
            zoom(by: 1 + delta, around: viewPoint)
        } else {
            canvasState.panOffset.x += event.scrollingDeltaX
            canvasState.panOffset.y -= event.scrollingDeltaY
            clampViewportPanOffset()
        }
        updateInlineTextEditorFrameAndStyle()
        onViewportChange?()
        needsDisplay = true
    }

    override func magnify(with event: NSEvent) {
        guard captureSelectionViewport == nil else { return }
        let viewPoint = convert(event.locationInWindow, from: nil)
        zoom(by: 1 + event.magnification, around: viewPoint)
        updateInlineTextEditorFrameAndStyle()
        onViewportChange?()
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        defer { onCaptureContentChange?() }
        if captureSelectionViewport != nil, event.modifierFlags.contains(.command),
           ["=", "+", "-", "_", "0"].contains(event.charactersIgnoringModifiers ?? "") { return }
        if event.keyCode == 53 { // Escape
            if discardAreaSelectionIfPresent() {
                needsDisplay = true
                return
            }
            super.keyDown(with: event)
            return
        }

        if toolManager.currentTool == .crop,
           (event.keyCode == 36 || event.keyCode == 76) {
            if canvasState.applyActiveCrop() {
                setSelectedAnnotationIDs([], primaryID: nil)
                annotationEditSession = nil
                toolManager.currentTool = .textSelect
                onEditingStateChange?()
                needsDisplay = true
            }
            return
        }

        if toolManager.currentTool != .ocr,
           (event.keyCode == 51 || event.keyCode == 117) {
            synchronizeAnnotationSelectionState()
            let selectedIDs = selectedAnnotationIDs.isEmpty
                ? (canvasState.selectedAnnotationID.map { Set([$0]) } ?? [])
                : selectedAnnotationIDs
            guard !selectedIDs.isEmpty else {
                super.keyDown(with: event)
                return
            }

            for selectedID in selectedIDs {
                canvasState.removeAnnotation(id: selectedID)
            }
            setSelectedAnnotationIDs([], primaryID: nil)
            annotationEditSession = nil
            needsDisplay = true
            return
        }

        guard event.modifierFlags.contains(.command),
              let characters = event.charactersIgnoringModifiers else {
            super.keyDown(with: event)
            return
        }

        let handled: Bool
        switch characters {
        case "=", "+":
            zoom(by: 1.12, around: CGPoint(x: bounds.midX, y: bounds.midY))
            handled = true
        case "-", "_":
            zoom(by: 1 / 1.12, around: CGPoint(x: bounds.midX, y: bounds.midY))
            handled = true
        case "0":
            configureViewportToFit()
            handled = true
        case "z":
            if event.modifierFlags.contains(.shift) {
                canvasState.undoManager.redo(state: canvasState)
            } else {
                canvasState.undoManager.undo(state: canvasState)
            }
            handled = true
        case "u":
            if event.modifierFlags.contains(.shift) {
                canvasState.undoManager.redo(state: canvasState)
            } else {
                canvasState.undoManager.undo(state: canvasState)
            }
            handled = true
        case "a":
            if toolManager.currentTool == .ocr {
                selectAllRecognizedText()
                handled = true
            } else {
                handled = false
            }
        case "c":
            if toolManager.currentTool == .ocr {
                handled = copySelectedTextToPasteboard()
            } else {
                handled = false
            }
        default:
            handled = false
        }

        if handled {
            onViewportChange?()
            needsDisplay = true
        } else {
            super.keyDown(with: event)
        }
    }

    @objc private func bringContextMenuAnnotationToFront() {
        guard let annotationID = contextMenuAnnotationID else { return }
        defer { contextMenuAnnotationID = nil }

        guard canvasState.bringAnnotationToFront(id: annotationID) else { return }
        setSelectedAnnotationIDs([annotationID], primaryID: annotationID)
        annotationEditSession = nil
        needsDisplay = true
    }

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.acceptsMouseMovedEvents = true
        window?.makeFirstResponder(self)
        resetViewportIfImageChanged()
        configureInitialViewportIfNeeded()
        syncCropModeState()
    }

    private func resetViewportIfImageChanged() {
        let imageSize = CGSize(width: canvasState.imageWidth, height: canvasState.imageHeight)
        if imageSize != viewportImageSize {
            viewportImageSize = imageSize
            hasInitializedViewport = false
            resetTextRecognitionState(cancelTask: true)
        }
    }

    private func configureInitialViewportIfNeeded() {
        if let region = captureSelectionViewport, region.width > 0, bounds.width > 0 {
            hasInitializedViewport = true
            canvasState.zoomLevel = bounds.width / region.width
            canvasState.panOffset = CGPoint(x: -region.minX * canvasState.zoomLevel,
                                           y: -region.minY * canvasState.zoomLevel)
            updateInlineTextEditorFrameAndStyle()
            return
        }
        guard !hasInitializedViewport else { return }
        hasInitializedViewport = configureViewportToActualSizeOrFit()
        if hasInitializedViewport {
            onViewportChange?()
        }
    }

    /// The editor owns compact, native zoom controls in its command bar.  The
    /// canvas keeps the viewport math here so those controls behave exactly
    /// like trackpad and keyboard zoom.
    func zoomIn() {
        zoom(by: 1.12, around: CGPoint(x: bounds.midX, y: bounds.midY))
        updateInlineTextEditorFrameAndStyle()
        onViewportChange?()
        needsDisplay = true
    }

    func zoomOut() {
        zoom(by: 1 / 1.12, around: CGPoint(x: bounds.midX, y: bounds.midY))
        updateInlineTextEditorFrameAndStyle()
        onViewportChange?()
        needsDisplay = true
    }

    func fitToCanvas() {
        hasInitializedViewport = configureViewportToFit()
        updateInlineTextEditorFrameAndStyle()
        onViewportChange?()
        needsDisplay = true
    }

    /// Open captures at 100% whenever their natural size fits the editor.
    /// Unlike the explicit Fit command, this initial policy never enlarges a
    /// small image merely to fill spare workspace.
    func showAtActualSizeOrFit() {
        hasInitializedViewport = configureViewportToActualSizeOrFit()
        updateInlineTextEditorFrameAndStyle()
        onViewportChange?()
        needsDisplay = true
    }

    /// Scale relative to the previous window viewport, preserving a user's
    /// explicit zoom and the image aspect ratio. Chrome-only layout changes
    /// do not call this method. Tall captures keep the current reading line
    /// near the top while their width follows the resized window.
    func resizeViewport(from previousSize: CGSize) {
        guard hasInitializedViewport,
              previousSize.width > 0, previousSize.height > 0,
              bounds.width > 0, bounds.height > 0 else { return }
        let oldZoom = canvasState.zoomLevel
        guard oldZoom > 0 else { return }
        let factor = viewportFitScale(for: bounds.size) / viewportFitScale(for: previousSize)
        let newZoom = min(10, max(0.1, oldZoom * factor))
        let isLongCapture = CGFloat(canvasState.imageHeight) / CGFloat(canvasState.imageWidth) >= 1.35
        let oldAnchor = CGPoint(
            x: previousSize.width / 2,
            y: isLongCapture ? previousSize.height - AnnotationEditorLayout.canvasPadding : previousSize.height / 2
        )
        let newAnchor = CGPoint(
            x: bounds.midX,
            y: isLongCapture ? bounds.height - AnnotationEditorLayout.canvasPadding : bounds.midY
        )
        canvasState.panOffset = CGPoint(
            x: newAnchor.x - (oldAnchor.x - canvasState.panOffset.x) * newZoom / oldZoom,
            y: newAnchor.y - (oldAnchor.y - canvasState.panOffset.y) * newZoom / oldZoom
        )
        canvasState.zoomLevel = newZoom
        clampViewportPanOffset()
        updateInlineTextEditorFrameAndStyle()
        onViewportChange?()
        needsDisplay = true
    }

    func zoomToActualSize() {
        let currentZoom = canvasState.zoomLevel
        guard currentZoom > 0 else { return }
        zoom(
            by: 1 / currentZoom,
            around: CGPoint(x: bounds.midX, y: bounds.midY)
        )
        updateInlineTextEditorFrameAndStyle()
        onViewportChange?()
        needsDisplay = true
    }

    var zoomPercentage: Int {
        Int((canvasState.zoomLevel * 100).rounded())
    }

    @discardableResult
    private func configureViewportToFit() -> Bool {
        configureViewport(preferActualSize: false)
    }

    @discardableResult
    private func configureViewportToActualSizeOrFit() -> Bool {
        configureViewport(preferActualSize: true)
    }

    @discardableResult
    private func configureViewport(preferActualSize: Bool) -> Bool {
        guard bounds.width > 0, bounds.height > 0 else { return false }
        let imageWidth = CGFloat(canvasState.imageWidth)
        let imageHeight = CGFloat(canvasState.imageHeight)
        guard imageWidth > 0, imageHeight > 0 else { return false }

        let padding = AnnotationEditorLayout.canvasPadding
        let isLongCapture = imageHeight / imageWidth >= 1.35
        // Whole-page fit makes a long capture a hairline in a normal editor
        // window.  Start long captures at fit-width and put their top edge in
        // view; two-finger scroll then reads the rest of the capture.  Normal
        // screenshots still fit as a complete page.
        let requestedScale = viewportFitScale(for: bounds.size)
        let preferredScale = preferActualSize ? min(1, requestedScale) : requestedScale
        let fitZoom = min(10.0, max(0.1, preferredScale))
        canvasState.zoomLevel = fitZoom

        let renderedWidth = imageWidth * fitZoom
        let renderedHeight = imageHeight * fitZoom
        canvasState.panOffset = CGPoint(
            x: (bounds.width - renderedWidth) / 2,
            y: isLongCapture && renderedHeight > bounds.height - padding
                ? bounds.height - padding - renderedHeight
                : (bounds.height - renderedHeight) / 2
        )
        return true
    }

    private func viewportFitScale(for size: CGSize) -> CGFloat {
        let width = max(1, CGFloat(canvasState.imageWidth))
        let height = max(1, CGFloat(canvasState.imageHeight))
        let padding = AnnotationEditorLayout.canvasPadding
        let widthScale = max(0.1, (size.width - padding) / width)
        let heightScale = max(0.1, (size.height - padding) / height)
        return height / width >= 1.35 ? widthScale : min(widthScale, heightScale)
    }

    private func zoom(by factor: CGFloat, around viewPoint: CGPoint) {
        let oldZoom = canvasState.zoomLevel
        let newZoom = max(0.1, min(10.0, oldZoom * factor))
        guard newZoom != oldZoom else { return }

        let scale = newZoom / oldZoom
        canvasState.zoomLevel = newZoom
        canvasState.panOffset.x = viewPoint.x - (viewPoint.x - canvasState.panOffset.x) * scale
        canvasState.panOffset.y = viewPoint.y - (viewPoint.y - canvasState.panOffset.y) * scale
        clampViewportPanOffset()
    }

    /// Keep at least one image edge in view while panning.  Without this a
    /// trackpad gesture can leave a completely blank canvas, making a capture
    /// appear to have vanished until the user discovers the Fit button.
    private func clampViewportPanOffset() {
        guard bounds.width > 0, bounds.height > 0 else { return }

        let renderedWidth = CGFloat(canvasState.imageWidth) * canvasState.zoomLevel
        let renderedHeight = CGFloat(canvasState.imageHeight) * canvasState.zoomLevel
        guard renderedWidth > 0, renderedHeight > 0 else { return }

        let margin: CGFloat = 12
        if renderedWidth <= bounds.width - (margin * 2) {
            canvasState.panOffset.x = (bounds.width - renderedWidth) / 2
        } else {
            let minX = bounds.width - margin - renderedWidth
            let maxX = margin
            canvasState.panOffset.x = min(max(canvasState.panOffset.x, minX), maxX)
        }

        if renderedHeight <= bounds.height - (margin * 2) {
            canvasState.panOffset.y = (bounds.height - renderedHeight) / 2
        } else {
            let minY = bounds.height - margin - renderedHeight
            let maxY = margin
            canvasState.panOffset.y = min(max(canvasState.panOffset.y, minY), maxY)
        }
    }

    // MARK: - Annotation Editing

    private func beginAnnotationInteraction(
        at point: CGPoint,
        hitAnnotation: (any Annotation)? = nil
    ) -> Bool {
        synchronizeAnnotationSelectionState()
        let activeSelection = selectedAnnotationIDs

        if let singleSelection = singleSelectionContext() {
            if beginRotationInteractionIfNeeded(at: point, selection: singleSelection) {
                return true
            }
            if beginResizeInteractionIfNeeded(at: point, selection: singleSelection) {
                return true
            }
        }

        guard let hitAnnotation = hitAnnotation ?? topmostAnnotation(at: point) else {
            annotationEditSession = nil
            return false
        }

        let moveIDs: Set<UUID>
        if !activeSelection.isEmpty, activeSelection.contains(hitAnnotation.id) {
            moveIDs = activeSelection
        } else {
            moveIDs = [hitAnnotation.id]
            setSelectedAnnotationIDs(moveIDs, primaryID: hitAnnotation.id)
        }

        var originals: [UUID: any Annotation] = [:]
        for annotationID in moveIDs {
            if let annotation = annotation(with: annotationID) {
                originals[annotationID] = annotation.duplicate()
            }
        }

        guard !originals.isEmpty else {
            annotationEditSession = nil
            return false
        }

        let validSelection = Set(originals.keys)
        setSelectedAnnotationIDs(validSelection, primaryID: hitAnnotation.id)

        guard let primaryOriginal = originals[hitAnnotation.id] ?? originals.values.first else {
            annotationEditSession = nil
            return false
        }

        let frame = AnnotationGeometry.editableFrame(for: primaryOriginal)
        annotationEditSession = AnnotationEditSession(
            annotationID: hitAnnotation.id,
            originalAnnotation: primaryOriginal,
            originalFrame: frame,
            startPoint: point,
            mode: .move(originals)
        )

        return true
    }

    @discardableResult
    private func updateAnnotationInteractionIfNeeded(at point: CGPoint) -> Bool {
        guard annotationEditSession != nil else { return false }
        updateAnnotationInteraction(to: point)
        needsDisplay = true
        return true
    }

    @discardableResult
    private func endAnnotationInteractionIfNeeded(at point: CGPoint) -> Bool {
        guard annotationEditSession != nil else { return false }
        updateAnnotationInteraction(to: point)
        endAnnotationInteraction()
        needsDisplay = true
        return true
    }

    private func updateAnnotationInteraction(to point: CGPoint) {
        guard let session = annotationEditSession else { return }

        switch session.mode {
        case .move(let originals):
            let delta = CGPoint(x: point.x - session.startPoint.x, y: point.y - session.startPoint.y)
            for original in originals.values {
                let transformed = AnnotationGeometry.translated(original, by: delta)
                applyTransformedAnnotation(transformed, preserving: original)
            }
        case .resize(let handle):
            let resizedRect = AnnotationGeometry.rectForResize(
                handle: handle,
                originalFrame: session.originalFrame,
                currentPoint: point
            )
            let transformed = AnnotationGeometry.resized(
                session.originalAnnotation,
                from: session.originalFrame,
                to: resizedRect
            )
            applyTransformedAnnotation(transformed, preserving: session.originalAnnotation)
        case .rotate(let initialPointerAngle, let originalRotationDegrees, let center, _):
            let currentPointerAngle = atan2(point.y - center.y, point.x - center.x)
            let deltaAngle = currentPointerAngle - initialPointerAngle
            let updatedRotation = originalRotationDegrees + (deltaAngle * 180 / .pi)
            let transformed = AnnotationGeometry.rotated(session.originalAnnotation, to: updatedRotation)
            applyTransformedAnnotation(transformed, preserving: session.originalAnnotation)
        }
    }

    private func endAnnotationInteraction() {
        guard let session = annotationEditSession else { return }
        defer { annotationEditSession = nil }

        switch session.mode {
        case .move(let originals):
            for (annotationID, originalAnnotation) in originals {
                guard let finalAnnotation = annotation(with: annotationID) else { continue }
                recordModifyIfGeometryChanged(from: originalAnnotation, to: finalAnnotation)
            }

        case .resize, .rotate:
            guard let finalAnnotation = annotation(with: session.annotationID) else { return }
            recordModifyIfGeometryChanged(from: session.originalAnnotation, to: finalAnnotation)
        }
    }

    private func singleSelectionContext() -> SingleSelectionContext? {
        guard selectedAnnotationIDs.count == 1 else { return nil }
        guard let selectedID = canvasState.selectedAnnotationID ?? selectedAnnotationIDs.first,
              let selectedAnnotation = annotation(with: selectedID) else {
            return nil
        }
        return SingleSelectionContext(
            id: selectedID,
            annotation: selectedAnnotation,
            frame: AnnotationGeometry.editableFrame(for: selectedAnnotation).standardized
        )
    }

    private func beginRotationInteractionIfNeeded(
        at point: CGPoint,
        selection: SingleSelectionContext
    ) -> Bool {
        guard AnnotationGeometry.supportsRotation(selection.annotation),
              let anchorCorner = rotationHandleCorner(at: point, for: selection.frame) else {
            return false
        }

        let center = CGPoint(x: selection.frame.midX, y: selection.frame.midY)
        annotationEditSession = AnnotationEditSession(
            annotationID: selection.id,
            originalAnnotation: selection.annotation.duplicate(),
            originalFrame: selection.frame,
            startPoint: point,
            mode: .rotate(
                initialPointerAngle: atan2(point.y - center.y, point.x - center.x),
                originalRotationDegrees: AnnotationGeometry.rotationDegrees(for: selection.annotation),
                center: center,
                anchorCorner: anchorCorner
            )
        )
        return true
    }

    private func beginResizeInteractionIfNeeded(
        at point: CGPoint,
        selection: SingleSelectionContext
    ) -> Bool {
        guard AnnotationGeometry.supportsResize(selection.annotation),
              let handle = resizeHandle(at: point, for: selection.frame) else {
            return false
        }

        annotationEditSession = AnnotationEditSession(
            annotationID: selection.id,
            originalAnnotation: selection.annotation.duplicate(),
            originalFrame: selection.frame,
            startPoint: point,
            mode: .resize(handle)
        )
        return true
    }

    private func applyTransformedAnnotation(
        _ transformed: (any Annotation)?,
        preserving original: any Annotation
    ) {
        guard let transformed else { return }
        transformed.zOrder = original.zOrder
        transformed.isVisible = original.isVisible
        replaceAnnotation(transformed)
    }

    private func recordModifyIfGeometryChanged(from oldAnnotation: any Annotation, to newAnnotation: any Annotation) {
        let oldSignature = annotationGeometrySignature(oldAnnotation)
        let newSignature = annotationGeometrySignature(newAnnotation)
        guard oldSignature != newSignature else { return }

        canvasState.undoManager.recordModify(
            oldAnnotation: oldAnnotation,
            newAnnotation: newAnnotation.duplicate(),
            state: canvasState
        )
    }

    private func topmostAnnotation(at point: CGPoint) -> (any Annotation)? {
        for annotation in canvasState.annotations.reversed() where annotation.isVisible {
            if annotation.hitTest(point: point) {
                return annotation
            }
        }
        return nil
    }

    private func synchronizeAnnotationSelectionState() {
        let validIDs = Set(canvasState.annotations.map(\.id))
        if !canvasState.selectedAnnotationIDs.isEmpty {
            selectedAnnotationIDs.formUnion(canvasState.selectedAnnotationIDs)
        }
        selectedAnnotationIDs = Set(selectedAnnotationIDs.filter { validIDs.contains($0) })

        if let primaryID = canvasState.selectedAnnotationID {
            if validIDs.contains(primaryID) {
                if selectedAnnotationIDs.isEmpty {
                    selectedAnnotationIDs = [primaryID]
                } else if !selectedAnnotationIDs.contains(primaryID) {
                    selectedAnnotationIDs.insert(primaryID)
                }
            } else {
                canvasState.selectedAnnotationID = nil
            }
        } else if !selectedAnnotationIDs.isEmpty {
            canvasState.selectedAnnotationID = selectedAnnotationIDs.first
        }

        if selectedAnnotationIDs.isEmpty {
            canvasState.selectedAnnotationID = nil
        }
        canvasState.selectedAnnotationIDs = selectedAnnotationIDs
    }

    private func setSelectedAnnotationIDs(_ ids: Set<UUID>, primaryID: UUID?) {
        let previousIDs = canvasState.selectedAnnotationIDs
        let previousPrimaryID = canvasState.selectedAnnotationID
        selectedAnnotationIDs = ids
        if let primaryID, ids.contains(primaryID) {
            canvasState.selectedAnnotationID = primaryID
        } else {
            canvasState.selectedAnnotationID = ids.first
        }
        canvasState.selectedAnnotationIDs = selectedAnnotationIDs
        if previousIDs != canvasState.selectedAnnotationIDs
            || previousPrimaryID != canvasState.selectedAnnotationID {
            onEditingStateChange?()
        }
    }

    private func toggleSelection(for annotationID: UUID) {
        let previousIDs = canvasState.selectedAnnotationIDs
        let previousPrimaryID = canvasState.selectedAnnotationID
        if selectedAnnotationIDs.contains(annotationID) {
            selectedAnnotationIDs.remove(annotationID)
            if canvasState.selectedAnnotationID == annotationID {
                canvasState.selectedAnnotationID = selectedAnnotationIDs.first
            }
        } else {
            selectedAnnotationIDs.insert(annotationID)
            canvasState.selectedAnnotationID = annotationID
        }

        if selectedAnnotationIDs.isEmpty {
            canvasState.selectedAnnotationID = nil
        }
        canvasState.selectedAnnotationIDs = selectedAnnotationIDs
        if previousIDs != canvasState.selectedAnnotationIDs
            || previousPrimaryID != canvasState.selectedAnnotationID {
            onEditingStateChange?()
        }
    }

    private func beginAnnotationMarqueeSelection(at point: CGPoint, additive: Bool) {
        let start = clampedImagePoint(point)
        annotationMarqueeStartPoint = start
        annotationMarqueeRect = CGRect(origin: start, size: .zero)
        annotationMarqueeBaseSelection = additive ? selectedAnnotationIDs : []
        annotationMarqueeBasePrimaryID = additive ? canvasState.selectedAnnotationID : nil
    }

    private func updateAnnotationMarqueeSelection(to point: CGPoint) {
        guard let start = annotationMarqueeStartPoint else { return }
        let current = clampedImagePoint(point)
        let rect = CGRect(
            x: min(start.x, current.x),
            y: min(start.y, current.y),
            width: abs(current.x - start.x),
            height: abs(current.y - start.y)
        ).intersection(imageBounds())
        annotationMarqueeRect = rect

        let dragThreshold = max(2, 6 / max(canvasState.zoomLevel, 0.1))
        guard rect.width > dragThreshold || rect.height > dragThreshold else { return }

        var ids = annotationMarqueeBaseSelection
        ids.formUnion(intersectingAnnotationIDs(in: rect))
        let primary = resolvedPrimarySelectionID(for: ids, preferred: annotationMarqueeBasePrimaryID)
        setSelectedAnnotationIDs(ids, primaryID: primary)
    }

    private func endAnnotationMarqueeSelection(at point: CGPoint) {
        guard annotationMarqueeStartPoint != nil else { return }
        defer { clearAnnotationMarqueeSelection() }

        let rect = annotationMarqueeRect?.intersection(imageBounds()) ?? .zero
        let dragThreshold = max(2, 6 / max(canvasState.zoomLevel, 0.1))

        if rect.width <= dragThreshold && rect.height <= dragThreshold {
            if annotationMarqueeBaseSelection.isEmpty {
                setSelectedAnnotationIDs([], primaryID: nil)
            } else {
                let primary = resolvedPrimarySelectionID(
                    for: annotationMarqueeBaseSelection,
                    preferred: annotationMarqueeBasePrimaryID
                )
                setSelectedAnnotationIDs(annotationMarqueeBaseSelection, primaryID: primary)
            }
            return
        }

        var ids = annotationMarqueeBaseSelection
        ids.formUnion(intersectingAnnotationIDs(in: rect))
        let primary = resolvedPrimarySelectionID(for: ids, preferred: annotationMarqueeBasePrimaryID)
        setSelectedAnnotationIDs(ids, primaryID: primary)
    }

    private func clearAnnotationMarqueeSelection() {
        annotationMarqueeStartPoint = nil
        annotationMarqueeRect = nil
        annotationMarqueeBaseSelection = []
        annotationMarqueeBasePrimaryID = nil
    }

    private func intersectingAnnotationIDs(in rect: CGRect) -> Set<UUID> {
        let normalizedRect = rect.standardized
        guard normalizedRect.width > 0 || normalizedRect.height > 0 else { return [] }
        var ids: Set<UUID> = []
        for annotation in canvasState.annotations where annotation.isVisible {
            let frame = AnnotationGeometry.editableFrame(for: annotation).standardized
            if frame.intersects(normalizedRect) {
                ids.insert(annotation.id)
            }
        }
        return ids
    }

    private func resolvedPrimarySelectionID(for ids: Set<UUID>, preferred: UUID?) -> UUID? {
        if let preferred, ids.contains(preferred) {
            return preferred
        }
        return ids.first
    }

    private func beginInlineTextEditing(for annotation: TextAnnotation, isNewCaptureText: Bool = false) {
        finishInlineTextEditing(commit: true)
        setSelectedAnnotationIDs([annotation.id], primaryID: annotation.id)

        let textField = InlineTextField(frame: inlineEditorFrame(for: annotation))
        textField.stringValue = annotation.text
        textField.delegate = self
        textField.font = displayFont(for: annotation)
        textField.textColor = annotation.color
        textField.drawsBackground = false
        textField.backgroundColor = .clear
        textField.isBordered = false
        textField.isBezeled = false
        textField.focusRingType = .none
        textField.lineBreakMode = .byClipping
        textField.maximumNumberOfLines = 1
        textField.usesSingleLineMode = true
        textField.onSubmit = { [weak self] in
            self?.finishInlineTextEditing(commit: true)
        }
        textField.onCancel = { [weak self] in
            self?.finishInlineTextEditing(commit: false)
        }

        addSubview(textField)
        inlineTextEditSession = InlineTextEditSession(annotationID: annotation.id, textField: textField,
                                                    isNewCaptureText: isNewCaptureText)
        window?.makeFirstResponder(textField)
        DispatchQueue.main.async {
            if let editor = textField.currentEditor() as? NSTextView {
                editor.drawsBackground = false
                editor.backgroundColor = .clear
                editor.insertionPointColor = annotation.color
                editor.selectAll(nil)
            } else {
                textField.currentEditor()?.selectAll(nil)
            }
        }
        needsDisplay = true
    }

    private func finishInlineTextEditing(commit: Bool) {
        guard let session = inlineTextEditSession else { return }
        defer { onCaptureContentChange?() }
        inlineTextEditSession = nil

        let textField = session.textField
        // Read only committed characters.  If the user clicks away while the
        // IME candidate window is still open, the pinyin composition is
        // discarded instead of being saved as annotation text.
        let rawText = textField.committedStringValue
        let normalizedText = rawText.trimmingCharacters(in: .newlines)
        let hasNonWhitespaceContent = !normalizedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        suppressInlineTextEndHandling = true
        if window?.firstResponder as AnyObject === textField.currentEditor() || window?.firstResponder === textField {
            window?.makeFirstResponder(self)
        }
        suppressInlineTextEndHandling = false

        textField.removeFromSuperview()

        if session.isNewCaptureText {
            guard commit, hasNonWhitespaceContent,
                  let existing = annotation(with: session.annotationID) as? TextAnnotation else {
                canvasState.annotations.removeAll { $0.id == session.annotationID }
                setSelectedAnnotationIDs([], primaryID: nil)
                needsDisplay = true
                return
            }
            let updated = cloneTextAnnotation(existing, text: normalizedText)
            replaceAnnotation(updated)
            canvasState.undoManager.recordAdd(annotation: updated, state: canvasState)
            needsDisplay = true
            return
        }

        guard commit,
              let existing = annotation(with: session.annotationID) as? TextAnnotation else {
            needsDisplay = true
            return
        }

        let previous = cloneTextAnnotation(existing)
        let finalText = hasNonWhitespaceContent ? normalizedText : existing.text
        guard previous.text != finalText else {
            needsDisplay = true
            return
        }

        let updated = cloneTextAnnotation(existing, text: finalText)
        replaceAnnotation(updated)
        canvasState.selectedAnnotationID = updated.id
        canvasState.selectedAnnotationIDs = [updated.id]
        canvasState.undoManager.recordModify(
            oldAnnotation: previous,
            newAnnotation: updated.duplicate(),
            state: canvasState
        )
        needsDisplay = true
    }

    private func updateInlineTextEditorFrameAndStyle() {
        guard let session = inlineTextEditSession else { return }
        guard let annotation = annotation(with: session.annotationID) as? TextAnnotation else {
            finishInlineTextEditing(commit: false)
            return
        }

        session.textField.frame = inlineEditorFrame(
            for: annotation,
            liveText: session.textField.editingStringValue
        )
        session.textField.font = displayFont(for: annotation)
        session.textField.textColor = annotation.color
    }

    private func inlineEditorFrame(for annotation: TextAnnotation, liveText: String? = nil) -> CGRect {
        let zoom = max(canvasState.zoomLevel, 0.1)
        let sizingAnnotation: TextAnnotation
        if let liveText {
            sizingAnnotation = cloneTextAnnotation(annotation, text: liveText)
        } else {
            sizingAnnotation = annotation
        }
        let rect = sizingAnnotation.boundingRect.standardized
        let minWidth = max(26, annotation.fontSize * zoom * 1.6)
        let minHeight = max(14, annotation.fontSize * zoom + 4)
        return CGRect(
            x: canvasState.panOffset.x + rect.minX * zoom,
            y: canvasState.panOffset.y + rect.minY * zoom,
            width: max(minWidth, rect.width * zoom),
            height: max(minHeight, rect.height * zoom)
        )
    }

    private func displayFont(for annotation: TextAnnotation) -> NSFont {
        let zoom = max(canvasState.zoomLevel, 0.1)
        let pointSize = max(annotation.fontSize * zoom, 8)
        return NSFont(name: annotation.fontName, size: pointSize) ?? NSFont.systemFont(ofSize: pointSize)
    }

    private func cloneTextAnnotation(_ annotation: TextAnnotation, text: String? = nil) -> TextAnnotation {
        let copy = TextAnnotation(
            id: annotation.id,
            position: annotation.position,
            text: text ?? annotation.text,
            fontName: annotation.fontName,
            fontSize: annotation.fontSize,
            color: annotation.color,
            rotationDegrees: annotation.rotationDegrees
        )
        copy.isBold = annotation.isBold
        copy.isItalic = annotation.isItalic
        copy.hasBackground = annotation.hasBackground
        copy.zOrder = annotation.zOrder
        copy.isVisible = annotation.isVisible
        return copy
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard !suppressInlineTextEndHandling,
              let session = inlineTextEditSession,
              let field = obj.object as? NSTextField,
              field === session.textField else {
            return
        }
        finishInlineTextEditing(commit: true)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard let session = inlineTextEditSession, control === session.textField else { return false }
        // The input method owns Return/Escape while composing, before they
        // acquire their annotation-level submit/cancel meaning.
        guard !textView.hasMarkedText() else { return false }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            finishInlineTextEditing(commit: true)
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            finishInlineTextEditing(commit: false)
            return true
        }
        return false
    }

    func controlTextDidChange(_ obj: Notification) {
        guard let session = inlineTextEditSession,
              let field = obj.object as? NSTextField,
              field === session.textField else {
            return
        }
        updateInlineTextEditorFrameAndStyle()
        needsDisplay = true
    }

    private func annotation(with id: UUID) -> (any Annotation)? {
        canvasState.annotations.first { $0.id == id }
    }

    private func replaceAnnotation(_ annotation: any Annotation) {
        guard let index = canvasState.annotations.firstIndex(where: { $0.id == annotation.id }) else {
            return
        }
        canvasState.annotations[index] = annotation
    }

    private func annotationGeometrySignature(_ annotation: any Annotation) -> String {
        if let rectangle = annotation as? RectangleAnnotation {
            return "rectangle:\(rectangle.rect.debugDescription):rot:\(rectangle.rotationDegrees)"
        }
        if let ellipse = annotation as? EllipseAnnotation {
            return "ellipse:\(ellipse.rect.debugDescription):rot:\(ellipse.rotationDegrees)"
        }
        if let line = annotation as? LineAnnotation {
            return "line:\(line.start.debugDescription):\(line.end.debugDescription)"
        }
        if let arrow = annotation as? ArrowAnnotation {
            return "arrow:\(arrow.start.debugDescription):\(arrow.end.debugDescription)"
        }
        if let highlighter = annotation as? HighlighterAnnotation {
            var hasher = Hasher()
            hasher.combine(highlighter.points.count)
            hasher.combine(highlighter.strokeWidth)
            for point in highlighter.points {
                hasher.combine(point.x)
                hasher.combine(point.y)
            }
            return "highlighter:\(hasher.finalize())"
        }
        if let blur = annotation as? BlurAnnotation {
            return "blur:\(blur.rect.debugDescription)"
        }
        if let pixelate = annotation as? PixelateAnnotation {
            return "pixelate:\(pixelate.rect.debugDescription)"
        }
        if let spotlight = annotation as? SpotlightAnnotation {
            return "spotlight:\(spotlight.rect.debugDescription)"
        }
        if let counter = annotation as? CounterAnnotation {
            return "counter:\(counter.position.debugDescription)"
        }
        if let crop = annotation as? CropAnnotation {
            return "crop:\(crop.rect.debugDescription)"
        }
        if let text = annotation as? TextAnnotation {
            return "text:\(text.position.debugDescription):rot:\(text.rotationDegrees)"
        }
        if let pencil = annotation as? PencilAnnotation {
            var hasher = Hasher()
            hasher.combine(pencil.points.count)
            hasher.combine(pencil.strokeWidth)
            for point in pencil.points {
                hasher.combine(point.x)
                hasher.combine(point.y)
            }
            return "pencil:\(hasher.finalize())"
        }

        return "\(annotation.id):\(annotation.boundingRect.debugDescription)"
    }

    private func resizeHandle(
        at point: CGPoint,
        for frame: CGRect
    ) -> AnnotationResizeHandle? {
        guard frame.width > 0, frame.height > 0 else { return nil }
        let hitRects = handleRects(for: frame, includeExpandedHitArea: true)
        for handle in AnnotationResizeHandle.allCases {
            if let rect = hitRects[handle], rect.contains(point) {
                return handle
            }
        }
        return nil
    }

    private func drawAnnotationMarqueeOverlay(in context: CGContext) {
        guard toolManager.currentTool == .textSelect,
              let marqueeRect = annotationMarqueeRect?.standardized,
              marqueeRect.width > 0 || marqueeRect.height > 0 else {
            return
        }

        let zoom = max(canvasState.zoomLevel, 0.1)
        let accent = NSColor.controlAccentColor
        let strokeWidth = max(1 / zoom, 0.75)

        context.saveGState()
        context.setFillColor(accent.withAlphaComponent(0.12).cgColor)
        context.fill(marqueeRect)
        context.setStrokeColor(accent.withAlphaComponent(0.95).cgColor)
        context.setLineWidth(strokeWidth)
        context.setLineDash(phase: 0, lengths: [6 / zoom, 4 / zoom])
        context.stroke(marqueeRect)
        context.restoreGState()
    }

    private func drawAnnotationSelectionOverlay(in context: CGContext) {
        if isActivelyDrawingNewShape() {
            return
        }

        let selectedIDs = selectedAnnotationIDs
        guard !selectedIDs.isEmpty else { return }

        if let inlineSession = inlineTextEditSession,
           selectedIDs.count == 1,
           selectedIDs.contains(inlineSession.annotationID) {
            return
        }

        let zoom = max(canvasState.zoomLevel, 0.1)
        let lineWidth = max(1 / zoom, 0.75)
        let accent = NSColor.controlAccentColor

        context.saveGState()
        context.setStrokeColor(accent.withAlphaComponent(0.95).cgColor)
        context.setLineWidth(lineWidth)
        context.setLineDash(phase: 0, lengths: [6 / zoom, 4 / zoom])
        for annotationID in selectedIDs {
            guard let selectedAnnotation = annotation(with: annotationID) else { continue }
            drawSelectionFrame(for: selectedAnnotation, in: context)
        }
        context.setLineDash(phase: 0, lengths: [])

        guard let selection = singleSelectionContext() else {
            context.restoreGState()
            return
        }

        drawResizeHandlesIfNeeded(for: selection, zoom: zoom, accent: accent, in: context)
        drawRotationHandleIfNeeded(for: selection, zoom: zoom, accent: accent, in: context)

        context.restoreGState()
    }

    private func isActivelyDrawingNewShape() -> Bool {
        guard isDragging else { return false }
        switch toolManager.currentTool {
        case .arrow, .rectangle, .ellipse, .line, .pencil, .highlighter, .blur, .pixelate, .spotlight:
            return true
        default:
            return false
        }
    }

    private func drawSelectionFrame(for annotation: any Annotation, in context: CGContext) {
        if toolManager.currentTool == .crop, annotation is CropAnnotation {
            return
        }

        let frame = AnnotationGeometry.editableFrame(for: annotation).standardized
        guard frame.width > 0, frame.height > 0 else { return }
        context.stroke(frame)
    }

    private func drawResizeHandlesIfNeeded(
        for selection: SingleSelectionContext,
        zoom: CGFloat,
        accent: NSColor,
        in context: CGContext
    ) {
        guard AnnotationGeometry.supportsResize(selection.annotation) else { return }
        let handleRects = handleRects(for: selection.frame, includeExpandedHitArea: false)
        for handle in AnnotationResizeHandle.allCases {
            guard let handleRect = handleRects[handle] else { continue }
            context.setFillColor(NSColor.white.cgColor)
            context.fillEllipse(in: handleRect)
            context.setStrokeColor(accent.cgColor)
            context.setLineWidth(max(0.8 / zoom, 0.5))
            context.strokeEllipse(in: handleRect)
        }
    }

    private func drawRotationHandleIfNeeded(
        for selection: SingleSelectionContext,
        zoom: CGFloat,
        accent: NSColor,
        in context: CGContext
    ) {
        guard AnnotationGeometry.supportsRotation(selection.annotation),
              let rotationHandle = visibleRotationHandle(for: selection.id, frame: selection.frame) else {
            return
        }

        context.setFillColor(
            (rotationHandle.isHovering ? accent.withAlphaComponent(0.95) : accent.withAlphaComponent(0.8))
                .cgColor
        )
        context.fillEllipse(in: rotationHandle.rect)

        context.setStrokeColor(NSColor.white.withAlphaComponent(0.95).cgColor)
        context.setLineWidth(max(0.9 / zoom, 0.55))
        context.strokeEllipse(in: rotationHandle.rect)
        drawRotationHandleIcon(
            in: rotationHandle.rect,
            zoom: zoom,
            context: context,
            isHovering: rotationHandle.isHovering
        )
    }

    private var rotationHandleCorners: [AnnotationResizeHandle] {
        [.topLeft, .topRight, .bottomRight, .bottomLeft]
    }

    private func rotationHandleCorner(at point: CGPoint, for frame: CGRect) -> AnnotationResizeHandle? {
        for corner in rotationHandleCorners {
            if rotationHandleRect(for: frame, corner: corner, includeExpandedHitArea: true).contains(point) {
                return corner
            }
        }
        return nil
    }

    private func visibleRotationHandle(for annotationID: UUID, frame: CGRect) -> (rect: CGRect, isHovering: Bool)? {
        if let session = annotationEditSession,
           session.annotationID == annotationID,
           case .rotate(_, _, _, let corner) = session.mode {
            return (rotationHandleRect(for: frame, corner: corner, includeExpandedHitArea: false), true)
        }

        if let hoveredRotationCorner = hoveredRotationHandleCorner(for: frame) {
            return (
                rotationHandleRect(for: frame, corner: hoveredRotationCorner, includeExpandedHitArea: false),
                true
            )
        }

        if let hoveredCorner = hoveredResizeCorner(for: frame) {
            return (
                rotationHandleRect(for: frame, corner: hoveredCorner, includeExpandedHitArea: false),
                false
            )
        }

        return nil
    }

    private func rotationHandleRect(
        for frame: CGRect,
        corner: AnnotationResizeHandle,
        includeExpandedHitArea: Bool
    ) -> CGRect {
        let zoom = max(canvasState.zoomLevel, 0.1)
        let visualSize = max(10 / zoom, 5)
        let hitExpansion = includeExpandedHitArea ? max(4 / zoom, 2) : 0
        let size = visualSize + (hitExpansion * 2)
        let offset = max(10 / zoom, 6)

        guard let cornerMeta = cornerAnchorAndDirection(for: frame, corner: corner) else {
            return .null
        }

        let center = CGPoint(
            x: cornerMeta.anchor.x + (offset * cornerMeta.direction.x),
            y: cornerMeta.anchor.y + (offset * cornerMeta.direction.y)
        )

        return CGRect(
            x: center.x - size / 2,
            y: center.y - size / 2,
            width: size,
            height: size
        )
    }

    private func drawRotationHandleIcon(
        in rect: CGRect,
        zoom: CGFloat,
        context: CGContext,
        isHovering: Bool
    ) {
        let radius = max(min(rect.width, rect.height) * 0.26, 2.2 / max(zoom, 0.1))
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let startAngle = CGFloat.pi * 0.2
        let endAngle = CGFloat.pi * 1.5
        let headLength = max(radius * 0.52, 1.8 / max(zoom, 0.1))
        let headAngle = CGFloat.pi / 5
        let tangentAngle = endAngle + (.pi / 2)
        let tip = CGPoint(
            x: center.x + cos(endAngle) * radius,
            y: center.y + sin(endAngle) * radius
        )
        let left = CGPoint(
            x: tip.x - cos(tangentAngle - headAngle) * headLength,
            y: tip.y - sin(tangentAngle - headAngle) * headLength
        )
        let right = CGPoint(
            x: tip.x - cos(tangentAngle + headAngle) * headLength,
            y: tip.y - sin(tangentAngle + headAngle) * headLength
        )

        context.saveGState()
        context.setStrokeColor(
            NSColor.white.withAlphaComponent(isHovering ? 1.0 : 0.9).cgColor
        )
        context.setLineWidth(max(0.85 / max(zoom, 0.1), 0.5))
        context.setLineCap(.round)
        context.addArc(center: center, radius: radius, startAngle: startAngle, endAngle: endAngle, clockwise: false)
        context.strokePath()

        context.move(to: tip)
        context.addLine(to: left)
        context.move(to: tip)
        context.addLine(to: right)
        context.strokePath()
        context.restoreGState()
    }

    private func hoveredResizeCorner(for frame: CGRect) -> AnnotationResizeHandle? {
        guard let point = currentMouseImagePoint() else { return nil }
        let zoom = max(canvasState.zoomLevel, 0.1)
        let hoverSize = max(28 / zoom, 14)
        for corner in rotationHandleCorners {
            if cornerHoverRect(for: frame, corner: corner, size: hoverSize).contains(point) {
                return corner
            }
        }
        return nil
    }

    private func hoveredRotationHandleCorner(for frame: CGRect) -> AnnotationResizeHandle? {
        guard let point = currentMouseImagePoint() else { return nil }
        for corner in rotationHandleCorners {
            if rotationHandleRect(for: frame, corner: corner, includeExpandedHitArea: true).contains(point) {
                return corner
            }
        }
        return nil
    }

    private func currentMouseImagePoint() -> CGPoint? {
        if let hoverImagePoint {
            return hoverImagePoint
        }
        guard let window else { return nil }
        let viewPoint = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        guard bounds.contains(viewPoint) else { return nil }
        return imagePoint(from: viewPoint)
    }

    private func cornerAnchorAndDirection(
        for frame: CGRect,
        corner: AnnotationResizeHandle
    ) -> (anchor: CGPoint, direction: CGPoint)? {
        switch corner {
        case .topLeft:
            return (CGPoint(x: frame.minX, y: frame.maxY), CGPoint(x: -1, y: 1))
        case .topRight:
            return (CGPoint(x: frame.maxX, y: frame.maxY), CGPoint(x: 1, y: 1))
        case .bottomRight:
            return (CGPoint(x: frame.maxX, y: frame.minY), CGPoint(x: 1, y: -1))
        case .bottomLeft:
            return (CGPoint(x: frame.minX, y: frame.minY), CGPoint(x: -1, y: -1))
        default:
            return nil
        }
    }

    private func cornerHoverRect(
        for frame: CGRect,
        corner: AnnotationResizeHandle,
        size: CGFloat
    ) -> CGRect {
        guard let meta = cornerAnchorAndDirection(for: frame, corner: corner) else {
            return .null
        }
        return CGRect(
            x: meta.anchor.x - size / 2,
            y: meta.anchor.y - size / 2,
            width: size,
            height: size
        )
    }

    private func handleRects(
        for frame: CGRect,
        includeExpandedHitArea: Bool
    ) -> [AnnotationResizeHandle: CGRect] {
        let zoom = max(canvasState.zoomLevel, 0.1)
        let visualSize = max(7 / zoom, 4)
        let hitExpansion = includeExpandedHitArea ? max(3 / zoom, 2) : 0
        let size = visualSize + (hitExpansion * 2)

        let centers: [AnnotationResizeHandle: CGPoint] = [
            .topLeft: CGPoint(x: frame.minX, y: frame.maxY),
            .top: CGPoint(x: frame.midX, y: frame.maxY),
            .topRight: CGPoint(x: frame.maxX, y: frame.maxY),
            .right: CGPoint(x: frame.maxX, y: frame.midY),
            .bottomRight: CGPoint(x: frame.maxX, y: frame.minY),
            .bottom: CGPoint(x: frame.midX, y: frame.minY),
            .bottomLeft: CGPoint(x: frame.minX, y: frame.minY),
            .left: CGPoint(x: frame.minX, y: frame.midY),
        ]

        return centers.mapValues { center in
            CGRect(
                x: center.x - size / 2,
                y: center.y - size / 2,
                width: size,
                height: size
            )
        }
    }

    // MARK: - OCR Text Overlay

    private func syncCropModeState() {
        let isCropToolActive = toolManager.currentTool == .crop

        if wasCropToolActive != isCropToolActive {
            let wasActive = wasCropToolActive
            wasCropToolActive = isCropToolActive
            if isCropToolActive {
                let crop = ensureActiveCropAnnotation()
                setSelectedAnnotationIDs([crop.id], primaryID: crop.id)
                annotationEditSession = nil
            } else if wasActive {
                let cropIDs = Set(canvasState.annotations.compactMap { ($0 as? CropAnnotation)?.id })
                if !cropIDs.isEmpty {
                    canvasState.annotations.removeAll { annotation in
                        cropIDs.contains(annotation.id)
                    }
                    selectedAnnotationIDs.subtract(cropIDs)
                    if let selectedID = canvasState.selectedAnnotationID, cropIDs.contains(selectedID) {
                        canvasState.selectedAnnotationID = selectedAnnotationIDs.first
                    }
                    canvasState.selectedAnnotationIDs = selectedAnnotationIDs
                }
                annotationEditSession = nil
            }
        }

        guard isCropToolActive else { return }
        let crop = ensureActiveCropAnnotation()
        if selectedAnnotationIDs.count != 1 || !selectedAnnotationIDs.contains(crop.id) {
            setSelectedAnnotationIDs([crop.id], primaryID: crop.id)
        }
    }

    @discardableResult
    private func ensureActiveCropAnnotation() -> CropAnnotation {
        let existingCrops = canvasState.annotations.compactMap { $0 as? CropAnnotation }
        let imageRect = CGRect(
            x: 0,
            y: 0,
            width: CGFloat(canvasState.imageWidth),
            height: CGFloat(canvasState.imageHeight)
        )

        if let active = existingCrops.last {
            active.isVisible = false
            let staleCropIDs = Set(existingCrops.dropLast().map(\.id))
            if !staleCropIDs.isEmpty {
                canvasState.annotations.removeAll { annotation in
                    staleCropIDs.contains(annotation.id)
                }
                selectedAnnotationIDs.subtract(staleCropIDs)
            }

            let normalized = active.rect.standardized.intersection(imageRect)
            if normalized.width > 1, normalized.height > 1 {
                return active
            }

            let refreshed = CropAnnotation(id: active.id, rect: imageRect)
            refreshed.zOrder = active.zOrder
            refreshed.isVisible = false
            replaceAnnotation(refreshed)
            return refreshed
        }

        let crop = CropAnnotation(rect: imageRect)
        crop.isVisible = false
        canvasState.annotations.append(crop)
        return crop
    }

    private func activeCropPreviewRect() -> CGRect? {
        let imageRect = CGRect(
            x: 0,
            y: 0,
            width: CGFloat(canvasState.imageWidth),
            height: CGFloat(canvasState.imageHeight)
        )
        guard let rect = canvasState.annotations
            .compactMap({ $0 as? CropAnnotation })
            .last?
            .rect
            .standardized
            .intersection(imageRect),
            rect.width > 1,
            rect.height > 1 else {
            return nil
        }
        return rect
    }

    private func syncTextSelectionState() {
        let isTextSelectionToolActive = toolManager.currentTool == .ocr

        if wasTextSelectionToolActive != isTextSelectionToolActive {
            wasTextSelectionToolActive = isTextSelectionToolActive

            if isTextSelectionToolActive {
                beginTextRecognitionIfNeeded()
            } else {
                clearTextSelection()
                annotationEditSession = nil
                canvasState.isOCRProcessing = false
                textRecognitionTask?.cancel()
                textRecognitionTask = nil
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.window?.makeFirstResponder(self)
                }
            }
        }

        guard isTextSelectionToolActive else { return }
        beginTextRecognitionIfNeeded()
    }

    private func beginTextRecognitionIfNeeded() {
        guard !hasCompletedTextRecognition, textRecognitionTask == nil else { return }
        guard Date() >= nextTextRecognitionRetryDate else { return }

        canvasState.isOCRProcessing = true
        let image = canvasState.baseImage

        textRecognitionTask = Task(priority: .userInitiated) { [weak self] in
            guard let self else { return }

            do {
                let blocks = try await TextRecognitionService.recognizeTextBlocks(in: image)
                guard !Task.isCancelled else { return }

                await MainActor.run {
                    self.recognizedTextBlocks = blocks
                    self.recognizedTextRectsByID = Dictionary(uniqueKeysWithValues: blocks.map { ($0.id, $0.imageRect) })
                    self.selectedTextBlockIDs.removeAll()
                    self.canvasState.recognizedText = TextRecognitionService.composeText(from: blocks)
                    self.canvasState.recognizedTextRegionCount = blocks.count
                    self.hasCompletedTextRecognition = true
                    self.nextTextRecognitionRetryDate = .distantPast
                    self.canvasState.isOCRProcessing = false
                    self.textRecognitionTask = nil
                    self.needsDisplay = true
                }
            } catch {
                guard !Task.isCancelled else { return }

                await MainActor.run {
                    self.recognizedTextBlocks = []
                    self.recognizedTextRectsByID = [:]
                    self.selectedTextBlockIDs.removeAll()
                    self.canvasState.recognizedText = ""
                    self.canvasState.recognizedTextRegionCount = 0
                    self.canvasState.isOCRProcessing = false
                    self.hasCompletedTextRecognition = false
                    self.nextTextRecognitionRetryDate = Date().addingTimeInterval(0.75)
                    self.textRecognitionTask = nil
                    self.needsDisplay = true
                }
                print("Text analysis failed: \(error)")
            }
        }
    }

    private func resetTextRecognitionState(cancelTask: Bool) {
        if cancelTask {
            textRecognitionTask?.cancel()
            textRecognitionTask = nil
        }

        finishInlineTextEditing(commit: false)
        hasCompletedTextRecognition = false
        nextTextRecognitionRetryDate = .distantPast
        recognizedTextBlocks = []
        recognizedTextRectsByID = [:]
        selectedTextBlockIDs.removeAll()
        canvasState.recognizedText = ""
        clearTextSelection()
        annotationEditSession = nil
        setSelectedAnnotationIDs([], primaryID: nil)
        canvasState.isOCRProcessing = false
        canvasState.recognizedTextRegionCount = 0
    }

    private func clearTextSelection() {
        textSelectionStartPoint = nil
        textSelectionRect = nil
        selectedTextBlockIDs.removeAll()
    }

    private func discardAreaSelectionIfPresent() -> Bool {
        var discarded = false

        if annotationMarqueeStartPoint != nil || annotationMarqueeRect != nil {
            clearAnnotationMarqueeSelection()
            discarded = true
        }

        if textSelectionStartPoint != nil || textSelectionRect != nil || !selectedTextBlockIDs.isEmpty {
            clearTextSelection()
            discarded = true
        }

        let cropIDs = Set(canvasState.annotations.compactMap { ($0 as? CropAnnotation)?.id })
        if !cropIDs.isEmpty {
            canvasState.annotations.removeAll { $0 is CropAnnotation }
            selectedAnnotationIDs.subtract(cropIDs)
            if let selectedID = canvasState.selectedAnnotationID, cropIDs.contains(selectedID) {
                canvasState.selectedAnnotationID = selectedAnnotationIDs.first
            }
            if selectedAnnotationIDs.isEmpty {
                canvasState.selectedAnnotationID = nil
            }
            canvasState.selectedAnnotationIDs = selectedAnnotationIDs
            annotationEditSession = nil
            discarded = true
        }

        return discarded
    }

    private func beginTextSelection(at point: CGPoint) {
        guard !recognizedTextBlocks.isEmpty, !canvasState.isOCRProcessing else { return }
        textSelectionStartPoint = point
        textSelectionRect = CGRect(origin: point, size: .zero)
        selectedTextBlockIDs.removeAll()
    }

    private func updateTextSelection(to point: CGPoint) {
        guard let start = textSelectionStartPoint else { return }
        let rect = CGRect(
            x: min(start.x, point.x),
            y: min(start.y, point.y),
            width: abs(point.x - start.x),
            height: abs(point.y - start.y)
        ).intersection(imageBounds())

        textSelectionRect = rect

        let dragThreshold = max(2, 6 / max(canvasState.zoomLevel, 0.1))
        if rect.width <= dragThreshold && rect.height <= dragThreshold {
            return
        }

        selectedTextBlockIDs = selectBlocks(in: rect)
    }

    private func endTextSelection(at point: CGPoint) {
        guard textSelectionStartPoint != nil else { return }
        defer {
            textSelectionStartPoint = nil
            textSelectionRect = nil
        }

        let rect = textSelectionRect?.intersection(imageBounds()) ?? .zero
        let dragThreshold = max(2, 6 / max(canvasState.zoomLevel, 0.1))

        if rect.width <= dragThreshold && rect.height <= dragThreshold {
            selectedTextBlockIDs = selectBlocks(near: point)
        } else {
            selectedTextBlockIDs = selectBlocks(in: rect)
        }
    }

    private func selectBlocks(in rect: CGRect) -> Set<UUID> {
        intersectingBlockIDs(in: rect)
    }

    private func intersectingBlockIDs(in rect: CGRect) -> Set<UUID> {
        let normalizedRect = rect.standardized
        guard normalizedRect.width > 0, normalizedRect.height > 0 else { return [] }

        let useCoverageThreshold = normalizedRect.width > 20 || normalizedRect.height > 20

        return Set(
            recognizedTextBlocks.compactMap { block in
                let blockRect = block.imageRect.standardized
                let intersection = blockRect.intersection(normalizedRect)
                guard !intersection.isNull, intersection.width > 0, intersection.height > 0 else { return nil }

                if !useCoverageThreshold {
                    return block.id
                }

                let blockArea = max(blockRect.width * blockRect.height, 1)
                let coveredRatio = (intersection.width * intersection.height) / blockArea
                return coveredRatio >= 0.16 ? block.id : nil
            }
        )
    }

    private func selectBlocks(near point: CGPoint) -> Set<UUID> {
        blocksNear(point: point)
    }

    private func blocksNear(point: CGPoint) -> Set<UUID> {
        let zoom = max(canvasState.zoomLevel, 0.1)
        let hitPadding = max(8, 16 / zoom)
        let hitRect = CGRect(
            x: point.x - hitPadding,
            y: point.y - hitPadding,
            width: hitPadding * 2,
            height: hitPadding * 2
        )

        let directHits = recognizedTextBlocks.filter { $0.imageRect.intersects(hitRect) }
        if let nearestDirectHit = directHits.min(by: {
            distance(from: point, to: $0.imageRect) < distance(from: point, to: $1.imageRect)
        }) {
            return [nearestDirectHit.id]
        }

        guard let nearest = recognizedTextBlocks.min(by: {
            distance(from: point, to: $0.imageRect)
                < distance(from: point, to: $1.imageRect)
        }) else {
            return []
        }

        let nearestDistance = distance(from: point, to: nearest.imageRect)
        let maxDistance = max(14, 32 / zoom)
        return nearestDistance <= maxDistance ? [nearest.id] : []
    }

    private func distance(from point: CGPoint, to rect: CGRect) -> CGFloat {
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return hypot(dx, dy)
    }

    private func selectAllRecognizedText() {
        guard !recognizedTextBlocks.isEmpty else { return }
        selectedTextBlockIDs = Set(recognizedTextBlocks.map(\.id))
    }

    private func copySelectedTextToPasteboard() -> Bool {
        let text = selectedText()
        guard !text.isEmpty else { return false }
        return PasteboardHelper.copyText(
            text,
            showsConfirmation: true,
            confirmationScreen: window?.screen
        )
    }

    private func selectedText() -> String {
        let selectedBlocks = recognizedTextBlocks
            .filter { selectedTextBlockIDs.contains($0.id) }

        guard !selectedBlocks.isEmpty else { return "" }

        let sortedBlocks = selectedBlocks.sorted {
            let lhsRect = $0.imageRect
            let rhsRect = $1.imageRect
            let yDelta = lhsRect.midY - rhsRect.midY
            if abs(yDelta) > 6 {
                return yDelta > 0
            }
            return lhsRect.minX < rhsRect.minX
        }

        var output = ""
        var previous: OCRTextBlock?

        for block in sortedBlocks {
            if let previous {
                let previousRect = previous.imageRect
                let currentRect = block.imageRect
                let sameLine = abs(previousRect.midY - currentRect.midY) <=
                    max(5, min(previousRect.height, currentRect.height) * 0.65)
                output.append(sameLine ? " " : "\n")
            }
            output.append(block.text)
            previous = block
        }

        return output
    }

    private func drawTextSelectionOverlay(in context: CGContext, imageRect: CGRect) {
        guard !recognizedTextBlocks.isEmpty else { return }

        context.saveGState()
        context.clip(to: imageRect)

        let zoom = max(canvasState.zoomLevel, 0.1)
        let lineWidth = max(0.5, 1 / zoom)
        let hasDragRect = (textSelectionRect?.width ?? 0) > 0 && (textSelectionRect?.height ?? 0) > 0
        var previewBlockIDs: Set<UUID> = []

        if let dragRect = textSelectionRect, hasDragRect {
            previewBlockIDs = intersectingBlockIDs(in: dragRect)
        }

        let selectedRects = mergedHighlightRects(for: selectedTextBlockIDs)
        for rect in selectedRects {
            fillHighlight(
                rect,
                in: context,
                zoom: zoom,
                style: .selected
            )
        }

        let previewOnlyIDs = previewBlockIDs.subtracting(selectedTextBlockIDs)
        let previewRects = mergedHighlightRects(for: previewOnlyIDs)
        for rect in previewRects {
            fillHighlight(
                rect,
                in: context,
                zoom: zoom,
                style: .preview
            )
        }

        let accent = NSColor.controlAccentColor
        if let dragRect = textSelectionRect,
           hasDragRect {
            context.setFillColor(accent.withAlphaComponent(0.08).cgColor)
            context.fill(dragRect)

            context.setStrokeColor(accent.withAlphaComponent(0.95).cgColor)
            context.setLineWidth(lineWidth)
            context.setLineDash(phase: 0, lengths: [6 / zoom, 4 / zoom])
            context.stroke(dragRect)
            context.setLineDash(phase: 0, lengths: [])
        }

        context.restoreGState()
    }

    private func fillHighlight(
        _ rect: CGRect,
        in context: CGContext,
        zoom: CGFloat,
        style: HighlightStyle
    ) {
        let expanded = rect.insetBy(dx: -1 / zoom, dy: -0.5 / zoom)
        let path = CGPath(
            roundedRect: expanded,
            cornerWidth: 3 / zoom,
            cornerHeight: 3 / zoom,
            transform: nil
        )

        let color = NSColor.systemBlue
        let gradient: CGGradient?
        switch style {
        case .selected:
            gradient = Self.selectedHighlightGradient
        case .preview:
            gradient = Self.previewHighlightGradient
        }

        guard let gradient else {
            context.addPath(path)
            context.setFillColor(color.withAlphaComponent(style.fallbackAlpha).cgColor)
            context.fillPath()
            return
        }

        context.saveGState()
        context.addPath(path)
        context.clip()
        context.drawLinearGradient(
            gradient,
            start: CGPoint(x: expanded.midX, y: expanded.maxY),
            end: CGPoint(x: expanded.midX, y: expanded.minY),
            options: []
        )
        context.restoreGState()
    }

    private static func makeHighlightGradient(topAlpha: CGFloat, bottomAlpha: CGFloat) -> CGGradient? {
        let color = NSColor.systemBlue
        return CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: [
                color.withAlphaComponent(topAlpha).cgColor,
                color.withAlphaComponent(bottomAlpha).cgColor,
            ] as CFArray,
            locations: [0, 1]
        )
    }

    private func mergedHighlightRects(for blockIDs: Set<UUID>) -> [CGRect] {
        guard !blockIDs.isEmpty else { return [] }

        let rects = blockIDs
            .compactMap { recognizedTextRectsByID[$0] }
            .sorted {
                let yDelta = $0.midY - $1.midY
                if abs(yDelta) > 2 { return yDelta > 0 }
                return $0.minX < $1.minX
            }

        guard !rects.isEmpty else { return [] }

        struct LineGroup {
            var midY: CGFloat
            var rects: [CGRect]
        }

        var lines: [LineGroup] = []
        for rect in rects {
            if var last = lines.last {
                let yTolerance = max(4, min(last.rects.first?.height ?? rect.height, rect.height) * 0.7)
                if abs(last.midY - rect.midY) <= yTolerance {
                    last.rects.append(rect)
                    last.midY = (last.midY * CGFloat(last.rects.count - 1) + rect.midY) / CGFloat(last.rects.count)
                    lines[lines.count - 1] = last
                    continue
                }
            }
            lines.append(LineGroup(midY: rect.midY, rects: [rect]))
        }

        var merged: [CGRect] = []
        for line in lines {
            let sortedLineRects = line.rects.sorted { $0.minX < $1.minX }
            guard let first = sortedLineRects.first else { continue }

            var minX = first.minX
            var maxX = first.maxX
            var minY = first.minY
            var maxY = first.maxY

            for rect in sortedLineRects.dropFirst() {
                minX = min(minX, rect.minX)
                maxX = max(maxX, rect.maxX)
                minY = min(minY, rect.minY)
                maxY = max(maxY, rect.maxY)
            }

            merged.append(CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY))
        }

        return merged
    }
}
