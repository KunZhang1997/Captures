import AppKit
import ServiceManagement
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    let appState = AppState()
    private var menuBarController: MenuBarController?
    private var hotkeyManager: HotkeyManager?
    private var captureCoordinator: CaptureCoordinator?
    private var pinnedScreenshotManager: PinnedScreenshotManager?
    private var quickAccessManager: QuickAccessManager?
    private var historyManager: HistoryManager?
    private var historyBrowserWindow: HistoryBrowserWindow?
    private var timerCaptureController: TimerCaptureController?
    private var onboardingWindowController: OnboardingWindowController?
    private var settingsWindow: NSWindow?
    private var observerTokens: [NSObjectProtocol] = []
    private var isWaitingForCaptureOutput = false

    deinit {
        for token in observerTokens {
            NotificationCenter.default.removeObserver(token)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // NSApp.terminate is deferred to the next run-loop pass, so a
        // duplicate instance must not construct status items or event taps.
        guard ensureSingleInstance() else { return }

        ProcessInfo.processInfo.disableAutomaticTermination("Captures should stay alive as a menu bar utility.")

        // Remove the login item created by older builds. The setting and the
        // registration path have been removed from the product.
        removeLegacyLoginItem()

        // Core services
        menuBarController = MenuBarController(appState: appState)
        hotkeyManager = HotkeyManager(appState: appState)
        captureCoordinator = CaptureCoordinator(appState: appState)

        // Keep the app reachable even when hotkey permissions are missing.
        if appState.menuBarVisible {
            menuBarController?.show()
        } else if PermissionChecker.isAccessibilityGranted() {
            menuBarController?.hide()
        } else {
            appState.menuBarVisible = true
            menuBarController?.show()
        }

        // Keep on Page has two coordinated surfaces: the original-size card
        // on the page and a reduced, lower-corner entry for recalling it.
        pinnedScreenshotManager = PinnedScreenshotManager(appState: appState)
        quickAccessManager = QuickAccessManager(appState: appState)

        // History
        historyManager = HistoryManager()
        if let historyManager {
            historyBrowserWindow = HistoryBrowserWindow(historyManager: historyManager, appState: appState)
        }

        // Advanced capture modes
        timerCaptureController = TimerCaptureController()

        // History & editor notifications
        observeNotifications()

        // History retention cleanup
        Task { @MainActor in
            let days = appState.historyRetentionDays
            if days > 0 {
                historyManager?.deleteOlderThan(days: days)
            }
        }

        // First run
        if appState.isFirstRun {
            showOnboarding()
        }

        // The XCTest host shares the regular app bundle identifier. Registering
        // its global shortcuts would collide with a running installed copy and
        // could present a modal conflict alert in the middle of UI unit tests.
        if !Self.isRunningTests {
            hotkeyManager?.start()
        }
        enforceReachability()
    }

    func applicationWillTerminate(_ notification: Notification) {
        quickAccessManager?.discardManagedBackings()
        historyManager?.cleanupTransientStorage()
        appState.flushDefaults()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let captureCoordinator else { return .terminateNow }
        guard !isWaitingForCaptureOutput else { return .terminateLater }

        isWaitingForCaptureOutput = true
        captureCoordinator.finishPendingOutput { [weak self] in
            self?.isWaitingForCaptureOutput = false
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !appState.menuBarVisible {
            showSettingsWindow()
        }
        return true
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        // Retry enabling priority global hotkeys after users grant Accessibility
        // and return from System Settings.
        if !Self.isRunningTests {
            hotkeyManager?.start()
        }
        enforceReachability()
    }

    private static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    private func ensureSingleInstance() -> Bool {
        // The unit-test host must not terminate itself when a regular capture
        // instance is already running.
        guard !Self.isRunningTests else { return true }
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else { return true }
        let currentPID = ProcessInfo.processInfo.processIdentifier
        let runningApps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)

        for runningApp in runningApps where runningApp.processIdentifier != currentPID {
            runningApp.activate(options: [.activateAllWindows])
            NSApp.terminate(nil)
            return false
        }
        return true
    }

    private func showOnboarding() {
        onboardingWindowController = OnboardingWindowController(appState: appState)
        onboardingWindowController?.showWindow(nil)
    }

    private func observeNotifications() {
        let showHistoryToken = NotificationCenter.default.addObserver(forName: .showHistory, object: nil, queue: .main) { [weak self] _ in
            self?.historyBrowserWindow?.show()
        }
        observerTokens.append(showHistoryToken)

        let showSettingsToken = NotificationCenter.default.addObserver(forName: .showSettings, object: nil, queue: .main) { [weak self] _ in
            self?.showSettingsWindow()
        }
        observerTokens.append(showSettingsToken)

        let languageChangedToken = NotificationCenter.default.addObserver(
            forName: .languageChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.settingsWindow?.title = Localization.string("Settings")
        }
        observerTokens.append(languageChangedToken)

        let showOnboardingToken = NotificationCenter.default.addObserver(forName: .showOnboarding, object: nil, queue: .main) { [weak self] _ in
            self?.showOnboarding()
        }
        observerTokens.append(showOnboardingToken)

        let onboardingFinishedToken = NotificationCenter.default.addObserver(forName: .onboardingFinished, object: nil, queue: .main) { [weak self] _ in
            self?.onboardingWindowController?.close()
            self?.onboardingWindowController = nil
        }
        observerTokens.append(onboardingFinishedToken)

        let requestPermissionsToken = NotificationCenter.default.addObserver(forName: .requestPermissions, object: nil, queue: .main) { [weak self] _ in
            self?.requestPermissions()
        }
        observerTokens.append(requestPermissionsToken)

        let hotkeyConflictToken = NotificationCenter.default.addObserver(
            forName: .hotkeyConflictsDetected,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let actions = notification.object as? [HotkeyAction] else { return }
            self?.presentHotkeyConflictAlert(actions: actions)
        }
        observerTokens.append(hotkeyConflictToken)

        let openEditorToken = NotificationCenter.default.addObserver(forName: .openEditor, object: nil, queue: .main) { notification in
            if let wrapper = notification.object as? ImageWrapper {
                AnnotationEditorWindow.open(with: wrapper.image, sourceScale: wrapper.scale)
            }
        }
        observerTokens.append(openEditorToken)

        let openImageToken = NotificationCenter.default.addObserver(forName: .openImage, object: nil, queue: .main) { [weak self] _ in
            self?.showImagePicker()
        }
        observerTokens.append(openImageToken)

        let menuVisibilityToken = NotificationCenter.default.addObserver(
            forName: .menuBarVisibilityChanged,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let isVisible = notification.object as? Bool else { return }
            guard let self else { return }

            if !isVisible, !(self.hotkeyManager?.hasActiveGlobalHotkeys ?? false) {
                self.appState.menuBarVisible = true
                self.menuBarController?.show()
                self.presentHotkeysUnavailableAlert()
                return
            }

            if isVisible {
                self.menuBarController?.show()
            } else {
                self.menuBarController?.hide()
            }
        }
        observerTokens.append(menuVisibilityToken)

        let historyRetentionToken = NotificationCenter.default.addObserver(
            forName: .historyRetentionChanged,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let days = notification.object as? Int else { return }
            guard days > 0 else { return }
            self?.historyManager?.deleteOlderThan(days: days)
        }
        observerTokens.append(historyRetentionToken)

        let clearHistoryToken = NotificationCenter.default.addObserver(
            forName: .clearHistoryRequested,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.historyManager?.clearAll()
        }
        observerTokens.append(clearHistoryToken)

        // Save captures to history
        let captureCompletedToken = NotificationCenter.default.addObserver(
            forName: .captureCompleted,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let info = notification.object as? CaptureCompletedInfo else { return }
            if let saveFailure = info.saveFailure {
                self?.presentCaptureSaveFailure(saveFailure)
            }
            guard let historyManager = self?.historyManager else { return }

            // Register the record before yielding to UI actions. Otherwise a
            // quick Delete/Clear can run before slow thumbnail encoding and a
            // delayed save will recreate data the user already deleted.
            MainActor.assumeIsolated {
                historyManager.saveCapture(
                    result: info.result,
                    savedURL: info.savedURL,
                    thumbnailURL: nil,
                    recordID: info.recordID,
                    fileSize: info.fileSize
                )
            }

            if let thumbnail = info.thumbnail {
                DispatchQueue.global(qos: .utility).async {
                    guard let thumbnailURL = historyManager.saveThumbnail(thumbnail, for: info.recordID) else {
                        return
                    }
                    DispatchQueue.main.async {
                        historyManager.attachThumbnail(thumbnailURL, to: info.recordID)
                    }
                }
            }
        }
        observerTokens.append(captureCompletedToken)

        let deleteHistoryRecordToken = NotificationCenter.default.addObserver(
            forName: .deleteHistoryRecord,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let recordID = notification.object as? UUID else { return }
            self?.historyManager?.delete(recordID: recordID)
        }
        observerTokens.append(deleteHistoryRecordToken)
    }

    private func showImagePicker() {
        let panel = NSOpenPanel()
        panel.title = Localization.string("Open Image")
        panel.message = Localization.string("Choose an image to edit.")
        panel.prompt = Localization.string("Open")
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = ImageImportService.supportedContentTypes

        guard panel.runModal() == .OK, let url = panel.url else { return }
        openImageForEditing(at: url)
    }

    private func openImageForEditing(at url: URL) {
        do {
            let imported = try ImageImportService.loadDocument(at: url)
            AnnotationEditorWindow.open(
                with: imported.image,
                sourceScale: imported.sourceScale,
                documentName: url.lastPathComponent
            )
        } catch {
            let alert = NSAlert(error: error)
            alert.runModal()
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            openImageForEditing(at: url)
        }
    }

    private func showSettingsWindow() {
        let window: NSWindow
        if let existingWindow = settingsWindow {
            window = existingWindow
        } else {
            let content = SettingsView()
                .environment(appState)
            let hostingController = NSHostingController(rootView: content)

            let newWindow = NSWindow(contentViewController: hostingController)
            newWindow.title = Localization.string("Settings")
            newWindow.styleMask = [.titled, .closable, .miniaturizable]
            newWindow.isReleasedWhenClosed = false
            newWindow.setContentSize(NSSize(width: 680, height: 520))
            newWindow.center()
            settingsWindow = newWindow
            window = newWindow

            // Settings writes are debounced; flush when the window closes so
            // changes survive an abnormal exit shortly after.
            let flushToken = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification,
                object: newWindow,
                queue: .main
            ) { [weak self] _ in
                self?.appState.flushDefaults()
            }
            observerTokens.append(flushToken)
        }

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func removeLegacyLoginItem() {
        _ = try? SMAppService.mainApp.unregister()
        UserDefaults.standard.removeObject(forKey: "launchAtLogin")
    }

    private func requestPermissions() {
        NSApp.activate(ignoringOtherApps: true)
        if !PermissionChecker.isScreenCaptureGranted() {
            let screenGranted = PermissionChecker.requestScreenCapture()
            if !screenGranted {
                PermissionChecker.openScreenRecordingSettings()
            }
            return
        }

        if !PermissionChecker.isAccessibilityGranted() {
            let accessibilityGranted = PermissionChecker.requestAccessibility()
            if !accessibilityGranted {
                PermissionChecker.openAccessibilitySettings()
            }
            return
        }

        hotkeyManager?.start()
    }

    private func enforceReachability() {
        // If users hide the menu icon while no global hotkeys are active, the app becomes unreachable.
        guard !appState.menuBarVisible else { return }
        guard !(hotkeyManager?.hasActiveGlobalHotkeys ?? false) else { return }
        appState.menuBarVisible = true
        menuBarController?.show()
    }

    private func presentHotkeysUnavailableAlert() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = Localization.string("Can't Hide Menu Bar Icon Yet")
        alert.informativeText = Localization.string("Global hotkeys are not active. Keep the menu bar icon visible until Accessibility permission is granted.")
        alert.addButton(withTitle: Localization.string("Open Permissions"))
        alert.addButton(withTitle: Localization.string("OK"))
        if alert.runModal() == .alertFirstButtonReturn {
            requestPermissions()
        }
    }

    private func presentHotkeyConflictAlert(actions: [HotkeyAction]) {
        guard !actions.isEmpty else { return }
        let shortcuts = actions.compactMap { action -> String? in
            guard let binding = appState.hotkeyBindings[action] else { return nil }
            return "\(binding.displayString) — \(action.localizedDisplayName)"
        }.joined(separator: "\n")

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = Localization.string("Some Shortcuts Are Already in Use")
        alert.informativeText = String(
            format: Localization.string("Another app registered these shortcuts first:\n%@\n\nCaptures will keep retrying without extra permission. Start Captures before that app, or assign different shortcuts in Settings."),
            shortcuts
        )
        alert.addButton(withTitle: Localization.string("Open Shortcut Settings"))
        alert.addButton(withTitle: Localization.string("Later"))
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            showSettingsWindow()
        default:
            break
        }
    }

    private func presentCaptureSaveFailure(_ failure: CaptureSaveFailure) {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = Localization.string("Screenshot Could Not Be Saved to the Selected Folder")
        if let recoveredURL = failure.recoveredURL {
            alert.informativeText = Localization.string(
                "The selected location was unavailable. A full-resolution recovery copy was saved at:\n\(recoveredURL.path)"
            )
            alert.addButton(withTitle: Localization.string("Reveal Recovery Copy"))
            alert.addButton(withTitle: Localization.string("OK"))
            if alert.runModal() == .alertFirstButtonReturn {
                NSWorkspace.shared.activateFileViewerSelecting([recoveredURL])
            }
        } else {
            alert.informativeText = Localization.string(
                "The selected location was unavailable and Captures could not create a recovery copy. Keep the editor or page card open and save the image manually."
            )
            alert.addButton(withTitle: Localization.string("OK"))
            alert.runModal()
        }
    }
}

extension Notification.Name {
    static let clearHistoryRequested = Notification.Name("clearHistoryRequested")
}
