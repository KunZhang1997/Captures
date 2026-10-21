import Foundation
import SwiftData

@Model
final class CaptureRecord {
    var id: UUID
    var timestamp: Date
    var captureType: String
    var width: Int
    var height: Int
    var filePath: String
    var fileIdentity: String?
    var sourceScale: Double?
    var thumbnailPath: String?
    var fileSize: Int
    var tags: [String]
    var ocrText: String?
    var applicationName: String?

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        captureType: String,
        width: Int,
        height: Int,
        filePath: String,
        fileIdentity: String? = nil,
        sourceScale: Double? = nil,
        thumbnailPath: String? = nil,
        fileSize: Int = 0,
        tags: [String] = [],
        ocrText: String? = nil,
        applicationName: String? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.captureType = captureType
        self.width = width
        self.height = height
        self.filePath = filePath
        self.fileIdentity = fileIdentity
        self.sourceScale = sourceScale
        self.thumbnailPath = thumbnailPath
        self.fileSize = fileSize
        self.tags = tags
        self.ocrText = ocrText
        self.applicationName = applicationName
    }

    var verifiedFileURL: URL? {
        guard !filePath.isEmpty else { return nil }
        let url = URL(fileURLWithPath: filePath)
        guard CaptureFileIdentity.matches(fileIdentity, at: url) else { return nil }
        return url
    }
}

/// Binds a history/quick-access entry to the file that existed when the
/// capture was saved. Paths alone are unsafe because common fixed filename
/// patterns can be reused after a screenshot is moved or deleted.
enum CaptureFileIdentity {
    static func token(for url: URL) -> String? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let systemNumber = (attributes[.systemNumber] as? NSNumber)?.uint64Value,
              let fileNumber = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value else {
            return nil
        }
        return "\(systemNumber):\(fileNumber)"
    }

    static func matches(_ token: String?, at url: URL) -> Bool {
        guard let token else { return false }
        return token == self.token(for: url)
    }
}
