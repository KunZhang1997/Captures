import Foundation

enum CaptureMode: String, CaseIterable, Codable {
    case fullscreen
    case area
    case window
    case scroll
    case timer

    var displayName: String {
        switch self {
        case .fullscreen: return "Fullscreen"
        case .area: return "Area"
        case .window: return "Window"
        case .scroll: return "Scroll"
        case .timer: return "Timer"
        }
    }

    var localizedDisplayName: String {
        Localization.string(displayName)
    }

    var iconName: String {
        switch self {
        case .fullscreen: return "rectangle.dashed"
        case .area: return "crop"
        case .window: return "macwindow"
        case .scroll: return "scroll"
        case .timer: return "timer"
        }
    }
}
