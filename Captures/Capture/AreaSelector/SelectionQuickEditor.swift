import AppKit

/// Keeps marks in immutable desktop pixel coordinates. The crop can be changed
/// only before the first annotation, so marks and their source pixels never
/// need to be rebased.
final class SelectionQuickEditor {
    static let tools: [ToolType] = [.textSelect, .rectangle, .ellipse, .arrow, .pencil, .text, .pixelate]
    private let snapshot: FrozenScreenSnapshot
    private let desktopFrame: CGRect
    private let retinaScale: Bool
    private var canvases: [CanvasNSView] = []
    private(set) var selectionRect: CGRect
    private(set) var canvasState: CanvasState?
    let toolManager = ToolManager()
    var onStateChange: (() -> Void)?
    var onCanvasPrepared: (() -> Void)?
    var onModeChange: (() -> Void)?

    init(snapshot: FrozenScreenSnapshot, selectionRect: CGRect, retinaScale: Bool) {
        self.snapshot = snapshot
        self.selectionRect = selectionRect
        self.retinaScale = retinaScale
        desktopFrame = snapshot.displays.reduce(CGRect.null) { $0.union($1.frame) }
        toolManager.currentTool = .textSelect
        toolManager.strokeWidth = 3
        toolManager.defersTextUndoUntilCommit = true
    }

    var canStartLongCapture: Bool { canvasState?.annotations.isEmpty ?? true }
    var canAdjustSelection: Bool { canvasState?.annotations.isEmpty ?? true }
    /// Crop geometry is only direct-manipulation in the default Select Annotation
    /// mode. Once a drawing tool is selected, every pointer drag — even over a
    /// crop handle — belongs to that tool; otherwise the initial mark can be
    /// swallowed as a resize gesture.
    var canDirectlyAdjustSelection: Bool {
        canAdjustSelection && toolManager.currentTool == .textSelect
    }

    var canDirectlyMoveSelection: Bool { canDirectlyAdjustSelection }

    private var sourceScale: CGFloat {
        guard let canvasState, desktopFrame.width > 0 else { return 1 }
        return CGFloat(canvasState.imageWidth) / desktopFrame.width
    }

    var selectedPixelRect: CGRect {
        CGRect(x: (selectionRect.minX - desktopFrame.minX) * sourceScale,
               y: (selectionRect.minY - desktopFrame.minY) * sourceScale,
               width: selectionRect.width * sourceScale, height: selectionRect.height * sourceScale)
    }

    @discardableResult
    func selectTool(_ tool: ToolType) -> Bool {
        guard Self.tools.contains(tool) else { return false }
        commitPendingEdits()
        if canvasState == nil {
            guard let image = snapshot.image(for: desktopFrame, retinaScale: retinaScale) else { return false }
            canvasState = CanvasState(image: image)
            // Parameters are expressed in source pixels, but start at a
            // consistent on-screen weight on both Retina and 1x displays.
            toolManager.strokeWidth = 3 * sourceScale
            toolManager.fontSize = 18 * sourceScale
            toolManager.pixelateBlockSize = 10 * sourceScale
            onCanvasPrepared?()
        }
        toolManager.currentTool = tool
        refreshCanvases()
        onModeChange?()
        onStateChange?()
        return true
    }

    func makeCanvasView() -> CanvasNSView? {
        guard let canvasState else { return nil }
        let view = CanvasNSView(canvasState: canvasState, toolManager: toolManager)
        view.frame = CGRect(origin: .zero, size: selectionRect.size)
        view.captureSelectionViewport = selectedPixelRect
        view.onCaptureContentChange = { [weak self] in
            self?.refreshCanvases()
            self?.onStateChange?()
        }
        view.onEditingStateChange = view.onCaptureContentChange
        canvases.append(view)
        return view
    }

    func updateSelection(_ rect: CGRect) -> Bool {
        guard canAdjustSelection, rect.width > 0, rect.height > 0 else { return false }
        commitPendingEdits()
        guard canAdjustSelection else { return false }
        selectionRect = rect
        refreshCanvases()
        onStateChange?()
        return true
    }

    func commitPendingEdits() {
        canvases.forEach { $0.commitPendingEdits() }
    }

    var isEditingInlineText: Bool {
        canvases.contains { $0.isInlineTextEditing }
    }

    func exportImage() -> CGImage? {
        commitPendingEdits()
        guard let canvasState, !canvasState.annotations.isEmpty else {
            return snapshot.image(for: selectionRect, retinaScale: retinaScale)
        }
        guard let rendered = canvasState.renderFinalImage(in: selectedPixelRect) else { return nil }
        let intersecting = snapshot.displays.filter { $0.frame.intersects(selectionRect) }
        let outputScale = retinaScale ? max(1, intersecting.map { max($0.scaleX, $0.scaleY) }.max() ?? 1) : 1
        let size = CGSize(width: ceil(selectionRect.width * outputScale), height: ceil(selectionRect.height * outputScale))
        if rendered.width == Int(size.width), rendered.height == Int(size.height) { return rendered }
        return ImageUtils.resize(rendered, to: size)
    }

