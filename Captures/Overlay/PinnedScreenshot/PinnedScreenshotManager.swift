import AppKit

final class PinnedScreenshotManager {
    private var panels: [UUID: PinnedScreenshotPanel] = [:]
    private var floatingPanels: [UUID: PinnedScreenshotPanel] = [:]
    private var floatingPanelIDsByRecordID: [UUID: UUID] = [:]
    private var floatingCaptureSelectionOpacities: [UUID: CGFloat] = [:]
    private let appState: AppState
    private let defaults: UserDefaults
    private let pinsDirectoryOverride: URL?
    private var observerTokens: [NSObjectProtocol] = []

    init(
        appState: AppState,
        defaults: UserDefaults = .standard,
        pinsDirectoryOverride: URL? = nil
    ) {
        self.appState = appState
        self.defaults = defaults
        self.pinsDirectoryOverride = pinsDirectoryOverride
        observeNotifications()
        restorePersistedState()
    }

    deinit {
        for token in observerTokens {
            NotificationCenter.default.removeObserver(token)
        }
    }

    private func observeNotifications() {
        let pinToken = NotificationCenter.default.addObserver(
            forName: .pinScreenshot,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            if let request = notification.object as? PinScreenshotRequest {
                request.succeeded = self.pinImage(request.image, scale: request.scale)
                if !request.succeeded {
                    self.presentPinSaveFailure()
                }
            } else if let wrapper = notification.object as? ImageWrapper,
                      !self.pinImage(wrapper.image, scale: wrapper.scale) {
                self.presentPinSaveFailure()
            }
        }
        observerTokens.append(pinToken)

        let floatingCaptureToken = NotificationCenter.default.addObserver(
            forName: .showFloatingCapture,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            if let request = notification.object as? FloatingCaptureRequest {
                self?.showFloatingCapture(
                    request.image,
                    scale: request.scale,
                    recordID: request.recordID,
                    frame: request.frame
                )
            } else if let wrapper = notification.object as? ImageWrapper {
                // Keep supporting the original notification payload for callers
                // outside the capture coordinator.
                self?.showFloatingCapture(wrapper.image, scale: wrapper.scale)
            }
        }
        observerTokens.append(floatingCaptureToken)

        let focusFloatingCaptureToken = NotificationCenter.default.addObserver(
            forName: .focusFloatingCapture,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let request = notification.object as? FloatingCaptureFocusRequest else { return }
            self?.focusFloatingCapture(request)
        }
        observerTokens.append(focusFloatingCaptureToken)

        let selectionBeganToken = NotificationCenter.default.addObserver(
            forName: .floatingCaptureSelectionBegan,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.keepFloatingCapturesVisibleDuringSelection()
        }
        observerTokens.append(selectionBeganToken)

        let selectionEndedToken = NotificationCenter.default.addObserver(
            forName: .floatingCaptureSelectionEnded,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.restoreFloatingCapturesAfterSelection()
        }
        observerTokens.append(selectionEndedToken)

        let closeToken = NotificationCenter.default.addObserver(
            forName: .pinnedScreenshotClosed,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let id = notification.object as? UUID else { return }
            guard let self else { return }
            if self.panels.removeValue(forKey: id) != nil {
                self.persistState()
            } else {
                let recordID = self.floatingPanelIDsByRecordID.first { $0.value == id }?.key
                self.floatingPanels.removeValue(forKey: id)
                if let recordID {
                    self.floatingPanelIDsByRecordID.removeValue(forKey: recordID)
                    NotificationCenter.default.post(
                        name: .floatingCapturePresentationChanged,
                        object: FloatingCapturePresentationChange(recordID: recordID, isVisible: false)
                    )
                }
            }
        }
        observerTokens.append(closeToken)

        let lockToken = NotificationCenter.default.addObserver(
            forName: .pinnedLockChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.persistState()
        }
        observerTokens.append(lockToken)

        let opacityToken = NotificationCenter.default.addObserver(
            forName: .pinnedOpacityChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.applyDefaultOpacityToAllPanels()
        }
        observerTokens.append(opacityToken)
    }

    @discardableResult
    func pinImage(
        _ image: CGImage,
        scale: CGFloat = 1,
        frame: NSRect? = nil,
        id: UUID = UUID(),
        opacity: CGFloat? = nil,
        locked: Bool = false,
        persist: Bool = true
    ) -> Bool {
        if persist, !writePinImage(image, id: id) {
            return false
        }

        let pointScale = max(1, scale)
        let defaultSize = NSSize(
            width: min(CGFloat(image.width) / pointScale / 2, 400),
            height: min(CGFloat(image.height) / pointScale / 2, 300)
        )
        let panelFrame = frame ?? NSRect(
            x: (NSScreen.main?.frame.midX ?? 500) - defaultSize.width / 2,
            y: (NSScreen.main?.frame.midY ?? 400) - defaultSize.height / 2,
            width: defaultSize.width,
            height: defaultSize.height
        )

        let panel = PinnedScreenshotPanel(image: image, scale: pointScale, frame: panelFrame, id: id)
        panel.currentOpacity = opacity ?? CGFloat(appState.defaultPinnedOpacity)
        panel.isLocked = locked
        panels[panel.imageID] = panel
        panel.makeKeyAndOrderFront(nil)
        if persist {
            _ = persistState()
        }
        return true
    }

