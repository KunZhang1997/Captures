import AppKit
import QuartzCore
import SwiftUI

@Observable
final class QuickAccessManager {
    var captures: [QuickAccessCapture] = []
    /// A lower-corner thumbnail and its full-size page card are two views of
    /// one capture. Never show both at once, and dismiss both from one close.
    var visibleCaptures: [QuickAccessCapture] {
        captures.filter { !visibleFloatingRecordIDs.contains($0.recordID) }
    }
    var screen: NSScreen? { panel?.screen }
    private var panel: QuickAccessPanel?
    private let appState: AppState
    @ObservationIgnored private var observerTokens: [NSObjectProtocol] = []
    private var visibleFloatingRecordIDs: Set<UUID> = []
    private let thumbnailWidth: CGFloat = 240
    private let thumbnailMaxHeight: CGFloat = 170
    private let thumbnailHorizontalInset: CGFloat = 8
    private let thumbnailVerticalInset: CGFloat = 4
    private let panelMaxHeight: CGFloat = 560
    private let panelMinHeight: CGFloat = 120
    private let maxCaptures = 20

    init(appState: AppState) {
        self.appState = appState
        observeCaptures()
        observeLayoutChanges()
        observeFloatingCapturePresentation()
    }

    deinit {
        discardManagedBackings()
        for token in observerTokens {
            NotificationCenter.default.removeObserver(token)
        }
    }

    private func observeCaptures() {
        let token = NotificationCenter.default.addObserver(
            forName: .captureCompleted,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let info = notification.object as? CaptureCompletedInfo else { return }
            self?.addCapture(info)
        }
        observerTokens.append(token)
    }

    private func observeLayoutChanges() {
        let cornerToken = NotificationCenter.default.addObserver(
            forName: .overlayCornerChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.updatePanelLayout(animated: true)
        }
        observerTokens.append(cornerToken)

        let screenToken = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.updatePanelLayout(animated: true)
        }
        observerTokens.append(screenToken)

        let selectionBeganToken = NotificationCenter.default.addObserver(
            forName: .floatingCaptureSelectionBegan,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // Keep the lower-corner cards visible without allowing them to
            // intercept the next selection gesture.
            self?.panel?.ignoresMouseEvents = true
        }
        observerTokens.append(selectionBeganToken)

