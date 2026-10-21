import AppKit

enum PinnedScreenshotPanelAppearance: Equatable {
    case pinned
    case floatingCapture
}

final class PinnedScreenshotPanel: NSPanel {
    var isLocked = false {
        didSet { applyLockedState() }
    }
    var currentOpacity: CGFloat = 1.0 {
        didSet { alphaValue = currentOpacity }
    }
    let imageID: UUID
    let sourceImage: CGImage
    let sourceScale: CGFloat
    private(set) var isAlwaysOnTop: Bool
    private let panelAppearance: PinnedScreenshotPanelAppearance
    private var ocrTask: Task<Void, Never>?
    private var recognizedOCRText: String?
    private var ocrFailed = false
    private var ocrPanel: FloatingCaptureOCRPanel?
    private weak var floatingActionBar: FloatingCaptureActionBar?

    init(
        image: CGImage,
        scale: CGFloat = 1,
        frame: NSRect,
        id: UUID = UUID(),
        appearance: PinnedScreenshotPanelAppearance = .pinned
    ) {
        self.imageID = id
        self.sourceImage = image
        self.sourceScale = scale
        self.panelAppearance = appearance
        self.isAlwaysOnTop = appearance == .pinned
        let pointScale = max(1, scale)
        let pointSize = NSSize(
            width: CGFloat(image.width) / pointScale,
            height: CGFloat(image.height) / pointScale
        )
        let aspectRatio = max(pointSize.width / max(pointSize.height, 1), 0.01)
        let initialFrame = appearance == .floatingCapture
            ? Self.aspectCorrectedFrame(frame, aspectRatio: aspectRatio)
            : frame
        let styleMask: NSWindow.StyleMask
        switch appearance {
        case .pinned:
            styleMask = [.nonactivatingPanel, .resizable, .titled, .fullSizeContentView]
        case .floatingCapture:
            // An unpinned Keep on Page card must behave like an ordinary
            // window: it can fall behind another app, but clicking it must
            // activate Captures and bring the card back to the front. A
            // nonactivating panel at `.normal` level cannot do that and can
            // become effectively stranded underneath every other app.
            styleMask = [.borderless, .resizable]
        }
        super.init(
            contentRect: initialFrame,
            styleMask: styleMask,
            backing: .buffered,
            defer: true
        )

        self.level = isAlwaysOnTop ? .floating : .normal
        self.isFloatingPanel = isAlwaysOnTop
        self.hidesOnDeactivate = false
        self.titlebarAppearsTransparent = appearance == .pinned
        self.titleVisibility = .hidden
        self.isMovableByWindowBackground = true
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        self.hasShadow = true
        self.sharingType = appearance == .floatingCapture ? .none : .readWrite
        if appearance == .floatingCapture {
            // The image view is rounded, but a borderless panel is rectangular
            // by default. Make the window's uncovered corners transparent so
            // no white square is visible outside the image card.
            self.isOpaque = false
            self.backgroundColor = .clear
        }
        self.minSize = appearance == .pinned
            ? NSSize(width: 100, height: 100)
            : Self.minimumFloatingSize(for: pointSize)
        if appearance == .floatingCapture {
            contentAspectRatio = pointSize
        }

        let nsImage = NSImage(
            cgImage: image,
            size: pointSize
        )
        let imageView: NSImageView
        if appearance == .floatingCapture {
            imageView = FloatingCaptureImageView(image: nsImage, aspectRatio: aspectRatio)
        } else {
            imageView = NSImageView(image: nsImage)
        }
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.autoresizingMask = [.width, .height]
        imageView.frame = NSRect(origin: .zero, size: initialFrame.size)
        if appearance == .floatingCapture {
            imageView.wantsLayer = true
            imageView.layer?.borderWidth = 1
            imageView.layer?.borderColor = NSColor.labelColor.withAlphaComponent(0.16).cgColor
            imageView.layer?.cornerRadius = FloatingCaptureMetrics.cornerRadius
            imageView.layer?.masksToBounds = true
            imageView.layer?.backgroundColor = NSColor.clear.cgColor

            let actionBar = FloatingCaptureActionBar(frame: NSRect(
                x: FloatingCaptureMetrics.toolbarInset,
                y: max(0, initialFrame.height - FloatingCaptureMetrics.toolbarSize.height - FloatingCaptureMetrics.toolbarInset),
                width: max(0, initialFrame.width - FloatingCaptureMetrics.toolbarInset * 2),
                height: FloatingCaptureMetrics.toolbarSize.height
            ))
            actionBar.identifier = NSUserInterfaceItemIdentifier("floatingCaptureActionBar")
            actionBar.installActions([
                .init(
                    style: .close,
                    symbolName: "xmark",
                    accessibilityDescription: Localization.string("Close"),
                    toolTip: Localization.string("Close")
                ),
                .init(
                    style: .utility,
                    symbolName: "pencil",
                    accessibilityDescription: Localization.string("Edit"),
                    toolTip: Localization.string("Edit")
                ),
                .init(
                    style: .utility,
                    symbolName: "text.viewfinder",
                    accessibilityDescription: Localization.string("OCR"),
                    toolTip: Localization.string("OCR")
                ),
                .init(
                    style: .utility,
                    symbolName: "pin",
                    accessibilityDescription: Localization.string("Keep on Top"),
                    toolTip: Localization.string("Keep on Top")
                ),
            ]) { [weak self] index in
                guard let self else { return }
                switch index {
                case 0: self.closePanel()
                case 1: self.annotateImage()
                case 2: self.toggleOCRPanel()
                case 3: self.toggleAlwaysOnTop()
                default: break
                }
            }
            floatingActionBar = actionBar
            imageView.addSubview(actionBar)
        }
        contentView = imageView

        if appearance == .floatingCapture {
            startBackgroundOCR()
        }
    }

