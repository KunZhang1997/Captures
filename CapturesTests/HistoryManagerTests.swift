import CoreGraphics
import XCTest
@testable import Captures

final class HistoryManagerTests: XCTestCase {
    @MainActor
    func testCorruptStoreFallsBackWithoutDestroyingOriginalData() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let storeURL = directory.appendingPathComponent("History.store")
        let corruptData = Data("not a sqlite database".utf8)
        try corruptData.write(to: storeURL)

        let manager = HistoryManager(storeURL: storeURL)

        XCTAssertFalse(manager.isUsingPersistentStore)
        XCTAssertTrue(manager.fetchAll().isEmpty)
        XCTAssertEqual(try Data(contentsOf: storeURL), corruptData)

        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: 2,
            height: 2,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let thumbnail = try XCTUnwrap(context.makeImage())
        let thumbnailURL = try XCTUnwrap(manager.saveThumbnail(thumbnail, for: UUID()))
        XCTAssertTrue(FileManager.default.fileExists(atPath: thumbnailURL.path))
        XCTAssertNotEqual(thumbnailURL.deletingLastPathComponent(), directory.appendingPathComponent("thumbnails"))

        manager.cleanupTransientStorage()
        XCTAssertFalse(FileManager.default.fileExists(atPath: manager.thumbnailDirectory.path))
    }

    func testRemovingManagedFilesPreservesExportAndDeletesThumbnail() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let exportedURL = directory.appendingPathComponent("exported.png")
        let thumbnailURL = directory.appendingPathComponent("thumbnail.png")
        try Data("export".utf8).write(to: exportedURL)
        try Data("thumbnail".utf8).write(to: thumbnailURL)

        let record = CaptureRecord(
            captureType: "area",
            width: 100,
            height: 100,
            filePath: exportedURL.path,
            thumbnailPath: thumbnailURL.path
        )

        HistoryManager.removeManagedFiles(for: record)

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: exportedURL.path),
            "Removing history must not delete the user's exported screenshot"
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: thumbnailURL.path),
            "Removing history should delete the app-owned thumbnail"
        )
    }

    @MainActor
    func testLateThumbnailCompletionCannotRestoreDataAfterRecordDeletion() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let manager = HistoryManager(storeURL: directory.appendingPathComponent("History.store"))
        let recordID = UUID()
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: 4,
            height: 4,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let image = try XCTUnwrap(context.makeImage())
        let result = CaptureResult(
            image: image,
            mode: .area,
            timestamp: Date(),
            sourceRect: CGRect(x: 0, y: 0, width: 4, height: 4),
            windowName: nil,
            applicationName: nil,
            scale: 1
        )
        manager.saveCapture(
            result: result,
            savedURL: nil,
            thumbnailURL: nil,
            recordID: recordID
        )
        XCTAssertEqual(manager.fetchAll().map(\.id), [recordID])

        manager.delete(recordID: recordID)
        let deletionProcessed = expectation(description: "Deletion processed on main queue")
        DispatchQueue.main.async { deletionProcessed.fulfill() }
        await fulfillment(of: [deletionProcessed], timeout: 2)
        XCTAssertTrue(manager.fetchAll().isEmpty)

        let lateThumbnailURL = directory.appendingPathComponent("late-thumbnail.png")
        try Data("sensitive thumbnail".utf8).write(to: lateThumbnailURL)
        manager.attachThumbnail(lateThumbnailURL, to: recordID)

        XCTAssertFalse(FileManager.default.fileExists(atPath: lateThumbnailURL.path))
        XCTAssertTrue(manager.fetchAll().isEmpty)
    }
}
