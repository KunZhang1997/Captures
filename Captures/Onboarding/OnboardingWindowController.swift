import AppKit
import SwiftUI

final class OnboardingWindowController: NSWindowController {
    private var languageObserver: NSObjectProtocol?

    convenience init(appState: AppState) {
        let content = OnboardingView()
            .environment(appState)
            .appLanguageLocale()
        let hostingController = NSHostingController(rootView: content)

        let window = NSWindow(contentViewController: hostingController)
        window.title = Localization.string("Welcome to Captures")
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()

        self.init(window: window)
        languageObserver = NotificationCenter.default.addObserver(
            forName: .languageChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.window?.title = Localization.string("Welcome to Captures")
        }
    }

    deinit {
        if let languageObserver {
            NotificationCenter.default.removeObserver(languageObserver)
        }
    }
}