        let selectionEndedToken = NotificationCenter.default.addObserver(
            forName: .floatingCaptureSelectionEnded,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let panel = self?.panel else { return }
            panel.ignoresMouseEvents = false
            panel.orderFrontRegardless()
        }
        observerTokens.append(selectionEndedToken)
    }

    private func observeFloatingCapturePresentation() {
        let presentationToken = NotificationCenter.default.addObserver(
            forName: .floatingCapturePresentationChanged,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let change = notification.object as? FloatingCapturePresentationChange else { return }
            self?.updateFloatingCapturePresentation(change)
        }
        observerTokens.append(presentationToken)

        let dismissToken = NotificationCenter.default.addObserver(
            forName: .dismissQuickPreviews,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.dismissAll()
        }
        observerTokens.append(dismissToken)
    }

    func addCapture(_ info: CaptureCompletedInfo) {
        guard info.resultMode == .preview else { return }

        let thumbnail = info.thumbnail ?? info.result.image
        let capture = QuickAccessCapture(
            id: UUID(),
            recordID: info.recordID,
            inMemoryImage: info.savedURL == nil && info.managedPreviewURL == nil
                ? info.result.image
                : nil,
            thumbnail: thumbnail,
            mode: info.result.mode,
            timestamp: info.result.timestamp,
            savedURL: info.savedURL,
            savedFileIdentity: info.savedURL.flatMap { CaptureFileIdentity.token(for: $0) },
            managedBackingURL: info.managedPreviewURL,
            managedBackingIdentity: info.managedPreviewURL.flatMap { CaptureFileIdentity.token(for: $0) },
            width: info.result.width,
            height: info.result.height,
            fileSize: info.fileSize,
            scale: info.result.scale
        )
        withAnimation(.interactiveSpring(response: 0.4, dampingFraction: 0.86, blendDuration: 0.12)) {
            captures.insert(capture, at: 0)
            while captures.count > maxCaptures,
                  let savedIndex = captures.lastIndex(where: { $0.savedURL != nil }) {
                // An unsaved preview may be the only remaining full-resolution
                // owner after its page card is closed. Never discard it merely
                // because another capture crossed the presentation limit.
                captures.remove(at: savedIndex)
            }
        }
        refreshPanelPresentation()
    }

    func removeCapture(_ id: UUID) {
        let removedCaptures = captures.filter { $0.id == id }
        withAnimation(.interactiveSpring(response: 0.3, dampingFraction: 0.9, blendDuration: 0.08)) {
            captures.removeAll { $0.id == id }
        }
        removeManagedBackings(for: removedCaptures)
        refreshPanelPresentation(animated: true)
    }

    func dismissAll() {
        let dismissedCaptures = captures
        withAnimation(.easeInOut(duration: 0.2)) {
            captures.removeAll()
        }
        removeManagedBackings(for: dismissedCaptures)
        hidePanel()
    }

    func discardManagedBackings() {
        removeManagedBackings(for: captures)
    }

    private func removeManagedBackings(for captures: [QuickAccessCapture]) {
        for capture in captures {
            guard let url = capture.verifiedManagedBackingURL() else { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func updateFloatingCapturePresentation(_ change: FloatingCapturePresentationChange) {
        if change.isVisible {
            visibleFloatingRecordIDs.insert(change.recordID)
        } else {
            visibleFloatingRecordIDs.remove(change.recordID)
            let dismissedIDs = captures
                .filter { $0.recordID == change.recordID }
                .map(\.id)
            for id in dismissedIDs {
                removeCapture(id)
            }
            if dismissedIDs.isEmpty {
                refreshPanelPresentation(animated: true)
            }
            return
        }
        refreshPanelPresentation(animated: true)
    }

    /// The lower-corner card is a reduced view of the page card, not a
    /// different destination. Clicking it focuses the same full-size card.
    func showOnPage(_ capture: QuickAccessCapture, showingOCR: Bool = false) {
        guard let image = capture.resolvedImage() else { return }
        NotificationCenter.default.post(
            name: .focusFloatingCapture,
            object: FloatingCaptureFocusRequest(
                recordID: capture.recordID,
                image: image,
                scale: capture.scale,
                shouldShowOCR: showingOCR
            )
        )
    }

    func openInEditor(_ capture: QuickAccessCapture) {
        guard let image = capture.resolvedImage() else { return }
        // The lower-corner preview must open the same native editor as a
        // normal "Open Editor" capture. Keep this direct so a legacy
        // notification observer cannot route it back to the retired editor.
        AnnotationEditorWindow.open(with: image, sourceScale: capture.scale)
    }

    func pin(
        _ capture: QuickAccessCapture,
        requestHandler: (PinScreenshotRequest) -> Void = { request in
            NotificationCenter.default.post(name: .pinScreenshot, object: request)
        }
    ) {
        guard let image = capture.resolvedImage() else { return }
        let request = PinScreenshotRequest(image, scale: capture.scale)
        requestHandler(request)
        guard request.succeeded else { return }
        removeCapture(capture.id)
    }

    func copy(_ capture: QuickAccessCapture) {
        guard let image = capture.resolvedImage() else { return }
        PasteboardHelper.copyImage(
            image,
            scale: capture.scale,
            showsConfirmation: true,
            confirmationScreen: screen
        )
    }

    func reveal(_ capture: QuickAccessCapture) {
        guard let url = capture.verifiedSavedURL() else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @discardableResult
    func delete(
        _ capture: QuickAccessCapture,
        fileRemover: (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) }
    ) -> Bool {
        let fileToDelete: URL?
        if capture.savedURL != nil {
            guard let verifiedURL = capture.verifiedSavedURL() else { return false }
            fileToDelete = verifiedURL
        } else if capture.managedBackingURL != nil {
            guard let verifiedURL = capture.verifiedManagedBackingURL() else { return false }
            fileToDelete = verifiedURL
        } else {
            fileToDelete = nil
        }

        if let fileToDelete {
            do {
                try fileRemover(fileToDelete)
            } catch {
                return false
            }
        }

        removeCapture(capture.id)
        NotificationCenter.default.post(name: .deleteHistoryRecord, object: capture.recordID)
        return true
    }

    func presentDeleteFailure() {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = Localization.string("Delete Failed")
        alert.informativeText = Localization.string(
            "The capture file could not be deleted. The quick preview and history entry were kept so the file does not become hidden from you."
        )
        alert.runModal()
    }

    private func showPanel() {
        guard !visibleCaptures.isEmpty else {
            hidePanel()
            return
        }
        if panel == nil {
            let panel = QuickAccessPanel(
                contentRect: NSRect(x: 0, y: 0, width: thumbnailWidth, height: panelMinHeight),
                styleMask: [],
                backing: .buffered,
                defer: true
            )

            let contentView = QuickAccessOverlayView(manager: self, thumbnailWidth: thumbnailWidth)
                .appLanguageLocale()
            let hostingView = NSHostingView(rootView: contentView)
            panel.contentView = hostingView
            self.panel = panel
        }

        let shouldAnimate = panel?.isVisible == true
        updatePanelLayout(animated: shouldAnimate)
        panel?.orderFrontRegardless()
    }

    private func refreshPanelPresentation(animated: Bool = false) {
        guard !visibleCaptures.isEmpty else {
            hidePanel()
            return
        }
        showPanel()
        if animated {
            updatePanelLayout(animated: true)
        }
    }

    private func hidePanel() {
        panel?.orderOut(nil)
        panel = nil
    }

    private func updatePanelLayout(animated: Bool) {
        guard let panel else { return }
        let screen = panel.screen ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return }

        let margin: CGFloat = 16
        let screenFrame = screen.visibleFrame
        let targetSize = NSSize(width: thumbnailWidth, height: targetPanelHeight())

        let origin: NSPoint
        switch appState.overlayCorner {
        case .topLeft:
            origin = NSPoint(
                x: screenFrame.minX + margin,
                y: screenFrame.maxY - targetSize.height - margin
            )
        case .topRight:
            origin = NSPoint(
                x: screenFrame.maxX - targetSize.width - margin,
                y: screenFrame.maxY - targetSize.height - margin
            )
        case .bottomLeft:
            origin = NSPoint(
                x: screenFrame.minX + margin,
                y: screenFrame.minY + margin
            )
        case .bottomRight:
            origin = NSPoint(
                x: screenFrame.maxX - targetSize.width - margin,
                y: screenFrame.minY + margin
            )
        }

        let targetFrame = NSRect(origin: origin, size: targetSize)
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.24
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                panel.animator().setFrame(targetFrame, display: true)
            }
        } else {
            panel.setFrame(targetFrame, display: true)
        }
    }

    private func targetPanelHeight() -> CGFloat {
        let spacing: CGFloat = 8
        let padding: CGFloat = 16
        let captureHeights = visibleCaptures.reduce(CGFloat.zero) { partial, capture in
            partial + estimatedThumbnailHeight(for: capture)
        }
        let contentHeight = captureHeights + max(0, CGFloat(visibleCaptures.count - 1)) * spacing + padding
        return min(panelMaxHeight, max(panelMinHeight, contentHeight))
    }

    private func estimatedThumbnailHeight(for capture: QuickAccessCapture) -> CGFloat {
        let width = max(1, thumbnailWidth - thumbnailHorizontalInset)
        let ratio = CGFloat(capture.height) / max(1, CGFloat(capture.width))
        let rawHeight = width * ratio
        let imageHeight = min(thumbnailMaxHeight, max(56, rawHeight))
        return imageHeight + thumbnailVerticalInset
    }
}

