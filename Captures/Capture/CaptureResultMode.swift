import Foundation

enum CaptureResultMode: String, CaseIterable, Codable {
    case ask
    case editor
    case clipboard
    case preview
    /// A transient direct-save route used by the active long-capture bar.
    /// It is intentionally not a persistent After Capture preference.
    case file

    var displayName: String {
        switch self {
        case .ask: return "Ask Every Time"
        case .editor: return "Open Editor"
        case .clipboard: return "Copy Only"
        case .preview: return "Keep on Page"
        case .file: return "Download"
        }
    }

    var localizedDisplayName: String {
        Localization.string(displayName)
    }

    var localizedDescription: String {
        switch self {
        case .ask:
            return Localization.string("Choose Edit, Keep on Page, or Copy after each capture.")
        case .editor:
            return Localization.string("Open the editor after each capture.")
        case .clipboard:
            return Localization.string("Copy the image to the clipboard without opening the editor.")
        case .preview:
            return Localization.string("Keep captured images stacked on the page without opening the editor.")
        case .file:
            return Localization.string("Save this capture directly to your selected folder.")
        }
    }
}
