import AppKit
import ScreenCaptureKit

struct WindowInfo {
    let window: SCWindow
    let frame: CGRect
    let title: String?
    let appName: String?
}

/// One shared source of truth for pointer-to-window resolution. Both the
/// dedicated Window shortcut and the primary Area shortcut use this catalog,
/// so a click means "this window" while a drag still means "this region."
enum WindowSelectionCatalog {
    static func loadSelectableWindows() async throws -> [SCWindow] {
        let content = try await SCShareableContent.excludingDesktopWindows(
            true,
            onScreenWindowsOnly: true
        )
        let ownPID = pid_t(ProcessInfo.processInfo.processIdentifier)
        let selectableWindows = content.windows.filter { window in
            window.frame.width > 50
                && window.frame.height > 50
                && (window.owningApplication.map { pid_t($0.processID) != ownPID } ?? true)
        }
        return frontToBack(selectableWindows)
    }

    static func window(atAppKitPoint point: NSPoint, in windows: [SCWindow]) -> SCWindow? {
        let cgPoint = CoordinateSpace.appKitToCG(point)
        return windows.first { $0.frame.contains(cgPoint) }
    }

    static func info(for window: SCWindow) -> WindowInfo {
        WindowInfo(
            window: window,
            frame: window.frame,
            title: window.title,
            appName: window.owningApplication?.applicationName
        )
    }

    static func displayTitle(for window: SCWindow) -> String? {
        let appName = window.owningApplication.map {
            $0.applicationName.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let windowTitle = window.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        switch (appName?.isEmpty == false ? appName : nil, windowTitle?.isEmpty == false ? windowTitle : nil) {
        case let (app?, title?): return "\(app) — \(title)"
        case let (app?, nil): return app
        case let (nil, title?): return title
        case (nil, nil): return nil
        }
    }

    /// ScreenCaptureKit does not promise a window z-order. Resolve it before
    /// installing the full-screen overlays so overlapping windows follow the
    /// same front-to-back order the person sees.
    static func frontToBack(_ candidates: [SCWindow]) -> [SCWindow] {
        let byWindowID = Dictionary(uniqueKeysWithValues: candidates.map { ($0.windowID, $0) })
        guard let systemWindows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return candidates
        }

        var ordered: [SCWindow] = []
        var usedWindowIDs: Set<CGWindowID> = []
        for entry in systemWindows {
            guard let layer = entry[kCGWindowLayer as String] as? Int,
                  layer == 0,
                  let windowID = entry[kCGWindowNumber as String] as? CGWindowID,
                  let window = byWindowID[windowID] else {
                continue
            }
            ordered.append(window)
            usedWindowIDs.insert(windowID)
        }
        ordered.append(contentsOf: candidates.filter { !usedWindowIDs.contains($0.windowID) })
        return ordered
    }
}

final class WindowSelectorController {
    private var overlayWindows: [NSWindow] = []
    private var highlightOverlays: [WindowHighlightOverlay] = []
    private var windows: [SCWindow] = []
    private let completion: (WindowInfo?) -> Void
    private var mouseMonitor: Any?
    private var didFinish = false
    private var holdsSelectionForResultChoice = false
    private var hoveredWindowID: CGWindowID?
    private var keepsFloatingCapturesVisible = false

    init(completion: @escaping (WindowInfo?) -> Void) {
        self.completion = completion
    }

    func show(
        keepFloatingCapturesVisible: Bool = false,
        defersCaptureUntilResultChoice: Bool = false
    ) {
        didFinish = false
        holdsSelectionForResultChoice = defersCaptureUntilResultChoice
        hoveredWindowID = nil
        keepsFloatingCapturesVisible = keepFloatingCapturesVisible
        Task {
            do {
                self.windows = try await WindowSelectionCatalog.loadSelectableWindows()
                await MainActor.run { setupOverlay() }
            } catch {
                print("Failed to get windows: \(error)")
                finish(with: nil)
            }
        }
    }

