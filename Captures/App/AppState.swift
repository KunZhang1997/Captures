import AppKit
import Foundation
import SwiftUI

@Observable
final class AppState {
    private let defaults: UserDefaults
    private var pendingDefaults: [String: Any] = [:]
    private var flushWorkItem: DispatchWorkItem?

    var isFirstRun: Bool {
        didSet { enqueueDefault(!isFirstRun, forKey: Constants.Keys.hasLaunchedBefore) }
    }

    var isCapturing = false

    var language: AppLanguage {
        didSet {
            enqueueDefault(language.rawValue, forKey: Constants.Keys.language)
            Localization.current = language
            NotificationCenter.default.post(name: .languageChanged, object: language)
        }
    }

    var menuBarVisible: Bool {
        didSet { enqueueDefault(menuBarVisible, forKey: Constants.Keys.menuBarVisible) }
    }

    var captureSound: Bool {
        didSet { enqueueDefault(captureSound, forKey: Constants.Keys.captureSound) }
    }

    var captureSoundName: CaptureSound {
        didSet { enqueueDefault(captureSoundName.rawValue, forKey: Constants.Keys.captureSoundName) }
    }

    var saveToFile: Bool {
        didSet { enqueueDefault(saveToFile, forKey: Constants.Keys.saveToFile) }
    }

    var closeEditorAfterCopy: Bool {
        didSet { defaults.set(closeEditorAfterCopy, forKey: Constants.Keys.closeEditorAfterCopy) }
    }

    var closeEditorAfterSave: Bool {
        didSet { defaults.set(closeEditorAfterSave, forKey: Constants.Keys.closeEditorAfterSave) }
    }

    var saveDirectory: URL {
        didSet { enqueueDefault(saveDirectory.path, forKey: Constants.Keys.saveDirectory) }
    }

    var imageFormat: ImageFormat {
        didSet { enqueueDefault(imageFormat.rawValue, forKey: Constants.Keys.imageFormat) }
    }

    var jpegQuality: Double {
        didSet { enqueueDefault(jpegQuality, forKey: Constants.Keys.jpegQuality) }
    }

    var filenamePattern: String {
        didSet { enqueueDefault(filenamePattern, forKey: Constants.Keys.filenamePattern) }
    }

    var showCrosshair: Bool {
        didSet { enqueueDefault(showCrosshair, forKey: Constants.Keys.showCrosshair) }
    }

    var showMagnifier: Bool {
        didSet { enqueueDefault(showMagnifier, forKey: Constants.Keys.showMagnifier) }
    }

    var freezeScreen: Bool {
        didSet { enqueueDefault(freezeScreen, forKey: Constants.Keys.freezeScreen) }
    }

    var retina2x: Bool {
        didSet { enqueueDefault(retina2x, forKey: Constants.Keys.retina2x) }
    }

    var windowCaptureIncludeShadow: Bool {
        didSet { enqueueDefault(windowCaptureIncludeShadow, forKey: Constants.Keys.windowCaptureIncludeShadow) }
    }

    var overlayCorner: OverlayCorner {
        didSet {
            enqueueDefault(overlayCorner.rawValue, forKey: Constants.Keys.overlayCorner)
            NotificationCenter.default.post(name: .overlayCornerChanged, object: nil)
        }
    }

    var historyRetentionDays: Int {
        didSet { enqueueDefault(historyRetentionDays, forKey: Constants.Keys.historyRetentionDays) }
    }

    var defaultPinnedOpacity: Double {
        didSet {
            enqueueDefault(defaultPinnedOpacity, forKey: Constants.Keys.defaultPinnedOpacity)
            NotificationCenter.default.post(name: .pinnedOpacityChanged, object: nil)
        }
    }

