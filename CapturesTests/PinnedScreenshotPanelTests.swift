import AppKit
import SwiftUI
import XCTest
@testable import Captures

@MainActor
final class PinnedScreenshotPanelTests: XCTestCase {
    func testLockedPanelKeepsUnlockMenuReachableWhileFreezingGeometry() throws {
        let panel = PinnedScreenshotPanel(
            image: try makeImage(),
            frame: NSRect(x: 0, y: 0, width: 100, height: 100)
        )

        panel.isLocked = true

        XCTAssertFalse(panel.ignoresMouseEvents, "locked pins must still receive the Unlock click")
        XCTAssertFalse(panel.isMovable)
        XCTAssertFalse(panel.isMovableByWindowBackground)
        XCTAssertFalse(panel.styleMask.contains(.resizable))

        panel.isLocked = false

        XCTAssertFalse(panel.ignoresMouseEvents)
        XCTAssertTrue(panel.isMovable)
        XCTAssertTrue(panel.isMovableByWindowBackground)
        XCTAssertTrue(panel.styleMask.contains(.resizable))
    }

    func testFloatingCapturePanelKeepsItsExactImageFrameWithEditableActions() throws {
        let frame = NSRect(x: 120, y: 160, width: 320, height: 320)
        let panel = PinnedScreenshotPanel(
            image: try makeImage(),
            scale: 2,
            frame: frame,
            appearance: .floatingCapture
        )

        XCTAssertEqual(panel.frame.size, frame.size)
        XCTAssertEqual(panel.minSize, NSSize(width: 96, height: 96))
        XCTAssertEqual(panel.contentAspectRatio, NSSize(width: 1, height: 1))
        XCTAssertFalse(panel.styleMask.contains(.titled))
        XCTAssertTrue(panel.styleMask.contains(.resizable))
        XCTAssertFalse(
            panel.styleMask.contains(.nonactivatingPanel),
            "an unpinned card must activate and return to the front when clicked"
        )
        XCTAssertFalse(panel.isAlwaysOnTop)
        XCTAssertEqual(panel.level, .normal)
        XCTAssertFalse(panel.isOpaque)
        XCTAssertEqual(panel.backgroundColor.alphaComponent, 0, accuracy: 0.001)
        XCTAssertEqual(panel.sharingType, .none)
        XCTAssertTrue(panel.isMovableByWindowBackground)

        let imageView = try XCTUnwrap(panel.contentView as? NSImageView)
        XCTAssertEqual(imageView.layer?.borderWidth, 1)
        XCTAssertEqual(imageView.layer?.cornerRadius, CapturesWindowStyle.cornerRadius)
        let toolbar = try XCTUnwrap(imageView.subviews.first {
            $0.identifier?.rawValue == "floatingCaptureActionBar"
        })
        toolbar.layoutSubtreeIfNeeded()
        XCTAssertEqual(toolbar.frame.origin.x, 10)
        XCTAssertEqual(toolbar.frame.size, NSSize(width: 300, height: 24))
        let buttons = toolbar.subviews.compactMap { $0 as? NSButton }
        XCTAssertEqual(buttons.count, 4)
        XCTAssertEqual(buttons.map(\.toolTip), [
            Localization.string("Close"),
            Localization.string("Edit"),
            Localization.string("OCR"),
            Localization.string("Keep on Top"),
        ])

        for button in buttons {
            let point = NSPoint(x: button.bounds.midX, y: button.bounds.midY)
            let hit = imageView.hitTest(button.convert(point, to: imageView))
            XCTAssertTrue(hit === button)
        }
    }

    func testFloatingCaptureOnlyStaysAboveOtherAppsWhenPinned() throws {
        let panel = PinnedScreenshotPanel(
            image: try makeImage(),
            frame: NSRect(x: 0, y: 0, width: 160, height: 160),
            appearance: .floatingCapture
        )

        XCTAssertFalse(panel.isAlwaysOnTop)
        XCTAssertEqual(panel.level, .normal)
        XCTAssertFalse(panel.styleMask.contains(.nonactivatingPanel))

        _ = panel.perform(NSSelectorFromString("toggleAlwaysOnTop"))

        XCTAssertTrue(panel.isAlwaysOnTop)
        XCTAssertEqual(panel.level, .floating)

        _ = panel.perform(NSSelectorFromString("toggleAlwaysOnTop"))

        XCTAssertFalse(panel.isAlwaysOnTop)
        XCTAssertEqual(panel.level, .normal)
        XCTAssertFalse(panel.styleMask.contains(.nonactivatingPanel))
    }

