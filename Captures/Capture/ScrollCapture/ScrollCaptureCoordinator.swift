import AppKit
import ScreenCaptureKit

struct ScrollCaptureResultRoute {
    let options: CaptureOptions
    let editorMode: AnnotationEditorMode
}

enum ScrollCaptureResultRouting {
    static func route(
        for choice: PostCaptureChoice,
        options: CaptureOptions
    ) -> ScrollCaptureResultRoute? {
        if choice == .ocr {
            var routedOptions = options
            routedOptions.resultMode = .editor
            routedOptions.copyToClipboard = false
            return ScrollCaptureResultRoute(
                options: routedOptions,
                editorMode: .ocr
            )
        }

        guard choice == .editor || choice == .save || choice == .clipboard,
              let resultMode = choice.resultMode else {
            return nil
        }
        return ScrollCaptureResultRoute(
            options: PostCaptureRoutingPolicy.resolvedOptions(
                from: options,
                choice: resultMode
            ),
            editorMode: .annotation
        )
    }
}

final class ScrollCaptureCoordinator {
    private let appState: AppState
    private let captureService = ScreenCaptureService()
    private let finishCaptureHandler: @MainActor (
        CaptureResult,
        CaptureOptions,
        AnnotationEditorMode
    ) -> Void
    private let errorHandler: @MainActor (Error, String) -> Void
    private let onSessionEnd: @MainActor () -> Void

    private var areaSelectorController: AreaSelectorWindowController?

    init(
        appState: AppState,
        finishCapture: @escaping @MainActor (
            CaptureResult,
            CaptureOptions,
            AnnotationEditorMode
        ) -> Void,
        handleError: @escaping @MainActor (Error, String) -> Void,
        onSessionEnd: @escaping @MainActor () -> Void
    ) {
        self.appState = appState
        self.finishCaptureHandler = finishCapture
        self.errorHandler = handleError
        self.onSessionEnd = onSessionEnd
    }

    func start(options: CaptureOptions) {
        let sourceApplication = ScrollCaptureSourceApplication.frontmostExternalApplication()
        areaSelectorController?.close()
        areaSelectorController = AreaSelectorWindowController { [weak self] selection in
            guard let self else { return }
            let selector = self.areaSelectorController
            self.areaSelectorController = nil
            // `finish(keepSelectionVisible:)` deliberately retains the normal
            // area selector for its draggable result choice. Long capture uses
            // a separate click-through frame; leaving this maximum-level
            // selector alive would swallow every wheel and mouse event.
            selector?.close()

            guard let rect = selection?.rect else {
                Task { @MainActor in
                    self.onSessionEnd()
                }
                return
            }

            Task {
                await self.runCaptureSession(
                    appKitRect: rect,
                    options: options,
                    sourceApplication: sourceApplication
                )
            }
        }
        areaSelectorController?.show(freezeScreen: false, showMagnifier: options.showMagnifier)
    }

    /// Continues directly from a normal area selection. The caller has
    /// already closed its frozen selector and keeps the capture reservation,
    /// so the person does not have to draw the same rectangle a second time.
    func start(
        from selectionRect: CGRect,
        options: CaptureOptions,
        sourceApplication: ScrollCaptureSourceApplication? = nil
    ) {
        areaSelectorController?.close()
        areaSelectorController = nil
        Task {
            await runCaptureSession(
                appKitRect: selectionRect,
                options: options,
                sourceApplication: sourceApplication
            )
        }
    }

