import AppKit
import SwiftUI

final class HistoryBrowserWindow {
    private var window: NSWindow?
    private let historyManager: HistoryManager
    private let appState: AppState
    private var languageObserver: NSObjectProtocol?

    init(historyManager: HistoryManager, appState: AppState) {
        self.historyManager = historyManager
        self.appState = appState
        languageObserver = NotificationCenter.default.addObserver(
            forName: .languageChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.window?.title = Localization.string("Capture History")
        }
    }

    deinit {
        if let languageObserver {
            NotificationCenter.default.removeObserver(languageObserver)
        }
    }

    func show() {
        if let existingWindow = window {
            existingWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let view = HistoryBrowserView(historyManager: historyManager)
            .appLanguageLocale()
        let hostingController = NSHostingController(rootView: view)

        let newWindow = NSWindow(contentViewController: hostingController)
        newWindow.title = Localization.string("Capture History")
        // The window is cached and reshown; without this, closing it releases
        // the instance and the next show() calls into a dangling pointer.
        newWindow.isReleasedWhenClosed = false
        newWindow.setContentSize(NSSize(width: 800, height: 600))
        newWindow.minSize = NSSize(width: 600, height: 400)
        newWindow.center()
        newWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        self.window = newWindow
    }
}
