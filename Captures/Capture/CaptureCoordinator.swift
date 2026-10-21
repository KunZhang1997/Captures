import AppKit
import OSLog

final class CaptureCoordinator {
    private static let logger = Logger(subsystem: "com.captures.app", category: "CaptureFlow")
    private let appState: AppState
    private let notificationCenter: NotificationCenter
    private let recoveryDirectory: URL
    private let previewCacheDirectory: URL
    private let openEditor: @MainActor (CGImage, CGFloat, AnnotationEditorMode) -> Void
    private let captureService = ScreenCaptureService()
    // Filename allocation and image creation must stay ordered. finishCapture
    // releases the capture reservation before disk output completes, so using
    // a global concurrent queue lets two same-second captures both choose and
    // write the same path.
    private let outputQueue = DispatchQueue(label: "com.captures.capture-output", qos: .userInitiated)
    private lazy var scrollCaptureCoordinator = ScrollCaptureCoordinator(
        appState: appState,
        finishCapture: { [weak self] result, options, editorMode in
            Task { @MainActor in
                self?.finishCapture(
                    result: result,
                    options: options,
                    editorMode: editorMode
                )
            }
        },
        handleError: { [weak self] error, context in
            Task { @MainActor in
                self?.handleCaptureError(error, context: context)
            }
        },
        onSessionEnd: { [weak self] in
            Task { @MainActor in
                self?.appState.isCapturing = false
            }
        }
    )
    private var areaSelectorController: AreaSelectorWindowController?
    private var windowSelectorController: WindowSelectorController?
    private var postCaptureChooserManager: PostCaptureChooserManager?
    private var observerTokens: [NSObjectProtocol] = []

    init(
        appState: AppState,
        notificationCenter: NotificationCenter = .default,
        recoveryDirectory: URL? = nil,
        previewCacheDirectory: URL? = nil,
        openEditor: @escaping @MainActor (CGImage, CGFloat, AnnotationEditorMode) -> Void = {
            image,
            sourceScale,
            mode in
            AnnotationEditorWindow.open(
                with: image,
                sourceScale: sourceScale,
                mode: mode
            )
        }
    ) {
        self.appState = appState
        self.notificationCenter = notificationCenter
        self.recoveryDirectory = recoveryDirectory ?? Self.defaultRecoveryDirectory
        self.previewCacheDirectory = previewCacheDirectory ?? Self.defaultPreviewCacheDirectory
        self.openEditor = openEditor
        observeCaptureTriggers()
    }

    deinit {
        for token in observerTokens {
            notificationCenter.removeObserver(token)
        }
    }

    private func observeCaptureTriggers() {
        let token = notificationCenter.addObserver(
            forName: .startCapture,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            if let request = notification.object as? TimerCaptureRequest {
                self?.startTimerCapture(request: request)
            } else if let mode = notification.object as? CaptureMode {
                self?.startCapture(mode: mode)
            }
        }
        observerTokens.append(token)

        let timerFinishToken = notificationCenter.addObserver(
            forName: .timerCaptureDidFinish,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            if let mode = notification.object as? CaptureMode {
                // The countdown owns the existing capture reservation. Continue
                // directly instead of re-entering startCapture and hitting its guard.
                guard self.appState.isCapturing else { return }
                self.performCapture(mode: mode == .timer ? .fullscreen : mode)
            } else {
                // A nil mode means the countdown was cancelled or could not start.
                self.appState.isCapturing = false
            }
        }
        observerTokens.append(timerFinishToken)
    }

    func startCapture(mode: CaptureMode) {
        guard !appState.isCapturing else {
            Self.logger.warning("Ignored capture request for \(String(describing: mode), privacy: .public); capture already active")
            return
        }
        Self.logger.notice("Starting capture mode \(String(describing: mode), privacy: .public)")
        appState.isCapturing = true

        performCapture(mode: mode)
    }

    private func startTimerCapture(request: TimerCaptureRequest) {
        guard !appState.isCapturing else { return }
        appState.isCapturing = true
        notificationCenter.post(name: .startTimerCapture, object: request)
    }

