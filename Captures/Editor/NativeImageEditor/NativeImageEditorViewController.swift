import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The six visible top-level sections from the All in One editor.  It is
/// shared with the compact SwiftUI parameter strip so each title exposes a
/// real, section-specific control surface rather than merely changing a
/// highlighted label.
enum NativeEditorSection: Int, CaseIterable {
    case adjust, retouch, filters, annotation, watermark, resize

    var title: String {
        switch self {
        case .adjust: return Localization.string("Adjust")
        case .retouch: return Localization.string("Retouch")
        case .filters: return Localization.string("Image Filters")
        case .annotation: return Localization.string("Annotate")
        case .watermark: return Localization.string("Text Watermark")
        case .resize: return Localization.string("Export size")
        }
    }
}

/// The native screenshot editor.  It deliberately owns one editing surface:
/// system window chrome, one compact command bar, one contextual tool strip,
/// and the canvas. Existing canvas and export services provide behavior only;
/// none of their older editor UI is embedded here.
final class NativeImageEditorViewController: NSViewController, NSTextViewDelegate {
    private enum ControlMetrics {
        static let selectionHeight: CGFloat = 27
        static let selectionMinimumWidth: CGFloat = 58
        static let selectionCornerRadius: CGFloat = 6
    }

    private enum ToolBarPresentation: Equatable {
        case hidden
        case pickerOnly
        case pickerWithOptions
        case optionsOnly
        case filterGallery

        var height: CGFloat {
            switch self {
            case .hidden:
                return 0
            case .pickerOnly, .optionsOnly:
                return AnnotationEditorLayout.compactToolBarHeight
            case .pickerWithOptions:
                return AnnotationEditorLayout.standardToolBarHeight
            case .filterGallery:
                return AnnotationEditorLayout.filterToolBarHeight
            }
        }
    }

    private let canvasState: CanvasState
    private let originalSnapshot: CanvasState.Snapshot
    private let toolManager = ToolManager()
    private let startsWithOCR: Bool
    let sourceScale: CGFloat
    private let preferences: UserDefaults
    private lazy var canvasView = CanvasNSView(canvasState: canvasState, toolManager: toolManager)

    private let commandBar = EditorChromeSurface()
    private let toolBar = EditorChromeSurface()
    private let toolPicker = NSStackView()
    private let toolOptionsDivider = NSBox()
    private let ocrPanel = NSVisualEffectView()
    private let ocrTextView = NSTextView()
    private let ocrStatusLabel = NSTextField(labelWithString: "")
    private let zoomValueButton = NSButton(title: "100%", target: nil, action: nil)
    private var toolButtons: [ToolType: NSButton] = [:]
    private var sectionButtons: [NativeEditorSection: NSButton] = [:]
    private var selectedSection: NativeEditorSection = .annotation
    private lazy var toolOptionsHost: NSHostingView<AnyView> = NSHostingView(
        rootView: AnyView(
            ToolOptionsView(
                canvasState: canvasState,
                toolManager: toolManager,
                showsToolPicker: false,
                activeSection: parameterSection(for: selectedSection),
                onCanvasChanged: { [weak self] in
                    self?.canvasView.needsDisplay = true
                },
                onCanvasGeometryChanged: { [weak self] in
                    self?.canvasView.fitToCanvas()
                    self?.updateZoomLabel()
                    self?.handleCanvasEditingStateChange()
                },
                onToolChanged: { [weak self] in
                    self?.handleContextualToolChange()
                }
            )
            .appLanguageLocale()
        )
    )
    private var canvasToRootConstraint: NSLayoutConstraint?
    private var canvasToOCRConstraint: NSLayoutConstraint?
    private var toolBarHeightConstraint: NSLayoutConstraint?
    private var standardToolBarConstraints: [NSLayoutConstraint] = []
    private var pickerOnlyToolBarConstraints: [NSLayoutConstraint] = []
    private var optionsOnlyToolBarConstraints: [NSLayoutConstraint] = []
    private var filterGalleryConstraints: [NSLayoutConstraint] = []
    private var currentToolBarPresentation: ToolBarPresentation?
    private var ocrTask: Task<Void, Never>?
    private var languageObserver: NSObjectProtocol?
    private var localizedCommandButtons: [(button: NSButton, key: String)] = []
    private var alwaysOnTopButton: NSButton?
    private(set) var isAlwaysOnTop = false
    private var ocrTitleLabel: NSTextField?
    private var ocrCloseButton: NSButton?
    private var ocrCopyButton: NSButton?
    private var hasConfiguredInitialCanvasViewport = false
    private var previousRootSize: CGSize?
    private var previousCanvasSize: CGSize?

