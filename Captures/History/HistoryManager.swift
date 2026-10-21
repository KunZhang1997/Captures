import AppKit
import SwiftData

final class HistoryManager {
    let modelContainer: ModelContainer
    let isUsingPersistentStore: Bool
    let thumbnailDirectory: URL
    private let ownsThumbnailDirectory: Bool

    init(storeURL: URL = Constants.App.historyDirectory.appendingPathComponent("History.store")) {
        let schema = Schema([CaptureRecord.self])
        let config = ModelConfiguration(url: storeURL)
        do {
            modelContainer = try ModelContainer(for: schema, configurations: [config])
            isUsingPersistentStore = true
            thumbnailDirectory = storeURL.deletingLastPathComponent()
                .appendingPathComponent("thumbnails", isDirectory: true)
            ownsThumbnailDirectory = false
        } catch {
            // A damaged or incompatible history database must not put a
            // screenshot utility into a permanent launch-crash loop. Preserve
            // the on-disk store for recovery and keep capture paths available
            // with a transient history container for this process.
            NSLog("Captures history store could not be opened; using transient history: %@", String(describing: error))
            do {
                let fallback = ModelConfiguration(isStoredInMemoryOnly: true)
                modelContainer = try ModelContainer(for: schema, configurations: [fallback])
                isUsingPersistentStore = false
                thumbnailDirectory = FileManager.default.temporaryDirectory
                    .appendingPathComponent("Captures-Transient-History-\(UUID().uuidString)", isDirectory: true)
                ownsThumbnailDirectory = true
            } catch {
                fatalError("Failed to create fallback ModelContainer: \(error)")
            }
        }
    }

    deinit {
        cleanupTransientStorage()
    }

    func cleanupTransientStorage() {
        guard ownsThumbnailDirectory else { return }
        try? FileManager.default.removeItem(at: thumbnailDirectory)
    }