    var hotkeyBindings: [HotkeyAction: HotkeyBinding] {
        didSet {
            if let data = Self.encodedHotkeyBindings(hotkeyBindings) {
                enqueueDefault(data, forKey: Constants.Keys.hotkeyBindings)
            }
            NotificationCenter.default.post(name: .hotkeyBindingsChanged, object: nil)
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        self.isFirstRun = !defaults.bool(forKey: Constants.Keys.hasLaunchedBefore)

        if let raw = defaults.string(forKey: Constants.Keys.language),
           let language = AppLanguage(rawValue: raw) {
            self.language = language
        } else {
            self.language = Localization.systemDefaultLanguage
        }
        self.menuBarVisible = defaults.object(forKey: Constants.Keys.menuBarVisible) as? Bool ?? true
        self.captureSound = defaults.object(forKey: Constants.Keys.captureSound) as? Bool ?? false
        if let raw = defaults.string(forKey: Constants.Keys.captureSoundName),
           let sound = CaptureSound(rawValue: raw) {
            self.captureSoundName = sound
        } else {
            self.captureSoundName = .glass
        }
        self.saveToFile = defaults.object(forKey: Constants.Keys.saveToFile) as? Bool ?? true
        self.closeEditorAfterCopy = defaults.object(forKey: Constants.Keys.closeEditorAfterCopy) as? Bool ?? false
        self.closeEditorAfterSave = defaults.object(forKey: Constants.Keys.closeEditorAfterSave) as? Bool ?? false

        if let path = defaults.string(forKey: Constants.Keys.saveDirectory) {
            self.saveDirectory = URL(fileURLWithPath: path)
        } else {
            self.saveDirectory = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSHomeDirectory())
        }

        if let raw = defaults.string(forKey: Constants.Keys.imageFormat),
           let format = ImageFormat(rawValue: raw) {
            self.imageFormat = format
        } else {
            self.imageFormat = .png
        }

        self.jpegQuality = defaults.object(forKey: Constants.Keys.jpegQuality) as? Double ?? 0.9
        let storedFilenamePattern = defaults.string(forKey: Constants.Keys.filenamePattern)
        if storedFilenamePattern == Constants.Defaults.legacyFilenamePattern {
            self.filenamePattern = Constants.Defaults.filenamePattern
            defaults.set(Constants.Defaults.filenamePattern, forKey: Constants.Keys.filenamePattern)
        } else {
            self.filenamePattern = storedFilenamePattern ?? Constants.Defaults.filenamePattern
        }
        self.showCrosshair = defaults.object(forKey: Constants.Keys.showCrosshair) as? Bool ?? true
        self.showMagnifier = defaults.object(forKey: Constants.Keys.showMagnifier) as? Bool ?? false
        self.freezeScreen = defaults.object(forKey: Constants.Keys.freezeScreen) as? Bool ?? true
        self.retina2x = defaults.object(forKey: Constants.Keys.retina2x) as? Bool ?? true
        self.windowCaptureIncludeShadow = defaults.object(forKey: Constants.Keys.windowCaptureIncludeShadow) as? Bool ?? true

        if let raw = defaults.string(forKey: Constants.Keys.overlayCorner),
           let corner = OverlayCorner(rawValue: raw) {
            self.overlayCorner = corner
        } else {
            self.overlayCorner = .bottomRight
        }

        self.historyRetentionDays = defaults.object(forKey: Constants.Keys.historyRetentionDays) as? Int ?? 30
        self.defaultPinnedOpacity = defaults.object(forKey: Constants.Keys.defaultPinnedOpacity) as? Double ?? 1.0

        let configuredHotkeys: [HotkeyAction: HotkeyBinding]
        if let data = defaults.data(forKey: Constants.Keys.hotkeyBindings),
           let storedValues = Self.decodedHotkeyBindings(from: data) {
            let stored = storedValues.reduce(into: [HotkeyAction: HotkeyBinding]()) { bindings, entry in
                guard let action = HotkeyAction(rawValue: entry.key) else { return }
                bindings[action] = entry.value
            }
            if stored == HotkeyBinding.legacyDefaultBindings {
                configuredHotkeys = HotkeyBinding.defaultBindings
                if let migratedData = Self.encodedHotkeyBindings(configuredHotkeys) {
                    defaults.set(migratedData, forKey: Constants.Keys.hotkeyBindings)
                }
            } else {
                var migrated = stored
                // Early customized shortcut maps could contain only the
                // primary area action. Add the long-capture shortcut once so
                // the feature remains reachable after its result-bar route is
                // restored, while preserving a later explicit user removal.
                if migrated[.captureScroll] == nil,
                   !defaults.bool(forKey: Constants.Keys.captureScrollShortcutExplicitlyRemoved),
                   let scrollBinding = HotkeyBinding.defaultBindings[.captureScroll] {
                    migrated[.captureScroll] = scrollBinding
                }
                configuredHotkeys = migrated
                if migrated != stored || stored.count != storedValues.count,
                   let migratedData = Self.encodedHotkeyBindings(migrated) {
                    defaults.set(migratedData, forKey: Constants.Keys.hotkeyBindings)
                }
            }
        } else {
            configuredHotkeys = HotkeyBinding.defaultBindings
        }
        self.hotkeyBindings = configuredHotkeys

        Localization.current = language
    }

