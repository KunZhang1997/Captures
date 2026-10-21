import AppKit

final class MenuBarMenu: NSMenu {
    private let appState: AppState
    private var bindingsObserver: NSObjectProtocol?
    private var languageObserver: NSObjectProtocol?

    init(appState: AppState) {
        self.appState = appState
        super.init(title: "Captures")
        buildMenu()
        bindingsObserver = NotificationCenter.default.addObserver(
            forName: .hotkeyBindingsChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.removeAllItems()
            self?.buildMenu()
        }
        languageObserver = NotificationCenter.default.addObserver(
            forName: .languageChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.removeAllItems()
            self?.buildMenu()
        }
    }

    deinit {
        if let bindingsObserver {
            NotificationCenter.default.removeObserver(bindingsObserver)
        }
        if let languageObserver {
            NotificationCenter.default.removeObserver(languageObserver)
        }
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    private func buildMenu() {
        // Capture modes; key equivalents mirror the user's actual bindings.
        let captureHeader = NSMenuItem(title: Localization.string("Capture"), action: nil, keyEquivalent: "")
        captureHeader.isEnabled = false
        addItem(captureHeader)

        addItem(makeItem("Capture Area", action: #selector(captureArea), hotkeyAction: .captureArea))
        addItem(makeItem("Capture Fullscreen", action: #selector(captureFullscreen), hotkeyAction: .captureFullscreen))
        addItem(makeItem("Capture Window", action: #selector(captureWindow), hotkeyAction: .captureWindow))
        addItem(makeItem("Capture Scroll", action: #selector(captureScroll), hotkeyAction: .captureScroll))

        let openImageItem = makeItem("Open Image…", action: #selector(openImage))
        openImageItem.keyEquivalent = "o"
        openImageItem.keyEquivalentModifierMask = [.command]
        addItem(openImageItem)

        addItem(NSMenuItem.separator())

        addItem(makeItem("Timer Capture", action: #selector(timerCapture), hotkeyAction: .timerCapture))

        addItem(NSMenuItem.separator())

        addItem(makeItem("Settings...", action: #selector(showSettings)))

        addItem(NSMenuItem.separator())

        let quitItem = makeItem("Quit Captures", action: #selector(quitApp))
        quitItem.keyEquivalent = "q"
        quitItem.keyEquivalentModifierMask = [.command]
        addItem(quitItem)
    }

    private func makeItem(_ title: String, action: Selector, hotkeyAction: HotkeyAction? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: Localization.string(title), action: action, keyEquivalent: "")
        if let hotkeyAction, let binding = appState.hotkeyBindings[hotkeyAction] {
            let keyName = KeyCodeMap.name(for: binding.keyCode)
            if keyName.count == 1 {
                item.keyEquivalent = keyName.lowercased()
                item.keyEquivalentModifierMask = modifierFlags(from: binding.modifiers)
            }
        }
        item.target = self
        return item
    }

    private func modifierFlags(from flags: CGEventFlags) -> NSEvent.ModifierFlags {
        var result: NSEvent.ModifierFlags = []
        if flags.contains(.maskCommand) { result.insert(.command) }
        if flags.contains(.maskShift) { result.insert(.shift) }
        if flags.contains(.maskAlternate) { result.insert(.option) }
        if flags.contains(.maskControl) { result.insert(.control) }
        return result
    }

    @objc private func captureFullscreen() {
        NotificationCenter.default.post(name: .startCapture, object: CaptureMode.fullscreen)
    }

    @objc private func captureArea() {
        NotificationCenter.default.post(name: .startCapture, object: CaptureMode.area)
    }

    @objc private func captureWindow() {
        NotificationCenter.default.post(name: .startCapture, object: CaptureMode.window)
    }

    @objc private func captureScroll() {
        NotificationCenter.default.post(name: .startCapture, object: CaptureMode.scroll)
    }

    @objc private func openImage() {
        NotificationCenter.default.post(name: .openImage, object: nil)
    }

    @objc private func timerCapture() {
        NotificationCenter.default.post(name: .startCapture, object: CaptureMode.timer)
    }

    @objc private func showSettings() {
        NotificationCenter.default.post(name: .showSettings, object: nil)
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}

extension Notification.Name {
    static let startCapture = Notification.Name("startCapture")
    static let openImage = Notification.Name("openImage")
    static let showHistory = Notification.Name("showHistory")
    static let showSettings = Notification.Name("showSettings")
    static let showOnboarding = Notification.Name("showOnboarding")
    static let requestPermissions = Notification.Name("requestPermissions")
    static let captureCompleted = Notification.Name("captureCompleted")
    static let menuBarVisibilityChanged = Notification.Name("menuBarVisibilityChanged")
    static let overlayCornerChanged = Notification.Name("overlayCornerChanged")
    static let pinnedOpacityChanged = Notification.Name("pinnedOpacityChanged")
    static let historyRetentionChanged = Notification.Name("historyRetentionChanged")
}