    deinit {
        ocrTask?.cancel()
        dismissOCRPanel()
    }

    override var canBecomeKey: Bool { !isLocked }
    override var canBecomeMain: Bool { false }

    override func scrollWheel(with event: NSEvent) {
        let delta = event.scrollingDeltaY * 0.01
        currentOpacity = max(0.1, min(1.0, currentOpacity + delta))
    }

    override func keyDown(with event: NSEvent) {
        let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
        switch event.keyCode {
        case 123: // Left arrow
            setFrameOrigin(NSPoint(x: frame.origin.x - step, y: frame.origin.y))
        case 124: // Right arrow
            setFrameOrigin(NSPoint(x: frame.origin.x + step, y: frame.origin.y))
        case 125: // Down arrow
            setFrameOrigin(NSPoint(x: frame.origin.x, y: frame.origin.y - step))
        case 126: // Up arrow
            setFrameOrigin(NSPoint(x: frame.origin.x, y: frame.origin.y + step))
        default:
            super.keyDown(with: event)
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        let menu = NSMenu()
        menu.addItem(withTitle: "Copy", action: #selector(copyImage), keyEquivalent: "c")
        menu.addItem(withTitle: "Save As...", action: #selector(saveImage), keyEquivalent: "s")
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "Annotate", action: #selector(annotateImage), keyEquivalent: "")
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: isLocked ? "Unlock" : "Lock", action: #selector(toggleLock), keyEquivalent: "")
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "Close", action: #selector(closePanel), keyEquivalent: "w")

        for item in menu.items {
            item.target = self
        }

        NSMenu.popUpContextMenu(menu, with: event, for: contentView!)
    }

    @objc private func copyImage() {
        PasteboardHelper.copyImage(
            sourceImage,
            scale: sourceScale,
            showsConfirmation: true,
            confirmationScreen: screen
        )
    }

    @objc private func saveImage() {
        let savePanel = NSSavePanel()
        savePanel.canCreateDirectories = true
        savePanel.allowedContentTypes = [.png]
        savePanel.nameFieldStringValue = "Pinned Screenshot.png"
        guard savePanel.runModal() == .OK, let url = savePanel.url else { return }

        do {
            try Self.writePNG(sourceImage, to: url)
        } catch {
            let alert = NSAlert()
            alert.messageText = Localization.string("Save Failed")
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            alert.runModal()
        }
    }

    static func writePNG(_ image: CGImage, to url: URL) throws {
        guard let data = ImageUtils.imageData(image, format: .png) else {
            throw PinnedScreenshotSaveError.encodingFailed
        }
        try data.write(to: url, options: .atomic)
    }

    @objc private func annotateImage() {
        if let imageView = contentView as? NSImageView, let image = imageView.image,
           let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            NotificationCenter.default.post(
                name: .openEditor,
                object: ImageWrapper(cgImage, scale: sourceScale)
            )
            // A persistent pin's backing file is deleted when the panel closes.
            // Keep that source alive until the user explicitly closes it; the
            // transient post-capture card can still hand off to the editor.
            if panelAppearance == .floatingCapture {
                closePanel()
            }
        }
    }

    @objc private func toggleOCRPanel() {
        if let ocrPanel, ocrPanel.isVisible {
            ocrPanel.orderOut(nil)
        } else {
            showOCRPanelIfNeeded()
        }
    }

    func bringToFront(showingOCR: Bool = false) {
        alphaValue = currentOpacity
        ignoresMouseEvents = false
        orderForCurrentLevel()
        if showingOCR {
            showOCRPanelIfNeeded()
        }
    }

    private func showOCRPanelIfNeeded() {
        if let ocrPanel {
            showOCRPanel(ocrPanel)
            return
        }

        let panel = FloatingCaptureOCRPanel(isAlwaysOnTop: isAlwaysOnTop)
        addChildWindow(panel, ordered: .above)
        ocrPanel = panel
        showOCRPanel(panel)
    }

    private func startBackgroundOCR() {
        let image = sourceImage
        ocrTask = Task { [weak self] in
            do {
                let text = try await TextRecognitionService.recognizeText(in: image)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard let self else { return }
                    self.recognizedOCRText = text
                    self.ocrFailed = false
                    self.ocrPanel?.update(text: text, isProcessing: false, failed: false)
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard let self else { return }
                    self.recognizedOCRText = ""
                    self.ocrFailed = true
                    self.ocrPanel?.update(text: "", isProcessing: false, failed: true)
                }
            }
        }
    }

    private func showOCRPanel(_ panel: FloatingCaptureOCRPanel) {
        panel.update(
            text: recognizedOCRText ?? "",
            isProcessing: recognizedOCRText == nil && !ocrFailed,
            failed: ocrFailed
        )
        repositionOCRPanel(panel)
        orderForCurrentLevel()
        panel.orderForCurrentLevel()
    }

    private func repositionOCRPanel(_ panel: FloatingCaptureOCRPanel? = nil) {
        guard let panel = panel ?? ocrPanel else { return }

        let visibleFrame = screen?.visibleFrame
            ?? NSScreen.screens.first(where: { $0.frame.intersects(frame) })?.visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? frame.insetBy(dx: -400, dy: -300)
        let panelSize = panel.frame.size
        let gap: CGFloat = 10
        let clampedX = min(
            max(frame.midX - panelSize.width / 2, visibleFrame.minX),
            visibleFrame.maxX - panelSize.width
        )
        let clampedY = min(
            max(frame.maxY - panelSize.height, visibleFrame.minY),
            visibleFrame.maxY - panelSize.height
        )

        let origin: NSPoint
        if frame.maxX + gap + panelSize.width <= visibleFrame.maxX {
            origin = NSPoint(x: frame.maxX + gap, y: clampedY)
        } else if frame.minX - gap - panelSize.width >= visibleFrame.minX {
            origin = NSPoint(x: frame.minX - gap - panelSize.width, y: clampedY)
        } else if frame.minY - gap - panelSize.height >= visibleFrame.minY {
            origin = NSPoint(x: clampedX, y: frame.minY - gap - panelSize.height)
        } else {
            origin = NSPoint(x: clampedX, y: frame.maxY + gap)
        }
        panel.setFrameOrigin(origin)
    }

    private func dismissOCRPanel() {
        guard let ocrPanel else { return }
        removeChildWindow(ocrPanel)
        ocrPanel.orderOut(nil)
        ocrPanel.close()
        self.ocrPanel = nil
    }

    @objc private func toggleLock() {
        isLocked.toggle()
        NotificationCenter.default.post(name: .pinnedLockChanged, object: imageID)
    }

    @objc private func toggleAlwaysOnTop() {
        guard panelAppearance == .floatingCapture else { return }
        isAlwaysOnTop.toggle()
        level = isAlwaysOnTop ? .floating : .normal
        isFloatingPanel = isAlwaysOnTop
        ocrPanel?.setAlwaysOnTop(isAlwaysOnTop)
        floatingActionBar?.updateAction(
            at: 3,
            symbolName: isAlwaysOnTop ? "pin.fill" : "pin",
            accessibilityDescription: Localization.string(
                isAlwaysOnTop ? "Stop Keeping on Top" : "Keep on Top"
            ),
            toolTip: Localization.string(
                isAlwaysOnTop ? "Stop Keeping on Top" : "Keep on Top"
            ),
            isSelected: isAlwaysOnTop
        )
        orderForCurrentLevel()
    }

    private func orderForCurrentLevel() {
        if isAlwaysOnTop {
            orderFrontRegardless()
        } else {
            orderFront(nil)
        }
    }

    @objc private func closePanel() {
        dismissOCRPanel()
        NotificationCenter.default.post(name: .pinnedScreenshotClosed, object: imageID)
        orderOut(nil)
    }

    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        super.setFrame(frameRect, display: flag)
        repositionOCRPanel()
    }
}