    init(
        image: CGImage,
        sourceScale: CGFloat = 1,
        startsWithOCR: Bool = false,
        preferences: UserDefaults = .standard
    ) {
        let state = CanvasState(image: image)
        canvasState = state
        originalSnapshot = state.makeSnapshot()
        self.sourceScale = sourceScale > 0 ? sourceScale : 1
        self.startsWithOCR = startsWithOCR
        self.preferences = preferences
        super.init(nibName: nil, bundle: nil)
        languageObserver = NotificationCenter.default.addObserver(
            forName: .languageChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshLocalizedStrings()
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        ocrTask?.cancel()
        if let languageObserver {
            NotificationCenter.default.removeObserver(languageObserver)
        }
    }

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        // Keep the editing surface clean and white.  This is intentionally
        // not a glass treatment: screenshots need a neutral workspace that
        // does not inherit a grey or tinted backdrop from the window chrome.
        root.layer?.backgroundColor = NSColor.white.cgColor

        let refreshChromeForAppearance = { [weak self] in
            guard let self else { return }
            self.refreshControls()
            self.updateZoomLabel()
        }
        commandBar.appearanceDidChangeHandler = refreshChromeForAppearance
        toolBar.appearanceDidChangeHandler = refreshChromeForAppearance

        configureOCRPanel()
        canvasView.onEditingStateChange = { [weak self] in
            self?.handleCanvasEditingStateChange()
        }
        canvasView.onViewportChange = { [weak self] in
            self?.updateZoomLabel()
        }

        canvasView.translatesAutoresizingMaskIntoConstraints = false
        commandBar.translatesAutoresizingMaskIntoConstraints = false
        toolBar.translatesAutoresizingMaskIntoConstraints = false
        ocrPanel.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(commandBar)
        root.addSubview(canvasView)
        root.addSubview(ocrPanel)
        root.addSubview(toolBar)

        canvasToRootConstraint = canvasView.trailingAnchor.constraint(equalTo: root.trailingAnchor)
        canvasToOCRConstraint = canvasView.trailingAnchor.constraint(equalTo: ocrPanel.leadingAnchor)
        let toolBarHeightConstraint = toolBar.heightAnchor.constraint(
            equalToConstant: AnnotationEditorLayout.standardToolBarHeight
        )
        self.toolBarHeightConstraint = toolBarHeightConstraint
        NSLayoutConstraint.activate([
            commandBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            commandBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            commandBar.topAnchor.constraint(equalTo: root.topAnchor),
            commandBar.heightAnchor.constraint(equalToConstant: AnnotationEditorLayout.commandBarHeight),

            canvasView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            canvasView.topAnchor.constraint(equalTo: toolBar.bottomAnchor),
            canvasView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            canvasToRootConstraint!,

            ocrPanel.topAnchor.constraint(equalTo: toolBar.bottomAnchor),
            ocrPanel.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            ocrPanel.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            ocrPanel.widthAnchor.constraint(equalToConstant: 340),

            toolBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            toolBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            toolBar.topAnchor.constraint(equalTo: commandBar.bottomAnchor),
            toolBarHeightConstraint,
        ])

        buildCommandBar()
        buildToolBar()
        setOCRPanelVisible(false)
        refreshControls()
        view = root
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        // The canvas can draw once while Auto Layout still has an interim
        // height. Resolve it after the real editor window is on screen, but
        // preserve the capture's actual size instead of filling spare space.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.configureInitialCanvasViewport()
        }
        if startsWithOCR, ocrTask == nil {
            runOCR()
        }
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        let rootSize = view.bounds.size
        defer {
            previousRootSize = rootSize
            previousCanvasSize = canvasView.bounds.size
        }
        guard hasConfiguredInitialCanvasViewport,
              let previousRootSize, previousRootSize != rootSize,
              let previousCanvasSize else { return }
        canvasView.resizeViewport(from: previousCanvasSize)
    }

    /// Resolve the launch viewport after the owning window has applied its
    /// final content size. A provisional measurement must not make an
    /// otherwise 1:1 capture open at an arbitrary zoom.
    func configureInitialCanvasViewport() {
        guard isViewLoaded, !hasConfiguredInitialCanvasViewport else { return }
        view.layoutSubtreeIfNeeded()
        guard canvasView.bounds.width > 0, canvasView.bounds.height > 0 else { return }
        canvasView.showAtActualSizeOrFit()
        hasConfiguredInitialCanvasViewport = true
        previousRootSize = view.bounds.size
        previousCanvasSize = canvasView.bounds.size
        updateZoomLabel()
    }

    private func buildCommandBar() {
        let tabs = NSStackView()
        tabs.orientation = .horizontal
        tabs.alignment = .centerY
        tabs.spacing = 4
        for section in NativeEditorSection.allCases {
            let button = sectionButton(title: section.title)
            button.tag = section.rawValue
            tabs.addArrangedSubview(button)
            sectionButtons[section] = button
        }

        let zoomOut = commandButton(
            title: "",
            symbolName: "minus.magnifyingglass",
            toolTip: Localization.string("Zoom Out"),
            action: #selector(zoomOut)
        )
        zoomValueButton.target = self
        zoomValueButton.action = #selector(zoomToActualSize)
        zoomValueButton.bezelStyle = .regularSquare
        zoomValueButton.isBordered = false
        zoomValueButton.controlSize = .small
        zoomValueButton.font = .monospacedDigitSystemFont(ofSize: 9, weight: .regular)
        zoomValueButton.contentTintColor = .secondaryLabelColor
        zoomValueButton.focusRingType = .none
        zoomValueButton.toolTip = Localization.string("Actual Size")
        zoomValueButton.setContentHuggingPriority(.required, for: .horizontal)
        zoomValueButton.widthAnchor.constraint(equalToConstant: 42).isActive = true
        zoomValueButton.heightAnchor.constraint(equalToConstant: 26).isActive = true
        setButtonTitleColor(zoomValueButton, color: .secondaryLabelColor)
        let zoomIn = commandButton(
            title: "",
            symbolName: "plus.magnifyingglass",
            toolTip: Localization.string("Zoom In"),
            action: #selector(zoomIn)
        )
        let reset = commandButton(
            title: "",
            symbolName: "arrow.counterclockwise",
            toolTip: Localization.string("Reset"),
            action: #selector(resetEditor)
        )
        let undo = commandButton(
            title: "",
            symbolName: "arrow.uturn.backward",
            toolTip: Localization.string("Undo"),
            action: #selector(undo)
        )
        let redo = commandButton(
            title: "",
            symbolName: "arrow.uturn.forward",
            toolTip: Localization.string("Redo"),
            action: #selector(redo)
        )
        let alwaysOnTop = commandButton(
            title: "",
            symbolName: "pin",
            toolTip: Localization.string("Keep on Top"),
            action: #selector(toggleAlwaysOnTop)
        )
        alwaysOnTopButton = alwaysOnTop
        let ocr = commandButton(
            title: "",
            symbolName: "text.viewfinder",
            toolTip: Localization.string("OCR"),
            action: #selector(runOCR)
        )
        let copy = commandButton(
            title: "",
            symbolName: "doc.on.doc",
            toolTip: Localization.string("Copy"),
            action: #selector(copyImage)
        )
        let save = commandButton(
            title: "",
            symbolName: "square.and.arrow.down",
            toolTip: Localization.string("Save"),
            action: #selector(saveImage)
        )
        localizedCommandButtons = [
            (zoomOut, "Zoom Out"),
            (zoomIn, "Zoom In"),
            (reset, "Reset"),
            (undo, "Undo"),
            (redo, "Redo"),
            (ocr, "OCR"),
            (copy, "Copy"),
            (save, "Save"),
        ]
        // Keep the three kinds of commands in their own airy groups.  The
        // editor often has much more horizontal room than its commands need;
        // using it here prevents a crowded, web-toolbar-like run of symbols.
        let zoomDivider = commandDivider()
        let historyDivider = commandDivider()
        let viewportControls = NSStackView(views: [zoomOut, zoomValueButton, zoomIn])
        viewportControls.orientation = .horizontal
        viewportControls.alignment = .centerY
        viewportControls.spacing = 4

        let historyControls = NSStackView(views: [reset, undo, redo])
        historyControls.orientation = .horizontal
        historyControls.alignment = .centerY
        historyControls.spacing = 4

        let outputControls = NSStackView(views: [alwaysOnTop, ocr, save, copy])
        outputControls.orientation = .horizontal
        outputControls.alignment = .centerY
        outputControls.spacing = 6

        let actions = NSStackView(views: [
            viewportControls, zoomDivider,
            historyControls, historyDivider,
            outputControls,
        ])
        actions.orientation = .horizontal
        actions.alignment = .centerY
        actions.spacing = 10

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let stack = NSStackView(views: [tabs, spacer, actions])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false
        commandBar.contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            // Reserve the native traffic-light area.  The tabs now occupy the
            // rest of that same title-bar row instead of starting a new row.
            stack.leadingAnchor.constraint(equalTo: commandBar.contentView.leadingAnchor, constant: 82),
            stack.trailingAnchor.constraint(equalTo: commandBar.contentView.trailingAnchor, constant: -12),
            stack.centerYAnchor.constraint(equalTo: commandBar.contentView.centerYAnchor),
        ])
        refreshAlwaysOnTopButton()
    }

    private func buildToolBar() {
        // The contextual area sits directly below the command bar so editing
        // controls never feel detached from the action that opened them.
        toolPicker.orientation = .horizontal
        toolPicker.alignment = .centerY
        toolPicker.spacing = 6
        toolPicker.translatesAutoresizingMaskIntoConstraints = false

        toolOptionsHost.translatesAutoresizingMaskIntoConstraints = false
        toolOptionsHost.wantsLayer = true
        toolOptionsHost.layer?.backgroundColor = NSColor.clear.cgColor

        toolOptionsDivider.boxType = .separator
        toolOptionsDivider.alphaValue = 0.18
        toolOptionsDivider.translatesAutoresizingMaskIntoConstraints = false

        toolBar.contentView.addSubview(toolOptionsHost)
        toolBar.contentView.addSubview(toolOptionsDivider)
        toolBar.contentView.addSubview(toolPicker)
        let commonConstraints = [
            toolOptionsHost.leadingAnchor.constraint(equalTo: toolBar.contentView.leadingAnchor, constant: 8),
            toolOptionsHost.trailingAnchor.constraint(equalTo: toolBar.contentView.trailingAnchor, constant: -8),

            toolOptionsDivider.leadingAnchor.constraint(equalTo: toolBar.contentView.leadingAnchor, constant: 10),
            toolOptionsDivider.trailingAnchor.constraint(equalTo: toolBar.contentView.trailingAnchor, constant: -10),
            toolOptionsDivider.heightAnchor.constraint(equalToConstant: 1),

            toolPicker.leadingAnchor.constraint(greaterThanOrEqualTo: toolBar.contentView.leadingAnchor, constant: 8),
            toolPicker.trailingAnchor.constraint(lessThanOrEqualTo: toolBar.contentView.trailingAnchor, constant: -8),
            toolPicker.centerXAnchor.constraint(equalTo: toolBar.contentView.centerXAnchor),
        ]
        standardToolBarConstraints = [
            toolPicker.topAnchor.constraint(equalTo: toolBar.contentView.topAnchor, constant: 1),
            toolPicker.heightAnchor.constraint(equalToConstant: ControlMetrics.selectionHeight),
            toolOptionsDivider.topAnchor.constraint(equalTo: toolPicker.bottomAnchor),
            toolOptionsHost.topAnchor.constraint(equalTo: toolOptionsDivider.bottomAnchor),
            toolOptionsHost.bottomAnchor.constraint(equalTo: toolBar.contentView.bottomAnchor, constant: -1),
        ]
        pickerOnlyToolBarConstraints = [
            toolPicker.centerYAnchor.constraint(equalTo: toolBar.contentView.centerYAnchor),
            toolPicker.heightAnchor.constraint(equalToConstant: ControlMetrics.selectionHeight),
        ]
        optionsOnlyToolBarConstraints = [
            toolOptionsHost.topAnchor.constraint(equalTo: toolBar.contentView.topAnchor),
            toolOptionsHost.bottomAnchor.constraint(equalTo: toolBar.contentView.bottomAnchor),
        ]
        filterGalleryConstraints = [
            toolOptionsHost.topAnchor.constraint(equalTo: toolBar.contentView.topAnchor, constant: 1),
            toolOptionsHost.bottomAnchor.constraint(equalTo: toolBar.contentView.bottomAnchor, constant: -1),
        ]
        NSLayoutConstraint.activate(commonConstraints)
        rebuildToolPicker()
        updateToolBarLayout()
    }

    private func rebuildToolPicker() {
        toolPicker.arrangedSubviews.forEach { view in
            toolPicker.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        toolButtons.removeAll()

        for tool in tools(for: selectedSection) {
            let title = toolTitle(tool)
            let button = NSButton(title: title, target: self, action: #selector(selectTool(_:)))
            button.tag = toolTag(tool)
            let symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
            button.image = NSImage(
                systemSymbolName: tool.iconName,
                accessibilityDescription: title
            )?.withSymbolConfiguration(symbolConfiguration)
            button.image?.size = NSSize(width: 13, height: 13)
            button.imagePosition = .imageLeading
            button.bezelStyle = .regularSquare
            button.isBordered = false
            button.controlSize = .small
            button.font = .systemFont(ofSize: 9)
            button.contentTintColor = .secondaryLabelColor
            button.focusRingType = .none
            button.toolTip = title
            button.widthAnchor.constraint(
                greaterThanOrEqualToConstant: ControlMetrics.selectionMinimumWidth
            ).isActive = true
            button.heightAnchor.constraint(
                equalToConstant: ControlMetrics.selectionHeight
            ).isActive = true
            setButtonTitleColor(button, color: .secondaryLabelColor)
            toolPicker.addArrangedSubview(button)
            toolButtons[tool] = button
        }
    }

    private func updateToolOptionsSurface() {
        toolOptionsHost.rootView = AnyView(
            ToolOptionsView(
                canvasState: canvasState,
                toolManager: toolManager,
                showsToolPicker: false,
                activeSection: parameterSection(for: selectedSection),
                onCanvasChanged: { [weak self] in
                    self?.canvasView.needsDisplay = true
                },
                onCanvasGeometryChanged: { [weak self] in
                    self?.canvasView.fitToCanvas()
                    self?.updateZoomLabel()
                    self?.handleCanvasEditingStateChange()
                },
                onToolChanged: { [weak self] in
                    self?.handleContextualToolChange()
                }
            )
            .appLanguageLocale()
        )
    }

    private func updateToolBarLayout() {
        let presentation = toolBarPresentation()
        guard presentation != currentToolBarPresentation else { return }

        NSLayoutConstraint.deactivate(
            standardToolBarConstraints
                + pickerOnlyToolBarConstraints
                + optionsOnlyToolBarConstraints
                + filterGalleryConstraints
        )

        switch presentation {
        case .hidden:
            break
        case .pickerOnly:
            NSLayoutConstraint.activate(pickerOnlyToolBarConstraints)
        case .pickerWithOptions:
            NSLayoutConstraint.activate(standardToolBarConstraints)
        case .optionsOnly:
            NSLayoutConstraint.activate(optionsOnlyToolBarConstraints)
        case .filterGallery:
            NSLayoutConstraint.activate(filterGalleryConstraints)
        }

        let showsPicker = presentation == .pickerOnly || presentation == .pickerWithOptions
        let showsOptions = presentation == .pickerWithOptions
            || presentation == .optionsOnly
            || presentation == .filterGallery
        toolBar.isHidden = presentation == .hidden
        toolPicker.isHidden = !showsPicker
        toolOptionsHost.isHidden = !showsOptions
        toolOptionsDivider.isHidden = presentation != .pickerWithOptions
        toolBarHeightConstraint?.constant = presentation.height
        currentToolBarPresentation = presentation

        // Changing sections moves this divider by only four points.  Preserve
        // the user's viewport instead of recomputing zoom from an interim
        // Auto Layout frame while the SwiftUI options host is being replaced.
        if isViewLoaded {
            view.layoutSubtreeIfNeeded()
            canvasView.needsDisplay = true
        }
    }

    private func toolBarPresentation() -> ToolBarPresentation {
        let hasPicker = !tools(for: selectedSection).isEmpty
        let hasOptions = hasVisibleParameterControls

        if selectedSection == .filters, toolManager.currentTool != .pixelate {
            return .filterGallery
        }
        switch (hasPicker, hasOptions) {
        case (true, true): return .pickerWithOptions
        case (true, false): return .pickerOnly
        case (false, true): return .optionsOnly
        case (false, false): return .hidden
        }
    }

    private var hasVisibleParameterControls: Bool {
        if parameterSection(for: selectedSection) != nil {
            return true
        }

        switch toolManager.currentTool.primaryGroup {
        case .mouse:
            return !canvasState.selectedAnnotations().isEmpty
        case .hand, .ocr:
            return false
        case .text, .draw, .shapes, .blur, .crop:
            return true
        }
    }

    private func handleContextualToolChange() {
        rebuildToolPicker()
        updateToolBarLayout()
        updateToolOptionsSurface()
        refreshControls()
    }

    private func parameterSection(for section: NativeEditorSection) -> NativeEditorSection? {
        switch section {
        case .adjust, .filters, .watermark, .resize:
            return section
        case .retouch, .annotation:
            return nil
        }
    }

    private func configureOCRPanel() {
        ocrPanel.material = .contentBackground
        ocrPanel.blendingMode = .withinWindow
        ocrPanel.state = .active

        let title = NSTextField(labelWithString: Localization.string("OCR Workspace"))
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        ocrTitleLabel = title
        ocrStatusLabel.font = .systemFont(ofSize: 11)
        ocrStatusLabel.textColor = .secondaryLabelColor

        let close = NSButton(title: Localization.string("Close"), target: self, action: #selector(closeOCRPanel))
        close.bezelStyle = .inline
        close.isBordered = false
        close.controlSize = .small
        close.font = .systemFont(ofSize: 12)
        close.contentTintColor = .secondaryLabelColor
        ocrCloseButton = close

        let headerSpacer = NSView()
        headerSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let header = NSStackView(views: [title, headerSpacer, ocrStatusLabel, close])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 8

        ocrTextView.isEditable = true
        ocrTextView.delegate = self
        ocrTextView.isRichText = false
        ocrTextView.font = .systemFont(ofSize: 13)
        ocrTextView.drawsBackground = false
        ocrTextView.textContainerInset = NSSize(width: 2, height: 4)
        let scroll = NSScrollView()
        scroll.documentView = ocrTextView
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder

        let copy = NSButton(title: Localization.string("Copy Text"), target: self, action: #selector(copyOCRText))
        copy.bezelStyle = .regularSquare
        copy.isBordered = false
        copy.controlSize = .small
        copy.font = .systemFont(ofSize: 12, weight: .medium)
        copy.wantsLayer = true
        copy.layer?.cornerRadius = 6
        copy.layer?.masksToBounds = true
        copy.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        copy.contentTintColor = .white
        setButtonTitleColor(copy, color: .white)
        ocrCopyButton = copy
        let footerSpacer = NSView()
        footerSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let footer = NSStackView(views: [footerSpacer, copy])
        footer.orientation = .horizontal
        footer.alignment = .centerY

        let stack = NSStackView(views: [header, scroll, footer])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        ocrPanel.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: ocrPanel.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: ocrPanel.trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: ocrPanel.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: ocrPanel.bottomAnchor, constant: -12),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }

    private func setOCRPanelVisible(_ visible: Bool) {
        // These two trailing constraints are mutually exclusive.  Toggle them
        // as a pair so OCR never collapses the panel or leaves the canvas with
        // conflicting geometry.
        if let canvasToRootConstraint, let canvasToOCRConstraint {
            NSLayoutConstraint.deactivate([canvasToRootConstraint, canvasToOCRConstraint])
            NSLayoutConstraint.activate([visible ? canvasToOCRConstraint : canvasToRootConstraint])
        }
        ocrPanel.isHidden = !visible
        guard isViewLoaded else {
            canvasView.needsDisplay = true
            return
        }

        // OCR stays in the same editor window.  Refit after the panel has
        // taken its width so the canvas never ends up clipped behind it.
        view.layoutSubtreeIfNeeded()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.canvasView.fitToCanvas()
            self.updateZoomLabel()
        }
    }

    private func commandButton(
        title: String,
        symbolName: String? = nil,
        toolTip: String? = nil,
        action: Selector
    ) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        if let symbolName {
            let configuration = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
            button.image = NSImage(
                systemSymbolName: symbolName,
                accessibilityDescription: toolTip ?? title
            )?.withSymbolConfiguration(configuration)
            button.image?.size = NSSize(width: 14, height: 14)
            button.imagePosition = title.isEmpty ? .imageOnly : .imageLeading
        }
        button.bezelStyle = .regularSquare
        button.isBordered = false
        button.controlSize = .small
        button.font = .systemFont(ofSize: 9)
        button.contentTintColor = .secondaryLabelColor
        button.focusRingType = .none
        button.toolTip = toolTip ?? title
        if title.isEmpty {
            button.widthAnchor.constraint(equalToConstant: 30).isActive = true
        }
        button.heightAnchor.constraint(equalToConstant: 26).isActive = true
        setButtonTitleColor(button, color: .secondaryLabelColor)
        return button
    }

    private func commandDivider() -> NSView {
        let divider = NSBox()
        divider.boxType = .separator
        divider.alphaValue = 0.42
        divider.widthAnchor.constraint(equalToConstant: 1).isActive = true
        divider.heightAnchor.constraint(equalToConstant: 18).isActive = true
        return divider
    }

    private func sectionButton(title: String) -> NSButton {
        let button = NSButton(title: title, target: self, action: #selector(selectSection(_:)))
        button.bezelStyle = .regularSquare
        button.isBordered = false
        button.controlSize = .small
        button.font = .systemFont(ofSize: 11, weight: .medium)
        button.contentTintColor = .secondaryLabelColor
        button.focusRingType = .none
        button.widthAnchor.constraint(
            greaterThanOrEqualToConstant: ControlMetrics.selectionMinimumWidth
        ).isActive = true
        button.heightAnchor.constraint(
            equalToConstant: ControlMetrics.selectionHeight
        ).isActive = true
        setButtonTitleColor(button, color: .secondaryLabelColor)
        return button
    }

    @objc private func selectSection(_ sender: NSButton) {
        guard let section = NativeEditorSection(rawValue: sender.tag) else { return }
        selectedSection = section
        switch section {
        case .adjust:
            // Opening "调整" should expose real global adjustments.  Crop is
            // still one click away in its contextual tool row rather than being
            // mistaken for the whole section.
            toolManager.currentTool = .hand
        case .retouch:
            toolManager.currentTool = .blur
        case .filters:
            // Pixelation is an available local tool, while the section's
            // default surface is the real image-wide filter picker.
            toolManager.currentTool = .hand
        case .annotation:
            toolManager.currentTool = .arrow
        case .watermark:
            toolManager.currentTool = .text
        case .resize:
            toolManager.currentTool = .hand
            canvasView.fitToCanvas()
        }
        rebuildToolPicker()
        updateToolBarLayout()
        updateToolOptionsSurface()
        refreshControls()
    }

    @objc private func selectTool(_ sender: NSButton) {
        guard let tool = tool(for: sender.tag) else { return }
        toolManager.currentTool = tool
        // Selection and Hand are shared interaction modes.  Choosing either
        // must not make the user lose the section they were working in.
        if let owningSection = section(for: tool) {
            selectedSection = owningSection
        }
        rebuildToolPicker()
        updateToolBarLayout()
        updateToolOptionsSurface()
        refreshControls()
    }

    @objc private func undo() {
        canvasState.undoManager.undo(state: canvasState)
        refreshControls()
    }

    @objc private func redo() {
        canvasState.undoManager.redo(state: canvasState)
        refreshControls()
    }

    @objc private func resetEditor() {
        canvasState.restore(from: originalSnapshot)
        canvasState.undoManager.reset()
        toolManager.currentTool = .textSelect
        selectedSection = .annotation
        setOCRPanelVisible(false)
        canvasView.fitToCanvas()
        updateZoomLabel()
        rebuildToolPicker()
        updateToolBarLayout()
        updateToolOptionsSurface()
        refreshControls()
    }

    @objc private func zoomIn() {
        // These are global viewport commands, not a tool switch.  A user can
        // safely zoom in the middle of drawing a rectangle and continue that
        // same edit immediately afterwards.
        canvasView.zoomIn()
        updateZoomLabel()
    }

    @objc private func zoomOut() {
        canvasView.zoomOut()
        updateZoomLabel()
    }

    @objc private func zoomToActualSize() {
        canvasView.zoomToActualSize()
        updateZoomLabel()
    }

    @objc private func toggleAlwaysOnTop() {
        guard let window = view.window else { return }
        isAlwaysOnTop.toggle()
        window.level = isAlwaysOnTop ? .floating : .normal
        if isAlwaysOnTop {
            window.orderFrontRegardless()
        } else {
            window.orderFront(nil)
        }
        refreshAlwaysOnTopButton()
    }

    private func refreshAlwaysOnTopButton() {
        guard let button = alwaysOnTopButton else { return }
        let key = isAlwaysOnTop ? "Stop Keeping on Top" : "Keep on Top"
        let label = Localization.string(key)
        let configuration = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        button.image = NSImage(
            systemSymbolName: isAlwaysOnTop ? "pin.fill" : "pin",
            accessibilityDescription: label
        )?.withSymbolConfiguration(configuration)
        button.image?.size = NSSize(width: 14, height: 14)
        button.contentTintColor = isAlwaysOnTop ? .controlAccentColor : .secondaryLabelColor
        button.toolTip = label
        button.setAccessibilityLabel(label)
        button.setAccessibilityValue(
            Localization.string(isAlwaysOnTop ? "On" : "Off")
        )
    }

    @objc private func copyImage() {
        // Once OCR is open, the visible document is the editable text result.
        // Keep one obvious Copy command in the top row instead of forcing a
        // second, hidden interpretation of "copy".
        if !ocrPanel.isHidden, !ocrTextView.string.isEmpty {
            copyOCRText()
            return
        }
        guard let image = canvasState.renderFinalImage() else { return }
        let copied = PasteboardHelper.copyImage(
            image,
            scale: sourceScale,
            showsConfirmation: true,
            confirmationScreen: view.window?.screen
        )
        if copied {
            closeEditorIfEnabled(forKey: Constants.Keys.closeEditorAfterCopy)
        }
    }

    @objc private func saveImage() {
        guard let image = canvasState.renderFinalImage() else { return }
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "\(Localization.string("Screenshot")).png"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard ImageUtils.save(image, to: url, format: .png) else {
            presentError(Localization.string("Unable to save image."))
            return
        }
        closeEditorIfEnabled(forKey: Constants.Keys.closeEditorAfterSave)
    }

    @objc private func runOCR() {
        guard let image = canvasState.renderFinalImage() else { return }
        setOCRPanelVisible(true)
        canvasState.isOCRProcessing = true
        canvasState.recognizedText = ""
        ocrTextView.string = ""
        ocrStatusLabel.stringValue = Localization.string("Reading text...")
        ocrTask?.cancel()
        ocrTask = Task { [weak self] in
            do {
                let text = try await TextRecognitionService.recognizeText(in: image)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard let self else { return }
                    self.canvasState.isOCRProcessing = false
                    self.canvasState.recognizedText = text
                    self.ocrTextView.string = text
                    self.ocrStatusLabel.stringValue = self.ocrStatus(for: text)
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self?.canvasState.isOCRProcessing = false
                    self?.ocrStatusLabel.stringValue = Localization.string("OCR Failed")
                }
            }
        }
    }

    @objc private func closeOCRPanel() {
        setOCRPanelVisible(false)
    }

    @objc private func copyOCRText() {
        guard !ocrTextView.string.isEmpty else { return }
        let copied = PasteboardHelper.copyText(
            ocrTextView.string,
            showsConfirmation: true,
            confirmationScreen: view.window?.screen
        )
        if copied {
            closeEditorIfEnabled(forKey: Constants.Keys.closeEditorAfterCopy)
        }
    }

    private func closeEditorIfEnabled(forKey key: String) {
        guard preferences.bool(forKey: key) else { return }
        view.window?.performClose(nil)
    }

    func textDidChange(_ notification: Notification) {
        guard notification.object as? NSTextView === ocrTextView else { return }
        canvasState.recognizedText = ocrTextView.string
        guard !canvasState.isOCRProcessing else { return }
        ocrStatusLabel.stringValue = ocrStatus(for: ocrTextView.string)
    }

    private func ocrStatus(for text: String) -> String {
        guard !text.isEmpty else {
            return Localization.string("No text detected")
        }
        return String(format: Localization.string("%lld characters"), Int64(text.count))
    }

    private func refreshLocalizedStrings() {
        guard isViewLoaded else { return }

        for (section, button) in sectionButtons {
            let title = section.title
            button.title = title
            button.toolTip = title
            setButtonTitleColor(button, color: section == selectedSection ? .labelColor : .secondaryLabelColor)
        }
        for command in localizedCommandButtons {
            command.button.toolTip = Localization.string(command.key)
        }
        refreshAlwaysOnTopButton()
        zoomValueButton.toolTip = Localization.string("Actual Size")
        ocrTitleLabel?.stringValue = Localization.string("OCR Workspace")
        ocrCloseButton?.title = Localization.string("Close")
        ocrCopyButton?.title = Localization.string("Copy Text")
        if let ocrCopyButton {
            setButtonTitleColor(ocrCopyButton, color: .white)
        }

        rebuildToolPicker()
        updateToolOptionsSurface()
        refreshControls()
    }

    private func refreshControls() {
        for (tool, button) in toolButtons {
            applySelectionStyle(to: button, isSelected: tool == toolManager.currentTool)
        }
        for (section, button) in sectionButtons {
            applySelectionStyle(to: button, isSelected: section == selectedSection)
        }
        canvasView.needsDisplay = true
        canvasView.window?.invalidateCursorRects(for: canvasView)
    }

    private func handleCanvasEditingStateChange() {
        let currentTool = toolManager.currentTool
        // Hand and Selection are shared modes.  They should update the
        // current-tool presentation, but they never commandeer the top-level
        // section the user deliberately selected.
        if let owningSection = section(for: currentTool), owningSection != selectedSection {
            selectedSection = owningSection
            rebuildToolPicker()
            updateToolBarLayout()
            updateToolOptionsSurface()
        }
        updateToolBarLayout()
        refreshControls()
    }

    private func applySelectionStyle(to button: NSButton, isSelected: Bool) {
        button.state = isSelected ? .on : .off
        button.bezelStyle = .regularSquare
        button.isBordered = false
        // Preserve the semantic on/off state for accessibility, but prevent
        // NSButtonCell from painting its own opaque selected background. The
        // layer below owns the appearance-aware selection treatment.
        (button.cell as? NSButtonCell)?.showsStateBy = []
        button.wantsLayer = true
        button.layer?.cornerRadius = ControlMetrics.selectionCornerRadius
        button.layer?.masksToBounds = false
        button.effectiveAppearance.performAsCurrentDrawingAppearance {
            button.layer?.backgroundColor = isSelected
                ? NSColor.labelColor.withAlphaComponent(0.10).cgColor
                : NSColor.clear.cgColor
            button.layer?.borderColor = NSColor.labelColor.withAlphaComponent(0.12).cgColor
        }
        button.layer?.borderWidth = isSelected ? 0.5 : 0
        button.layer?.shadowColor = NSColor.black.cgColor
        button.layer?.shadowOpacity = isSelected ? 0.12 : 0
        button.layer?.shadowRadius = isSelected ? 2 : 0
        button.layer?.shadowOffset = CGSize(width: 0, height: -1)
        button.contentTintColor = isSelected ? .labelColor : .secondaryLabelColor
        setButtonTitleColor(button, color: isSelected ? .labelColor : .secondaryLabelColor)
    }

    private func updateZoomLabel() {
        zoomValueButton.title = "\(canvasView.zoomPercentage)%"
        setButtonTitleColor(zoomValueButton, color: .secondaryLabelColor)
    }

    private func setButtonTitleColor(_ button: NSButton, color: NSColor) {
        let font = button.font ?? .systemFont(ofSize: 12)
        button.attributedTitle = NSAttributedString(
            string: button.title,
            attributes: [.font: font, .foregroundColor: color]
        )
    }

    private func section(for tool: ToolType) -> NativeEditorSection? {
        switch tool {
        case .crop:
            return .adjust
        case .blur, .spotlight:
            return .retouch
        case .pixelate:
            return .filters
        case .hand, .textSelect, .ocr:
            return nil
        case .text:
            return .annotation
        case .arrow, .rectangle, .ellipse, .line, .pencil, .highlighter, .counter:
            return .annotation
        }
    }

    private func tools(for section: NativeEditorSection) -> [ToolType] {
        switch section {
        case .adjust:
            return [.crop]
        case .retouch:
            return [.blur, .spotlight]
        case .filters:
            return [.pixelate]
        case .annotation:
            return [.hand, .textSelect, .text, .arrow, .rectangle, .ellipse, .pencil, .line, .highlighter, .counter]
        case .watermark:
            return [.text]
        case .resize:
            return [.hand, .textSelect]
        }
    }

    private func toolTag(_ tool: ToolType) -> Int {
        ToolType.allCases.firstIndex(of: tool) ?? 0
    }

    private func tool(for tag: Int) -> ToolType? {
        guard ToolType.allCases.indices.contains(tag) else { return nil }
        return ToolType.allCases[tag]
    }

    private func toolTitle(_ tool: ToolType) -> String {
        switch tool {
        case .hand: return Localization.string("Hand")
        case .textSelect: return Localization.string("Select")
        case .text: return Localization.string("Text")
        case .arrow: return Localization.string("Arrow")
        case .rectangle: return Localization.string("Rectangle")
        case .ellipse: return Localization.string("Ellipse")
        case .pencil: return Localization.string("Pencil")
        case .highlighter: return Localization.string("Highlighter")
        case .line: return Localization.string("Line")
        case .blur: return Localization.string("Blur")
        case .pixelate: return Localization.string("Pixelate")
        case .spotlight: return Localization.string("Spotlight")
        case .counter: return Localization.string("Counter")
        case .crop: return Localization.string("Crop")
        default: return tool.localizedDisplayName
        }
    }

    private func presentError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = Localization.string("Screenshot Editor")
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }
}

/// One opaque, neutral surface for the editor command and tool bars.  The
/// editor deliberately avoids transparent glass so the canvas remains a clean
/// white work area instead of picking up a grey or tinted backdrop.
final class EditorChromeSurface: NSView {
    fileprivate let contentView = EditorChromeContentView()
    var appearanceDidChangeHandler: (() -> Void)?

    // The merged title-bar background remains a normal window drag target.
    // Buttons and other controls still receive their own mouse events, while
    // the canvas below is never allowed to move the window accidentally.
    override var mouseDownCanMoveWindow: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        installMaterial()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        installMaterial()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateBackgroundColor()
        appearanceDidChangeHandler?()
    }

    private func installMaterial() {
        wantsLayer = true
        updateBackgroundColor()
        contentView.frame = bounds
        contentView.autoresizingMask = [.width, .height]
        addSubview(contentView)
    }

    private func updateBackgroundColor() {
        // Dynamic NSColor values stop being dynamic once converted to a
        // CALayer CGColor. Resolve again inside the view's effective
        // appearance whenever macOS switches between Aqua appearances.
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        }
    }
}

private final class EditorChromeContentView: NSView {
    override var mouseDownCanMoveWindow: Bool { true }
}