    private func performCapture(mode: CaptureMode) {
        let options = CaptureOptions.from(appState: appState)

        switch mode {
        case .fullscreen:
            captureFullscreen(options: options)
        case .area:
            captureArea(options: options)
        case .window:
            captureWindow(options: options)
        case .scroll:
            captureScroll(options: options)
        case .timer:
            notificationCenter.post(name: .startTimerCapture, object: TimerCaptureRequest.default)
        }
    }

    private func captureFullscreen(options: CaptureOptions) {
        Task {
            do {
                let capture = try await captureService.captureAllDisplays(retinaScale: options.retina2x)
                let result = CaptureResult(
                    image: capture.image,
                    mode: .fullscreen,
                    timestamp: Date(),
                    sourceRect: capture.sourceRect,
                    windowName: nil,
                    applicationName: nil,
                    scale: capture.scale
                )
                await finishCapture(result: result, options: options)
            } catch {
                await handleCaptureError(error, context: "Fullscreen capture")
            }
        }
    }

    private func captureArea(options: CaptureOptions) {
        // The selector becomes the frontmost window before the user reaches
        // the action bar. Keep the originating app for the long-capture
        // target resolver, otherwise manual scrolling can lose its source.
        let sourceApplication = ScrollCaptureSourceApplication.frontmostExternalApplication()
        areaSelectorController?.close()
        areaSelectorController = nil
        areaSelectorController = AreaSelectorWindowController { [weak self] selection in
            guard let self else { return }

            guard let selection else {
                self.areaSelectorController = nil
                self.appState.isCapturing = false
                return
            }

            if options.resultMode == .ask {
                Task { @MainActor in
                    self.beginAreaCaptureChoice(
                        initialRect: selection.rect,
                        options: options,
                        sourceApplication: sourceApplication
                    )
                }
                return
            }

            Task {
                do {
                    let result = try await self.captureResult(
                        for: selection,
                        options: options
                    )
                    await self.finishCapture(
                        result: result,
                        options: options,
                        onResultResolved: { [weak self] in
                            self?.areaSelectorController?.close()
                            self?.areaSelectorController = nil
                        }
                    )
                } catch {
                    await self.handleCaptureError(error, context: "Area capture")
                }
            }
        }
        areaSelectorController?.show(
            freezeScreen: options.freezeScreen,
            showMagnifier: options.showMagnifier,
            retinaScale: options.retina2x,
            defersCaptureUntilResultChoice: options.resultMode == .ask,
            keepFloatingCapturesVisible: PostCaptureRoutingPolicy.keepsFloatingCapturesVisible(
                for: options.resultMode
            ),
            selectsWindowsOnClick: true
        )
    }

    @MainActor
    private func beginAreaCaptureChoice(
        initialRect: NSRect,
        options: CaptureOptions,
        sourceApplication: ScrollCaptureSourceApplication?
    ) {
        let chooserManager = postCaptureChooserManager ?? PostCaptureChooserManager()
        postCaptureChooserManager = chooserManager
        let quickEditor = areaSelectorController?.prepareQuickEditor()
        let chooserID = chooserManager.show(
            anchoredTo: initialRect,
            configuration: .areaSelection,
            quickEditor: quickEditor
        ) { [weak self] choice in
            guard let self else { return }

            let selector = self.areaSelectorController
            let finalSelection = choice == nil ? nil : selector?.currentPendingSelectionResult()
            selector?.close()
            self.areaSelectorController = nil

            guard let choice, let finalSelection else {
                self.appState.isCapturing = false
                return
            }

            if choice == .scroll {
                // Keep the existing reservation through the long-capture
                // session. The coordinator clears it when the session ends.
                self.appState.isCapturing = true
                self.scrollCaptureCoordinator.start(
                    from: finalSelection.rect,
                    options: options,
                    sourceApplication: sourceApplication
                )
                return
            }

            self.appState.isCapturing = false
            guard let route = self.postCaptureRoute(for: choice, options: options) else { return }

            Task { @MainActor in
                do {
                    let result = try await self.captureResult(
                        for: finalSelection,
                        options: options
                    )
                    self.completeCapture(
                        result: result,
                        options: route.options,
                        editorMode: route.editorMode,
                        playSound: true,
                        showCopyConfirmation: false,
                        floatingFrame: finalSelection.rect
                    )
                } catch {
                    self.handleCaptureError(error, context: "Area capture")
                }
            }
        }

        areaSelectorController?.pendingSelectionChangedHandler = { movedOrResizedRect in
            chooserManager.reposition(id: chooserID, anchoredTo: movedOrResizedRect)
        }
        areaSelectorController?.pendingSelectionKeyHandler = { [weak quickEditor] event in
            quickEditor?.handleKey(event) { choice in
                chooserManager.choose(id: chooserID, choice: choice)
            } ?? false
        }
    }

