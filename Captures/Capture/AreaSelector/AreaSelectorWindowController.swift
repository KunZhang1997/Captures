import AppKit
import ScreenCaptureKit

struct AreaSelectionResult {
    let rect: CGRect
    let frozenImage: CGImage?
    let selectedWindow: WindowInfo?

    init(rect: CGRect, frozenImage: CGImage?, selectedWindow: WindowInfo? = nil) {
        self.rect = rect
        self.frozenImage = frozenImage
        self.selectedWindow = selectedWindow
    }
}

enum PendingSelectionLayout {
    static let minimumSize = NSSize(width: 24, height: 24)

    static func constrainedFrame(_ frame: NSRect, within bounds: NSRect) -> NSRect {
        guard !bounds.isNull, bounds.width > 0, bounds.height > 0 else { return frame }

        var result = frame
        result.origin.x = constrainedOrigin(
            frame.minX,
            itemLength: frame.width,
            boundsMin: bounds.minX,
            boundsMax: bounds.maxX
        )
        result.origin.y = constrainedOrigin(
            frame.minY,
            itemLength: frame.height,
            boundsMin: bounds.minY,
            boundsMax: bounds.maxY
        )
        return result
    }

    static func resizedFrame(
        fixedPoint: NSPoint,
        draggedPoint: NSPoint,
        minimumSize: NSSize = minimumSize,
        within bounds: NSRect
    ) -> NSRect {
        guard !bounds.isNull, bounds.width > 0, bounds.height > 0 else {
            return normalizedRect(from: fixedPoint, to: draggedPoint)
        }

        let adjustedPoint = NSPoint(
            x: adjustedCoordinate(
                draggedPoint.x,
                fixed: fixedPoint.x,
                minimumDistance: minimumSize.width,
                lowerBound: bounds.minX,
                upperBound: bounds.maxX
            ),
            y: adjustedCoordinate(
                draggedPoint.y,
                fixed: fixedPoint.y,
                minimumDistance: minimumSize.height,
                lowerBound: bounds.minY,
                upperBound: bounds.maxY
            )
        )
        return normalizedRect(from: fixedPoint, to: adjustedPoint)
    }

    private static func constrainedOrigin(
        _ origin: CGFloat,
        itemLength: CGFloat,
        boundsMin: CGFloat,
        boundsMax: CGFloat
    ) -> CGFloat {
        let latestOrigin = boundsMax - itemLength
        guard latestOrigin >= boundsMin else {
            return boundsMin + (boundsMax - boundsMin - itemLength) / 2
        }
        return min(max(origin, boundsMin), latestOrigin)
    }

    private static func adjustedCoordinate(
        _ coordinate: CGFloat,
        fixed: CGFloat,
        minimumDistance: CGFloat,
        lowerBound: CGFloat,
        upperBound: CGFloat
    ) -> CGFloat {
        let clamped = min(max(coordinate, lowerBound), upperBound)
        guard abs(clamped - fixed) < minimumDistance else { return clamped }

        let preferred = fixed + (clamped < fixed ? -minimumDistance : minimumDistance)
        if preferred >= lowerBound, preferred <= upperBound {
            return preferred
        }

        let opposite = fixed + (preferred < fixed ? minimumDistance : -minimumDistance)
        return min(max(opposite, lowerBound), upperBound)
    }

    private static func normalizedRect(from first: NSPoint, to second: NSPoint) -> NSRect {
        NSRect(
            x: min(first.x, second.x),
            y: min(first.y, second.y),
            width: abs(second.x - first.x),
            height: abs(second.y - first.y)
        )
    }
}

private enum PendingSelectionCorner: CaseIterable {
    case topLeft
    case topRight
    case bottomLeft
    case bottomRight

    func point(in rect: NSRect) -> NSPoint {
        switch self {
        case .topLeft: NSPoint(x: rect.minX, y: rect.maxY)
        case .topRight: NSPoint(x: rect.maxX, y: rect.maxY)
        case .bottomLeft: NSPoint(x: rect.minX, y: rect.minY)
        case .bottomRight: NSPoint(x: rect.maxX, y: rect.minY)
        }
    }

    func oppositePoint(in rect: NSRect) -> NSPoint {
        switch self {
        case .topLeft: NSPoint(x: rect.maxX, y: rect.minY)
        case .topRight: NSPoint(x: rect.minX, y: rect.minY)
        case .bottomLeft: NSPoint(x: rect.maxX, y: rect.maxY)
        case .bottomRight: NSPoint(x: rect.minX, y: rect.maxY)
        }
    }
}

private enum PendingSelectionDragState {
    case move(offset: NSPoint)
    case resize(fixedPoint: NSPoint)
}

/// A held selection has exactly one pointer owner. This state is deliberately
/// independent from AppKit hit-testing so an old crop drag can never consume
/// the first gesture of a selected markup tool.
enum HeldSelectionPointerTarget: Equatable {
    case cropGeometry
    case markupCanvas
    case overlay
}