private enum PinnedScreenshotSaveError: LocalizedError {
    case encodingFailed

    var errorDescription: String? {
        Localization.string("Save Failed")
    }
}

private final class FloatingCaptureImageView: NSImageView {
    private enum ResizeCorner {
        case topLeft
        case topRight
        case bottomLeft
        case bottomRight

        var isLeft: Bool {
            switch self {
            case .topLeft, .bottomLeft: return true
            case .topRight, .bottomRight: return false
            }
        }

        var isBottom: Bool {
            switch self {
            case .bottomLeft, .bottomRight: return true
            case .topLeft, .topRight: return false
            }
        }
    }

    private let aspectRatio: CGFloat
    private let resizeHandleSize: CGFloat = 16
    private var activeResizeCorner: ResizeCorner?
    private var resizeStartFrame: NSRect?

    init(image: NSImage, aspectRatio: CGFloat) {
        self.aspectRatio = max(aspectRatio, 0.01)
        super.init(frame: .zero)
        self.image = image
        isEnabled = true
    }

    required init?(coder: NSCoder) {
        aspectRatio = 1
        super.init(coder: coder)
        isEnabled = true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // NSImageView normally treats itself as a display-only control. Walk
        // its action-bar subviews explicitly so the buttons receive clicks;
        // empty parts of the image still fall back to the image view for
        // whole-surface dragging and corner resizing.
        for subview in subviews.reversed() {
            guard !subview.isHidden, subview.alphaValue > 0 else { continue }
            let pointInSubview = convert(point, to: subview)
            guard subview.bounds.contains(pointInSubview) else { continue }
            if let hitView = subview.hitTest(pointInSubview) {
                return hitView
            }
        }
        return self
    }