    private func enqueueDefault(_ value: Any, forKey key: String) {
        pendingDefaults[key] = value
        flushWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.flushDefaults()
        }
        flushWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: item)
    }

    func flushDefaults() {
        flushWorkItem?.cancel()
        flushWorkItem = nil
        guard !pendingDefaults.isEmpty else { return }
        for (key, value) in pendingDefaults {
            defaults.set(value, forKey: key)
        }
        pendingDefaults.removeAll()
    }

    func setHotkeyBinding(_ binding: HotkeyBinding?, for action: HotkeyAction) {
        var updatedBindings = hotkeyBindings
        updatedBindings[action] = binding
        hotkeyBindings = updatedBindings
        if action == .captureScroll {
            defaults.set(
                binding == nil,
                forKey: Constants.Keys.captureScrollShortcutExplicitlyRemoved
            )
        }
        // Shortcut edits are a deliberate, user-visible preference. Persist
        // them synchronously so a remove action cannot be mistaken for a
        // legacy map and revived on the next launch before the coalesced
        // settings write runs.
        if let data = Self.encodedHotkeyBindings(updatedBindings) {
            defaults.set(data, forKey: Constants.Keys.hotkeyBindings)
        }
    }

    private static func encodedHotkeyBindings(
        _ bindings: [HotkeyAction: HotkeyBinding]
    ) -> Data? {
        let rawBindings = Dictionary(
            uniqueKeysWithValues: bindings.map { ($0.key.rawValue, $0.value) }
        )
        return try? JSONEncoder().encode(rawBindings)
    }

    private static func decodedHotkeyBindings(
        from data: Data
    ) -> [String: HotkeyBinding]? {
        // Current format: a keyed JSON object, which tolerates removal of an
        // obsolete action without invalidating every remaining shortcut.
        if let bindings = try? JSONDecoder().decode([String: HotkeyBinding].self, from: data) {
            return bindings
        }

        // Compatibility for builds that encoded a dictionary keyed by the raw
        // enum. JSON represents that as alternating [key, value] entries.
        guard let values = try? JSONSerialization.jsonObject(with: data) as? [Any],
              values.count.isMultiple(of: 2) else {
            return nil
        }

        var decoded: [String: HotkeyBinding] = [:]
        for index in stride(from: 0, to: values.count, by: 2) {
            guard let action = values[index] as? String,
                  JSONSerialization.isValidJSONObject(values[index + 1]),
                  let bindingData = try? JSONSerialization.data(withJSONObject: values[index + 1]),
                  let binding = try? JSONDecoder().decode(HotkeyBinding.self, from: bindingData) else {
                continue
            }
            decoded[action] = binding
        }
        return decoded
    }
}

enum ImageFormat: String, CaseIterable {
    case png = "png"
    case jpeg = "jpeg"
    case tiff = "tiff"

    var displayName: String {
        switch self {
        case .png: return "PNG"
        case .jpeg: return "JPEG"
        case .tiff: return "TIFF"
        }
    }

    var localizedDisplayName: String {
        Localization.string(displayName)
    }

    var utType: String {
        switch self {
        case .png: return "public.png"
        case .jpeg: return "public.jpeg"
        case .tiff: return "public.tiff"
        }
    }

    var fileExtension: String { rawValue }
}

enum CaptureSound: String, CaseIterable {
    case cameraShot
    case glass
    case tink
    case pop
    case funk
    case hero
    case submarine

    var displayName: String {
        switch self {
        case .cameraShot: return "Camera Shot"
        case .glass: return "Glass"
        case .tink: return "Tink"
        case .pop: return "Pop"
        case .funk: return "Funk"
        case .hero: return "Hero"
        case .submarine: return "Submarine"
        }
    }

    var localizedDisplayName: String {
        Localization.string(displayName)
    }

    var nsSoundName: NSSound.Name {
        switch self {
        case .cameraShot: return NSSound.Name("PhotoShutter")
        case .glass: return NSSound.Name("Glass")
        case .tink: return NSSound.Name("Tink")
        case .pop: return NSSound.Name("Pop")
        case .funk: return NSSound.Name("Funk")
        case .hero: return NSSound.Name("Hero")
        case .submarine: return NSSound.Name("Submarine")
        }
    }
}

enum OverlayCorner: String, CaseIterable {
    case topLeft, topRight, bottomLeft, bottomRight

    var displayName: String {
        switch self {
        case .topLeft: return "Top Left"
        case .topRight: return "Top Right"
        case .bottomLeft: return "Bottom Left"
        case .bottomRight: return "Bottom Right"
        }
    }

    var localizedDisplayName: String {
        Localization.string(displayName)
    }
}