    func testClosingFloatingCaptureAlsoDismissesItsQuickPreview() throws {
        let image = try makeImage()
        let recordID = UUID()
        let capture = QuickAccessCapture(
            id: UUID(),
            recordID: recordID,
            inMemoryImage: image,
            thumbnail: image,
            mode: .area,
            timestamp: Date(),
            savedURL: nil,
            width: image.width,
            height: image.height,
            fileSize: 0,
            scale: 1
        )
        let suiteName = "CapturesTests.quickPreviewLifecycle.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let manager = QuickAccessManager(appState: AppState(defaults: defaults))
        manager.captures = [capture]

        NotificationCenter.default.post(
            name: .floatingCapturePresentationChanged,
            object: FloatingCapturePresentationChange(recordID: recordID, isVisible: false)
        )

        XCTAssertTrue(manager.captures.isEmpty)
        XCTAssertTrue(manager.visibleCaptures.isEmpty)
    }

    func testEditorWindowCanToggleAlwaysOnTop() throws {
        let controller = NativeImageEditorViewController(image: try makeImage())
        let window = NSWindow(contentViewController: controller)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        _ = controller.view

        XCTAssertFalse(controller.isAlwaysOnTop)
        XCTAssertEqual(window.level, .normal)

        _ = controller.perform(NSSelectorFromString("toggleAlwaysOnTop"))

        XCTAssertTrue(controller.isAlwaysOnTop)
        XCTAssertEqual(window.level, .floating)

        _ = controller.perform(NSSelectorFromString("toggleAlwaysOnTop"))

        XCTAssertFalse(controller.isAlwaysOnTop)
        XCTAssertEqual(window.level, .normal)
    }

    func testFloatingCapturePanelKeepsTheSourceAspectRatioWhenResizing() throws {
        let panel = PinnedScreenshotPanel(
            image: try makeImage(width: 4, height: 2),
            frame: NSRect(x: 0, y: 0, width: 320, height: 240),
            appearance: .floatingCapture
        )

        XCTAssertEqual(panel.frame.width / panel.frame.height, 2, accuracy: 0.001)
        XCTAssertEqual(panel.minSize.width / panel.minSize.height, 2, accuracy: 0.001)
        XCTAssertEqual(
            panel.contentAspectRatio.width / panel.contentAspectRatio.height,
            2,
            accuracy: 0.001
        )
    }

    func testFloatingCaptureOCRUsesASeparateCompanionPanel() throws {
        let panel = PinnedScreenshotPanel(
            image: try makeImage(width: 480, height: 270),
            frame: NSRect(x: 100, y: 100, width: 480, height: 270),
            appearance: .floatingCapture
        )

        _ = panel.perform(NSSelectorFromString("toggleOCRPanel"))

        let ocrPanel = try XCTUnwrap(panel.childWindows?.first)
        XCTAssertFalse(ocrPanel.isOpaque)
        XCTAssertEqual(ocrPanel.backgroundColor.alphaComponent, 0, accuracy: 0.001)
        XCTAssertEqual(ocrPanel.frame.size, NSSize(width: 300, height: 220))
        XCTAssertEqual(ocrPanel.sharingType, .none)

        let imageView = try XCTUnwrap(panel.contentView as? NSImageView)
        XCTAssertFalse(imageView.subviews.contains {
            $0.identifier?.rawValue == "floatingCaptureOCROverlay"
        })
    }