    override func mouseDown(with event: NSEvent) {
        if let corner = resizeCorner(at: convert(event.locationInWindow, from: nil)),
           let window {
            activeResizeCorner = corner
            resizeStartFrame = window.frame
            return
        }
        window?.performDrag(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let corner = activeResizeCorner,
              let startFrame = resizeStartFrame,
              let window else {
            return
        }

        let currentMouseLocation = NSEvent.mouseLocation
        let rawWidth = corner.isLeft
            ? startFrame.maxX - currentMouseLocation.x
            : currentMouseLocation.x - startFrame.minX
        let rawHeight = corner.isBottom
            ? startFrame.maxY - currentMouseLocation.y
            : currentMouseLocation.y - startFrame.minY
        let widthScale = rawWidth / max(startFrame.width, 1)
        let heightScale = rawHeight / max(startFrame.height, 1)
        let scale = abs(widthScale - 1) >= abs(heightScale - 1)
            ? widthScale
            : heightScale
        let minimumScale = max(
            window.minSize.width / max(startFrame.width, 1),
            window.minSize.height / max(startFrame.height, 1)
        )
        let clampedScale = max(minimumScale, max(0.01, scale))
        let newWidth = startFrame.width * clampedScale
        let newHeight = newWidth / aspectRatio
        let anchor: NSPoint
        switch corner {
        case .topLeft:
            anchor = NSPoint(x: startFrame.maxX, y: startFrame.minY)
        case .topRight:
            anchor = NSPoint(x: startFrame.minX, y: startFrame.minY)
        case .bottomLeft:
            anchor = NSPoint(x: startFrame.maxX, y: startFrame.maxY)
        case .bottomRight:
            anchor = NSPoint(x: startFrame.minX, y: startFrame.maxY)
        }
        let newOrigin = NSPoint(
            x: corner.isLeft ? anchor.x - newWidth : anchor.x,
            y: corner.isBottom ? anchor.y - newHeight : anchor.y
        )
        let newFrame = NSRect(origin: newOrigin, size: NSSize(width: newWidth, height: newHeight))

        window.setFrame(newFrame, display: true)
    }

    override func mouseUp(with event: NSEvent) {
        activeResizeCorner = nil
        resizeStartFrame = nil
    }

    override func layout() {
        super.layout()
        if let actionBar = subviews.first(where: {
            $0.identifier?.rawValue == "floatingCaptureActionBar"
        }) {
            let inset = FloatingCaptureMetrics.toolbarInset
            let availableWidth = max(0, bounds.width - inset * 2)
            let width = availableWidth
            let height = FloatingCaptureMetrics.toolbarSize.height
            actionBar.frame = NSRect(
                x: inset,
                y: max(inset, bounds.maxY - height - inset),
                width: width,
                height: height
            )
            actionBar.layoutSubtreeIfNeeded()
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        window?.rightMouseDown(with: event)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .openHand)
        addCursorRect(
            NSRect(x: 0, y: max(0, bounds.height - resizeHandleSize), width: resizeHandleSize, height: resizeHandleSize),
            cursor: .resizeUpDown
        )
        addCursorRect(
            NSRect(x: max(0, bounds.width - resizeHandleSize), y: max(0, bounds.height - resizeHandleSize), width: resizeHandleSize, height: resizeHandleSize),
            cursor: .resizeUpDown
        )
        addCursorRect(
            NSRect(x: 0, y: 0, width: resizeHandleSize, height: resizeHandleSize),
            cursor: .resizeUpDown
        )
        addCursorRect(
            NSRect(x: max(0, bounds.width - resizeHandleSize), y: 0, width: resizeHandleSize, height: resizeHandleSize),
            cursor: .resizeUpDown
        )
    }

    private func resizeCorner(at location: NSPoint) -> ResizeCorner? {
        let nearLeft = location.x <= resizeHandleSize
        let nearRight = location.x >= bounds.maxX - resizeHandleSize
        let nearBottom = location.y <= resizeHandleSize
        let nearTop = location.y >= bounds.maxY - resizeHandleSize

        switch (nearLeft, nearRight, nearBottom, nearTop) {
        case (true, false, false, true): return .topLeft
        case (false, true, false, true): return .topRight
        case (true, false, true, false): return .bottomLeft
        case (false, true, true, false): return .bottomRight
        default: return nil
        }
    }
}

private final class FloatingCaptureOCRPanel: NSPanel {
    private let ocrView = FloatingCaptureOCRView()
    private var isAlwaysOnTop: Bool