enum HeldSelectionPointerRouter {
    static func target(
        canDirectlyAdjustSelection: Bool,
        hasPendingCropDrag: Bool,
        hasActiveMarkupDrag: Bool,
        isCropGeometryHit: Bool,
        isInsideSelection: Bool
    ) -> HeldSelectionPointerTarget {
        if canDirectlyAdjustSelection {
            return hasPendingCropDrag || isCropGeometryHit ? .cropGeometry : .overlay
        }
        return hasActiveMarkupDrag || isInsideSelection ? .markupCanvas : .overlay
    }
}

struct FrozenScreenSnapshot {
    struct Display {
        let frame: CGRect
        let image: CGImage

        var scaleX: CGFloat { CGFloat(image.width) / frame.width }
        var scaleY: CGFloat { CGFloat(image.height) / frame.height }
    }

    let displays: [Display]

    func image(for rect: CGRect, retinaScale: Bool) -> CGImage? {
        let intersecting = displays.filter { $0.frame.intersects(rect) }
        guard !intersecting.isEmpty, rect.width > 0, rect.height > 0 else { return nil }

        // The common single-display quick-editor source can reuse its frozen
        // bitmap instead of allocating another full-screen raster.
        if intersecting.count == 1, let display = intersecting.first,
           display.frame == rect,
           retinaScale || (display.scaleX == 1 && display.scaleY == 1) {
            return display.image
        }

        let outputScale = retinaScale
            ? max(1, intersecting.map { max($0.scaleX, $0.scaleY) }.max() ?? 1)
            : 1
        let outputWidth = max(1, Int((rect.width * outputScale).rounded(.up)))
        let outputHeight = max(1, Int((rect.height * outputScale).rounded(.up)))

        guard let context = CGContext(
            data: nil,
            width: outputWidth,
            height: outputHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.interpolationQuality = .high

        for display in intersecting {
            let intersection = display.frame.intersection(rect)
            guard !intersection.isNull, intersection.width > 0, intersection.height > 0 else { continue }

            let sourceRect = CGRect(
                x: (intersection.minX - display.frame.minX) * display.scaleX,
                y: (display.frame.maxY - intersection.maxY) * display.scaleY,
                width: intersection.width * display.scaleX,
                height: intersection.height * display.scaleY
            ).integral
            guard let cropped = display.image.cropping(to: sourceRect) else { continue }

            let destinationRect = CGRect(
                x: (intersection.minX - rect.minX) * outputScale,
                y: (intersection.minY - rect.minY) * outputScale,
                width: intersection.width * outputScale,
                height: intersection.height * outputScale
            ).integral
            context.draw(cropped, in: destinationRect)
        }

        return context.makeImage()
    }
}

final class AreaSelectorWindowController {
    var pendingSelectionChangedHandler: ((NSRect) -> Void)?
    var pendingSelectionKeyHandler: ((NSEvent) -> Bool)?
    private var quickEditor: SelectionQuickEditor?
    private var quickCanvases: [ObjectIdentifier: CanvasNSView] = [:]

    private(set) var overlayWindows: [NSWindow] = []
    private var overlayViews: [AreaSelectorOverlayView] = []
    private var overlayScreenFrames: [ObjectIdentifier: CGRect] = [:]
    private var overlayScreenScales: [ObjectIdentifier: CGFloat] = [:]
    private var localKeyMonitor: Any?
    private var localMouseMonitor: Any?
    private var didFinish = false
    private var selectionStartInScreen: NSPoint?
    private var selectionCurrentInScreen: NSPoint?
    private var pendingSelectionRect: NSRect?
    private var pendingSelectedWindow: WindowInfo?
    private var pendingDragState: PendingSelectionDragState?
    /// The canvas that owns a live quick-markup drag. Keeping this explicit
    /// means a drag can finish normally even when it crosses the selection or
    /// a display boundary, instead of falling back to overlay hit-testing.
    private weak var activeQuickMarkupCanvas: CanvasNSView?
    private var isHoldingSelectionForResultChoice = false
    private let pendingHandleHitRadius: CGFloat = 12
    private let completion: (AreaSelectionResult?) -> Void
    // Keep source pixels captured before any selection panel appears, even
    // when the user turns off the visual freeze.
    private var sourceSnapshot: FrozenScreenSnapshot?
    private var frozenSnapshot: FrozenScreenSnapshot?
    private var preparationTask: Task<Void, Never>?
    private let snapshotProvider: @MainActor () async throws -> FrozenScreenSnapshot
    private let screenCaptureAccess: () -> Bool
    private var retinaScale = true
    private var defersCaptureUntilResultChoice = false
    private var keepsFloatingCapturesVisible = false
    private var selectsWindowsOnClick = false
    private var selectableWindows: [SCWindow] = []
    private var pressedWindow: SCWindow?

