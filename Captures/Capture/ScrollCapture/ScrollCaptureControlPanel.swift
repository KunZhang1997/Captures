import AppKit
import SwiftUI

enum ScrollCaptureProgressPreviewLayout {
    static let panelWidth: CGFloat = 60
    static let contentWidth: CGFloat = 52
    static let minimumHeight: CGFloat = 46
    static let maximumHeight: CGFloat = 260

    static func panelHeight(for imageSize: CGSize) -> CGFloat {
        guard imageSize.width > 0, imageSize.height > 0 else {
            return minimumHeight
        }
        let proportionalHeight = (imageSize.height / imageSize.width) * contentWidth + 8
        return min(max(proportionalHeight, minimumHeight), maximumHeight)
    }

}

/// Places the long-capture controls above the selected content while keeping
/// the growing preview aligned to the selected frame itself. The two surfaces
/// therefore keep distinct jobs: actions stay readable above, and the image
/// thumbnail remains visually tied to the rectangle being captured.
enum ScrollCaptureSessionChromeLayout {
    struct Frames: Equatable {
        let chooser: CGRect
        let preview: CGRect
    }

    private static let screenInset: CGFloat = 8
    private static let panelGap: CGFloat = 8

    static func frames(
        for imageSize: CGSize,
        anchoredTo captureRect: CGRect,
        chooserSize: CGSize,
        within screenFrame: CGRect
    ) -> Frames {
        let usableFrame = screenFrame.insetBy(dx: screenInset, dy: screenInset)
        let baseChooser = PostCaptureChooserLayout.frame(
            anchoredTo: captureRect,
            panelSize: chooserSize,
            within: screenFrame
        )
        let previewHeight = min(
            ScrollCaptureProgressPreviewLayout.panelHeight(for: imageSize),
            usableFrame.height
        )
        let chooser = baseChooser

        let leftX = chooser.minX - ScrollCaptureProgressPreviewLayout.panelWidth - panelGap
        let rightX = chooser.maxX + panelGap
        let previewX: CGFloat
        if leftX >= usableFrame.minX {
            previewX = leftX
        } else if rightX + ScrollCaptureProgressPreviewLayout.panelWidth <= usableFrame.maxX {
            previewX = rightX
        } else {
            previewX = min(
                max(chooser.midX - ScrollCaptureProgressPreviewLayout.panelWidth / 2, usableFrame.minX),
                usableFrame.maxX - ScrollCaptureProgressPreviewLayout.panelWidth
            )
        }
        // AppKit's maxY is the visible top edge. Align the thumbnail with the
        // capture frame below the action capsule, clipping only when the screen
        // edge leaves no room for the full live preview.
        let previewTop = min(
            max(captureRect.maxY, usableFrame.minY + previewHeight),
            usableFrame.maxY
        )
        let preview = CGRect(
            x: previewX,
            y: previewTop - previewHeight,
            width: ScrollCaptureProgressPreviewLayout.panelWidth,
            height: previewHeight
        )
        return Frames(chooser: chooser, preview: preview)
    }
}

@MainActor
private final class ScrollCaptureProgressPreviewState: ObservableObject {
    enum Phase: Equatable {
        case capturing
        case limitReached
    }

    @Published var image: NSImage
    @Published var panelHeight: CGFloat
    @Published var currentHeight: Int
    @Published var maximumHeight: Int
    @Published var phase: Phase = .capturing

    init(
        image: NSImage,
        panelHeight: CGFloat,
        currentHeight: Int,
        maximumHeight: Int
    ) {
        self.image = image
        self.panelHeight = panelHeight
        self.currentHeight = currentHeight
        self.maximumHeight = maximumHeight
    }

    var progress: Double {
        guard maximumHeight > 0 else { return 0 }
        return min(1, max(0, Double(currentHeight) / Double(maximumHeight)))
    }
}

@MainActor
final class ScrollCaptureProgressPreviewPanel {
    static let panelIdentifier = NSUserInterfaceItemIdentifier("scrollCaptureProgressPreview")

    private var panel: NSPanel?
    private var state: ScrollCaptureProgressPreviewState?

