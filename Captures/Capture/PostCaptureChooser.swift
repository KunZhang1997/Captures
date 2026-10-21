import AppKit
import SwiftUI

enum PostCaptureChoice: Hashable {
    case clipboard
    case editor
    case ocr
    case preview
    case scroll
    case save

    /// Final actions for an already captured image. A long capture deliberately
    /// does not appear here: it is only available while the original area
    /// selection is still live, so it can reuse that exact rectangle.
    static let resultChoices: [PostCaptureChoice] = [.editor, .ocr, .preview, .save, .clipboard]

    var resultMode: CaptureResultMode? {
        switch self {
        case .editor: .editor
        case .preview: .preview
        case .clipboard: .clipboard
        case .save: .file
        case .ocr, .scroll: nil
        }
    }

    var iconName: String {
        switch self {
        case .editor: "pencil"
        case .preview: "pin"
        case .clipboard: "doc.on.doc"
        case .ocr: "text.viewfinder"
        case .scroll: CaptureMode.scroll.iconName
        case .save: "square.and.arrow.down"
        }
    }

    var shortcut: String {
        switch self {
        case .editor: "E"
        case .preview: "P"
        case .clipboard: "C"
        case .ocr: "O"
        case .scroll: "S"
        case .save: "D"
        }
    }

    var actionTitle: String {
        switch self {
        case .clipboard: Localization.string("Copy")
        case .editor: Localization.string("Edit")
        case .ocr: Localization.string("OCR")
        case .preview: Localization.string("Pin")
        case .scroll: Localization.string("Long Capture")
        case .save: Localization.string("Download")
        }
    }
}

struct PostCaptureChooserConfiguration {
    let choices: [PostCaptureChoice]
    let showsCloseButton: Bool

    static let result = PostCaptureChooserConfiguration(
        choices: PostCaptureChoice.resultChoices,
        showsCloseButton: true
    )
    /// The original area selection remains available here, so this variant can
    /// continue straight into manual long capture without making the person
    /// draw the same rectangle again.
    static let areaSelection = PostCaptureChooserConfiguration(
        choices: [.scroll, .editor, .ocr, .preview, .save, .clipboard],
        showsCloseButton: true
    )
    /// A manual long capture is still recording when this bar is shown. Each
    /// result action freezes the current stitched image before routing it, so
    /// Edit and OCR receive the same final pixels as Download and Copy.
    static let longCaptureActive = PostCaptureChooserConfiguration(
        choices: [.editor, .ocr, .save, .clipboard],
        showsCloseButton: true
    )
    var controlCount: Int {
        choices.count + (showsCloseButton ? 1 : 0)
    }
}

enum PostCaptureRoutingPolicy {
    static let choices: [CaptureResultMode] = [.editor, .preview, .clipboard, .file]

    static func resolvedOptions(
        from options: CaptureOptions,
        choice: CaptureResultMode
    ) -> CaptureOptions {
        precondition(choices.contains(choice), "A post-capture choice must resolve to a direct result route.")
        var resolved = options
        resolved.resultMode = choice
        // Choosing one explicit action must not inherit the independent global
        // clipboard toggle. Edit means edit, Keep on Page means float, and Copy
        // is already guaranteed by the clipboard route itself. Download is a
        // deliberate one-shot file output, even when automatic saving is off.
        resolved.copyToClipboard = false
        if choice == .file {
            resolved.saveToFile = true
        }
        return resolved
    }

    static func keepsFloatingCapturesVisible(for mode: CaptureResultMode) -> Bool {
        mode == .ask || mode == .preview
    }
}

enum PostCaptureChooserLayout {
    private static let panelHeight: CGFloat = 42
    // Keep the English Download label legible beside its symbol.
    static let controlWidth: CGFloat = 82

    static var panelSize: NSSize {
        panelSize(for: PostCaptureChooserConfiguration.result.controlCount)
    }
    private static let edgeInset: CGFloat = 8
    private static let anchorGap: CGFloat = 8
    private static let insideInset: CGFloat = 8

    static func panelSize(for choiceCount: Int) -> NSSize {
        let count = max(1, choiceCount)
        return NSSize(
            width: CGFloat(count) * controlWidth + CGFloat(max(0, count - 1) * 3 + 6),
            height: panelHeight
        )
    }

