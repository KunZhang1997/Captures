import Foundation

enum FileNameGenerator {
    private static let lock = NSLock()
    private static var counter: Int = {
        UserDefaults.standard.integer(forKey: "fileNameCounter")
    }()
    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH-mm-ss"
        return formatter
    }()

    static func generate(pattern: String, mode: CaptureMode, appName: String? = nil) -> String {
        let now = Date()
        let dateStr: String
        let timeStr: String
        let currentCounter: Int

        lock.lock()
        defer { lock.unlock() }
        dateStr = dateFormatter.string(from: now)
        timeStr = timeFormatter.string(from: now)
        counter += 1
        currentCounter = counter
        UserDefaults.standard.set(currentCounter, forKey: "fileNameCounter")

        let trimmedPattern = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectivePattern = trimmedPattern.isEmpty ? Constants.Defaults.filenamePattern : pattern
        var result = effectivePattern
        result = result.replacingOccurrences(of: "{date}", with: dateStr)
        result = result.replacingOccurrences(of: "{time}", with: timeStr)
        result = result.replacingOccurrences(of: "{counter}", with: String(format: "%04d", currentCounter))
        result = result.replacingOccurrences(of: "{app}", with: appName ?? "Unknown")
        // Keep filename tokens stable across UI language changes.
        result = result.replacingOccurrences(of: "{type}", with: mode.rawValue)

        // Sanitize filename
        let invalidChars = CharacterSet(charactersIn: "/\\:*?\"<>|")
        result = result.components(separatedBy: invalidChars).joined(separator: "_")

        // Empty and dot-only URL path components resolve to the selected
        // directory itself or its parent. Never let a filename template move
        // a capture outside the configured save directory.
        let normalizedResult = result.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalizedResult.isEmpty || normalizedResult == "." || normalizedResult == ".." {
            result = "\(dateStr)_\(mode.rawValue)_\(timeStr)"
        }

        return result
    }
}