    @MainActor
    func saveCapture(
        result: CaptureResult,
        savedURL: URL?,
        thumbnailURL: URL?,
        recordID: UUID = UUID(),
        fileSize: Int? = nil
    ) {
        let resolvedFileSize: Int
        if let fileSize {
            resolvedFileSize = max(0, fileSize)
        } else {
            resolvedFileSize = savedURL.flatMap { url in
                (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            } ?? 0
        }

        let captureType = result.mode.rawValue
        let width = result.width
        let height = result.height
        let filePath = savedURL?.path ?? ""
        let thumbPath = thumbnailURL?.path
        let appName = result.applicationName

        dispatchPrecondition(condition: .onQueue(.main))
        let record = CaptureRecord(
            id: recordID,
            captureType: captureType,
            width: width,
            height: height,
            filePath: filePath,
            fileIdentity: savedURL.flatMap { CaptureFileIdentity.token(for: $0) },
            sourceScale: Double(result.scale),
            thumbnailPath: thumbPath,
            fileSize: resolvedFileSize,
            applicationName: appName
        )
        modelContainer.mainContext.insert(record)
        try? modelContainer.mainContext.save()
        NotificationCenter.default.post(name: .historyDidChange, object: nil)
    }

    /// Attaches a thumbnail only while its record still exists. A user may
    /// delete/clear history while background PNG encoding is running; in that
    /// case remove the late app-owned file instead of resurrecting private
    /// capture data without a record.
    @MainActor
    func attachThumbnail(_ thumbnailURL: URL, to recordID: UUID) {
        dispatchPrecondition(condition: .onQueue(.main))
        let predicate = #Predicate<CaptureRecord> { $0.id == recordID }
        let descriptor = FetchDescriptor<CaptureRecord>(predicate: predicate)
        guard let record = try? modelContainer.mainContext.fetch(descriptor).first else {
            try? FileManager.default.removeItem(at: thumbnailURL)
            return
        }

        record.thumbnailPath = thumbnailURL.path
        try? modelContainer.mainContext.save()
        NotificationCenter.default.post(name: .historyDidChange, object: nil)
    }

    func saveThumbnail(_ image: CGImage, for recordID: UUID) -> URL? {
        let url = thumbnailDirectory
            .appendingPathComponent("\(recordID.uuidString).png")

        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        if ImageUtils.save(image, to: url, format: .png) {
            return url
        }
        return nil
    }

    @MainActor
    func fetchAll(sortedBy sortOrder: SortOrder = .reverse) -> [CaptureRecord] {
        let descriptor = FetchDescriptor<CaptureRecord>(
            sortBy: [SortDescriptor(\.timestamp, order: sortOrder)]
        )
        let records = (try? modelContainer.mainContext.fetch(descriptor)) ?? []
        var updatedLegacyIdentity = false
        for record in records where record.fileIdentity == nil && !record.filePath.isEmpty {
            record.fileIdentity = CaptureFileIdentity.token(for: URL(fileURLWithPath: record.filePath))
            updatedLegacyIdentity = updatedLegacyIdentity || record.fileIdentity != nil
        }
        if updatedLegacyIdentity {
            try? modelContainer.mainContext.save()
        }
        return records
    }

    @MainActor
    func search(query: String) -> [CaptureRecord] {
        let predicate = #Predicate<CaptureRecord> {
            $0.ocrText?.localizedStandardContains(query) == true ||
            $0.applicationName?.localizedStandardContains(query) == true ||
            $0.captureType.localizedStandardContains(query)
        }
        let descriptor = FetchDescriptor<CaptureRecord>(
            predicate: predicate,
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
        return (try? modelContainer.mainContext.fetch(descriptor)) ?? []
    }

    func delete(_ record: CaptureRecord) {
        delete(recordID: record.id)
    }

    func delete(recordID: UUID) {
        DispatchQueue.main.async { [modelContainer] in
            let predicate = #Predicate<CaptureRecord> { $0.id == recordID }
            let descriptor = FetchDescriptor<CaptureRecord>(predicate: predicate)
            guard let record = try? modelContainer.mainContext.fetch(descriptor).first else { return }

            Self.removeManagedFiles(for: record)
            modelContainer.mainContext.delete(record)
            try? modelContainer.mainContext.save()
            NotificationCenter.default.post(name: .historyDidChange, object: nil)
        }
    }

    func deleteOlderThan(days: Int) {
        guard days > 0 else { return }
        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date())!
        DispatchQueue.main.async { [modelContainer] in
            let predicate = #Predicate<CaptureRecord> { $0.timestamp < cutoff }
            let descriptor = FetchDescriptor<CaptureRecord>(predicate: predicate)
            guard let records = try? modelContainer.mainContext.fetch(descriptor), !records.isEmpty else { return }

            for record in records {
                Self.removeManagedFiles(for: record)
                modelContainer.mainContext.delete(record)
            }
            try? modelContainer.mainContext.save()
            NotificationCenter.default.post(name: .historyDidChange, object: nil)
        }
    }

    @MainActor
    func totalStorageSize() -> Int {
        let records = fetchAll()
        return records.reduce(0) { $0 + $1.fileSize }
    }

    func clearAll() {
        DispatchQueue.main.async { [modelContainer] in
            let descriptor = FetchDescriptor<CaptureRecord>()
            guard let records = try? modelContainer.mainContext.fetch(descriptor), !records.isEmpty else { return }

            for record in records {
                Self.removeManagedFiles(for: record)
                modelContainer.mainContext.delete(record)
            }
            try? modelContainer.mainContext.save()
            NotificationCenter.default.post(name: .historyDidChange, object: nil)
        }
    }

    static func removeManagedFiles(for record: CaptureRecord) {
        if let thumbPath = record.thumbnailPath {
            try? FileManager.default.removeItem(atPath: thumbPath)
        }
    }
}

extension Notification.Name {
    static let historyDidChange = Notification.Name("historyDidChange")
}