    init(isAlwaysOnTop: Bool) {
        self.isAlwaysOnTop = isAlwaysOnTop
        super.init(
            contentRect: NSRect(origin: .zero, size: FloatingCaptureMetrics.ocrPanelSize),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        level = isAlwaysOnTop ? .floating : .normal
        isFloatingPanel = isAlwaysOnTop
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hasShadow = true
        isOpaque = false
        backgroundColor = .clear
        sharingType = .none
        contentView = ocrView
        ocrView.closeHandler = { [weak self] in
            self?.orderOut(nil)
        }
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    func update(text: String, isProcessing: Bool, failed: Bool) {
        ocrView.update(text: text, isProcessing: isProcessing, failed: failed)
    }

    func setAlwaysOnTop(_ value: Bool) {
        isAlwaysOnTop = value
        level = value ? .floating : .normal
        isFloatingPanel = value
    }

    func orderForCurrentLevel() {
        if isAlwaysOnTop {
            orderFrontRegardless()
        } else {
            orderFront(nil)
        }
    }
}

private final class FloatingCaptureOCRView: NSView {
    private let ocrTextView = NSTextView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let copyButton = NSButton(title: Localization.string("Copy"), target: nil, action: nil)
    var closeHandler: (() -> Void)?

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = FloatingCaptureMetrics.cornerRadius
        layer?.borderWidth = 1
        layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.98).cgColor
        layer?.borderColor = NSColor.labelColor.withAlphaComponent(0.16).cgColor
        layer?.masksToBounds = true

        let titleIcon = NSImageView(image: NSImage(
            systemSymbolName: "text.viewfinder",
            accessibilityDescription: Localization.string("OCR")
        ) ?? NSImage())
        titleIcon.imageScaling = .scaleProportionallyDown
        titleIcon.contentTintColor = .secondaryLabelColor
        titleIcon.translatesAutoresizingMaskIntoConstraints = false
        titleIcon.widthAnchor.constraint(equalToConstant: 16).isActive = true
        titleIcon.heightAnchor.constraint(equalToConstant: 16).isActive = true

        let title = NSTextField(labelWithString: Localization.string("OCR"))
        title.font = .systemFont(ofSize: 13, weight: .semibold)

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor

        let closeButton = NSButton(
            image: NSImage(
                systemSymbolName: "xmark",
                accessibilityDescription: Localization.string("Close")
            ) ?? NSImage(),
            target: self,
            action: #selector(closeOCRPanel)
        )
        closeButton.setButtonType(.momentaryPushIn)
        closeButton.isBordered = false
        closeButton.controlSize = .small
        closeButton.contentTintColor = .secondaryLabelColor
        closeButton.toolTip = Localization.string("Close")
        closeButton.imageScaling = .scaleProportionallyDown
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.widthAnchor.constraint(equalToConstant: 24).isActive = true
        closeButton.heightAnchor.constraint(equalToConstant: 24).isActive = true

        let headerSpacer = NSView()
        headerSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let header = NSStackView(views: [titleIcon, title, headerSpacer, statusLabel, closeButton])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 8

        ocrTextView.isEditable = false
        ocrTextView.isSelectable = true
        ocrTextView.isRichText = false
        ocrTextView.font = .systemFont(ofSize: 13)
        ocrTextView.drawsBackground = false
        ocrTextView.textContainerInset = NSSize(width: 2, height: 4)
        ocrTextView.isVerticallyResizable = true
        ocrTextView.isHorizontallyResizable = false
        ocrTextView.autoresizingMask = [.width]
        ocrTextView.textContainer?.widthTracksTextView = true

        let scroll = NSScrollView()
        scroll.documentView = ocrTextView
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        scroll.setContentCompressionResistancePriority(.defaultLow, for: .vertical)

        copyButton.title = Localization.string("Copy")
        copyButton.bezelStyle = .rounded
        copyButton.isBordered = true
        copyButton.controlSize = .small
        copyButton.font = .systemFont(ofSize: 12, weight: .medium)
        copyButton.target = self
        copyButton.action = #selector(copyAllText)
        copyButton.setContentHuggingPriority(.required, for: .horizontal)

        let footerSpacer = NSView()
        footerSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let footer = NSStackView(views: [footerSpacer, copyButton])
        footer.orientation = .horizontal
        footer.alignment = .centerY

        let stack = NSStackView(views: [header, scroll, footer])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            header.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            footer.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])

