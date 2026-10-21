import AppKit
import ScreenCaptureKit

struct ScrollCaptureSourceApplication: Sendable, Equatable {
    let processIdentifier: pid_t
    let name: String?

    static func frontmostExternalApplication() -> ScrollCaptureSourceApplication? {
        guard let application = NSWorkspace.shared.frontmostApplication,
              application.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            return nil
        }
        return ScrollCaptureSourceApplication(
            processIdentifier: application.processIdentifier,
            name: application.localizedName
        )
    }
}

struct ScrollCaptureTarget: Sendable, Equatable {
    let appPID: pid_t?
    let appName: String?
}

enum ScrollCaptureInputMode: Equatable {
    case manual
}

/// Resolves and activates the application beneath the selected region.
/// Scrolling itself deliberately remains real user input: synthetic wheel and
/// accessibility-scroll events are not reliable across browsers, PDF viewers,
/// Electron apps, and nested scroll containers.
final class ScrollCaptureTargetController {
    static let inputMode = ScrollCaptureInputMode.manual

    private let target: ScrollCaptureTarget

    init(target: ScrollCaptureTarget) {
        self.target = target
    }

    var targetName: String? {
        target.appName
    }

    static func resolveTarget(
        at point: CGPoint,
        content: SCShareableContent,
        fallbackApplication: ScrollCaptureSourceApplication? = nil
    ) -> ScrollCaptureTarget {
        let window = topmostWindow(at: point, content: content)
        let appPID = window.flatMap { $0.owningApplication?.processID }.map { pid_t($0) }
            ?? fallbackApplication?.processIdentifier
        let appName = window?.owningApplication?.applicationName
            ?? fallbackApplication?.name
        return ScrollCaptureTarget(appPID: appPID, appName: appName)
    }

    func prepareForManualScrolling() async {
        guard let appPID = target.appPID,
              let application = NSRunningApplication(processIdentifier: appPID) else {
            return
        }
        await MainActor.run {
            _ = application.activate(options: [.activateAllWindows])
        }
    }

    /// Frontmost normal-level window under the point, excluding Captures' own
    /// windows. `SCShareableContent.windows` has no guaranteed z-order, so the
    /// CG window list supplies front-to-back order.
    private static func topmostWindow(
        at point: CGPoint,
        content: SCShareableContent
    ) -> SCWindow? {
        let ownPID = pid_t(ProcessInfo.processInfo.processIdentifier)

        if let windowInfo = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] {
            for entry in windowInfo {
                guard let pid = entry[kCGWindowOwnerPID as String] as? pid_t,
                      pid != ownPID,
                      let layer = entry[kCGWindowLayer as String] as? Int,
                      layer == 0,
                      let boundsDict = entry[kCGWindowBounds as String] as? NSDictionary,
                      let bounds = CGRect(dictionaryRepresentation: boundsDict),
                      bounds.contains(point),
                      let windowID = entry[kCGWindowNumber as String] as? CGWindowID else {
                    continue
                }
                if let match = content.windows.first(where: { $0.windowID == windowID }) {
                    return match
                }
            }
        }

        return content.windows.first(where: { window in
            window.frame.contains(point)
                && (window.owningApplication.map { pid_t($0.processID) != ownPID } ?? true)
        })
    }
}