    private func captureWindow(options: CaptureOptions) {
        windowSelectorController?.close()
        windowSelectorController = nil
        windowSelectorController = WindowSelectorController { [weak self] windowInfo in
            guard let self else { return }

            guard let windowInfo else {
                self.windowSelectorController?.close()
                self.windowSelectorController = nil
                self.appState.isCapturing = false
                return
            }

            if options.resultMode == .ask {
                Task { @MainActor [weak self] in
                    self?.beginWindowCaptureChoice(windowInfo, options: options)
                }
            } else {
                self.windowSelectorController?.close()
                self.windowSelectorController = nil
                self.captureSelectedWindow(windowInfo, options: options)
            }
        }
        windowSelectorController?.show(
            keepFloatingCapturesVisible: PostCaptureRoutingPolicy.keepsFloatingCapturesVisible(
                for: options.resultMode
            ),
            defersCaptureUntilResultChoice: options.resultMode == .ask
        )
    }

    @MainActor
    private func beginWindowCaptureChoice(
        _ windowInfo: WindowInfo,
        options: CaptureOptions
    ) {
        let chooserManager = postCaptureChooserManager ?? PostCaptureChooserManager()
        postCaptureChooserManager = chooserManager
        let appKitFrame = CoordinateSpace.cgToAppKit(windowInfo.frame)
        chooserManager.show(anchoredTo: appKitFrame) { [weak self] choice in
            guard let self else { return }

            self.windowSelectorController?.close()
            self.windowSelectorController = nil
            self.appState.isCapturing = false

            guard let choice,
                  let route = self.postCaptureRoute(for: choice, options: options) else { return }
            self.captureSelectedWindow(
                windowInfo,
                options: route.options,
                editorMode: route.editorMode
            )
        }
    }

    private func captureSelectedWindow(
        _ windowInfo: WindowInfo,
        options: CaptureOptions,
        editorMode: AnnotationEditorMode = .annotation
    ) {
        Task { [weak self] in
            guard let self else { return }
            do {
                let image = try await self.captureService.captureWindow(
                    windowInfo.window,
                    retinaScale: options.retina2x,
                    includeShadow: options.includeShadow
                )
                let result = CaptureResult(
                    image: image,
                    mode: .window,
                    timestamp: Date(),
                    sourceRect: windowInfo.frame,
                    windowName: windowInfo.title,
                    applicationName: windowInfo.appName,
                    scale: windowInfo.frame.width > 0
                        ? CGFloat(image.width) / windowInfo.frame.width
                        : 1
                )
                await self.finishCapture(
                    result: result,
                    options: options,
                    editorMode: editorMode
                )
            } catch {
                await self.handleCaptureError(error, context: "Window capture")
            }
        }
    }

    private struct PostCaptureRoute {
        let options: CaptureOptions
        let editorMode: AnnotationEditorMode
    }

    private func postCaptureRoute(
        for choice: PostCaptureChoice,
        options: CaptureOptions
    ) -> PostCaptureRoute? {
        if choice == .ocr {
            var routedOptions = options
            routedOptions.resultMode = .editor
            routedOptions.copyToClipboard = false
            return PostCaptureRoute(options: routedOptions, editorMode: .ocr)
        }

        guard let resultMode = choice.resultMode else { return nil }
        return PostCaptureRoute(
            options: PostCaptureRoutingPolicy.resolvedOptions(
                from: options,
                choice: resultMode
            ),
            editorMode: .annotation
        )
    }