        update(text: "", isProcessing: true, failed: false)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    func update(text: String, isProcessing: Bool, failed: Bool) {
        ocrTextView.string = text
        copyButton.isEnabled = !text.isEmpty && !isProcessing
        copyButton.alphaValue = copyButton.isEnabled ? 1 : 0.5

        if isProcessing {
            statusLabel.stringValue = Localization.string("Reading text...")
        } else if failed {
            statusLabel.stringValue = Localization.string("OCR Failed")
        } else if text.isEmpty {
            statusLabel.stringValue = Localization.string("No text detected")
        } else {
            statusLabel.stringValue = String(
                format: Localization.string("%lld characters"),
                Int64(text.count)
            )
        }
    }

    @objc private func closeOCRPanel() {
        closeHandler?()
    }

    @objc private func copyAllText() {
        guard !ocrTextView.string.isEmpty else { return }
        _ = PasteboardHelper.copyText(
            ocrTextView.string,
            showsConfirmation: true,
            confirmationScreen: window?.screen
        )
    }

}

private struct FloatingCaptureToolbarAction {
    let style: FloatingCaptureToolbarActionStyle
    let symbolName: String
    let accessibilityDescription: String
    let toolTip: String
}

private enum FloatingCaptureToolbarActionStyle {
    case close
    case utility
}