    init(
        snapshotProvider: @escaping @MainActor () async throws -> FrozenScreenSnapshot = {
            let displays = try await ScreenCaptureService().captureDisplayImages()
            return FrozenScreenSnapshot(displays: displays.map {
                .init(frame: CoordinateSpace.cgToAppKit($0.frame), image: $0.image)
            })
        },
        screenCaptureAccess: @escaping () -> Bool = PermissionChecker.isScreenCaptureGranted,
        completion: @escaping (AreaSelectionResult?) -> Void
    ) {
        self.snapshotProvider = snapshotProvider
        self.screenCaptureAccess = screenCaptureAccess
        self.completion = completion
    }

    func show(
        freezeScreen: Bool,
        showMagnifier: Bool = false,
        retinaScale: Bool = true,
        defersCaptureUntilResultChoice: Bool = false,
        keepFloatingCapturesVisible: Bool = false,
        selectsWindowsOnClick: Bool = false
    ) {
        didFinish = false
        // Without recording access CoreGraphics can return only desktop
        // pixels. Never cover the user's windows with that incomplete image.
        guard screenCaptureAccess() else {
            didFinish = true
            completion(nil)
            Task { @MainActor in
                PermissionChecker.promptForScreenRecordingInSettings()
            }
            return
        }
        self.retinaScale = retinaScale
        self.defersCaptureUntilResultChoice = defersCaptureUntilResultChoice
        keepsFloatingCapturesVisible = keepFloatingCapturesVisible
        self.selectsWindowsOnClick = selectsWindowsOnClick
        selectableWindows = []
        pressedWindow = nil
        preparationTask?.cancel()
        preparationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let snapshot = try await self.snapshotProvider()
                try Task.checkCancellation()
                guard !self.didFinish else { return }
                // Never present a partial desktop snapshot as the user's
                // screen. Every currently attached display must be present.
                guard NSScreen.screens.allSatisfy({ screen in
                    snapshot.displays.contains { $0.frame == screen.frame }
                }), !snapshot.displays.isEmpty else {
                    throw CaptureError.noDisplay
                }
                self.sourceSnapshot = snapshot
                self.frozenSnapshot = freezeScreen ? snapshot : nil
                self.preparationTask = nil
                self.showOverlays(showMagnifier: showMagnifier)
            } catch {
                guard !Task.isCancelled, !self.didFinish else { return }
                self.preparationTask = nil
                print("Failed to prepare screenshot selection: \(error)")
                self.finish(with: nil)
            }
        }
    }

    @MainActor
    private func showOverlays(showMagnifier: Bool) {
        installKeyMonitor()

        for screen in NSScreen.screens {
            let window = AreaSelectorWindow(
                // The `screen:` initializer interprets this origin relative
                // to the selected screen. Passing screen.frame here applies a
                // secondary display's global origin twice and can put its
                // overlay entirely offscreen.
                contentRect: NSRect(origin: .zero, size: screen.frame.size),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false,
                screen: screen
            )
            // Keep existing "Keep on Page" cards above the selector while a
            // new area is chosen. The cards become click-through, so this
            // overlay still owns every selection gesture.
            window.level = keepsFloatingCapturesVisible
                ? .floating
                : .init(rawValue: Int(CGWindowLevelForKey(.maximumWindow)))
            window.isOpaque = false
            window.backgroundColor = .clear
            window.ignoresMouseEvents = false
            window.acceptsMouseMovedEvents = true
            window.hasShadow = false
            window.hidesOnDeactivate = false
            // The selector is a menu-bar app window. When another app keeps
            // the visible menu bar, relying only on NSEvent's local monitor
            // can leave this frontmost overlay dimmed but unable to receive a
            // drag or Escape. Route events from the overlay window itself as
            // the primary path; the local monitor below remains a cross-screen
            // fallback for windowless events.
            window.inputHandler = { [weak self] event in
                self?.handleOverlayWindowEvent(event) ?? false
            }
            window.collectionBehavior = [
                .canJoinAllSpaces, .fullScreenAuxiliary,
                .canJoinAllApplications, .transient, .ignoresCycle,
            ]
            // Make the global frame explicit. On an extended desktop AppKit
            // may otherwise retain a stale placement while a borderless
            // window is being associated with a non-main screen.
            window.setFrame(screen.frame, display: false)
            // We manage the window lifetime via `overlayWindows`; avoid legacy release-on-close over-release.
            window.isReleasedWhenClosed = false

            let overlayView = AreaSelectorOverlayView(frame: NSRect(origin: .zero, size: screen.frame.size))
            overlayView.showsMagnifier = showMagnifier
            overlayView.frozenImage = frozenSnapshot?.displays.first(where: { $0.frame == screen.frame })?.image
            let overlayID = ObjectIdentifier(overlayView)
            overlayScreenFrames[overlayID] = screen.frame
            overlayScreenScales[overlayID] = max(1.0, screen.backingScaleFactor)

            window.contentView = overlayView
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(overlayView)
            if screen.frame.contains(NSEvent.mouseLocation) {
                overlayView.showReadyFeedback()
            }
            overlayWindows.append(window)
            overlayViews.append(overlayView)
        }

        if keepsFloatingCapturesVisible {
            NotificationCenter.default.post(name: .floatingCaptureSelectionBegan, object: nil)
        }

        installMouseMonitor()

        if selectsWindowsOnClick {
            Task { [weak self] in
                do {
                    let windows = try await WindowSelectionCatalog.loadSelectableWindows()
                    self?.applyDiscoveredWindows(windows)
                } catch {
                    // Region dragging remains fully available when window
                    // discovery is temporarily unavailable.
                    print("Failed to prepare click-to-capture windows: \(error)")
                }
            }
        }
    }

    @MainActor
    private func applyDiscoveredWindows(_ windows: [SCWindow]) {
        guard !didFinish else { return }
        selectableWindows = windows
        updateWindowHoverAcrossOverlays(
            for: WindowSelectionCatalog.window(
                atAppKitPoint: NSEvent.mouseLocation,
                in: windows
            )
        )
    }

    func close() {
        didFinish = true
        preparationTask?.cancel()
        preparationTask = nil
        let shouldRestoreFloatingCaptures = keepsFloatingCapturesVisible
        keepsFloatingCapturesVisible = false
        if let localKeyMonitor {
            NSEvent.removeMonitor(localKeyMonitor)
            self.localKeyMonitor = nil
        }
        if let localMouseMonitor {
            NSEvent.removeMonitor(localMouseMonitor)
            self.localMouseMonitor = nil
        }
        for window in overlayWindows {
            if let selectorWindow = window as? AreaSelectorWindow {
                selectorWindow.inputHandler = nil
            }
            window.close()
        }
        overlayWindows.removeAll()
        overlayViews.removeAll()
        overlayScreenFrames.removeAll()
        overlayScreenScales.removeAll()
        selectionStartInScreen = nil
        selectionCurrentInScreen = nil
        pendingSelectionRect = nil
        pendingSelectedWindow = nil
        pendingDragState = nil
        activeQuickMarkupCanvas = nil
        pendingSelectionChangedHandler = nil
        pendingSelectionKeyHandler = nil
        quickEditor?.onCanvasPrepared = nil
        quickEditor?.onModeChange = nil
        quickCanvases.removeAll()
        quickEditor = nil
        isHoldingSelectionForResultChoice = false
        defersCaptureUntilResultChoice = false
        selectsWindowsOnClick = false
        selectableWindows.removeAll()
        pressedWindow = nil
        sourceSnapshot = nil
        frozenSnapshot = nil
        NSCursor.arrow.set()
        if shouldRestoreFloatingCaptures {
            NotificationCenter.default.post(name: .floatingCaptureSelectionEnded, object: nil)
        }
    }

    private func installKeyMonitor() {
        guard localKeyMonitor == nil else { return }
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            // An inline quick-markup text field owns Escape while it is
            // editing.  Let AppKit deliver the key so it cancels that text
            // edit rather than discarding the entire screenshot selection.
            if self.quickEditor?.isEditingInlineText == true {
                return event
            }
            if self.handleEscape(event) {
                return nil
            }
            return event
        }
    }

    /// Primary event route for a selection overlay. A local event monitor only
    /// observes events once AppKit has already decided to deliver them to this
    /// menu-bar app; a direct NSWindow route keeps the selector operable when
    /// another application's menu bar is still visible.
    private func handleOverlayWindowEvent(_ event: NSEvent) -> Bool {
        // Do not let the overlay's result shortcuts steal text, Return, or
        // Escape from an in-place NSTextField.  Returning false deliberately
        // falls through to NSWindow.sendEvent(_:), which routes the key to
        // the active field editor.
        if isHoldingSelectionForResultChoice,
           event.type == .keyDown,
           quickEditor?.isEditingInlineText == true {
            return false
        }
        if isHoldingSelectionForResultChoice, event.type == .keyDown {
            return pendingSelectionKeyHandler?(event) ?? false
        }
        if handleEscape(event) {
            return true
        }
        return handleMouseEvent(event)
    }

    private func handleEscape(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown, event.keyCode == 53 else { return false }

        let discardedAnySelection = overlayViews.reduce(false) { partialResult, overlayView in
            overlayView.clearSelection() || partialResult
        }
        selectionStartInScreen = nil
        selectionCurrentInScreen = nil
        if !discardedAnySelection {
            finish(with: nil)
        }
        return true
    }

    private func installMouseMonitor() {
        guard localMouseMonitor == nil else { return }
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .mouseMoved]
        ) { [weak self] event in
            guard let self else { return event }
            if self.handleMouseEvent(event) {
                return nil
            }
            return event
        }
    }

    private func handleMouseEvent(_ event: NSEvent) -> Bool {
        guard isOverlayEvent(event) else { return false }
        let screenPoint = screenPoint(for: event)

        if isHoldingSelectionForResultChoice {
            if let quickEditor {
                let isPointerDownOrHover = event.type == .leftMouseDown || event.type == .mouseMoved
                let isCropGeometryHit = isPointerDownOrHover && (
                    pendingSelectionRect.map({ pendingSelectionCorner(at: screenPoint, in: $0) != nil }) == true
                    || pendingSelectionRect?.contains(screenPoint) == true
                )
                let pointerTarget = HeldSelectionPointerRouter.target(
                    canDirectlyAdjustSelection: quickEditor.canDirectlyAdjustSelection,
                    hasPendingCropDrag: pendingDragState != nil,
                    hasActiveMarkupDrag: activeQuickMarkupCanvas != nil,
                    isCropGeometryHit: isCropGeometryHit,
                    isInsideSelection: pendingSelectionRect?.contains(screenPoint) == true
                )

                switch pointerTarget {
                case .cropGeometry:
                    // Crop resize/move is reserved for the default Select
                    // Annotation tool. A stale crop drag must never survive
                    // into a drawing tool and swallow its first gesture.
                    activeQuickMarkupCanvas = nil
                    return handlePendingSelectionMouseEvent(event, screenPoint: screenPoint)

                case .markupCanvas:
                    // The result overlay has one input owner at a time. Once
                    // markup is active, send its pointer stream directly to
                    // the selected CanvasNSView instead of hoping NSWindow
                    // hit-testing will hand it over after the overlay
                    // inspected the same event.
                    pendingDragState = nil
                    return handleQuickMarkupMouseEvent(event, screenPoint: screenPoint)

                case .overlay:
                    if event.type == .mouseMoved { NSCursor.arrow.set() }
                    return true
                }
            }
            return handlePendingSelectionMouseEvent(event, screenPoint: screenPoint)
        }

        switch event.type {
        case .leftMouseDown:
            selectionStartInScreen = screenPoint
            selectionCurrentInScreen = screenPoint
            pressedWindow = selectsWindowsOnClick
                ? WindowSelectionCatalog.window(atAppKitPoint: screenPoint, in: selectableWindows)
                : nil
            updateMagnifierAcrossOverlays(at: screenPoint)
            return true
        case .leftMouseDragged:
            guard let start = selectionStartInScreen else { return true }
            selectionCurrentInScreen = screenPoint
            let distance = hypot(screenPoint.x - start.x, screenPoint.y - start.y)
            if distance > 5 {
                pressedWindow = nil
                clearWindowHoverAcrossOverlays()
                updateSelectionAcrossOverlays()
            }
            updateMagnifierAcrossOverlays(at: screenPoint)
            return true
        case .leftMouseUp:
            guard let start = selectionStartInScreen else { return true }
            selectionCurrentInScreen = screenPoint
            let end = screenPoint
            let selectedRect = normalizedRect(from: start, to: end)
            selectionStartInScreen = nil
            selectionCurrentInScreen = nil

            if selectedRect.width > 5, selectedRect.height > 5 {
                pressedWindow = nil
                updateSelectionAcrossOverlays(for: selectedRect)
                let frozenImage = defersCaptureUntilResultChoice
                    ? nil
                    : (frozenSnapshot ?? sourceSnapshot)?.image(
                        for: selectedRect,
                        retinaScale: retinaScale
                    )
                finish(
                    with: AreaSelectionResult(rect: selectedRect, frozenImage: frozenImage),
                    keepSelectionVisible: true
                )
            } else if let window = pressedWindow,
                      WindowSelectionCatalog.window(
                        atAppKitPoint: screenPoint,
                        in: selectableWindows
                      )?.windowID == window.windowID {
                pressedWindow = nil
                let appKitRect = CoordinateSpace.cgToAppKit(window.frame)
                let frozenImage = defersCaptureUntilResultChoice
                    ? nil
                    : (frozenSnapshot ?? sourceSnapshot)?.image(
                        for: appKitRect,
                        retinaScale: retinaScale
                    )
                finish(
                    with: AreaSelectionResult(
                        rect: appKitRect,
                        frozenImage: frozenImage,
                        selectedWindow: WindowSelectionCatalog.info(for: window)
                    ),
                    keepSelectionVisible: true
                )
            } else {
                pressedWindow = nil
                clearSelectionAcrossOverlays()
                updateWindowHoverAcrossOverlays(
                    for: WindowSelectionCatalog.window(
                        atAppKitPoint: screenPoint,
                        in: selectableWindows
                    )
                )
            }
            return true
        case .mouseMoved:
            if selectsWindowsOnClick, selectionStartInScreen == nil {
                updateWindowHoverAcrossOverlays(
                    for: WindowSelectionCatalog.window(
                        atAppKitPoint: screenPoint,
                        in: selectableWindows
                    )
                )
            }
            updateMagnifierAcrossOverlays(at: screenPoint)
            return true
        default:
            return false
        }
    }

    private func isOverlayEvent(_ event: NSEvent) -> Bool {
        if let window = event.window {
            // The chooser sits above the retained overlays. Its events must
            // pass through this local monitor so every result action remains
            // clickable while the screenshot itself is draggable.
            return overlayWindows.contains(where: { $0 === window })
        }

        // A borderless overlay on a non-key display can receive a mouse event
        // with no window. During an active selection, its screen position is
        // the reliable signal.
        // This keeps the built-in display selectable when another monitor owns
        // keyboard focus.
        let mouseLocation = NSEvent.mouseLocation
        return overlayScreenFrames.values.contains { $0.contains(mouseLocation) }
    }

    private func handlePendingSelectionMouseEvent(
        _ event: NSEvent,
        screenPoint: NSPoint
    ) -> Bool {
        guard let pendingSelectionRect else { return true }

        switch event.type {
        case .leftMouseDown:
            if let corner = pendingSelectionCorner(at: screenPoint, in: pendingSelectionRect) {
                pendingDragState = .resize(fixedPoint: corner.oppositePoint(in: pendingSelectionRect))
                NSCursor.crosshair.set()
            } else if pendingSelectionRect.contains(screenPoint) {
                pendingDragState = .move(offset: NSPoint(
                    x: screenPoint.x - pendingSelectionRect.minX,
                    y: screenPoint.y - pendingSelectionRect.minY
                ))
                NSCursor.closedHand.set()
            }
            return true
        case .leftMouseDragged:
            guard let pendingDragState else { return true }
            pendingSelectedWindow = nil
            let changedFrame: NSRect
            switch pendingDragState {
            case let .move(offset):
                let proposedFrame = NSRect(
                    x: screenPoint.x - offset.x,
                    y: screenPoint.y - offset.y,
                    width: pendingSelectionRect.width,
                    height: pendingSelectionRect.height
                )
                changedFrame = PendingSelectionLayout.constrainedFrame(
                    proposedFrame,
                    within: virtualDesktopBounds
                )
            case let .resize(fixedPoint):
                changedFrame = PendingSelectionLayout.resizedFrame(
                    fixedPoint: fixedPoint,
                    draggedPoint: screenPoint,
                    within: virtualDesktopBounds
                )
            }
            if let quickEditor, !quickEditor.updateSelection(changedFrame) {
                self.pendingDragState = nil
                return true
            }
            self.pendingSelectionRect = changedFrame
            renderPendingSelection()
            pendingSelectionChangedHandler?(changedFrame)
            return true
        case .leftMouseUp:
            pendingDragState = nil
            updatePendingSelectionCursor(at: screenPoint, in: pendingSelectionRect)
            return true
        case .mouseMoved:
            updatePendingSelectionCursor(at: screenPoint, in: pendingSelectionRect)
            return true
        default:
            return false
        }
    }

    private func handleQuickMarkupMouseEvent(
        _ event: NSEvent,
        screenPoint: NSPoint
    ) -> Bool {
        switch event.type {
        case .leftMouseDown:
            guard pendingSelectionRect?.contains(screenPoint) == true,
                  let canvas = quickCanvas(at: screenPoint) else {
                return true
            }
            activeQuickMarkupCanvas = canvas
            forwardQuickMarkupEvent(event, at: screenPoint, to: canvas)
            return true

        case .leftMouseDragged:
            guard let canvas = activeQuickMarkupCanvas else { return true }
            forwardQuickMarkupEvent(event, at: screenPoint, to: canvas)
            return true

        case .leftMouseUp:
            defer { activeQuickMarkupCanvas = nil }
            guard let canvas = activeQuickMarkupCanvas else { return true }
            forwardQuickMarkupEvent(event, at: screenPoint, to: canvas)
            return true

        case .mouseMoved:
            guard pendingSelectionRect?.contains(screenPoint) == true,
                  let canvas = quickCanvas(at: screenPoint) else {
                NSCursor.arrow.set()
                return true
            }
            forwardQuickMarkupEvent(event, at: screenPoint, to: canvas)
            return true

        default:
            return true
        }
    }

    private func quickCanvas(at screenPoint: NSPoint) -> CanvasNSView? {
        for window in overlayWindows where window.frame.contains(screenPoint) {
            guard let overlay = window.contentView,
                  let canvas = quickCanvases[ObjectIdentifier(overlay)] else {
                continue
            }
            let windowPoint = window.convertPoint(fromScreen: screenPoint)
            let pointInOverlay = overlay.convert(windowPoint, from: nil)
            if canvas.frame.contains(pointInOverlay) {
                return canvas
            }
        }
        return nil
    }

    private func forwardQuickMarkupEvent(
        _ event: NSEvent,
        at screenPoint: NSPoint,
        to canvas: CanvasNSView
    ) {
        guard let canvasWindow = canvas.window else { return }
        let canvasEvent: NSEvent
        if event.window === canvasWindow {
            canvasEvent = event
        } else if let normalizedEvent = NSEvent.mouseEvent(
            with: event.type,
            location: canvasWindow.convertPoint(fromScreen: screenPoint),
            modifierFlags: event.modifierFlags,
            timestamp: event.timestamp,
            windowNumber: canvasWindow.windowNumber,
            context: nil,
            eventNumber: event.eventNumber,
            clickCount: event.clickCount,
            pressure: event.pressure
        ) {
            canvasEvent = normalizedEvent
        } else {
            return
        }

        canvas.handleQuickMarkupPointerEvent(canvasEvent)
    }

    private func pendingSelectionCorner(
        at point: NSPoint,
        in rect: NSRect
    ) -> PendingSelectionCorner? {
        PendingSelectionCorner.allCases.first { corner in
            let handlePoint = corner.point(in: rect)
            return abs(point.x - handlePoint.x) <= pendingHandleHitRadius
                && abs(point.y - handlePoint.y) <= pendingHandleHitRadius
        }
    }

    private func updatePendingSelectionCursor(at point: NSPoint, in rect: NSRect) {
        if pendingSelectionCorner(at: point, in: rect) != nil {
            NSCursor.crosshair.set()
        } else if rect.contains(point) {
            NSCursor.openHand.set()
        } else {
            NSCursor.arrow.set()
        }
    }

    private var virtualDesktopBounds: NSRect {
        guard let firstFrame = NSScreen.screens.first?.frame else { return .zero }
        return NSScreen.screens.dropFirst().reduce(firstFrame) { bounds, screen in
            bounds.union(screen.frame)
        }
    }

    private func screenPoint(for event: NSEvent) -> NSPoint {
        if let window = event.window,
           overlayWindows.contains(where: { $0 === window }) {
            return window.convertPoint(toScreen: event.locationInWindow)
        }
        return NSEvent.mouseLocation
    }

    private func updateSelectionAcrossOverlays(for resolvedRect: CGRect? = nil) {
        let globalRect: CGRect
        if let resolvedRect {
            globalRect = resolvedRect
        } else if let start = selectionStartInScreen, let current = selectionCurrentInScreen {
            globalRect = normalizedRect(from: start, to: current)
        } else {
            clearSelectionAcrossOverlays()
            return
        }
        let globalScale = max(1.0, overlayViews.compactMap { overlayView in
            let overlayID = ObjectIdentifier(overlayView)
            guard let screenFrame = overlayScreenFrames[overlayID],
                  screenFrame.intersects(globalRect),
                  let screenScale = overlayScreenScales[overlayID] else {
                return nil
            }
            return screenScale
        }.max() ?? 1.0)
        let pixelSize = CGSize(
            width: globalRect.width * globalScale,
            height: globalRect.height * globalScale
        )

        for overlayView in overlayViews {
            guard let screenFrame = overlayScreenFrames[ObjectIdentifier(overlayView)] else { continue }
            let localRect = CGRect(
                x: globalRect.minX - screenFrame.minX,
                y: globalRect.minY - screenFrame.minY,
                width: globalRect.width,
                height: globalRect.height
            ).intersection(overlayView.bounds)
            overlayView.setSelectionRect(localRect.isNull ? nil : localRect, pixelSize: pixelSize)
        }
    }

    private func clearSelectionAcrossOverlays() {
        for overlayView in overlayViews {
            overlayView.setSelectionRect(nil, pixelSize: nil)
        }
    }

    private func updateWindowHoverAcrossOverlays(for window: SCWindow?) {
        guard selectsWindowsOnClick else {
            clearWindowHoverAcrossOverlays()
            return
        }
        let appKitFrame = window.map { CoordinateSpace.cgToAppKit($0.frame) }

        for overlayView in overlayViews {
            guard let screenFrame = overlayScreenFrames[ObjectIdentifier(overlayView)] else { continue }
            let localRect = appKitFrame.map {
                NSRect(
                    x: $0.minX - screenFrame.minX,
                    y: $0.minY - screenFrame.minY,
                    width: $0.width,
                    height: $0.height
                ).intersection(overlayView.bounds)
            }
            overlayView.setWindowHoverRect(
                localRect?.isNull == false ? localRect : nil
            )
        }
    }

    private func clearWindowHoverAcrossOverlays() {
        for overlayView in overlayViews {
            overlayView.setWindowHoverRect(nil)
        }
    }

    private func updateMagnifierAcrossOverlays(at screenPoint: NSPoint) {
        for overlayView in overlayViews {
            guard let screenFrame = overlayScreenFrames[ObjectIdentifier(overlayView)] else { continue }
            overlayView.setMagnifierPointInScreen(screenFrame.contains(screenPoint) ? screenPoint : nil)
        }
    }

    private func normalizedRect(from first: NSPoint, to second: NSPoint) -> CGRect {
        CGRect(
            x: min(first.x, second.x),
            y: min(first.y, second.y),
            width: abs(second.x - first.x),
            height: abs(second.y - first.y)
        )
    }

    private func finish(
        with result: AreaSelectionResult?,
        keepSelectionVisible: Bool = false
    ) {
        guard !didFinish else { return }
        didFinish = true
        // Avoid changing the overlay hierarchy while AppKit is still
        // dispatching the current mouse/key event.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if keepSelectionVisible, let result {
                self.holdSelectionForResultChoice(result)
            } else {
                self.close()
            }
            self.completion(result)
        }
    }

    private func holdSelectionForResultChoice(_ result: AreaSelectionResult) {
        if let localKeyMonitor {
            NSEvent.removeMonitor(localKeyMonitor)
            self.localKeyMonitor = nil
        }

        pendingSelectionRect = result.rect
        pendingSelectedWindow = result.selectedWindow
        pendingDragState = nil
        isHoldingSelectionForResultChoice = true
        for overlayView in overlayViews {
            let screenFrame = overlayScreenFrames[ObjectIdentifier(overlayView)]
            let capturedDisplay = sourceSnapshot?.displays.first { $0.frame == screenFrame }
            overlayView.holdSelectionForResultChoice(
                frozenImage: capturedDisplay?.image,
                visibleSelectionRect: nil,
                selectionFrame: .zero
            )
        }
        for window in overlayWindows {
            window.ignoresMouseEvents = false
        }
        renderPendingSelection()
    }

    func currentPendingSelectionResult() -> AreaSelectionResult? {
        guard let pendingSelectionRect else { return nil }
        if let quickEditor {
            guard let image = quickEditor.exportImage() else { return nil }
            // A clicked window must not be re-captured live and erase the
            // frozen crop/annotations. This result already owns its pixels.
            return AreaSelectionResult(rect: pendingSelectionRect, frozenImage: image)
        }
        let image = sourceSnapshot?.image(
            for: pendingSelectionRect,
            retinaScale: retinaScale
        )
        return AreaSelectionResult(
            rect: pendingSelectionRect,
            frozenImage: image,
            selectedWindow: pendingSelectedWindow
        )
    }

    private func renderPendingSelection() {
        guard let pendingSelectionRect else { return }

        for overlayView in overlayViews {
            guard let screenFrame = overlayScreenFrames[ObjectIdentifier(overlayView)] else { continue }
            let localCapturedFrame = NSRect(
                x: pendingSelectionRect.minX - screenFrame.minX,
                y: pendingSelectionRect.minY - screenFrame.minY,
                width: pendingSelectionRect.width,
                height: pendingSelectionRect.height
            )
            let visibleRect = localCapturedFrame.intersection(overlayView.bounds)
            overlayView.updateHeldSelection(
                visibleSelectionRect: visibleRect.isNull ? nil : visibleRect,
                selectionFrame: localCapturedFrame
            )
            quickCanvases[ObjectIdentifier(overlayView)]?.frame = localCapturedFrame
        }
    }

    func prepareQuickEditor() -> SelectionQuickEditor? {
        guard let sourceSnapshot, let pendingSelectionRect else { return nil }
        let editor = SelectionQuickEditor(snapshot: sourceSnapshot,
                                          selectionRect: pendingSelectionRect, retinaScale: retinaScale)
        quickEditor = editor
        editor.onCanvasPrepared = { [weak self, weak editor] in
            guard let self, let editor else { return }
            for overlay in self.overlayViews {
                guard let canvas = editor.makeCanvasView() else { continue }
                overlay.wantsLayer = true
                overlay.layer?.masksToBounds = true
                overlay.addSubview(canvas)
                self.quickCanvases[ObjectIdentifier(overlay)] = canvas
            }
            self.renderPendingSelection()
        }
        editor.onModeChange = { [weak self] in
            guard let self else { return }
            if let window = self.overlayWindows.first(where: { $0.frame.contains(NSEvent.mouseLocation) }),
               let overlay = window.contentView,
               let canvas = self.quickCanvases[ObjectIdentifier(overlay)] {
                window.makeKeyAndOrderFront(nil)
                window.makeFirstResponder(canvas)
            }
        }
        guard editor.selectTool(.textSelect) else {
            quickEditor = nil
            return nil
        }
        return editor
    }

}

/// A screenshot panel may take keyboard focus for Escape and markup without
/// activating Captures or displacing the source app's full-screen/Stage Manager
/// window set. A regular NSWindow plus NSApp.activate switches that set away.
final class AreaSelectorWindow: NSPanel {
    var inputHandler: ((NSEvent) -> Bool)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        if inputHandler?(event) == true {
            return
        }
        super.sendEvent(event)
    }
}