    static func frame(
        anchoredTo anchorRect: NSRect,
        panelSize: NSSize = panelSize,
        within screenFrame: NSRect
    ) -> NSRect {
        let usableFrame = screenFrame.insetBy(dx: edgeInset, dy: edgeInset)
        let outsideAboveY = anchorRect.maxY + anchorGap
        let canPlaceOutsideAbove = outsideAboveY + panelSize.height <= usableFrame.maxY

        let proposedX = canPlaceOutsideAbove
            ? anchorRect.minX
            : anchorRect.minX + insideInset
        let proposedY = canPlaceOutsideAbove
            ? outsideAboveY
            : anchorRect.maxY - panelSize.height - insideInset

        return NSRect(
            x: min(max(proposedX, usableFrame.minX), usableFrame.maxX - panelSize.width),
            y: min(max(proposedY, usableFrame.minY), usableFrame.maxY - panelSize.height),
            width: panelSize.width,
            height: panelSize.height
        )
    }
}

@MainActor
final class PostCaptureChooserManager {
    static let windowLevel: NSWindow.Level = .statusBar

    private var panels: [UUID: PostCaptureChooserPanel] = [:]

    static func panelIdentifier(for id: UUID) -> NSUserInterfaceItemIdentifier {
        NSUserInterfaceItemIdentifier("postCaptureChooser.\(id.uuidString)")
    }

    @discardableResult
    func show(
        anchoredTo sourceRect: NSRect,
        completion: @escaping (PostCaptureChoice?) -> Void
    ) -> UUID {
        show(
            anchoredTo: sourceRect,
            configuration: .result,
            completion: completion
        )
    }

    @discardableResult
    func show(
        anchoredTo sourceRect: NSRect,
        configuration: PostCaptureChooserConfiguration,
        quickEditor: SelectionQuickEditor? = nil,
        completion: @escaping (PostCaptureChoice?) -> Void
    ) -> UUID {
        let id = UUID()
        let screen = screen(for: sourceRect)
        let availableFrame = screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? sourceRect
        let frame = PostCaptureChooserLayout.frame(
            anchoredTo: sourceRect,
            panelSize: PostCaptureChooserLayout.panelSize(for: configuration.controlCount),
            within: availableFrame
        )
        let panel = PostCaptureChooserPanel(contentRect: frame)
        panel.allowedChoices = Set(configuration.choices)
        panel.identifier = Self.panelIdentifier(for: id)
        panel.choiceHandler = { [weak self] choice in
            guard let self else { return }
            quickEditor?.commitPendingEdits()
            if choice == .scroll, quickEditor?.canStartLongCapture == false { return }
            self.dismiss(id: id)
            completion(choice)
        }

        if let quickEditor {
            panel.quickEditor = quickEditor
            let toolbar = SelectionQuickEditToolbar(editor: quickEditor, onChoose: { [weak panel] choice in
                panel?.choose(choice)
            }, availableWidth: availableFrame.width - 16)
            panel.setFrame(SelectionQuickEditToolbar.anchoredFrame(to: sourceRect,
                size: toolbar.preferredSize, within: availableFrame), display: false)
            panel.contentView = toolbar
            panel.quickKeyHandler = { [weak panel, weak quickEditor] event in
                quickEditor?.handleKey(event) { panel?.choose($0) } ?? false
            }
        } else {
            let view = PostCaptureChooserView(
            configuration: configuration,
            onChoose: { [weak panel] choice in
                panel?.choose(choice)
            },
            onCancel: { [weak panel] in
                panel?.choose(nil)
            }
        )
        .appLanguageLocale()
        let hostingView = NSHostingView(rootView: view)
        hostingView.frame = NSRect(origin: .zero, size: frame.size)
        hostingView.autoresizingMask = [.width, .height]
        panel.contentView = hostingView
        }

        panels[id] = panel
        panel.makeKeyAndOrderFront(nil)
        // `isFloatingPanel` can normalize the window back to `.floating`.
        // The retained selection overlays also use that level, so the first
        // chooser may appear by ordering luck while the next one is covered.
        // Reassert `.statusBar` every time before forcing the panel forward.
        panel.level = Self.windowLevel
        panel.orderFrontRegardless()
        panel.contentView?.needsDisplay = true
        panel.contentView?.displayIfNeeded()

        DispatchQueue.main.async { [weak self, weak panel] in
            guard let self, let panel, self.panels[id] === panel else { return }
            panel.level = Self.windowLevel
            panel.orderFrontRegardless()
            panel.contentView?.needsDisplay = true
            panel.contentView?.displayIfNeeded()
        }
        return id
    }