    private func runCaptureSession(
        appKitRect: CGRect,
        options: CaptureOptions,
        sourceApplication: ScrollCaptureSourceApplication?
    ) async {
        // The selector hands back an AppKit bottom-left rect; everything
        // downstream ScreenCaptureKit APIs speak CG top-left.
        let rect = CoordinateSpace.appKitToCG(appKitRect)

        let sessionState = LockedScrollCaptureSessionState()
        let sessionUI = await MainActor.run { () -> ScrollCaptureSessionUI in
            let ui = ScrollCaptureSessionUI(captureRect: appKitRect)
            ui.showSelection()
            return ui
        }

        defer {
            Task { @MainActor in
                sessionUI.close()
                self.onSessionEnd()
            }
        }

        do {
            let content = try await captureService.getShareableContent()
            let context = try await captureService.prepareRectCapture(
                for: rect,
                content: content,
                retinaScale: options.retina2x
            )
            let scrollPoint = CGPoint(x: rect.midX, y: rect.midY)
            let target = ScrollCaptureTargetController.resolveTarget(
                at: scrollPoint,
                content: content,
                fallbackApplication: sourceApplication
            )
            let targetController = ScrollCaptureTargetController(target: target)

            let recorder = ScrollCaptureRecorder()
            try await recorder.startCapturing(
                rect: rect,
                context: context,
                framesPerSecond: 30
            )
            defer {
                Task {
                    await recorder.stopCapturing()
                }
            }

            guard let initialFrame = await recorder.nextFrame(after: 0, timeout: 2.0) else {
                throw ScrollCaptureError.noInitialFrame
            }

            let stitcher = ScrollStitcher(initialImage: initialFrame.image)
            let estimator = ScrollMotionEstimator(
                minShift: 6,
                maxShiftRatio: 0.62
            )
            var lastAcceptedFrame = initialFrame
            var lastObservedSequence = initialFrame.sequence
            var lastPreviewUpdateUptime = 0.0

            await MainActor.run {
                sessionUI.showCapturing(
                    initialPreview: stitcher.previewImage() ?? initialFrame.image,
                    currentHeight: stitcher.currentHeight,
                    maximumHeight: stitcher.maxHeight,
                    onChoice: { sessionState.resolve($0) }
                )
            }
            await targetController.prepareForManualScrolling()

            func appendMovedFrame(_ frame: ScrollCapturedFrame) -> Int? {
                guard !stitcher.reachedMaxHeight,
                      let estimate = estimator.estimate(
                        previous: lastAcceptedFrame.image,
                        current: frame.image
                      ),
                      estimate.verticalShift >= 6,
                      estimate.confidence >= 0.40,
                      stitcher.append(
                        frame: frame.image,
                        verticalShift: estimate.verticalShift
                      ) else {
                    return nil
                }
                lastAcceptedFrame = frame
                return estimate.verticalShift
            }

            // The target application owns scrolling. Captures only observes
            // the selected region and appends visually confirmed downward
            // movement. This keeps browser, PDF, Electron, and native scroll
            // behavior under the person's real wheel or trackpad input instead
            // of relying on synthetic events that some apps ignore.
            while sessionState.isCapturing {
                if stitcher.reachedMaxHeight {
                    sessionState.reachSafetyLimit()
                    break
                }

                guard let nextFrame = await recorder.nextFrame(
                    after: lastObservedSequence,
                    timeout: 0.25
                ) else {
                    continue
                }
                lastObservedSequence = nextFrame.sequence
                if appendMovedFrame(nextFrame) != nil {
                    let now = ProcessInfo.processInfo.systemUptime
                    if now - lastPreviewUpdateUptime >= 0.18,
                       let preview = stitcher.previewImage() {
                        lastPreviewUpdateUptime = now
                        await MainActor.run {
                            sessionUI.updatePreview(
                                preview,
                                currentHeight: stitcher.currentHeight,
                                maximumHeight: stitcher.maxHeight
                            )
                        }
                    }
                }
            }

            // Include the page position visible when a result action was
            // chosen. One final trackpad animation may still be settling when
            // the click arrives; draining one frame keeps the output aligned
            // with the page that remains on screen.
            if !sessionState.isCancelled,
               !stitcher.reachedMaxHeight,
               let finalFrame = await recorder.nextFrame(
                after: lastObservedSequence,
                timeout: 0.16
            ), let _ = appendMovedFrame(finalFrame),
               let preview = stitcher.previewImage() {
                await MainActor.run {
                    sessionUI.updatePreview(
                        preview,
                        currentHeight: stitcher.currentHeight,
                        maximumHeight: stitcher.maxHeight
                    )
                }
            }

            // Stop ScreenCaptureKit before routing the chosen result. The
            // selected page stays exactly where manual scrolling ended and no
            // late frame can change the image after the user commits.
            await recorder.stopCapturing()
            guard !sessionState.isCancelled else { return }

            if sessionState.state == .awaitingAction {
                await MainActor.run {
                    sessionUI.showLimitReached(
                        currentHeight: stitcher.currentHeight,
                        maximumHeight: stitcher.maxHeight
                    )
                }
            }
            await sessionState.waitForResolution()
            guard case let .selected(choice) = sessionState.state else { return }

            let finalImage = stitcher.image
            let result = CaptureResult(
                image: finalImage,
                mode: .scroll,
                timestamp: Date(),
                sourceRect: appKitRect,
                windowName: nil,
                applicationName: targetController.targetName,
                scale: rect.width > 0 ? CGFloat(finalImage.width) / rect.width : 1
            )
            guard let route = ScrollCaptureResultRouting.route(
                for: choice,
                options: options
            ) else { return }

            await MainActor.run {
                sessionUI.close()
                self.finishCaptureHandler(
                    result,
                    route.options,
                    route.editorMode
                )
            }
        } catch {
            await MainActor.run {
                self.errorHandler(error, "Scroll capture")
            }
        }
    }
}