    /// The "Keep on Page" route is deliberately transient: it keeps the
    /// capture at its real point size on the desktop until the user closes it,
    /// but it does not turn every quick capture into a persistent pin.
    func showFloatingCapture(
        _ image: CGImage,
        scale: CGFloat = 1,
        recordID: UUID? = nil,
        frame: NSRect? = nil
    ) {
        // Starting another capture must never dismiss the cards that are
        // already on the page. Reassert their visible state before adding the
        // new card because the selector temporarily changes their input
        // behavior while it owns the capture gesture.
        restoreFloatingCapturesToFront()

        let pointScale = max(1, scale)
        let pointSize = NSSize(
            width: CGFloat(image.width) / pointScale,
            height: CGFloat(image.height) / pointScale
        )
        let screen = screenUnderPointer() ?? NSScreen.main ?? NSScreen.screens.first
        let panelFrame = frame.map { NSRect(origin: $0.origin, size: pointSize) }
            ?? nextFloatingFrame(for: pointSize, on: screen)
        let panel = PinnedScreenshotPanel(
            image: image,
            scale: pointScale,
            frame: panelFrame,
            appearance: .floatingCapture
        )
        panel.currentOpacity = 1
        floatingPanels[panel.imageID] = panel
        if let recordID {
            floatingPanelIDsByRecordID[recordID] = panel.imageID
            NotificationCenter.default.post(
                name: .floatingCapturePresentationChanged,
                object: FloatingCapturePresentationChange(recordID: recordID, isVisible: true)
            )
        }
        panel.bringToFront()
    }

    private func focusFloatingCapture(_ request: FloatingCaptureFocusRequest) {
        if let panelID = floatingPanelIDsByRecordID[request.recordID],
           let panel = floatingPanels[panelID] {
            panel.bringToFront(showingOCR: request.shouldShowOCR)
            return
        }

        // A lower-corner entry can focus a card that is temporarily absent
        // from this manager during notification ordering. A user-closed card
        // is removed from Quick Access and cannot be recreated from here.
        showFloatingCapture(
            request.image,
            scale: request.scale,
            recordID: request.recordID
        )
        if request.shouldShowOCR,
           let panelID = floatingPanelIDsByRecordID[request.recordID],
           let panel = floatingPanels[panelID] {
            panel.bringToFront(showingOCR: true)
        }
    }

    private func keepFloatingCapturesVisibleDuringSelection() {
        guard floatingCaptureSelectionOpacities.isEmpty else { return }

        for (id, panel) in floatingPanels {
            floatingCaptureSelectionOpacities[id] = panel.currentOpacity
            // Keep existing screenshots fully visible while selecting a new
            // one. The selector windows receive the gesture; the cards remain
            // visible and are click-through only for this short interval.
            panel.alphaValue = panel.currentOpacity
            panel.ignoresMouseEvents = true
            panel.bringToFront()
        }
    }

    private func restoreFloatingCapturesAfterSelection() {
        for (id, opacity) in floatingCaptureSelectionOpacities {
            guard let panel = floatingPanels[id] else { continue }
            panel.alphaValue = opacity
            panel.ignoresMouseEvents = false
            // Closing the selector can leave same-level floating panels below
            // it. Put every retained card back in the visible window order;
            // otherwise the panel still exists but looks as though it vanished.
            panel.bringToFront()
        }
        floatingCaptureSelectionOpacities.removeAll()
    }

    private func restoreFloatingCapturesToFront() {
        for panel in floatingPanels.values {
            panel.alphaValue = panel.currentOpacity
            panel.ignoresMouseEvents = false
            panel.orderFrontRegardless()
        }
    }