    func reposition(id: UUID, anchoredTo sourceRect: NSRect) {
        guard let panel = panels[id] else { return }
        let screen = screen(for: sourceRect)
        let availableFrame = screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? sourceRect
        if let editor = panel.quickEditor,
           panel.frame.size != SelectionQuickEditToolbar.size(for: availableFrame.width - 16) {
            let toolbar = SelectionQuickEditToolbar(editor: editor, onChoose: { [weak panel] in panel?.choose($0) },
                                                    availableWidth: availableFrame.width - 16)
            panel.setContentSize(toolbar.preferredSize)
            panel.contentView = toolbar
        }
        let frame = panel.quickKeyHandler != nil
            ? SelectionQuickEditToolbar.anchoredFrame(to: sourceRect, size: panel.frame.size, within: availableFrame)
            : PostCaptureChooserLayout.frame(anchoredTo: sourceRect, panelSize: panel.frame.size, within: availableFrame)
        panel.setFrame(frame, display: true)
    }

    /// Long capture owns a live thumbnail beside this action bar. It computes
    /// both frames as one chrome group, then asks the chooser manager to apply
    /// the shared result rather than allowing two independent clamping rules.
    func setFrame(id: UUID, frame: NSRect) {
        guard let panel = panels[id] else { return }
        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()
    }

    func frame(id: UUID) -> NSRect? {
        panels[id]?.frame
    }

    func choose(id: UUID, choice: PostCaptureChoice?) {
        panels[id]?.choose(choice)
    }

    func dismiss(id: UUID) {
        guard let panel = panels.removeValue(forKey: id) else { return }
        panel.choiceHandler = nil
        panel.quickKeyHandler = nil
        panel.quickEditor = nil
        panel.orderOut(nil)
        panel.contentView = nil
        // `orderOut` alone leaves an AppKit window registered and can retain
        // stale Liquid Glass composition state. Close it so the next capture
        // starts with a genuinely fresh chooser window.
        panel.close()
    }

    private func screen(for sourceRect: NSRect) -> NSScreen? {
        if let bestMatch = NSScreen.screens.max(by: { first, second in
            intersectionArea(first.frame, sourceRect) < intersectionArea(second.frame, sourceRect)
        }), intersectionArea(bestMatch.frame, sourceRect) > 0 {
            return bestMatch
        }
        return NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
    }

    private func intersectionArea(_ first: NSRect, _ second: NSRect) -> CGFloat {
        let intersection = first.intersection(second)
        guard !intersection.isNull else { return 0 }
        return intersection.width * intersection.height
    }
}

private final class PostCaptureChooserPanel: NSPanel {
    var choiceHandler: ((PostCaptureChoice?) -> Void)?
    var quickKeyHandler: ((NSEvent) -> Bool)?
    var quickEditor: SelectionQuickEditor?
    var allowedChoices = Set(PostCaptureChoice.resultChoices)

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        // Set this after `isFloatingPanel`; AppKit otherwise downgrades the
        // custom level to `.floating`, the same level as the area overlays.
        level = PostCaptureChooserManager.windowLevel
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        isMovableByWindowBackground = false
        ignoresMouseEvents = false
        acceptsMouseMovedEvents = true
        sharingType = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        isReleasedWhenClosed = false
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    func choose(_ choice: PostCaptureChoice?) {
        if let choice, !allowedChoices.contains(choice) { return }
        choiceHandler?(choice)
    }

    override func cancelOperation(_ sender: Any?) {
        choose(nil)
    }

