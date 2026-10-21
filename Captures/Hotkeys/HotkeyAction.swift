import Foundation

enum HotkeyAction: String, CaseIterable, Codable {
    case captureFullscreen
    case captureArea
    case captureWindow
    case captureScroll
    case timerCapture
    case toggleDesktopIcons

    static var configurableCases: [HotkeyAction] {
        [
            .captureArea,
            .captureFullscreen,
            .captureWindow,
            .captureScroll,
            .timerCapture,
            .toggleDesktopIcons,
        ]
    }

    var displayName: String {
        switch self {
        case .captureFullscreen: return "Capture Fullscreen"
        case .captureArea: return "Capture Area"
        case .captureWindow: return "Capture Window"
        case .captureScroll: return "Capture Scroll"
        case .timerCapture: return "Timer Capture"
        case .toggleDesktopIcons: return "Toggle Desktop Icons"
        }
    }

    var localizedDisplayName: String {
        Localization.string(displayName)
    }

    var captureMode: CaptureMode? {
        switch self {
        case .captureFullscreen: return .fullscreen
        case .captureArea: return .area
        case .captureWindow: return .window
        case .captureScroll: return .scroll
        case .timerCapture: return .timer
        case .toggleDesktopIcons: return nil
        }
    }
}