    func undo() {
        commitPendingEdits()
        if let canvasState { canvasState.undoManager.undo(state: canvasState) }
        refreshCanvases()
        onStateChange?()
    }

    func redo() {
        commitPendingEdits()
        if let canvasState { canvasState.undoManager.redo(state: canvasState) }
        refreshCanvases()
        onStateChange?()
    }

    func setColor(_ color: NSColor) { toolManager.strokeColor = color; onStateChange?() }

    func setSize(_ points: CGFloat) {
        if toolManager.currentTool == .text { toolManager.fontSize = points * sourceScale }
        else if toolManager.currentTool == .pixelate { toolManager.pixelateBlockSize = points * sourceScale }
        else { toolManager.strokeWidth = points * sourceScale }
        onStateChange?()
    }

    var sizeInPoints: CGFloat {
        let value = toolManager.currentTool == .text ? toolManager.fontSize
            : toolManager.currentTool == .pixelate ? toolManager.pixelateBlockSize : toolManager.strokeWidth
        return value / sourceScale
    }

    private func refreshCanvases() {
        for canvas in canvases {
            canvas.setFrameSize(selectionRect.size)
            canvas.captureSelectionViewport = selectedPixelRect
            canvas.window?.invalidateCursorRects(for: canvas)
            canvas.needsDisplay = true
        }
    }

    /// Called only when a text field does not own the event. Bare tool keys
    /// must never turn Chinese/English typing into result actions.
    func handleKey(_ event: NSEvent, choose: (PostCaptureChoice?) -> Void) -> Bool {
        guard event.type == .keyDown else { return false }
        // Events synthesized by an overlay can be attached to that overlay
        // rather than the canvas window.  Session state is the reliable
        // signal that an inline text field owns keyboard input.
        guard !isEditingInlineText else { return false }
        if event.window?.firstResponder is NSTextView { return false }
        // Borderless, non-key display events can have no window attached.
        // Still defer to an active field editor instead of consuming its text.
        if event.window == nil, canvases.contains(where: { $0.window?.firstResponder is NSTextView }) { return false }
        if event.keyCode == 53 { choose(nil); return true }
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        if event.modifierFlags.contains(.command) {
            if key == "z" {
                event.modifierFlags.contains(.shift) ? redo() : undo()
                return true
            }
            if key == "c" { choose(.clipboard); return true }
            if key == "s" { choose(.save); return true }
            return false
        }
        guard event.modifierFlags.intersection([.option, .control]).isEmpty else { return false }
        if event.keyCode == 36 || event.keyCode == 76 { choose(.clipboard); return true }
        if let tool = Self.tools.first(where: { $0.shortcutKey.lowercased() == key }) {
            _ = selectTool(tool)
            return true
        }
        return false
    }
}

/// Compact native controls for the selection stage only. The full editor's
/// title bar, parameter strip, icon, and layout are deliberately unchanged.
final class SelectionQuickEditToolbar: NSView {
    let preferredSize: NSSize
    private let editor: SelectionQuickEditor
    private let onChoose: (PostCaptureChoice?) -> Void
    private var toolButtons: [ToolType: NSButton] = [:]
    private let undoButton = NSButton()
    private let redoButton = NSButton()
    private let scrollButton = NSButton()
    private let sizeButton = NSPopUpButton()
    private let colorButton = NSPopUpButton()
    private let surface = NSVisualEffectView()
    private var accessibilityObserver: NSObjectProtocol?
    private let colors: [(String, NSColor)] = [("Red", .systemRed), ("Yellow", .systemYellow),
        ("Blue", .systemBlue), ("Green", .systemGreen), ("White", .white), ("Black", .black)]

    private static func layout(for availableWidth: CGFloat) -> (columns: Int, slots: [Int], size: CGSize) {
        let columns = max(3, min(22, Int((availableWidth - 20) / 34)))
        var slot = 0
        var slots: [Int] = []
        let spans = Array(repeating: 1, count: 8) + [2, 2] + Array(repeating: 1, count: 9)
        for (index, span) in spans.enumerated() {
            if index == 12, columns >= 7 {
                // Keep result actions together, with Copy on the right.
                if slot % columns + 7 > columns { slot += columns - slot % columns }
                slot += columns - slot % columns - 7
            }
            if slot % columns + span > columns { slot += columns - slot % columns }
            slots.append(slot)
            slot += span
        }
        let rows = Int(ceil(Double(slot) / Double(columns)))
        return (columns, slots, CGSize(width: columns * 34 + 12, height: rows * 36 + 12))
    }