    func show(
        image: CGImage,
        currentHeight: Int,
        maximumHeight: Int,
        frame: CGRect
    ) {
        let nsImage = NSImage(
            cgImage: image,
            size: NSSize(width: image.width, height: image.height)
        )
        let state = ScrollCaptureProgressPreviewState(
            image: nsImage,
            panelHeight: frame.height,
            currentHeight: currentHeight,
            maximumHeight: maximumHeight
        )
        let hostingView = NSHostingView(
            rootView: ScrollCaptureProgressPreviewView(state: state)
                .appLanguageLocale()
        )

        let panel = NSPanel(
            contentRect: frame,
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.identifier = Self.panelIdentifier
        panel.isFloatingPanel = true
        panel.level = PostCaptureChooserManager.windowLevel
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.acceptsMouseMovedEvents = false
        panel.sharingType = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        hostingView.frame = CGRect(origin: .zero, size: frame.size)
        hostingView.autoresizingMask = [.width, .height]
        panel.contentView = hostingView
        panel.orderFrontRegardless()

        self.state = state
        self.panel = panel
    }

    func update(
        image: CGImage,
        currentHeight: Int,
        maximumHeight: Int,
        frame: CGRect
    ) {
        guard let panel, let state else {
            show(
                image: image,
                currentHeight: currentHeight,
                maximumHeight: maximumHeight,
                frame: frame
            )
            return
        }

        state.image = NSImage(
            cgImage: image,
            size: NSSize(width: image.width, height: image.height)
        )
        state.panelHeight = frame.height
        state.currentHeight = currentHeight
        state.maximumHeight = maximumHeight
        // The preview is progress feedback, not direct manipulation. Resize
        // immediately so rapid wheel gestures never queue decorative motion.
        panel.setFrame(frame, display: true, animate: false)
        panel.orderFrontRegardless()
    }

    func showLimitReached(
        currentHeight: Int,
        maximumHeight: Int
    ) {
        guard let state, state.phase == .capturing else { return }
        state.currentHeight = currentHeight
        state.maximumHeight = maximumHeight
        state.phase = .limitReached

        let announcement = Localization.string(
            "Capture limit reached. Choose an action to finish."
        )
        if let application = NSApp {
            NSAccessibility.post(
                element: application,
                notification: .announcementRequested,
                userInfo: [
                    .announcement: announcement,
                    .priority: NSAccessibilityPriorityLevel.high.rawValue,
                ]
            )
        }
    }

    func close() {
        panel?.orderOut(nil)
        panel?.contentView = nil
        panel?.close()
        panel = nil
        state = nil
    }

}

private struct ScrollCaptureProgressPreviewView: View {
    @ObservedObject var state: ScrollCaptureProgressPreviewState
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Image(nsImage: state.image)
                .resizable()
                .interpolation(.low)
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.primary.opacity(0.07))
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))

            if state.phase == .limitReached {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.caption2.weight(.semibold))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(Color.orange, Color.white.opacity(0.94))
                    .padding(5)

                Text(Localization.string("Limit"))
                    .font(.caption2.weight(.semibold))
                    .lineLimit(1)
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(.regularMaterial, in: Capsule())
                    .padding(5)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            } else if state.phase == .capturing {
                Image(systemName: "record.circle.fill")
                    .font(.caption2.weight(.semibold))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(Color.green, Color.white.opacity(0.92))
                    .padding(5)

                Text("\(Int((state.progress * 100).rounded()))%")
                    .font(.caption2.weight(.medium))
                    .fontDesign(.rounded)
                    .monospacedDigit()
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(.regularMaterial, in: Capsule())
                    .padding(5)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            }
        }
        .padding(4)
        .frame(
            width: ScrollCaptureProgressPreviewLayout.panelWidth,
            height: state.panelHeight
        )
        .background {
            if reduceTransparency {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(nsColor: .windowBackgroundColor))
            } else if #available(macOS 26.0, *) {
                Color.clear.glassEffect(
                    .regular,
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                )
            } else {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.ultraThinMaterial)
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(
                    Color.primary.opacity(colorSchemeContrast == .increased ? 0.34 : 0.16),
                    lineWidth: colorSchemeContrast == .increased ? 1 : 0.6
                )
                .allowsHitTesting(false)
        }
        .shadow(color: .black.opacity(0.18), radius: 8, y: 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Localization.string("Live long capture preview"))
        .accessibilityValue(accessibilityValue)
    }

    private var accessibilityValue: String {
        if state.phase == .limitReached {
            return Localization.string("Capture limit reached. Choose an action to finish.")
        }

        return String(
            format: Localization.string("Long capture progress: %lld%%"),
            Int64((state.progress * 100).rounded())
        )
    }
}