/// Keep the real macOS close meaning on the left. Editing, OCR, and window
/// pinning are independent utility actions aligned on the right, rather than
/// borrowing the yellow and green traffic-light semantics.
private final class FloatingCaptureActionBar: NSView {
    private var actionHandler: ((Int) -> Void)?
    private var actionButtons: [NSButton] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    func installActions(
        _ actions: [FloatingCaptureToolbarAction],
        handler: @escaping (Int) -> Void
    ) {
        actionHandler = handler
        actionButtons.forEach { $0.removeFromSuperview() }
        actionButtons = actions.enumerated().map { index, action in
            let button: NSButton
            switch action.style {
            case .close:
                button = FloatingCaptureTrafficLightButton(
                    color: .init(red: 1.0, green: 0.37, blue: 0.34, alpha: 1),
                    symbolName: action.symbolName,
                    accessibilityDescription: action.accessibilityDescription,
                    toolTip: action.toolTip
                )
            case .utility:
                button = FloatingCaptureUtilityButton(
                    symbolName: action.symbolName,
                    accessibilityDescription: action.accessibilityDescription,
                    toolTip: action.toolTip
                )
            }
            button.tag = index
            button.target = self
            button.action = #selector(performAction(_:))
            addSubview(button)
            return button
        }
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    override func layout() {
        super.layout()
        let hitSize = FloatingCaptureMetrics.toolbarHitSize
        let spacing = FloatingCaptureMetrics.toolbarItemSpacing
        actionButtons.first?.frame = NSRect(
            x: 0,
            y: (bounds.height - hitSize) / 2,
            width: hitSize,
            height: hitSize
        )
        for (offset, button) in actionButtons.dropFirst().reversed().enumerated() {
            button.frame = NSRect(
                x: bounds.maxX - hitSize - CGFloat(offset) * (hitSize + spacing),
                y: (bounds.height - hitSize) / 2,
                width: hitSize,
                height: hitSize
            )
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard bounds.contains(point) else { return nil }
        for button in actionButtons.reversed() {
            let pointInButton = convert(point, to: button)
            if button.bounds.contains(pointInButton) {
                return button
            }
        }
        return nil
    }

    @objc private func performAction(_ sender: NSButton) {
        actionHandler?(sender.tag)
    }

    func updateAction(
        at index: Int,
        symbolName: String,
        accessibilityDescription: String,
        toolTip: String,
        isSelected: Bool
    ) {
        guard actionButtons.indices.contains(index),
              let button = actionButtons[index] as? FloatingCaptureUtilityButton else { return }
        button.update(
            symbolName: symbolName,
            accessibilityDescription: accessibilityDescription,
            toolTip: toolTip,
            isSelected: isSelected
        )
    }
}

private final class FloatingCaptureUtilityButton: NSButton {
    init(symbolName: String, accessibilityDescription: String, toolTip: String) {
        super.init(frame: .zero)
        title = ""
        isBordered = false
        bezelStyle = .regularSquare
        focusRingType = .none
        imagePosition = .imageOnly
        wantsLayer = true
        layer?.cornerRadius = 6
        update(
            symbolName: symbolName,
            accessibilityDescription: accessibilityDescription,
            toolTip: toolTip,
            isSelected: false
        )
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    func update(
        symbolName: String,
        accessibilityDescription: String,
        toolTip: String,
        isSelected: Bool
    ) {
        image = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: accessibilityDescription
        )?.withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))
        image?.isTemplate = true
        contentTintColor = isSelected ? .controlAccentColor : .labelColor
        layer?.backgroundColor = (
            isSelected
                ? NSColor.controlAccentColor.withAlphaComponent(0.16)
                : NSColor.windowBackgroundColor.withAlphaComponent(0.86)
        ).cgColor
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.7).cgColor
        self.toolTip = toolTip
        setAccessibilityLabel(accessibilityDescription)
        setAccessibilityValue(isSelected ? Localization.string("On") : Localization.string("Off"))
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .arrow)
    }
}