    static func size(for availableWidth: CGFloat) -> CGSize { layout(for: availableWidth).size }

    static func anchoredFrame(to selection: CGRect, size: CGSize, within screen: CGRect) -> CGRect {
        let usable = screen.insetBy(dx: 8, dy: 8)
        // Unlike the tiny result capsule, the wider markup toolbar must not
        // cover a small crop just because its top edge touches the menu bar.
        if selection.maxY + 8 + size.height > usable.maxY,
           selection.minY - 8 - size.height >= usable.minY {
            return CGRect(x: min(max(selection.minX, usable.minX), usable.maxX - size.width),
                          y: selection.minY - 8 - size.height, width: size.width, height: size.height)
        }
        return PostCaptureChooserLayout.frame(anchoredTo: selection, panelSize: size, within: screen)
    }

    init(editor: SelectionQuickEditor, onChoose: @escaping (PostCaptureChoice?) -> Void, availableWidth: CGFloat) {
        self.editor = editor
        self.onChoose = onChoose
        // Two compact rows on narrow displays, never a clipped tool strip.
        let layout = Self.layout(for: availableWidth)
        let columns = layout.columns
        preferredSize = layout.size
        super.init(frame: CGRect(origin: .zero, size: preferredSize))
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.masksToBounds = true
        surface.frame = bounds
        surface.autoresizingMask = [.width, .height]
        surface.material = .popover
        surface.blendingMode = .behindWindow
        surface.state = .active
        addSubview(surface)

        let close = button("xmark", "Close", #selector(cancel))
        var controls: [NSView] = [close]
        for tool in SelectionQuickEditor.tools {
            let control = button(tool.iconName, tool.displayName, #selector(selectTool(_:)))
            control.identifier = NSUserInterfaceItemIdentifier(tool.rawValue)
            control.toolTip = "\(tool.localizedDisplayName) · \(tool.shortcutKey)"
            toolButtons[tool] = control
            controls.append(control)
        }
        colorButton.target = self
        colorButton.action = #selector(changeColor)
        colorButton.setAccessibilityLabel(Localization.string("Color"))
        colorButton.toolTip = Localization.string("Color")
        for (name, color) in colors {
            let item = NSMenuItem(title: Localization.string(name), action: nil, keyEquivalent: "")
            item.image = NSImage(size: NSSize(width: 14, height: 14), flipped: false) { rect in
                color.setFill()
                NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
                NSColor.separatorColor.setStroke()
                NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).stroke()
                return true
            }
            colorButton.menu?.addItem(item)
        }
        colorButton.imagePosition = .imageOnly
        controls.append(colorButton)
        sizeButton.target = self
        sizeButton.action = #selector(changeSize)
        controls.append(sizeButton)
        configure(undoButton, icon: "arrow.uturn.backward", title: "Undo", action: #selector(undo))
        configure(redoButton, icon: "arrow.uturn.forward", title: "Redo", action: #selector(redo))
        controls += [undoButton, redoButton]
        // Light separators also make the tool/result distinction non-colour-based.
        let divider = NSBox(); divider.boxType = .separator
        controls.append(divider)
        configure(scrollButton, icon: PostCaptureChoice.scroll.iconName, title: "Long Capture", action: #selector(longCapture))
        controls.append(scrollButton)
        for (icon, title, action) in [
            ("slider.horizontal.3", "Open Full Editor", #selector(fullEditor)),
            ("text.viewfinder", "OCR", #selector(ocr)),
            ("pin", "Pin", #selector(pin)),
            (PostCaptureChoice.save.iconName, "Download", #selector(downloadCapture)),
            ("doc.on.doc", "Copy", #selector(copyCapture))
        ] { controls.append(button(icon, title, action)) }
        // 19 controls; a width of 2 cells for parameter menus remains usable.
        for (index, control) in controls.enumerated() {
            let slot = layout.slots[index]
            let span = (control === colorButton || control === sizeButton) ? 2 : 1
            let row = slot / columns
            control.frame = CGRect(x: 6 + (slot % columns) * 34,
                                   y: Int(preferredSize.height) - 6 - (row + 1) * 36,
                                   width: span * 34 - 2, height: 32)
            if control === divider { control.frame = control.frame.insetBy(dx: 15, dy: 5) }
            addSubview(control)
        }
        editor.onStateChange = { [weak self] in self?.refresh() }
        accessibilityObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.updateSurface() }
        updateSurface()
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    deinit {
        if let accessibilityObserver { NSWorkspace.shared.notificationCenter.removeObserver(accessibilityObserver) }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateSurface()
    }

    private func updateSurface() {
        let opaque = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        let increaseContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua

        // Keep the quick-action strip visually separate from the captured
        // screen. The old popover material was too close to the page beneath
        // it, especially on bright browser surfaces, so use a more legible
        // menu-like material plus an explicit edge and shadow.
        surface.material = isDark ? .hudWindow : .menu
        surface.blendingMode = .withinWindow
        surface.state = .active
        surface.isEmphasized = true
        surface.isHidden = opaque
        let fallbackFill = (isDark ? NSColor.windowBackgroundColor : NSColor.controlBackgroundColor)
            .withAlphaComponent(opaque ? 1 : 0.96)
        layer?.backgroundColor = fallbackFill.cgColor
        let edgeColor = (isDark ? NSColor.white : NSColor.black)
            .withAlphaComponent(increaseContrast ? 0.42 : 0.22)
        layer?.borderColor = edgeColor.cgColor
        layer?.borderWidth = increaseContrast ? 1.5 : 1
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = increaseContrast ? 0.32 : 0.22
        layer?.shadowRadius = 12
        layer?.shadowOffset = CGSize(width: 0, height: -3)
    }

    private func button(_ icon: String, _ title: String, _ action: Selector) -> NSButton {
        let control = NSButton()
        configure(control, icon: icon, title: title, action: action)
        return control
    }

    private func configure(_ button: NSButton, icon: String, title: String, action: Selector) {
        button.image = NSImage(systemSymbolName: icon, accessibilityDescription: Localization.string(title))
        button.title = ""
        button.bezelStyle = .regularSquare
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.target = self
        button.action = action
        button.toolTip = Localization.string(title)
        button.setAccessibilityLabel(Localization.string(title))
        button.contentTintColor = NSColor.labelColor
        button.image?.isTemplate = true
        button.wantsLayer = true
        button.layer?.cornerRadius = 6
    }

    private func refresh() {
        let selectedBackground = NSColor.controlAccentColor.withAlphaComponent(0.16).cgColor
        for (tool, button) in toolButtons {
            let selected = editor.toolManager.currentTool == tool
            button.state = selected ? .on : .off
            button.layer?.backgroundColor = selected ? selectedBackground : NSColor.clear.cgColor
            button.layer?.borderWidth = selected ? 1 : 0
            button.layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.7).cgColor
            button.contentTintColor = selected ? NSColor.controlAccentColor : NSColor.labelColor
        }
        undoButton.isEnabled = editor.canvasState?.undoManager.canUndo ?? false
        redoButton.isEnabled = editor.canvasState?.undoManager.canRedo ?? false
        scrollButton.isEnabled = editor.canStartLongCapture
        scrollButton.toolTip = Localization.string(editor.canStartLongCapture ? "Long Capture" : "Undo annotations before long capture")
        let text = editor.toolManager.currentTool == .text
        let mosaic = editor.toolManager.currentTool == .pixelate
        let sizes = text ? [14, 18, 24, 32] : mosaic ? [6, 10, 16, 24] : [1, 3, 5, 8]
        let titles = sizes.map { String($0) }
        if sizeButton.itemTitles != titles { sizeButton.removeAllItems(); sizeButton.addItems(withTitles: titles) }
        sizeButton.selectItem(withTitle: String(Int(editor.sizeInPoints.rounded())))
        sizeButton.setAccessibilityLabel(Localization.string(text ? "Font Size" : mosaic ? "Pixel Size" : "Stroke Width"))
        sizeButton.toolTip = Localization.string(text ? "Font Size" : mosaic ? "Pixel Size" : "Stroke Width")
        colorButton.isEnabled = !mosaic && editor.toolManager.currentTool != .textSelect
        if let index = colors.firstIndex(where: { $0.1.isEqual(editor.toolManager.strokeColor) }) {
            colorButton.selectItem(at: index)
        }
        sizeButton.isEnabled = editor.toolManager.currentTool != .textSelect
    }

    @objc private func cancel() { onChoose(nil) }
    @objc private func selectTool(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue, let tool = ToolType(rawValue: raw) else { return }
        if !editor.selectTool(tool) { NSSound.beep() }
    }
    @objc private func changeColor() {
        let index = colorButton.indexOfSelectedItem
        if colors.indices.contains(index) { editor.setColor(colors[index].1) }
    }
    @objc private func changeSize() { editor.setSize(CGFloat(Double(sizeButton.titleOfSelectedItem ?? "3") ?? 3)) }
    @objc private func undo() { editor.undo() }
    @objc private func redo() { editor.redo() }
    @objc private func longCapture() { if editor.canStartLongCapture { onChoose(.scroll) } }
    @objc private func fullEditor() { onChoose(.editor) }
    @objc private func ocr() { onChoose(.ocr) }
    @objc private func pin() { onChoose(.preview) }
    @objc private func downloadCapture() { onChoose(.save) }
    @objc private func copyCapture() { onChoose(.clipboard) }
}