    func testAnnotatingPersistentPinDoesNotCloseAndDeleteItsSource() throws {
        let panel = PinnedScreenshotPanel(
            image: try makeImage(),
            frame: NSRect(x: 0, y: 0, width: 100, height: 100)
        )
        defer { panel.close() }

        var editorOpenCount = 0
        var closeCount = 0
        let editorToken = NotificationCenter.default.addObserver(
            forName: .openEditor,
            object: nil,
            queue: .main
        ) { _ in
            editorOpenCount += 1
        }
        let closeToken = NotificationCenter.default.addObserver(
            forName: .pinnedScreenshotClosed,
            object: nil,
            queue: .main
        ) { _ in
            closeCount += 1
        }
        defer {
            NotificationCenter.default.removeObserver(editorToken)
            NotificationCenter.default.removeObserver(closeToken)
        }

        _ = panel.perform(NSSelectorFromString("annotateImage"))

        XCTAssertEqual(editorOpenCount, 1)
        XCTAssertEqual(closeCount, 0)
    }

    func testSavingPinnedImageReportsAnUnwritableDestination() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Captures-Pinned-Save-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let fileBlockingParent = root.appendingPathComponent("not-a-directory")
        try Data("blocker".utf8).write(to: fileBlockingParent)
        let destination = fileBlockingParent.appendingPathComponent("Pinned Screenshot.png")

        XCTAssertThrowsError(try PinnedScreenshotPanel.writePNG(makeImage(), to: destination))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testPersistentPinIsRejectedBeforeShowingWhenItsBackingCannotBeWritten() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Captures-Pin-Backing-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let fileBlockingParent = root.appendingPathComponent("not-a-directory")
        try Data("blocker".utf8).write(to: fileBlockingParent)
        let suiteName = "CapturesTests.pinBacking.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let appState = AppState(defaults: defaults)
        let manager = PinnedScreenshotManager(
            appState: appState,
            defaults: defaults,
            pinsDirectoryOverride: fileBlockingParent.appendingPathComponent("Pins")
        )

        XCTAssertFalse(manager.pinImage(try makeImage()))
        XCTAssertNil(defaults.array(forKey: Constants.Keys.pinnedScreenshots))
    }

    func testFloatingCapturePanelRendersToolbarSnapshot() throws {
        let panel = PinnedScreenshotPanel(
            image: try makeImage(width: 480, height: 270),
            frame: NSRect(x: 0, y: 0, width: 480, height: 270),
            appearance: .floatingCapture
        )
        let contentView = try XCTUnwrap(panel.contentView)
        contentView.layoutSubtreeIfNeeded()

        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 960,
            pixelsHigh: 540,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        bitmap.size = contentView.bounds.size
        contentView.cacheDisplay(in: contentView.bounds, to: bitmap)

        let snapshot = NSImage(size: contentView.bounds.size)
        snapshot.addRepresentation(bitmap)
        let attachment = XCTAttachment(image: snapshot)
        attachment.name = "floating-capture-toolbar"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testQuickPreviewRendersCompactActionsInsideTheImage() throws {
        let image = try makeImage(width: 480, height: 270)
        let capture = QuickAccessCapture(
            id: UUID(),
            recordID: UUID(),
            inMemoryImage: image,
            thumbnail: image,
            mode: .area,
            timestamp: Date(),
            savedURL: nil,
            width: image.width,
            height: image.height,
            fileSize: 0,
            scale: 1
        )
        let suiteName = "CapturesTests.quickPreviewSnapshot.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let manager = QuickAccessManager(appState: AppState(defaults: defaults))
        let contentView = NSHostingView(rootView: CaptureThumbnailView(
            capture: capture,
            manager: manager,
            thumbnailWidth: 232
        ))
        let fittingSize = contentView.fittingSize
        XCTAssertLessThan(
            fittingSize.height,
            150,
            "Overlay actions must not add a separate toolbar below the 130.5-point image"
        )
        contentView.frame = NSRect(origin: .zero, size: fittingSize)
        contentView.layoutSubtreeIfNeeded()

        let bitmap = try XCTUnwrap(contentView.bitmapImageRepForCachingDisplay(in: contentView.bounds))
        contentView.cacheDisplay(in: contentView.bounds, to: bitmap)
        let snapshot = NSImage(size: contentView.bounds.size)
        snapshot.addRepresentation(bitmap)
        let attachment = XCTAttachment(image: snapshot)
        attachment.name = "quick-preview-overlay-actions"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func makeImage(width: Int = 2, height: Int = 2) throws -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let image = context.makeImage() else {
            throw TestError.imageCreationFailed
        }
        return image
    }

    private enum TestError: Error {
        case imageCreationFailed
    }
}
