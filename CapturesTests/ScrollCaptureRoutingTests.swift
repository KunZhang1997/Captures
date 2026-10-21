import AppKit
import CoreGraphics
import XCTest
@testable import Captures

final class ScrollCaptureRoutingTests: XCTestCase {
    func testLongCaptureResultBarExposesEveryFinalAction() {
        XCTAssertEqual(
            PostCaptureChooserConfiguration.longCaptureActive.choices,
            [.editor, .ocr, .save, .clipboard]
        )
        XCTAssertTrue(PostCaptureChooserConfiguration.longCaptureActive.showsCloseButton)
        XCTAssertEqual(PostCaptureChooserConfiguration.longCaptureActive.controlCount, 5)
    }

    func testLongCaptureRoutesEditOCRDownloadAndCopyWithoutMutatingOriginalOptions() throws {
        let original = CaptureOptions(
            copyToClipboard: true,
            resultMode: .ask,
            saveToFile: false
        )

        let edit = try XCTUnwrap(
            ScrollCaptureResultRouting.route(for: .editor, options: original)
        )
        XCTAssertEqual(edit.options.resultMode, .editor)
        XCTAssertEqual(edit.editorMode, .annotation)
        XCTAssertFalse(edit.options.copyToClipboard)

        let ocr = try XCTUnwrap(
            ScrollCaptureResultRouting.route(for: .ocr, options: original)
        )
        XCTAssertEqual(ocr.options.resultMode, .editor)
        XCTAssertEqual(ocr.editorMode, .ocr)
        XCTAssertFalse(ocr.options.copyToClipboard)

        let download = try XCTUnwrap(
            ScrollCaptureResultRouting.route(for: .save, options: original)
        )
        XCTAssertEqual(download.options.resultMode, .file)
        XCTAssertTrue(download.options.saveToFile)
        XCTAssertFalse(download.options.copyToClipboard)

        let copy = try XCTUnwrap(
            ScrollCaptureResultRouting.route(for: .clipboard, options: original)
        )
        XCTAssertEqual(copy.options.resultMode, .clipboard)
        XCTAssertFalse(copy.options.copyToClipboard)

        XCTAssertNil(ScrollCaptureResultRouting.route(for: .scroll, options: original))
        XCTAssertNil(ScrollCaptureResultRouting.route(for: .preview, options: original))
        XCTAssertEqual(original.resultMode, .ask)
        XCTAssertTrue(original.copyToClipboard)
        XCTAssertFalse(original.saveToFile)
    }

    @MainActor
    func testLongCaptureChooserDeliversEditAndDownloadInsteadOfLeavingSessionActive() throws {
        for choice in [PostCaptureChoice.editor, .save] {
            let state = LockedScrollCaptureSessionState()
            let manager = PostCaptureChooserManager()
            let chooserID = manager.show(
                anchoredTo: NSRect(x: 160, y: 160, width: 420, height: 260),
                configuration: .longCaptureActive,
                completion: { state.resolve($0) }
            )
            let panel = try XCTUnwrap(
                NSApp.windows.first {
                    $0.identifier == PostCaptureChooserManager.panelIdentifier(for: chooserID)
                }
            )

            manager.choose(id: chooserID, choice: choice)

            XCTAssertEqual(state.state, .selected(choice))
            XCTAssertFalse(state.isCapturing)
            XCTAssertFalse(panel.isVisible)
            XCTAssertNil(panel.contentView)
        }
    }

    @MainActor
    func testLongCaptureEditOpensTheNativeEditorRouteExactlyOnce() throws {
        let suiteName = "ScrollCaptureRoutingTests.edit.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var opened: [(CGImage, CGFloat, AnnotationEditorMode)] = []
        let coordinator = CaptureCoordinator(
            appState: AppState(defaults: defaults),
            notificationCenter: NotificationCenter(),
            openEditor: { opened.append(($0, $1, $2)) }
        )
        let route = try XCTUnwrap(
            ScrollCaptureResultRouting.route(
                for: .editor,
                options: CaptureOptions(saveToFile: false)
            )
        )
        let image = makeImage(width: 32, height: 160)

        coordinator.finishCapture(
            result: makeScrollResult(image: image),
            options: route.options,
            editorMode: route.editorMode
        )

        XCTAssertEqual(opened.count, 1)
        XCTAssertEqual(opened[0].0.width, 32)
        XCTAssertEqual(opened[0].0.height, 160)
        XCTAssertEqual(opened[0].1, 2)
        XCTAssertEqual(opened[0].2, .annotation)
    }