private extension CGRect {
    var area: CGFloat {
        guard !isNull else { return 0 }
        return width * height
    }
}

/// Separates the visual cutout from the four transparent input shields. The
/// visual mask is rendered by one continuous panel so Retina rounding cannot
/// leave visible seams between independently blended surfaces.
enum ScrollCaptureMaskLayout {
    static func transparentRect(for selection: CGRect, in screen: CGRect) -> CGRect? {
        let intersection = selection.intersection(screen)
        guard !intersection.isNull, intersection.width > 0, intersection.height > 0 else {
            return nil
        }
        return intersection.offsetBy(dx: -screen.minX, dy: -screen.minY)
    }

    static func blockingFrames(for selection: CGRect, in screen: CGRect) -> [CGRect] {
        let intersection = selection.intersection(screen)
        guard !intersection.isNull, intersection.width > 0, intersection.height > 0 else {
            return [screen]
        }

        let top = CGRect(
            x: screen.minX,
            y: intersection.maxY,
            width: screen.width,
            height: screen.maxY - intersection.maxY
        )
        let bottom = CGRect(
            x: screen.minX,
            y: screen.minY,
            width: screen.width,
            height: intersection.minY - screen.minY
        )
        let left = CGRect(
            x: screen.minX,
            y: intersection.minY,
            width: intersection.minX - screen.minX,
            height: intersection.height
        )
        let right = CGRect(
            x: intersection.maxX,
            y: intersection.minY,
            width: screen.maxX - intersection.maxX,
            height: intersection.height
        )

        return [top, bottom, left, right].filter { $0.width > 0 && $0.height > 0 }
    }
}

/// Keeps the exact region chosen in `AreaSelectorWindowController` visible
/// while a scroll capture is being assembled. The selector is deliberately
/// the only source of this rect: this overlay never invents a default size.
@MainActor
final class ScrollCaptureSelectionOverlay {
    static let windowLevel: NSWindow.Level = .floating

    private var dimmingPanels: [NSPanel] = []
    private var inputShieldPanels: [NSPanel] = []
    private var cornerPanels: [NSPanel] = []

    func show(for captureRect: CGRect) {
        close()
        guard captureRect.width > 0, captureRect.height > 0 else { return }

        let intersectingScreens = NSScreen.screens.filter {
            $0.frame.intersects(captureRect)
        }
        guard !intersectingScreens.isEmpty else { return }

        for screen in intersectingScreens {
            let intersection = screen.frame.intersection(captureRect)
            guard !intersection.isNull, intersection.width > 0, intersection.height > 0 else {
                continue
            }

            guard ScrollCaptureMaskLayout.transparentRect(
                for: captureRect,
                in: screen.frame
            ) != nil else {
                continue
            }
            let visualCutoutRect = captureRect.offsetBy(
                dx: -screen.frame.minX,
                dy: -screen.frame.minY
            )

            let dimmingPanel = makePanel(
                frame: screen.frame,
                screen: screen,
                contentView: ScrollCaptureDimmingMaskView(
                    frame: CGRect(origin: .zero, size: screen.frame.size),
                    transparentRect: visualCutoutRect
                ),
                interceptsPointerEvents: false
            )
            dimmingPanel.orderFrontRegardless()
            dimmingPanels.append(dimmingPanel)

            for shieldFrame in ScrollCaptureMaskLayout.blockingFrames(
                for: captureRect,
                in: screen.frame
            ) {
                let shieldPanel = makePanel(
                    frame: shieldFrame,
                    screen: screen,
                    contentView: ScrollCaptureInputShieldView(
                        frame: CGRect(origin: .zero, size: shieldFrame.size)
                    ),
                    interceptsPointerEvents: true
                )
                shieldPanel.orderFrontRegardless()
                inputShieldPanels.append(shieldPanel)
            }

            let localRect = CGRect(origin: .zero, size: intersection.size)
            let localSelectionRect = captureRect.offsetBy(
                dx: -intersection.minX,
                dy: -intersection.minY
            )
            let cornerPanel = makePanel(
                frame: intersection,
                screen: screen,
                contentView: ScrollCaptureSelectionOverlayView(
                    frame: localRect,
                    selectionRect: localSelectionRect
                ),
                interceptsPointerEvents: false
            )
            cornerPanel.orderFrontRegardless()
            cornerPanels.append(cornerPanel)
        }
    }