    @MainActor
    private func setupOverlay() {
        guard !NSScreen.screens.isEmpty else { return }

        for screen in NSScreen.screens {
            let window = NSWindow(
                // The screen initializer treats this origin as local to the
                // selected screen. Passing its global origin here offsets a
                // secondary-display overlay twice and leaves it offscreen.
                contentRect: NSRect(origin: .zero, size: screen.frame.size),
                styleMask: .borderless,
                backing: .buffered,
                defer: false,
                screen: screen
            )
            window.level = keepsFloatingCapturesVisible
                ? .floating
                : .init(rawValue: Int(CGWindowLevelForKey(.maximumWindow)) - 1)
            window.isOpaque = false
            window.backgroundColor = NSColor.black.withAlphaComponent(0.01)
            window.ignoresMouseEvents = false
            window.acceptsMouseMovedEvents = true
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            // Keep ownership under ARC via `overlayWindows`; don't let close() release the instance.
            window.isReleasedWhenClosed = false
            window.setFrame(screen.frame, display: false)

            let overlay = WindowHighlightOverlay(
                frame: NSRect(origin: .zero, size: screen.frame.size)
            )
            window.contentView = overlay
            window.makeKeyAndOrderFront(nil)
            overlayWindows.append(window)
            highlightOverlays.append(overlay)
        }

        if keepsFloatingCapturesVisible {
            NotificationCenter.default.post(name: .floatingCaptureSelectionBegan, object: nil)
        }

        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown, .keyDown]) { [weak self] event in
            self?.handleEvent(event)
            return event
        }
    }

    private func handleEvent(_ event: NSEvent) {
        switch event.type {
        case .mouseMoved:
            guard !didFinish else { return }
            let mouseLocation = NSEvent.mouseLocation
            updateHoverHighlight(for: hitTestWindow(atAppKitPoint: mouseLocation))

        case .leftMouseDown:
            guard !didFinish else { return }
            let mouseLocation = NSEvent.mouseLocation
            if let selectedWindow = hitTestWindow(atAppKitPoint: mouseLocation) {
                let info = WindowSelectionCatalog.info(for: selectedWindow)
                if holdsSelectionForResultChoice {
                    didFinish = true
                    updateHoverHighlight(for: selectedWindow, isSelectionLocked: true)
                    completion(info)
                } else {
                    finish(with: info)
                }
            } else {
                finish(with: nil)
            }

        case .keyDown:
            if event.keyCode == 53 { // Escape
                finish(with: nil)
            }

        default:
            break
        }
    }

    private func hitTestWindow(atAppKitPoint point: NSPoint) -> SCWindow? {
        WindowSelectionCatalog.window(atAppKitPoint: point, in: windows)
    }

    private func updateHoverHighlight(
        for window: SCWindow?,
        isSelectionLocked: Bool = false
    ) {
        let nextWindowID = window?.windowID
        guard nextWindowID != hoveredWindowID || isSelectionLocked else { return }
        hoveredWindowID = nextWindowID

        let screenFrame = window.map { CoordinateSpace.cgToAppKit($0.frame) }
        let title = window.flatMap(WindowSelectionCatalog.displayTitle(for:))
        for overlay in highlightOverlays {
            overlay.setHighlight(
                screenFrame: screenFrame,
                title: title,
                isSelectionLocked: isSelectionLocked
            )
        }
    }

    private func finish(with result: WindowInfo?) {
        guard !didFinish else { return }
        didFinish = true
        close()
        completion(result)
    }

    func close() {
        let shouldRestoreFloatingCaptures = keepsFloatingCapturesVisible
        keepsFloatingCapturesVisible = false
        if let monitor = mouseMonitor {
            NSEvent.removeMonitor(monitor)
            mouseMonitor = nil
        }
        for window in overlayWindows {
            window.close()
        }
        overlayWindows.removeAll()
        highlightOverlays.removeAll()
        hoveredWindowID = nil
        holdsSelectionForResultChoice = false
        if shouldRestoreFloatingCaptures {
            NotificationCenter.default.post(name: .floatingCaptureSelectionEnded, object: nil)
        }
    }
}