    private func screenUnderPointer() -> NSScreen? {
        let mouseLocation = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouseLocation) }
    }

    private func nextFloatingFrame(for size: NSSize, on screen: NSScreen?) -> NSRect {
        let screenFrame = screen?.visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let cascade = CGFloat(floatingPanels.count % 8) * 22
        let mouseLocation = NSEvent.mouseLocation
        let proposedOrigin = NSPoint(
            x: mouseLocation.x - size.width / 2 + cascade,
            y: mouseLocation.y - size.height / 2 - cascade
        )
        let margin: CGFloat = 8
        let maxX = max(screenFrame.minX + margin, screenFrame.maxX - size.width - margin)
        let maxY = max(screenFrame.minY + margin, screenFrame.maxY - size.height - margin)
        let origin = NSPoint(
            x: min(max(proposedOrigin.x, screenFrame.minX + margin), maxX),
            y: min(max(proposedOrigin.y, screenFrame.minY + margin), maxY)
        )
        return NSRect(origin: origin, size: size)
    }

    private func applyDefaultOpacityToAllPanels() {
        let opacity = CGFloat(appState.defaultPinnedOpacity)
        for (_, panel) in panels {
            panel.currentOpacity = opacity
        }
        _ = persistState()
    }

    private var pinsDirectory: URL? {
        let directory: URL
        if let pinsDirectoryOverride {
            directory = pinsDirectoryOverride
        } else {
            guard let appSupport = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first else { return nil }
            directory = appSupport.appendingPathComponent("Captures/Pins", isDirectory: true)
        }

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let values = try directory.resourceValues(forKeys: [.isDirectoryKey])
            guard values.isDirectory == true else { return nil }
            return directory
        } catch {
            return nil
        }
    }

    private func writePinImage(_ image: CGImage, id: UUID) -> Bool {
        guard let directory = pinsDirectory else { return false }
        let imageURL = directory.appendingPathComponent("\(id.uuidString).png")
        do {
            try PinnedScreenshotPanel.writePNG(image, to: imageURL)
            return true
        } catch {
            return false
        }
    }

    @discardableResult
    private func persistState() -> Bool {
        if panels.isEmpty {
            defaults.set([], forKey: Constants.Keys.pinnedScreenshots)
            if let directory = pinsDirectory {
                removeOrphanedPinImages(in: directory, keeping: [])
            }
            return true
        }
        guard let directory = pinsDirectory else { return false }

        var states: [[String: Any]] = []
        var durableIDs: Set<UUID> = []
        for (id, panel) in panels {
            let imageURL = directory.appendingPathComponent("\(id.uuidString).png")
            if !FileManager.default.fileExists(atPath: imageURL.path),
               !writePinImage(panel.sourceImage, id: id) {
                continue
            }
            durableIDs.insert(id)
            let state: [String: Any] = [
                "id": id.uuidString,
                "x": panel.frame.origin.x,
                "y": panel.frame.origin.y,
                "width": panel.frame.width,
                "height": panel.frame.height,
                "opacity": panel.currentOpacity,
                "locked": panel.isLocked,
                "scale": panel.sourceScale,
            ]
            states.append(state)
        }
        defaults.set(states, forKey: Constants.Keys.pinnedScreenshots)
        removeOrphanedPinImages(in: directory, keeping: durableIDs)
        return durableIDs.count == panels.count
    }

    private func removeOrphanedPinImages(in directory: URL, keeping ids: Set<UUID>) {
        guard let files = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
              ) else { return }
        for file in files where file.pathExtension == "png" {
            guard let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent),
                  !ids.contains(id) else { continue }
            try? FileManager.default.removeItem(at: file)
        }
    }

    private func restorePersistedState() {
        guard let states = defaults.array(
            forKey: Constants.Keys.pinnedScreenshots
        ) as? [[String: Any]],
        let directory = pinsDirectory else { return }

        for state in states {
            guard let idString = state["id"] as? String,
                  let id = UUID(uuidString: idString),
                  let x = (state["x"] as? NSNumber)?.doubleValue,
                  let y = (state["y"] as? NSNumber)?.doubleValue,
                  let width = (state["width"] as? NSNumber)?.doubleValue,
                  let height = (state["height"] as? NSNumber)?.doubleValue else { continue }

            let imageURL = directory.appendingPathComponent("\(id.uuidString).png")
            guard let nsImage = NSImage(contentsOf: imageURL),
                  let cgImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                continue
            }

            // Defer persistence until every pin is restored — persisting per pin
            // would run orphan cleanup with only the pins restored so far in
            // `panels`, deleting the image files of pins not yet restored.
            _ = pinImage(
                cgImage,
                scale: (state["scale"] as? NSNumber).map { CGFloat($0.doubleValue) } ?? 1,
                frame: NSRect(x: x, y: y, width: width, height: height),
                id: id,
                opacity: (state["opacity"] as? NSNumber).map { CGFloat($0.doubleValue) },
                locked: (state["locked"] as? NSNumber)?.boolValue ?? false,
                persist: false
            )
        }

        // Persist once now that all panels exist, reconciling UserDefaults and
        // pruning image files for any pins that failed to restore.
        _ = persistState()
    }

    private func presentPinSaveFailure() {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = Localization.string("Save Failed")
        alert.informativeText = Localization.string(
            "Captures could not store the pinned image. The original quick capture has been kept so you can try again or save it elsewhere."
        )
        alert.runModal()
    }
}