private final class FloatingCaptureTrafficLightButton: NSButton {
    private let fillColor: NSColor
    private let symbolName: String
    private var hoverTrackingArea: NSTrackingArea?
    private var isPointerInside = false {
        didSet { needsDisplay = true }
    }

    init(color: NSColor, symbolName: String, accessibilityDescription: String, toolTip: String) {
        fillColor = color
        self.symbolName = symbolName
        super.init(frame: .zero)
        title = ""
        isBordered = false
        bezelStyle = .regularSquare
        focusRingType = .none
        self.toolTip = toolTip
        setAccessibilityLabel(accessibilityDescription)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    override func draw(_ dirtyRect: NSRect) {
        let diameter = FloatingCaptureMetrics.toolbarLightDiameter
        let circle = NSRect(
            x: (bounds.width - diameter) / 2,
            y: (bounds.height - diameter) / 2,
            width: diameter,
            height: diameter
        )
        let color = isHighlighted ? fillColor.blended(withFraction: 0.18, of: .black) ?? fillColor : fillColor
        color.setFill()
        NSBezierPath(ovalIn: circle).fill()

        guard isPointerInside,
              let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 8, weight: .bold)) else {
            return
        }
        symbol.isTemplate = false
        symbol.draw(
            in: circle.insetBy(dx: 4, dy: 4),
            from: .zero,
            operation: .sourceOver,
            fraction: 0.72,
            respectFlipped: true,
            hints: nil
        )
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isPointerInside = true
    }

    override func mouseExited(with event: NSEvent) {
        isPointerInside = false
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .arrow)
    }
}

private enum FloatingCaptureMetrics {
    static let cornerRadius = CapturesWindowStyle.cornerRadius
    static let toolbarInset: CGFloat = 10
    static let toolbarSize = NSSize(width: 0, height: 24)
    static let toolbarHitSize: CGFloat = 24
    static let toolbarLightDiameter: CGFloat = 16
    static let toolbarItemSpacing: CGFloat = 4
    static let ocrPanelSize = NSSize(width: 300, height: 220)
}

extension Notification.Name {
    static let pinnedScreenshotClosed = Notification.Name("pinnedScreenshotClosed")
    static let pinnedLockChanged = Notification.Name("pinnedLockChanged")
    static let showFloatingCapture = Notification.Name("showFloatingCapture")
    static let focusFloatingCapture = Notification.Name("focusFloatingCapture")
    static let floatingCapturePresentationChanged = Notification.Name("floatingCapturePresentationChanged")
    static let floatingCaptureSelectionBegan = Notification.Name("floatingCaptureSelectionBegan")
    static let floatingCaptureSelectionEnded = Notification.Name("floatingCaptureSelectionEnded")
}

struct FloatingCaptureRequest {
    let recordID: UUID
    let image: CGImage
    let scale: CGFloat
    let frame: NSRect?
}

struct FloatingCaptureFocusRequest {
    let recordID: UUID
    let image: CGImage
    let scale: CGFloat
    let shouldShowOCR: Bool
}

struct FloatingCapturePresentationChange {
    let recordID: UUID
    let isVisible: Bool
}

private extension PinnedScreenshotPanel {
    static func minimumFloatingSize(for pointSize: NSSize) -> NSSize {
        let widthScale = 96 / max(pointSize.width, 1)
        let heightScale = 72 / max(pointSize.height, 1)
        let scale = max(widthScale, heightScale)
        return NSSize(width: pointSize.width * scale, height: pointSize.height * scale)
    }

    static func aspectCorrectedFrame(_ frame: NSRect, aspectRatio: CGFloat) -> NSRect {
        guard frame.width > 0, frame.height > 0 else { return frame }
        let width = min(frame.width, frame.height * aspectRatio)
        let height = width / aspectRatio
        return NSRect(
            x: frame.midX - width / 2,
            y: frame.midY - height / 2,
            width: width,
            height: height
        )
    }

    func applyLockedState() {
        // A locked pin must still receive right-clicks so its Unlock command is
        // reachable. Lock its geometry instead of making the entire panel
        // click-through and permanently inaccessible.
        ignoresMouseEvents = false
        isMovable = !isLocked
        isMovableByWindowBackground = !isLocked
        if isLocked {
            styleMask.remove(.resizable)
        } else {
            styleMask.insert(.resizable)
        }
    }
}
