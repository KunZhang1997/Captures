import Foundation

enum Constants {
    enum Keys {
        static let hasLaunchedBefore = "hasLaunchedBefore"
        static let menuBarVisible = "menuBarVisible"
        static let captureSound = "captureSound"
        static let captureSoundName = "captureSoundName"
        static let saveToFile = "saveToFile"
        static let closeEditorAfterCopy = "closeEditorAfterCopy"
        static let closeEditorAfterSave = "closeEditorAfterSave"
        static let saveDirectory = "saveDirectory"
        static let imageFormat = "imageFormat"
        static let jpegQuality = "jpegQuality"
        static let filenamePattern = "filenamePattern"
        static let showCrosshair = "showCrosshair"
        static let showMagnifier = "showMagnifier"
        static let freezeScreen = "freezeScreen"
        static let retina2x = "retina2x"
        static let overlayCorner = "overlayCorner"
        static let historyRetentionDays = "historyRetentionDays"
        static let defaultPinnedOpacity = "defaultPinnedOpacity"
        static let pinnedScreenshots = "pinnedScreenshots"
        static let windowCaptureIncludeShadow = "windowCaptureIncludeShadow"
        static let hideDesktopIcons = "hideDesktopIcons"
        static let hotkeyBindings = "hotkeyBindings"
        static let captureScrollShortcutExplicitlyRemoved = "captureScrollShortcutExplicitlyRemoved"
        static let language = "language"
    }

    enum Defaults {
        static let filenamePattern = "{date}_{type}_{time}"
        static let legacyFilenamePattern = "Captures {date} at {time}"
        static let thumbnailWidth: CGFloat = 300
        static let overlayWidth: CGFloat = 320
        static let magnifierSize: CGFloat = 120
        static let magnifierZoom: CGFloat = 8
    }

    enum App {
        static let name = "Captures"
        static let bundleIdentifier = "com.captures.app"
        static let githubURL = "https://github.com/KunZhang1997/Captures"
        static let supportDirectory: URL = {
            let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                .appendingPathComponent("Captures")
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }()
        static let historyDirectory: URL = {
            let url = supportDirectory.appendingPathComponent("History")
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }()
    }
}

/// Shared surface geometry for transient Captures windows. It deliberately
/// lives outside any capture entry point so floating cards, previews, and
/// selection feedback remain visually consistent after the Hub is removed.
enum CapturesWindowStyle {
    static let cornerRadius: CGFloat = 14
}