    func close() {
        (dimmingPanels + inputShieldPanels + cornerPanels).forEach { panel in
            panel.orderOut(nil)
            panel.contentView = nil
            panel.close()
        }
        dimmingPanels.removeAll()
        inputShieldPanels.removeAll()
        cornerPanels.removeAll()
    }

    private func makePanel(
        frame: CGRect,
        screen: NSScreen,
        contentView: NSView,
        interceptsPointerEvents: Bool
    ) -> NSPanel {
        let panel = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false,
            screen: screen
        )
        // The visual panel stays click-through. Separate transparent shields
        // consume only pointer input outside the selection, while the marker
        // over the selection lets real manual scrolling reach the source app
        // without an Accessibility event tap.
        panel.level = Self.windowLevel
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = !interceptsPointerEvents
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.sharingType = .none
        panel.isReleasedWhenClosed = false
        panel.setFrame(frame, display: false)
        contentView.frame = CGRect(origin: .zero, size: frame.size)
        contentView.autoresizingMask = [.width, .height]
        panel.contentView = contentView
        return panel
    }
}

/// A single continuous visual dimming surface with an even-odd transparent
/// cutout. It intentionally receives no pointer events; input blocking is
/// owned by the transparent panels below it in the overlay's window order.
private final class ScrollCaptureDimmingMaskView: NSView {
    private let transparentRect: CGRect

    init(frame: CGRect, transparentRect: CGRect) {
        self.transparentRect = transparentRect
        super.init(frame: frame)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.setFillColor(NSColor.black.withAlphaComponent(0.38).cgColor)
        context.addRect(bounds)
        context.addPath(CaptureSelectionFrameStyle.cutoutPath(for: transparentRect))
        context.drawPath(using: .eoFill)
    }
}

/// Temporary pointer shield for the dimmed space around a manual long capture.
/// It is deliberately nonactivating and has no actions: it prevents an outer
/// click, drag, selection, context menu, or scroll from mutating the app behind
/// it while leaving the selected rectangle uncovered. It is transparent so its
/// frame boundaries never create visual seams in the continuous dimming mask.
private final class ScrollCaptureInputShieldView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {}
    override func mouseDragged(with event: NSEvent) {}
    override func rightMouseDown(with event: NSEvent) {}
    override func rightMouseUp(with event: NSEvent) {}
    override func rightMouseDragged(with event: NSEvent) {}
    override func otherMouseDown(with event: NSEvent) {}
    override func otherMouseUp(with event: NSEvent) {}
    override func otherMouseDragged(with event: NSEvent) {}
    override func scrollWheel(with event: NSEvent) {}
    override func magnify(with event: NSEvent) {}
    override func rotate(with event: NSEvent) {}
    override func swipe(with event: NSEvent) {}
}

private final class ScrollCaptureSelectionOverlayView: NSView {
    private let selectionRect: CGRect

    init(frame: CGRect, selectionRect: CGRect) {
        self.selectionRect = selectionRect
        super.init(frame: frame)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        CaptureSelectionFrameStyle.drawCorners(
            context: context,
            rect: selectionRect,
            appearance: effectiveAppearance
        )
    }
}