final class LockedScrollCaptureSessionState: @unchecked Sendable {
    enum State: Equatable {
        case capturing
        case awaitingAction
        case cancelled
        case selected(PostCaptureChoice)
    }

    private let lock = NSLock()
    private var value: State = .capturing
    private var resolutionWaiters: [CheckedContinuation<Void, Never>] = []

    var state: State {
        lock.withLock { value }
    }

    var isCapturing: Bool {
        lock.withLock { value == .capturing }
    }

    var isCancelled: Bool {
        lock.withLock { value == .cancelled }
    }

    @discardableResult
    func reachSafetyLimit() -> Bool {
        lock.withLock {
            guard value == .capturing else { return false }
            value = .awaitingAction
            return true
        }
    }

    func cancel() {
        finish(with: .cancelled)
    }

    func resolve(_ choice: PostCaptureChoice?) {
        guard let choice else {
            cancel()
            return
        }
        finish(with: .selected(choice))
    }

    private func finish(with nextState: State) {
        let waiters: [CheckedContinuation<Void, Never>] = lock.withLock {
            guard value == .capturing || value == .awaitingAction else { return [] }
            value = nextState
            let waiters = resolutionWaiters
            resolutionWaiters.removeAll()
            return waiters
        }
        waiters.forEach { $0.resume() }
    }

    func waitForResolution() async {
        await withCheckedContinuation { continuation in
            let shouldResumeImmediately: Bool = lock.withLock {
                guard value == .awaitingAction else { return true }
                resolutionWaiters.append(continuation)
                return false
            }
            if shouldResumeImmediately {
                continuation.resume()
            }
        }
    }
}

@MainActor
private final class ScrollCaptureSessionUI {
    private let captureRect: CGRect
    private let selectionOverlay = ScrollCaptureSelectionOverlay()
    private let chooserManager = PostCaptureChooserManager()
    private lazy var progressPreview = ScrollCaptureProgressPreviewPanel()
    private var chooserID: UUID?

    init(captureRect: CGRect) {
        self.captureRect = captureRect
    }

    func showSelection() {
        selectionOverlay.show(for: captureRect)
    }

    func showCapturing(
        initialPreview: CGImage,
        currentHeight: Int,
        maximumHeight: Int,
        onChoice: @escaping (PostCaptureChoice?) -> Void
    ) {
        guard chooserID == nil else { return }
        chooserID = chooserManager.show(
            anchoredTo: captureRect,
            configuration: .longCaptureActive,
            completion: onChoice
        )
        let frames = chromeFrames(for: initialPreview)
        if let chooserID {
            chooserManager.setFrame(id: chooserID, frame: frames.chooser)
        }
        progressPreview.show(
            image: initialPreview,
            currentHeight: currentHeight,
            maximumHeight: maximumHeight,
            frame: frames.preview
        )

    }

    func showLimitReached(
        currentHeight: Int,
        maximumHeight: Int
    ) {
        progressPreview.showLimitReached(
            currentHeight: currentHeight,
            maximumHeight: maximumHeight
        )
    }

    func updatePreview(
        _ image: CGImage,
        currentHeight: Int,
        maximumHeight: Int
    ) {
        let frames = chromeFrames(for: image)
        if let chooserID {
            chooserManager.setFrame(id: chooserID, frame: frames.chooser)
        }
        progressPreview.update(
            image: image,
            currentHeight: currentHeight,
            maximumHeight: maximumHeight,
            frame: frames.preview
        )
    }

    func close() {
        if let chooserID {
            chooserManager.dismiss(id: chooserID)
            self.chooserID = nil
        }
        progressPreview.close()
        selectionOverlay.close()
    }

    private func chromeFrames(for image: CGImage) -> ScrollCaptureSessionChromeLayout.Frames {
        let screen = NSScreen.screens.max { first, second in
            let firstIntersection = first.frame.intersection(captureRect)
            let secondIntersection = second.frame.intersection(captureRect)
            let firstArea = firstIntersection.isNull ? 0 : firstIntersection.width * firstIntersection.height
            let secondArea = secondIntersection.isNull ? 0 : secondIntersection.width * secondIntersection.height
            return firstArea < secondArea
        } ?? NSScreen.main
        let screenFrame = screen?.visibleFrame ?? captureRect
        return ScrollCaptureSessionChromeLayout.frames(
            for: CGSize(width: image.width, height: image.height),
            anchoredTo: captureRect,
            chooserSize: PostCaptureChooserLayout.panelSize(
                for: PostCaptureChooserConfiguration.longCaptureActive.controlCount
            ),
            within: screenFrame
        )
    }
}

private enum ScrollCaptureError: LocalizedError {
    case noInitialFrame

    var errorDescription: String? {
        switch self {
        case .noInitialFrame:
            return "Scroll capture couldn't start the video stream."
        }
    }
}