extension Notification.Name {
    /// Hides only the small lower-corner previews. It intentionally does not
    /// affect history records or full-size floating capture cards.
    static let dismissQuickPreviews = Notification.Name("dismissQuickPreviews")
}

struct QuickAccessCapture: Identifiable {
    let id: UUID
    let recordID: UUID
    let inMemoryImage: CGImage?
    let thumbnail: CGImage
    let mode: CaptureMode
    let timestamp: Date
    let savedURL: URL?
    let savedFileIdentity: String?
    let managedBackingURL: URL?
    let managedBackingIdentity: String?
    let width: Int
    let height: Int
    let fileSize: Int
    let scale: CGFloat

    init(
        id: UUID,
        recordID: UUID,
        inMemoryImage: CGImage?,
        thumbnail: CGImage,
        mode: CaptureMode,
        timestamp: Date,
        savedURL: URL?,
        savedFileIdentity: String? = nil,
        managedBackingURL: URL? = nil,
        managedBackingIdentity: String? = nil,
        width: Int,
        height: Int,
        fileSize: Int,
        scale: CGFloat
    ) {
        self.id = id
        self.recordID = recordID
        self.inMemoryImage = inMemoryImage
        self.thumbnail = thumbnail
        self.mode = mode
        self.timestamp = timestamp
        self.savedURL = savedURL
        self.savedFileIdentity = savedFileIdentity ?? savedURL.flatMap { CaptureFileIdentity.token(for: $0) }
        self.managedBackingURL = managedBackingURL
        self.managedBackingIdentity = managedBackingIdentity
            ?? managedBackingURL.flatMap { CaptureFileIdentity.token(for: $0) }
        self.width = width
        self.height = height
        self.fileSize = fileSize
        self.scale = scale
    }

    var formattedFileSize: String {
        ByteCountFormatter.string(fromByteCount: Int64(fileSize), countStyle: .file)
    }

    func resolvedImage() -> CGImage? {
        if let inMemoryImage {
            return inMemoryImage
        }

        guard let backingURL = verifiedSavedURL() ?? verifiedManagedBackingURL() else { return nil }
        guard let nsImage = NSImage(contentsOf: backingURL),
              let cgImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }
        return cgImage
    }

    func verifiedSavedURL() -> URL? {
        guard let savedURL,
              CaptureFileIdentity.matches(savedFileIdentity, at: savedURL) else {
            return nil
        }
        return savedURL
    }

    func verifiedManagedBackingURL() -> URL? {
        guard let managedBackingURL,
              CaptureFileIdentity.matches(managedBackingIdentity, at: managedBackingURL) else {
            return nil
        }
        return managedBackingURL
    }
}