    private func captureResult(
        for selection: AreaSelectionResult,
        options: CaptureOptions
    ) async throws -> CaptureResult {
        let image: CGImage
        let mode: CaptureMode
        let windowName: String?
        let applicationName: String?

        if let selectedWindow = selection.selectedWindow {
            image = try await captureService.captureWindow(
                selectedWindow.window,
                retinaScale: options.retina2x,
                includeShadow: options.includeShadow
            )
            mode = .window
            windowName = selectedWindow.title
            applicationName = selectedWindow.appName
        } else {
            if let frozenImage = selection.frozenImage {
                image = frozenImage
            } else {
                image = try await captureService.captureRect(
                    CoordinateSpace.appKitToCG(selection.rect),
                    retinaScale: options.retina2x
                )
            }
            mode = .area
            windowName = nil
            applicationName = nil
        }

        return CaptureResult(
            image: image,
            mode: mode,
            timestamp: Date(),
            sourceRect: selection.rect,
            windowName: windowName,
            applicationName: applicationName,
            scale: selection.rect.width > 0
                ? CGFloat(image.width) / selection.rect.width
                : 1
        )
    }

    private func captureScroll(options: CaptureOptions) {
        scrollCaptureCoordinator.start(options: options)
    }

    @MainActor
    func finishCapture(
        result: CaptureResult,
        options: CaptureOptions,
        editorMode: AnnotationEditorMode = .annotation,
        onResultResolved: (() -> Void)? = nil
    ) {
        appState.isCapturing = false

        if options.resultMode == .ask {
            if options.playSound {
                SoundPlayer.playCapture(options.captureSound)
            }

            let chooserManager = postCaptureChooserManager ?? PostCaptureChooserManager()
            postCaptureChooserManager = chooserManager
            chooserManager.show(anchoredTo: result.sourceRect) { [weak self] choice in
                defer { onResultResolved?() }
                guard let self, let choice,
                      let route = self.postCaptureRoute(for: choice, options: options) else { return }
                self.completeCapture(
                    result: result,
                    options: route.options,
                    editorMode: route.editorMode,
                    playSound: false,
                    showCopyConfirmation: false
                )
            }
            return
        }

        completeCapture(
            result: result,
            options: options,
            editorMode: editorMode,
            playSound: true,
            showCopyConfirmation: true
        )
        onResultResolved?()
    }