    @MainActor
    func testLongCaptureDownloadWritesConfiguredFormatAndDirectoryOnce() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Captures-Long-Download-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let suiteName = "ScrollCaptureRoutingTests.download.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let notificationCenter = NotificationCenter()
        var editorOpenCount = 0
        let coordinator = CaptureCoordinator(
            appState: AppState(defaults: defaults),
            notificationCenter: notificationCenter,
            openEditor: { _, _, _ in editorOpenCount += 1 }
        )
        let completed = expectation(description: "Long capture download completes")
        var completionInfos: [CaptureCompletedInfo] = []
        let token = notificationCenter.addObserver(
            forName: .captureCompleted,
            object: nil,
            queue: .main
        ) { notification in
            if let info = notification.object as? CaptureCompletedInfo {
                completionInfos.append(info)
            }
            completed.fulfill()
        }
        defer { notificationCenter.removeObserver(token) }
        var original = CaptureOptions(
            copyToClipboard: true,
            resultMode: .ask,
            saveToFile: false,
            format: .png,
            saveDirectory: directory,
            filenamePattern: "long-result"
        )
        original.playSound = false
        let route = try XCTUnwrap(
            ScrollCaptureResultRouting.route(for: .save, options: original)
        )

        coordinator.finishCapture(
            result: makeScrollResult(image: makeImage(width: 24, height: 144)),
            options: route.options,
            editorMode: route.editorMode
        )
        await fulfillment(of: [completed], timeout: 5)

        XCTAssertEqual(completionInfos.count, 1)
        let info = try XCTUnwrap(completionInfos.first)
        let savedURL = try XCTUnwrap(info.savedURL)
        XCTAssertEqual(savedURL.deletingLastPathComponent(), directory)
        XCTAssertEqual(savedURL.lastPathComponent, "long-result.png")
        XCTAssertEqual(info.result.mode, .scroll)
        XCTAssertEqual(info.resultMode, .file)
        XCTAssertNil(info.saveFailure)
        XCTAssertEqual(editorOpenCount, 0)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["long-result.png"])
        let savedImage = try XCTUnwrap(NSImage(contentsOf: savedURL))
        XCTAssertEqual(savedImage.representations.first?.pixelsWide, 24)
        XCTAssertEqual(savedImage.representations.first?.pixelsHigh, 144)
    }

    @MainActor
    func testFailedLongCaptureDownloadKeepsPixelsInNativeEditorForRetry() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Captures-Long-Recovery-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let unavailableDirectory = directory.appendingPathComponent("blocked-destination")
        let unavailableRecovery = directory.appendingPathComponent("blocked-recovery")
        try Data("not a directory".utf8).write(to: unavailableDirectory)
        try Data("not a directory".utf8).write(to: unavailableRecovery)

        let suiteName = "ScrollCaptureRoutingTests.recovery.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let notificationCenter = NotificationCenter()
        var openedImages: [CGImage] = []
        let coordinator = CaptureCoordinator(
            appState: AppState(defaults: defaults),
            notificationCenter: notificationCenter,
            recoveryDirectory: unavailableRecovery,
            openEditor: { image, _, _ in openedImages.append(image) }
        )
        let completed = expectation(description: "Failed long download retains image")
        var completedInfo: CaptureCompletedInfo?
        let token = notificationCenter.addObserver(
            forName: .captureCompleted,
            object: nil,
            queue: .main
        ) { notification in
            completedInfo = notification.object as? CaptureCompletedInfo
            completed.fulfill()
        }
        defer { notificationCenter.removeObserver(token) }
        let image = makeImage(width: 20, height: 120)
        let route = try XCTUnwrap(
            ScrollCaptureResultRouting.route(
                for: .save,
                options: CaptureOptions(
                    playSound: false,
                    copyToClipboard: false,
                    resultMode: .ask,
                    saveToFile: false,
                    format: .png,
                    saveDirectory: unavailableDirectory,
                    filenamePattern: "must-remain"
                )
            )
        )

        coordinator.finishCapture(
            result: makeScrollResult(image: image),
            options: route.options,
            editorMode: route.editorMode
        )
        await fulfillment(of: [completed], timeout: 5)

        XCTAssertEqual(openedImages.count, 1)
        XCTAssertEqual(openedImages.first?.width, image.width)
        XCTAssertEqual(openedImages.first?.height, image.height)
        XCTAssertNotNil(completedInfo?.saveFailure)
        XCTAssertNil(completedInfo?.saveFailure?.recoveredURL)
        XCTAssertNil(completedInfo?.savedURL)
    }

    private func makeScrollResult(image: CGImage) -> CaptureResult {
        CaptureResult(
            image: image,
            mode: .scroll,
            timestamp: Date(),
            sourceRect: CGRect(x: 10, y: 20, width: 16, height: 80),
            windowName: nil,
            applicationName: "Test App",
            scale: 2
        )
    }

    private func makeImage(width: Int, height: Int) -> CGImage {
        let bytesPerRow = width * 4
        let data = Data(repeating: 220, count: height * bytesPerRow)
        let provider = CGDataProvider(data: data as CFData)!
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )!
    }
}