    override func sendEvent(_ event: NSEvent) {
        if quickKeyHandler?(event) == true { return }
        // A nonactivating result panel can have a SwiftUI control as first
        // responder. Intercept Escape at the window boundary so it always
        // follows the same discard path as Close, rather than relying on the
        // current responder to forward cancelOperation(_:).
        if event.type == .keyDown, event.keyCode == 53 {
            choose(nil)
            return
        }
        super.sendEvent(event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.keyCode == 53 {
            choose(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if let quickKeyHandler {
            if !quickKeyHandler(event) { super.keyDown(with: event) }
            return
        }
        if event.keyCode == 53 {
            choose(nil)
            return
        }

        let disallowedModifiers: NSEvent.ModifierFlags = [.command, .control, .option]
        guard event.modifierFlags.intersection(disallowedModifiers).isEmpty,
              let character = event.charactersIgnoringModifiers?.lowercased() else {
            super.keyDown(with: event)
            return
        }

        switch character {
        case "e": choose(.editor)
        case "p": choose(.preview)
        case "c": choose(.clipboard)
        case "o": choose(.ocr)
        case "s": choose(.scroll)
        case "d": choose(.save)
        default: super.keyDown(with: event)
        }
    }
}

private struct PostCaptureChooserView: View {
    let configuration: PostCaptureChooserConfiguration
    let onChoose: (PostCaptureChoice) -> Void
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 3) {
            if configuration.showsCloseButton {
                PostCaptureChoiceButton(
                    icon: "xmark",
                    title: Localization.string("Close"),
                    shortcut: "Esc",
                    emphasis: .cancel,
                    accessibilityHint: Localization.string("Closes this capture without copying"),
                    action: onCancel
                )
            }

            ForEach(configuration.choices, id: \.self) { choice in
                choiceButton(choice)
            }
        }
        .padding(3)
        .frame(
            width: PostCaptureChooserLayout.panelSize(for: configuration.controlCount).width,
            height: PostCaptureChooserLayout.panelSize.height
        )
        .modifier(PostCaptureGlassSurface())
        .overlay {
            RoundedRectangle(
                cornerRadius: 12,
                style: .continuous
            )
            .strokeBorder(Color.white.opacity(0.24), lineWidth: 0.6)
            .allowsHitTesting(false)
        }
        .shadow(color: .black.opacity(0.2), radius: 9, y: 4)
    }

    private func choiceButton(_ choice: PostCaptureChoice) -> some View {
        PostCaptureChoiceButton(
            icon: choice.iconName,
            title: choice.actionTitle,
            shortcut: choice.shortcut,
            emphasis: choice == .clipboard ? .primary : .standard,
            action: { onChoose(choice) }
        )
    }
}

private struct PostCaptureGlassSurface: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(
                .regular.interactive(),
                in: RoundedRectangle(
                    cornerRadius: 12,
                    style: .continuous
                )
            )
        } else {
            content.background(
                .ultraThinMaterial,
                in: RoundedRectangle(
                    cornerRadius: 12,
                    style: .continuous
                )
            )
        }
    }
}

private enum PostCaptureChoiceButtonEmphasis: Equatable {
    case standard
    case primary
    case cancel
}

private struct PostCaptureChoiceButton: View {
    let icon: String
    let title: String
    let shortcut: String
    let emphasis: PostCaptureChoiceButtonEmphasis
    let accessibilityHint: String?
    let action: () -> Void

    init(
        icon: String,
        title: String,
        shortcut: String,
        emphasis: PostCaptureChoiceButtonEmphasis,
        accessibilityHint: String? = nil,
        action: @escaping () -> Void
    ) {
        self.icon = icon
        self.title = title
        self.shortcut = shortcut
        self.emphasis = emphasis
        self.accessibilityHint = accessibilityHint
        self.action = action
    }

    @State private var isHovering = false
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                    .symbolRenderingMode(.monochrome)
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
            }
                .foregroundStyle(foregroundColor)
                .frame(width: PostCaptureChooserLayout.controlWidth, height: 34)
                .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                .background {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(backgroundColor)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(strokeColor, lineWidth: strokeWidth)
                }
        }
        .buttonStyle(PostCapturePressStyle())
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) {
                isHovering = hovering
            }
        }
        .help("\(title) · \(shortcut)")
        .accessibilityLabel(title)
        .accessibilityHint(accessibilityHint ?? "Keyboard shortcut \(shortcut)")
    }

    private var foregroundColor: Color {
        switch emphasis {
        case .cancel:
            return .primary.opacity(isHovering ? 0.82 : 0.58)
        case .primary:
            return .white
        case .standard:
            return .primary.opacity(isHovering ? 0.96 : 0.8)
        }
    }

    private var backgroundColor: Color {
        switch emphasis {
        case .cancel:
            return .primary.opacity(isHovering ? 0.08 : 0.001)
        case .primary:
            return Color.accentColor.opacity(isHovering ? 1 : 0.9)
        case .standard:
            return .white.opacity(isHovering ? 0.2 : 0.001)
        }
    }

    private var strokeColor: Color {
        switch emphasis {
        case .primary:
            return .white.opacity(isHovering ? 0.28 : 0.12)
        case .standard, .cancel:
            return .white.opacity(
                isHovering ? 0.2 : (colorSchemeContrast == .increased ? 0.12 : 0)
            )
        }
    }

    private var strokeWidth: CGFloat {
        colorSchemeContrast == .increased ? 1 : 0.5
    }
}

private struct PostCapturePressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.88 : 1)
            .opacity(configuration.isPressed ? 0.76 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}