    @MainActor
    private func completeCapture(
        result: CaptureResult,
        options: CaptureOptions,
        editorMode: AnnotationEditorMode = .annotation,
        playSound: Bool,
        showCopyConfirmation: Bool,
        floatingFrame: NSRect? = nil
    ) {
        let recordID = UUID()

        // Copy-only mode is an explicit result route, so it always copies even
        // when the independent "Copy to Clipboard" toggle is off.
        if options.copyToClipboard || options.resultMode == .clipboard {
            PasteboardHelper.copyImage(
                result.image,
                scale: result.scale,
                showsConfirmation: showCopyConfirmation
            )
        }

        // The editor is only one result route. Clipboard leaves the user's
        // current app untouched; Keep on Page creates a separate floating
        // image window without opening the editor.
        if options.resultMode == .editor {
            openEditor(result.image, result.scale, editorMode)
        } else if options.resultMode == .preview {
            notificationCenter.post(
                name: .showFloatingCapture,
                object: FloatingCaptureRequest(
                    recordID: recordID,
                    image: result.image,
                    scale: result.scale,
                    frame: floatingFrame
                )
            )
        }

        // Play sound
        if playSound && options.playSound {
            SoundPlayer.playCapture(options.captureSound)
        }

        // Copy Only promises a clipboard-only result. Do not emit the
        // completion payload consumed by HistoryManager, because its
        // thumbnail encoder would otherwise leave a PNG copy under
        // Application Support even when Save is disabled.
        if options.resultMode == .clipboard {
            return
        }

        let completionNotificationCenter = notificationCenter
        let recoveryDirectory = recoveryDirectory
        let previewCacheDirectory = previewCacheDirectory
        let openEditor = openEditor
        outputQueue.async {
            var savedURL: URL?
            var managedPreviewURL: URL?
            var fileSize = 0
            var saveFailure: CaptureSaveFailure?
            // "Copy Only" is intentionally exclusive: it must not create a
            // second file output in the background.
            if options.saveToFile && options.resultMode != .clipboard {
                let filename = FileNameGenerator.generate(
                    pattern: options.filenamePattern,
                    mode: result.mode,
                    appName: result.applicationName
                )
                let url = FileManager.default.uniqueURL(
                    for: options.saveDirectory
                        .appendingPathComponent(filename)
                        .appendingPathExtension(options.format.fileExtension)
                )
                if ImageUtils.save(result.image, to: url, format: options.format, jpegQuality: options.jpegQuality) {
                    savedURL = url
                    fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
                } else {
                    // The configured destination may disappear (for example,
                    // an unplugged external volume). Keep a durable full-size
                    // recovery copy instead of silently leaving only history's
                    // thumbnail after the editor/card is closed.
                    try? FileManager.default.createDirectory(
                        at: recoveryDirectory,
                        withIntermediateDirectories: true
                    )
                    let recoveryURL = FileManager.default.uniqueURL(
                        for: recoveryDirectory.appendingPathComponent(url.lastPathComponent)
                    )
                    if ImageUtils.save(
                        result.image,
                        to: recoveryURL,
                        format: options.format,
                        jpegQuality: options.jpegQuality
                    ) {
                        savedURL = recoveryURL
                        fileSize = (try? FileManager.default.attributesOfItem(atPath: recoveryURL.path)[.size] as? Int) ?? 0
                        saveFailure = CaptureSaveFailure(
                            requestedURL: url,
                            recoveredURL: recoveryURL
                        )
                    } else {
                        saveFailure = CaptureSaveFailure(
                            requestedURL: url,
                            recoveredURL: nil
                        )
                    }
                }
            }
            if options.resultMode == .preview && savedURL == nil {
                try? FileManager.default.createDirectory(
                    at: previewCacheDirectory,
                    withIntermediateDirectories: true
                )
                let cacheURL = previewCacheDirectory
                    .appendingPathComponent(recordID.uuidString)
                    .appendingPathExtension("png")
                if ImageUtils.save(result.image, to: cacheURL, format: .png) {
                    managedPreviewURL = cacheURL
                }
            }
            let thumbnail = ImageUtils.generateThumbnail(result.image)

            DispatchQueue.main.async {
                // A one-shot Download must never discard the only full-size
                // image. If both the chosen folder and recovery location are
                // unavailable, retain the pixels in the native editor so the
                // person can choose another destination and retry.
                if options.resultMode == .file,
                   saveFailure?.recoveredURL == nil,
                   saveFailure != nil {
                    openEditor(result.image, result.scale, .annotation)
                }
                completionNotificationCenter.post(
                    name: .captureCompleted,
                    object: CaptureCompletedInfo(
                        recordID: recordID,
                        result: result,
                        savedURL: savedURL,
                        managedPreviewURL: managedPreviewURL,
                        fileSize: fileSize,
                        thumbnail: thumbnail,
                        resultMode: options.resultMode,
                        saveFailure: saveFailure
                    )
                )
            }
        }
    }

    /// Runs `completion` on the main queue after every output operation that
    /// has already been submitted. App termination uses this barrier so a
    /// capture cannot be killed while ImageIO is still finalizing its file.
    func finishPendingOutput(completion: @escaping () -> Void) {
        outputQueue.async {
            DispatchQueue.main.async(execute: completion)
        }
    }

    @MainActor
    private func handleCaptureError(_ error: Error, context: String) {
        appState.isCapturing = false
        areaSelectorController?.close()
        areaSelectorController = nil

        if let captureError = error as? CaptureError, captureError == .permissionDenied {
            PermissionChecker.promptForScreenRecordingInSettings()
            return
        }

        print("\(context) failed: \(error)")
    }

    private static var defaultRecoveryDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Captures/Recovered Captures", isDirectory: true)
    }

    private static var defaultPreviewCacheDirectory: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("Captures/Quick Access", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }
}

struct CaptureSaveFailure {
    let requestedURL: URL
    let recoveredURL: URL?
}

struct CaptureCompletedInfo {
    let recordID: UUID
    let result: CaptureResult
    let savedURL: URL?
    let managedPreviewURL: URL?
    let fileSize: Int
    let thumbnail: CGImage?
    let resultMode: CaptureResultMode
    let saveFailure: CaptureSaveFailure?
}

extension Notification.Name {
    static let startTimerCapture = Notification.Name("startTimerCapture")
    static let deleteHistoryRecord = Notification.Name("deleteHistoryRecord")
    static let timerCaptureDidFinish = Notification.Name("timerCaptureDidFinish")
}
