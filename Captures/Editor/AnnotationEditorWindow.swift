import AppKit

enum AnnotationEditorMode: Equatable {
    case annotation
    case ocr
}

enum AnnotationEditorLayout {
    // Match the compact dimensions used by a normal macOS title bar and
    // toolbar.  The command bar is the title bar; it is not a second row.
    static let commandBarHeight: CGFloat = 40
    static let compactToolBarHeight: CGFloat = 32
    static let standardToolBarHeight: CGFloat = 64
    static let filterToolBarHeight: CGFloat = compactToolBarHeight * 2
    static let canvasPadding: CGFloat = 24
    private static let screenMargin: CGFloat = 12

    static func contentSize(
        for imageSize: CGSize,
        mode: AnnotationEditorMode,
        visibleFrame: CGRect
    ) -> CGSize {
        // A completed capture is easiest to judge at its real pixel size.
        // Use the visible screen apart from a small edge margin, and only
        // reduce the canvas when the image truly cannot fit.
        let maxWindowWidth = max(1, visibleFrame.width - screenMargin * 2)
        let maxWindowHeight = max(1, visibleFrame.height - screenMargin * 2)
        let chromeHeight = commandBarHeight + standardToolBarHeight
        let ocrResultPaneWidth: CGFloat = mode == .ocr ? 360 : 0
        let imageWidth = max(1, imageSize.width)
        let imageHeight = max(1, imageSize.height)
        let maximumCanvasWidth = max(
            1,
            maxWindowWidth - ocrResultPaneWidth - canvasPadding
        )
        let maximumCanvasHeight = max(
            1,
            maxWindowHeight - chromeHeight - canvasPadding
        )
        let fitScale = min(
            1,
            maximumCanvasWidth / imageWidth,
            maximumCanvasHeight / imageHeight
        )
        let isLongCapture = imageHeight / imageWidth >= 1.35

        let canvasSize: CGSize
        if !isLongCapture {
            canvasSize = CGSize(
                width: imageWidth * fitScale,
                height: imageHeight * fitScale
            )
        } else {
            // Long captures are read vertically. Keep their natural width
            // when it fits and let the canvas pan through the remainder.
            canvasSize = CGSize(
                width: min(imageWidth, maximumCanvasWidth),
                height: min(maximumCanvasHeight, max(260, min(imageHeight, maximumCanvasHeight)))
            )
        }

        return CGSize(
            width: min(maxWindowWidth, canvasSize.width + canvasPadding + ocrResultPaneWidth),
            height: min(
                maxWindowHeight,
                canvasSize.height + canvasPadding + chromeHeight
            )
        )
    }
}

final class AnnotationEditorWindow: NSObject, NSWindowDelegate {
    private static var activeWindows: [UUID: AnnotationEditorWindow] = [:]

    private let id = UUID()
    private let window: NSWindow
    private let contentController: NativeImageEditorViewController

    private init(image: CGImage, sourceScale: CGFloat, mode: AnnotationEditorMode, documentName: String?) {
        let contentController = NativeImageEditorViewController(
            image: image,
            sourceScale: sourceScale,
            startsWithOCR: mode == .ocr
        )

        let visibleFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let contentSize = AnnotationEditorLayout.contentSize(
            for: CGSize(width: image.width, height: image.height),
            mode: mode,
            visibleFrame: visibleFrame
        )

        let window = NSWindow(contentViewController: contentController)
        // The editor sections take the title bar's useful space.  A capture's
        // often very long temporary filename adds no value here and used to
        // force the real controls into an unnecessary second row.
        window.title = ""
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.styleMask.insert(.fullSizeContentView)
        // A Swift strong reference plus the AppKit default (release on close)
        // double-releases the window during close.
        window.isReleasedWhenClosed = false
        // This is an editor, not a capture HUD.  A normal-level window must
        // yield to the app the user switches to.
        window.level = .normal
        window.hidesOnDeactivate = false
        // The editor canvas owns drag gestures for drawing and panning.  Its
        // title-bar surface explicitly opts into window dragging below.
        window.isMovableByWindowBackground = false
        window.setContentSize(contentSize)
        // Do not let a historical minimum window width enlarge a small image
        // on open. Retain that lower bound only for larger editor windows.
        window.minSize = NSSize(
            width: min(680, contentSize.width),
            height: min(240, contentSize.height)
        )
        self.contentController = contentController
        self.window = window
        super.init()
        self.window.delegate = self
    }

    static func open(
        with image: CGImage,
        sourceScale: CGFloat = 1,
        mode: AnnotationEditorMode = .annotation,
        documentName: String? = nil
    ) {
        NotificationCenter.default.post(name: .editorWillOpen, object: nil)
        let editorWindow = AnnotationEditorWindow(
            image: image,
            sourceScale: sourceScale,
            mode: mode,
            documentName: documentName
        )
        activeWindows[editorWindow.id] = editorWindow

        // Menu-bar apps can receive the capture completion while another app
        // (including System Settings) still owns the active space. Defer the
        // activation by one run-loop pass so AppKit has finished creating the
        // window before we bring it to the front.
        DispatchQueue.main.async {
            guard activeWindows[editorWindow.id] != nil else { return }
            NSApp.activate(ignoringOtherApps: true)
            NSRunningApplication.current.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
            editorWindow.window.center()
            editorWindow.window.makeKeyAndOrderFront(nil)
            editorWindow.contentController.configureInitialCanvasViewport()
        }
    }

    func windowWillClose(_ notification: Notification) {
        Self.activeWindows.removeValue(forKey: id)
    }
}
