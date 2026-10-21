import XCTest
import CoreGraphics
import AppKit
import ImageIO
import Observation
import UniformTypeIdentifiers
@testable import Captures

final class CapturesTests: XCTestCase {
    func testBrandNameRemainsEnglishInEverySupportedLanguage() {
        let originalLanguage = Localization.current
        defer { Localization.current = originalLanguage }

        for language in AppLanguage.allCases {
            Localization.current = language
            XCTAssertEqual(Localization.string("Captures"), "Captures")
        }

        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String, "Captures")
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String, "Captures")
    }

    func testLocalizationStringInvalidatesObservationWhenLanguageChanges() {
        let originalLanguage = Localization.current
        defer { Localization.current = originalLanguage }

        Localization.current = .english
        let invalidated = expectation(description: "localized SwiftUI content invalidates")
        withObservationTracking {
            _ = Localization.string("Usage")
        } onChange: {
            invalidated.fulfill()
        }

        Localization.current = .simplifiedChinese

        wait(for: [invalidated], timeout: 0.1)
    }

    func testInAppUpdatesAreNotConfigured() {
        let info = Bundle.main.infoDictionary
        XCTAssertNil(info?["SUFeedURL"])
        XCTAssertNil(info?["SUPublicEDKey"])
        XCTAssertNil(info?["SURequireSignedFeed"])
        XCTAssertNil(info?["SUVerifyUpdateBeforeExtraction"])
    }

    func testCaptureModeCases() {
        XCTAssertEqual(CaptureMode.allCases.count, 5)
        XCTAssertEqual(CaptureMode.fullscreen.displayName, "Fullscreen")
        XCTAssertEqual(CaptureMode.scroll.displayName, "Scroll")
    }

    func testCaptureOptionsAlwaysRouteThroughThePostCaptureActionBar() {
        let suiteName = "CapturesTests.postCaptureActionBar.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        // An old Hub preference must not bypass the post-capture action bar.
        defaults.set(CaptureResultMode.preview.rawValue, forKey: "captureResultMode")
        let options = CaptureOptions.from(appState: AppState(defaults: defaults))

        XCTAssertEqual(options.resultMode, .ask)
        XCTAssertFalse(options.copyToClipboard)
    }

    func testCustomizedShortcutMapRestoresLongCaptureOnce() throws {
        let suiteName = "CapturesTests.longCaptureShortcutMigration.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let customArea = HotkeyBinding(
            keyCode: 12,
            modifiers: [.maskCommand, .maskShift]
        )
        // Pre-fix builds encoded enum-keyed dictionaries as alternating JSON
        // values. The migration must recover that existing user preference.
        let stored = [HotkeyAction.captureArea: customArea]
        defaults.set(
            try JSONEncoder().encode(stored),
            forKey: Constants.Keys.hotkeyBindings
        )

        let migratedState = AppState(defaults: defaults)
        XCTAssertEqual(migratedState.hotkeyBindings[.captureArea], customArea)
        XCTAssertEqual(
            migratedState.hotkeyBindings[.captureScroll],
            HotkeyBinding.defaultBindings[.captureScroll]
        )

        migratedState.setHotkeyBinding(nil, for: .captureScroll)
        migratedState.flushDefaults()
        XCTAssertTrue(defaults.bool(forKey: Constants.Keys.captureScrollShortcutExplicitlyRemoved))
        let persisted = try XCTUnwrap(defaults.data(forKey: Constants.Keys.hotkeyBindings))
        let persistedBindings = try JSONDecoder().decode([String: HotkeyBinding].self, from: persisted)
        XCTAssertNil(persistedBindings[HotkeyAction.captureScroll.rawValue])
        let reloadedState = AppState(defaults: defaults)
        XCTAssertNil(reloadedState.hotkeyBindings[.captureScroll])
    }

    func testPostCaptureChoiceIsOneShotAndDoesNotInheritAutomaticCopy() {
        let original = CaptureOptions(
            copyToClipboard: true,
            resultMode: .ask,
            saveToFile: true
        )

        let edit = PostCaptureRoutingPolicy.resolvedOptions(from: original, choice: .editor)
        XCTAssertEqual(edit.resultMode, .editor)
        XCTAssertFalse(edit.copyToClipboard)
        XCTAssertTrue(edit.saveToFile)
        XCTAssertEqual(original.resultMode, .ask)
        XCTAssertTrue(original.copyToClipboard)

        XCTAssertTrue(PostCaptureRoutingPolicy.keepsFloatingCapturesVisible(for: .ask))
        XCTAssertTrue(PostCaptureRoutingPolicy.keepsFloatingCapturesVisible(for: .preview))
        XCTAssertFalse(PostCaptureRoutingPolicy.keepsFloatingCapturesVisible(for: .clipboard))

        let download = PostCaptureRoutingPolicy.resolvedOptions(from: original, choice: .file)
        XCTAssertEqual(download.resultMode, .file)
        XCTAssertFalse(download.copyToClipboard)
        XCTAssertTrue(download.saveToFile)
    }

    func testPostCaptureChooserUsesOutsideTopLeadingThenFallsBackInside() {
        let size = PostCaptureChooserLayout.panelSize
        let screen = NSRect(x: 0, y: 0, width: 1_440, height: 900)

        let outside = PostCaptureChooserLayout.frame(
            anchoredTo: NSRect(x: 100, y: 300, width: 500, height: 300),
            panelSize: size,
            within: screen
        )
        XCTAssertEqual(outside.origin, NSPoint(x: 100, y: 608))

        let fullscreen = PostCaptureChooserLayout.frame(
            anchoredTo: screen,
            panelSize: size,
            within: screen
        )
        XCTAssertEqual(fullscreen.origin, NSPoint(x: 8, y: 850))
        XCTAssertTrue(screen.contains(fullscreen))

        let topEdgeSelection = NSRect(x: 1_000, y: 700, width: 300, height: 180)
        let inside = PostCaptureChooserLayout.frame(
            anchoredTo: topEdgeSelection,
            panelSize: size,
            within: screen
        )
        // The six-control result capsule shifts left near the right edge;
        // adding Download must never clip Copy outside the screen.
        XCTAssertEqual(inside.origin, NSPoint(x: screen.maxX - 8 - size.width, y: 830))
        XCTAssertEqual(inside.maxX, screen.maxX - 8)
        XCTAssertTrue(topEdgeSelection.intersects(inside))
        XCTAssertTrue(screen.contains(inside))
    }

    func testEditorCompletionPreferencesDefaultOffAndPersistIndependently() {
        let suiteName = "CapturesTests.editorCompletion.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let initialState = AppState(defaults: defaults)
        XCTAssertFalse(initialState.closeEditorAfterCopy)
        XCTAssertFalse(initialState.closeEditorAfterSave)

        initialState.closeEditorAfterCopy = true
        XCTAssertTrue(defaults.bool(forKey: Constants.Keys.closeEditorAfterCopy))
        XCTAssertFalse(defaults.bool(forKey: Constants.Keys.closeEditorAfterSave))

        initialState.closeEditorAfterSave = true
        let restoredState = AppState(defaults: defaults)
        XCTAssertTrue(restoredState.closeEditorAfterCopy)
        XCTAssertTrue(restoredState.closeEditorAfterSave)
    }

    func testNativeEditorRetainsRetinaScaleForClipboardExport() {
        let image = makeSolidRGBAImage(width: 20, height: 10, red: 255, green: 255, blue: 255)
        let controller = NativeImageEditorViewController(image: image, sourceScale: 2)

        XCTAssertEqual(controller.sourceScale, 2)
    }

    func testEditorChromeFollowsLightAndDarkAppearances() throws {
        let surface = EditorChromeSurface(frame: NSRect(x: 0, y: 0, width: 320, height: 40))
        let lightAppearance = try XCTUnwrap(NSAppearance(named: .aqua))
        let darkAppearance = try XCTUnwrap(NSAppearance(named: .darkAqua))

        surface.appearance = lightAppearance
        surface.viewDidChangeEffectiveAppearance()
        let lightColor = try XCTUnwrap(
            surface.layer?.backgroundColor.flatMap(NSColor.init(cgColor:))?.usingColorSpace(.sRGB)
        )

        surface.appearance = darkAppearance
        surface.viewDidChangeEffectiveAppearance()
        let darkColor = try XCTUnwrap(
            surface.layer?.backgroundColor.flatMap(NSColor.init(cgColor:))?.usingColorSpace(.sRGB)
        )

        XCTAssertGreaterThan(lightColor.brightnessComponent, 0.8)
        XCTAssertLessThan(darkColor.brightnessComponent, 0.3)
        XCTAssertGreaterThan(lightColor.brightnessComponent - darkColor.brightnessComponent, 0.5)
    }

    func testNativeEditorRendersDarkChromeSnapshot() throws {
        let image = makeSolidRGBAImage(width: 1_280, height: 720, red: 24, green: 25, blue: 28)
        let controller = NativeImageEditorViewController(image: image)
        let window = NSWindow(contentViewController: controller)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.appearance = try XCTUnwrap(NSAppearance(named: .darkAqua))
        window.setContentSize(NSSize(width: 1_000, height: 620))

        let contentView = controller.view
        contentView.layoutSubtreeIfNeeded()
        contentView.displayIfNeeded()

        let chromeSurfaces = contentView.subviews.compactMap { $0 as? EditorChromeSurface }
        XCTAssertEqual(chromeSurfaces.count, 2)
        for surface in chromeSurfaces {
            let background = try XCTUnwrap(
                surface.layer?.backgroundColor.flatMap(NSColor.init(cgColor:))?.usingColorSpace(.sRGB)
            )
            XCTAssertLessThan(background.brightnessComponent, 0.3)
        }

        func buttons(in view: NSView) -> [NSButton] {
            view.subviews.flatMap { subview in
                (subview as? NSButton).map { [$0] } ?? buttons(in: subview)
            }
        }
        let selectedButtons = buttons(in: contentView).filter { $0.state == .on }
        XCTAssertFalse(selectedButtons.isEmpty)
        for button in selectedButtons {
            let background = try XCTUnwrap(
                button.layer?.backgroundColor.flatMap(NSColor.init(cgColor:))?.usingColorSpace(.sRGB)
            )
            XCTAssertLessThanOrEqual(
                background.alphaComponent,
                0.12,
                "Selected button \(button.title) must not paint an opaque light-mode fill"
            )
        }

        let bitmap = try XCTUnwrap(contentView.bitmapImageRepForCachingDisplay(in: contentView.bounds))
        contentView.cacheDisplay(in: contentView.bounds, to: bitmap)
        let snapshot = NSImage(size: contentView.bounds.size)
        snapshot.addRepresentation(bitmap)
        let attachment = XCTAttachment(image: snapshot)
        attachment.name = "native-editor-dark-mode"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testEditorToolDefaultsStartWithLightAnnotationTreatment() {
        let toolManager = ToolManager()

        XCTAssertEqual(Double(toolManager.strokeWidth), 6, accuracy: 0.001)
        XCTAssertEqual(Double(toolManager.fontSize), 18, accuracy: 0.001)
        XCTAssertEqual(Double(toolManager.watermarkOpacity), 0.55, accuracy: 0.001)
        XCTAssertEqual(Double(toolManager.spotlightDimOpacity), 0.45, accuracy: 0.001)
    }

    func testImageFormatExtensions() {
        XCTAssertEqual(ImageFormat.png.fileExtension, "png")
        XCTAssertEqual(ImageFormat.jpeg.fileExtension, "jpeg")
        XCTAssertEqual(ImageFormat.tiff.fileExtension, "tiff")
    }

    func testImageImportPreservesTransparentPNGPixels() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CapturesImageImport-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: 20,
            height: 12,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.clear(CGRect(x: 0, y: 0, width: 20, height: 12))
        context.setFillColor(NSColor.systemRed.cgColor)
        context.fill(CGRect(x: 6, y: 2, width: 8, height: 8))
        let source = try XCTUnwrap(context.makeImage())
        let url = directory.appendingPathComponent("transparent.png")
        XCTAssertTrue(ImageUtils.save(source, to: url, format: .png))

        let imported = try ImageImportService.loadImage(at: url)
        XCTAssertEqual(imported.width, 20)
        XCTAssertEqual(imported.height, 12)
        XCTAssertEqual(rgbaPixel(in: imported, x: 0, y: 0).a, 0)
        XCTAssertGreaterThan(rgbaPixel(in: imported, x: 8, y: 6).a, 240)
        let exported = try XCTUnwrap(CanvasState(image: imported).renderFinalImage())
        XCTAssertEqual(rgbaPixel(in: exported, x: 0, y: 0).a, 0)
        let resizedState = CanvasState(image: imported)
        resizedState.setOutputWidth(10)
        let resized = try XCTUnwrap(resizedState.renderFinalImage())
        XCTAssertEqual(rgbaPixel(in: resized, x: 0, y: 0).a, 0)
    }

    func testImageImportAppliesEXIFOrientationToWorkingPixels() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CapturesOrientedImport-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: 20,
            height: 30,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(NSColor.systemRed.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 20, height: 30))
        let source = try XCTUnwrap(context.makeImage())
        let url = directory.appendingPathComponent("portrait.jpg")
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ))
        CGImageDestinationAddImage(
            destination,
            source,
            [
                kCGImagePropertyOrientation: UInt32(6),
                kCGImagePropertyTIFFDictionary: [
                    kCGImagePropertyTIFFOrientation: UInt32(6),
                ],
                kCGImageDestinationLossyCompressionQuality: 1.0,
            ] as CFDictionary
        )
        XCTAssertTrue(CGImageDestinationFinalize(destination))

        let fixtureSource = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let fixtureProperties = try XCTUnwrap(
            CGImageSourceCopyPropertiesAtIndex(fixtureSource, 0, nil) as? [CFString: Any]
        )
        XCTAssertEqual((fixtureProperties[kCGImagePropertyOrientation] as? NSNumber)?.intValue, 6)

        let imported = try ImageImportService.loadImage(at: url)
        XCTAssertEqual(imported.width, 30)
        XCTAssertEqual(imported.height, 20)
        XCTAssertEqual(imported.colorSpace?.model, .rgb)
    }

    func testImageImportNormalizesCMYKForEditorRendering() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CapturesCMYKImport-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let colorSpace = CGColorSpaceCreateDeviceCMYK()
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: 24,
            height: 16,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ))
        context.setFillColor(CGColor(colorSpace: colorSpace, components: [1, 0, 0, 0, 1])!)
        context.fill(CGRect(x: 0, y: 0, width: 24, height: 16))
        let source = try XCTUnwrap(context.makeImage())
        let url = directory.appendingPathComponent("cmyk.jpg")
        XCTAssertTrue(ImageUtils.save(source, to: url, format: .jpeg, jpegQuality: 1))

        let imported = try ImageImportService.loadImage(at: url)
        XCTAssertEqual(imported.colorSpace?.model, .rgb)
        XCTAssertEqual(imported.bitsPerComponent, 8)
        XCTAssertNotNil(CanvasState(image: imported).renderFinalImage())
    }

    func testImageImportRendersSVGForNativeEditor() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CapturesSVGImport-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = directory.appendingPathComponent("logo.svg")
        let svg = """
        <svg xmlns="http://www.w3.org/2000/svg" width="40" height="24">
          <rect width="40" height="24" fill="#ff0000"/>
        </svg>
        """
        try Data(svg.utf8).write(to: url)

        let imported = try ImageImportService.loadImage(at: url)
        XCTAssertEqual(imported.width, 40)
        XCTAssertEqual(imported.height, 24)
        XCTAssertGreaterThan(rgbaPixel(in: imported, x: 20, y: 12).r, 220)
    }

    func testImageImportRejectsOversizedSVGWithoutTrapping() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CapturesOversizedSVG-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("oversized.svg")
        let svg = """
        <svg xmlns="http://www.w3.org/2000/svg" width="100000000000000000000" height="100">
          <rect width="100%" height="100%" fill="red"/>
        </svg>
        """
        try Data(svg.utf8).write(to: url)

        XCTAssertThrowsError(try ImageImportService.loadDocument(at: url))
    }

    func testImageImportPreservesRetinaPointScaleFromFileMetadata() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CapturesRetinaImport-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("retina.png")
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 100,
            pixelsHigh: 80,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        bitmap.size = NSSize(width: 50, height: 40)
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: url)

        let imported = try ImageImportService.loadDocument(at: url)

        XCTAssertEqual(imported.image.width, 100)
        XCTAssertEqual(imported.image.height, 80)
        XCTAssertEqual(imported.sourceScale, 2, accuracy: 0.01)
    }

    func testTransparencyGridUsesTwoNonWhiteSquares() throws {
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: 24,
            height: 12,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        TransparencyGridRenderer.draw(
            in: context,
            rect: CGRect(x: 0, y: 0, width: 24, height: 12),
            tileSize: 12
        )
        let grid = try XCTUnwrap(context.makeImage())
        let left = rgbaPixel(in: grid, x: 4, y: 4)
        let right = rgbaPixel(in: grid, x: 16, y: 4)
        XCTAssertEqual(left.a, 255)
        XCTAssertEqual(right.a, 255)
        XCTAssertNotEqual(left.r, right.r)
        XCTAssertLessThan(left.r, 255)
        XCTAssertLessThan(right.r, 255)
    }

    func testNativeFilterLibraryRendersWideRealPreviews() throws {
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: 120,
            height: 80,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(NSColor.systemBlue.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 120, height: 80))
        context.setFillColor(NSColor.systemOrange.cgColor)
        context.fill(CGRect(x: 12, y: 12, width: 48, height: 56))
        context.setFillColor(NSColor.systemGreen.cgColor)
        context.fillEllipse(in: CGRect(x: 66, y: 18, width: 42, height: 42))

        let source = try XCTUnwrap(context.makeImage())
        let state = CanvasState(image: source)
        XCTAssertEqual(ImageFilterPreset.allCases.count, 10)

        for preset in ImageFilterPreset.allCases {
            let preview = state.filterPreviewImage(
                for: preset,
                pixelSize: CGSize(width: 200, height: 72)
            )
            XCTAssertEqual(preview.width, 200, "\(preset) preview width")
            XCTAssertEqual(preview.height, 72, "\(preset) preview height")

            state.updateRasterAdjustment { $0.filter = preset }
            let rendered = state.renderedBaseImage()
            XCTAssertEqual(rendered.width, 120, "\(preset) render width")
            XCTAssertEqual(rendered.height, 80, "\(preset) render height")
        }
    }

    func testEditorWindowStartsAtActualSizeUntilTheScreenCannotFitIt() {
        XCTAssertEqual(AnnotationEditorLayout.commandBarHeight, 40)
        XCTAssertEqual(AnnotationEditorLayout.compactToolBarHeight, 32)
        XCTAssertEqual(AnnotationEditorLayout.standardToolBarHeight, 64)
        XCTAssertEqual(AnnotationEditorLayout.filterToolBarHeight, 64)

        let imageSize = CGSize(width: 1_517, height: 595)
        let contentSize = AnnotationEditorLayout.contentSize(
            for: imageSize,
            mode: .annotation,
            visibleFrame: CGRect(x: 0, y: 0, width: 1_512, height: 982)
        )
        let fittedImageSize = CGSize(
            width: contentSize.width - AnnotationEditorLayout.canvasPadding,
            height: contentSize.height
                - AnnotationEditorLayout.commandBarHeight
                - AnnotationEditorLayout.standardToolBarHeight
                - AnnotationEditorLayout.canvasPadding
        )

        // The 1,517 px image is just wider than the safe 1,488 px content
        // area, so it only receives the small reduction that is unavoidable.
        XCTAssertEqual(contentSize.width, 1_488, accuracy: 0.001)
        XCTAssertGreaterThan(contentSize.height, 701)
        XCTAssertLessThan(contentSize.height, 703)
        XCTAssertEqual(
            fittedImageSize.width / fittedImageSize.height,
            imageSize.width / imageSize.height,
            accuracy: 0.001
        )
    }

    func testEditorWindowSizeTracksUltraWideImageAspectRatio() {
        let imageSize = CGSize(width: 1_517, height: 200)
        let contentSize = AnnotationEditorLayout.contentSize(
            for: imageSize,
            mode: .annotation,
            visibleFrame: CGRect(x: 0, y: 0, width: 1_512, height: 982)
        )
        let canvasSize = CGSize(
            width: contentSize.width - AnnotationEditorLayout.canvasPadding,
            height: contentSize.height
                - AnnotationEditorLayout.commandBarHeight
                - AnnotationEditorLayout.standardToolBarHeight
                - AnnotationEditorLayout.canvasPadding
        )

        XCTAssertEqual(contentSize.width, 1_488, accuracy: 0.001)
        XCTAssertGreaterThan(contentSize.height, 320)
        XCTAssertLessThan(contentSize.height, 322)
        XCTAssertEqual(
            canvasSize.width / canvasSize.height,
            imageSize.width / imageSize.height,
            accuracy: 0.001
        )
    }

    func testCanvasZoomToActualSizeRestoresOneHundredPercent() {
        let state = CanvasState(
            image: makeSolidRGBAImage(
                width: 120,
                height: 80,
                red: 255,
                green: 255,
                blue: 255
            )
        )
        let canvas = CanvasNSView(canvasState: state, toolManager: ToolManager())
        canvas.frame = CGRect(x: 0, y: 0, width: 600, height: 400)

        canvas.fitToCanvas()
        XCTAssertNotEqual(canvas.zoomPercentage, 100)

        canvas.zoomToActualSize()
        XCTAssertEqual(canvas.zoomPercentage, 100)
    }

    func testCanvasInitialViewportPrefersActualSizeOverFillingWhitespace() {
        let state = CanvasState(
            image: makeSolidRGBAImage(
                width: 120,
                height: 80,
                red: 255,
                green: 255,
                blue: 255
            )
        )
        let canvas = CanvasNSView(canvasState: state, toolManager: ToolManager())
        canvas.frame = CGRect(x: 0, y: 0, width: 600, height: 400)

        canvas.showAtActualSizeOrFit()

        XCTAssertEqual(canvas.zoomPercentage, 100)
    }

    func testNativeEditorWindowResizeScalesImageAndUpdatesPercentage() throws {
        let image = makeSolidRGBAImage(width: 1200, height: 600, red: 244, green: 245, blue: 247)
        let controller = NativeImageEditorViewController(image: image)
        let window = NSWindow(contentViewController: controller)
        window.isReleasedWhenClosed = false
        window.styleMask.insert(.fullSizeContentView)
        defer { window.close() }
        window.setContentSize(NSSize(width: 1224, height: 728))
        controller.configureInitialCanvasViewport()
        let canvas = try XCTUnwrap(controller.view.subviews.compactMap { $0 as? CanvasNSView }.first)
        let initialCanvasSize = canvas.bounds.size
        XCTAssertEqual(canvas.zoomPercentage, 100)
        let marker = RectangleAnnotation(rect: CGRect(x: 60, y: 40, width: 240, height: 100), strokeColor: .systemRed, fillColor: nil, strokeWidth: 6)
        canvas.canvasState.addAnnotation(marker)
        canvas.canvasState.addAnnotation(TextAnnotation(position: CGPoint(x: 60, y: 300), text: "Resize with window", fontName: "Helvetica", fontSize: 40, color: .black))

        for (size, expectedPercentage) in [
            (NSSize(width: 1524, height: 878), 125),
            (NSSize(width: 924, height: 578), 75),
            (NSSize(width: 1224, height: 728), 100),
        ] {
            window.setContentSize(size)
            controller.view.layoutSubtreeIfNeeded()
            XCTAssertEqual(canvas.zoomPercentage, expectedPercentage, "Initial canvas \(initialCanvasSize); root \(controller.view.bounds.size); resized canvas \(canvas.bounds.size)")
            XCTAssertEqual(
                canvas.canvasState.panOffset.x,
                (canvas.bounds.width - 1200 * canvas.canvasState.zoomLevel) / 2,
                accuracy: 0.01
            )
            XCTAssertTrue(editorButtons(in: controller.view).contains { $0.title == "\(expectedPercentage)%" })
            let bitmap = try XCTUnwrap(controller.view.bitmapImageRepForCachingDisplay(in: controller.view.bounds))
            controller.view.cacheDisplay(in: controller.view.bounds, to: bitmap)
            let snapshot = NSImage(size: controller.view.bounds.size)
            snapshot.addRepresentation(bitmap)
            let attachment = XCTAttachment(image: snapshot)
            attachment.name = "editor-resize-\(expectedPercentage)-percent"
            attachment.lifetime = .keepAlways
            add(attachment)
        }

        canvas.zoomIn()
        controller.configureInitialCanvasViewport()
        XCTAssertEqual(canvas.zoomPercentage, 112, "A later appearance/layout callback must not reset the user's zoom")
        let filterButton = try XCTUnwrap(editorButtons(in: controller.view).first { $0.title == NativeEditorSection.filters.title })
        filterButton.performClick(nil)
        controller.view.layoutSubtreeIfNeeded()
        XCTAssertEqual(canvas.zoomPercentage, 112, "Changing the parameter strip must preserve zoom")
        window.setContentSize(NSSize(width: 1524, height: 878))
        controller.view.layoutSubtreeIfNeeded()
        XCTAssertEqual(canvas.zoomPercentage, 140)
        XCTAssertEqual(canvas.canvasState.imageWidth, 1200)
        XCTAssertEqual(canvas.canvasState.imageHeight, 600)
        XCTAssertEqual(marker.rect, CGRect(x: 60, y: 40, width: 240, height: 100))
    }

    func testLongCaptureWindowResizePreservesReadingPosition() throws {
        let controller = NativeImageEditorViewController(image: makeSolidRGBAImage(width: 800, height: 3000, red: 255, green: 255, blue: 255))
        let window = NSWindow(contentViewController: controller)
        window.isReleasedWhenClosed = false
        window.styleMask.insert(.fullSizeContentView)
        defer { window.close() }
        window.setContentSize(NSSize(width: 1024, height: 700))
        controller.configureInitialCanvasViewport()
        let canvas = try XCTUnwrap(controller.view.subviews.compactMap { $0 as? CanvasNSView }.first)
        let readingLine: CGFloat = 2300
        canvas.canvasState.panOffset.y = canvas.bounds.height - AnnotationEditorLayout.canvasPadding - readingLine
        for size in [NSSize(width: 1274, height: 800), NSSize(width: 1274, height: 1000)] {
            window.setContentSize(size)
            controller.view.layoutSubtreeIfNeeded()
            XCTAssertEqual(canvas.zoomPercentage, 125)
            let visibleTop = (canvas.bounds.height - AnnotationEditorLayout.canvasPadding - canvas.canvasState.panOffset.y) / canvas.canvasState.zoomLevel
            XCTAssertEqual(visibleTop, readingLine, accuracy: 0.01)
        }
    }

    func testExplicitMouseToolStillMovesExistingAnnotation() throws {
        let state = CanvasState(image: makeSolidRGBAImage(width: 400, height: 300, red: 255, green: 255, blue: 255))
        state.addAnnotation(RectangleAnnotation(rect: CGRect(x: 50, y: 50, width: 80, height: 60), strokeColor: .red, fillColor: .red, strokeWidth: 2))
        let manager = ToolManager()
        manager.currentTool = .textSelect
        let canvas = CanvasNSView(canvasState: state, toolManager: manager)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 424, height: 324), styleMask: .borderless, backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = canvas
        canvas.showAtActualSizeOrFit()
        canvas.mouseDown(with: try canvasMouseEvent(.leftMouseDown, at: CGPoint(x: 80, y: 80), canvas: canvas))
        canvas.mouseDragged(with: try canvasMouseEvent(.leftMouseDragged, at: CGPoint(x: 120, y: 110), canvas: canvas))
        canvas.mouseUp(with: try canvasMouseEvent(.leftMouseUp, at: CGPoint(x: 120, y: 110), canvas: canvas))
        XCTAssertEqual(manager.currentTool, .textSelect)
        XCTAssertEqual(state.annotations.count, 1)
        XCTAssertEqual(try XCTUnwrap(state.annotations.first as? RectangleAnnotation).rect, CGRect(x: 90, y: 80, width: 80, height: 60))
    }

    func testDrawingToolStaysActiveAcrossOverlappingStrokes() throws {
        for tool in [ToolType.arrow, .rectangle, .ellipse, .pencil, .highlighter, .blur, .pixelate, .counter] {
            let state = CanvasState(image: makeSolidRGBAImage(width: 400, height: 300, red: 255, green: 255, blue: 255))
            let manager = ToolManager()
            manager.currentTool = tool
            let canvas = CanvasNSView(canvasState: state, toolManager: manager)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 424, height: 324), styleMask: .borderless, backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false
            defer { window.close() }
            window.contentView = canvas
            canvas.showAtActualSizeOrFit()

            for count in 1...3 {
                canvas.mouseDown(with: try canvasMouseEvent(.leftMouseDown, at: CGPoint(x: 60, y: 60), canvas: canvas))
                canvas.mouseDragged(with: try canvasMouseEvent(.leftMouseDragged, at: CGPoint(x: 180, y: 140), canvas: canvas))
                canvas.mouseUp(with: try canvasMouseEvent(.leftMouseUp, at: CGPoint(x: 180, y: 140), canvas: canvas))
                XCTAssertEqual(manager.currentTool, tool, "\(tool) changed after stroke \(count)")
                XCTAssertEqual(state.annotations.count, count, "Overlapping strokes should create a new \(tool) annotation")
            }
        }
    }

    private func editorButtons(in view: NSView) -> [NSButton] {
        view.subviews.flatMap { ($0 as? NSButton).map { [$0] } ?? editorButtons(in: $0) }
    }

    private func canvasMouseEvent(_ type: NSEvent.EventType, at point: CGPoint, canvas: CanvasNSView) throws -> NSEvent {
        let state = canvas.canvasState
        let viewPoint = CGPoint(
            x: point.x * state.zoomLevel + state.panOffset.x,
            y: point.y * state.zoomLevel + state.panOffset.y
        )
        return try XCTUnwrap(NSEvent.mouseEvent(
            with: type, location: canvas.convert(viewPoint, to: nil), modifierFlags: [],
            timestamp: 0, windowNumber: canvas.window?.windowNumber ?? 0, context: nil,
            eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1
        ))
    }

    func testCaptureSoundIncludesCameraShot() {
        XCTAssertTrue(CaptureSound.allCases.contains(.cameraShot))
        XCTAssertEqual(CaptureSound.cameraShot.displayName, "Camera Shot")
        XCTAssertEqual(CaptureSound.cameraShot.nsSoundName, NSSound.Name("PhotoShutter"))
    }

    func testToolTypeShortcuts() {
        XCTAssertEqual(ToolType.arrow.shortcutKey, "A")
        XCTAssertEqual(ToolType.ocr.shortcutKey, "O")
        XCTAssertEqual(ToolType.rectangle.shortcutKey, "R")
        XCTAssertEqual(ToolType.crop.shortcutKey, "C")
        XCTAssertEqual(ToolType.allCases.count, 15)
    }

    func testOCRTextCompositionMakesReadableLinesForTheVisibleResult() {
        let blocks = [
            OCRTextBlock(text: "second", imageRect: CGRect(x: 10, y: 12, width: 35, height: 10)),
            OCRTextBlock(text: "world", imageRect: CGRect(x: 60, y: 56, width: 35, height: 10)),
            OCRTextBlock(text: "Hello", imageRect: CGRect(x: 10, y: 56, width: 40, height: 10)),
        ]

        XCTAssertEqual(TextRecognitionService.composeText(from: blocks), "Hello world\nsecond")
    }

    func testCounterStyleDisplay() {
        XCTAssertEqual(CounterStyle.numbers.display(for: 1), "1")
        XCTAssertEqual(CounterStyle.letters.display(for: 1), "A")
        XCTAssertEqual(CounterStyle.roman.display(for: 4), "IV")
    }

    func testFileNameGenerator() {
        let name = FileNameGenerator.generate(pattern: "test-{type}", mode: .fullscreen, appName: "Safari")
        XCTAssertTrue(name.contains("fullscreen"))
    }

    func testFileNameGeneratorUsesStableTypeAndTimeTokens() {
        let name = FileNameGenerator.generate(pattern: "{date}_{type}_{time}", mode: .scroll)
        let components = name.split(separator: "_", omittingEmptySubsequences: false)

        XCTAssertEqual(components.count, 3)
        guard components.count == 3 else { return }
        XCTAssertEqual(String(components[1]), "scroll")
        XCTAssertEqual(components[0].count, 10)
        XCTAssertEqual(components[2].count, 8)
        XCTAssertTrue(components[2].contains("-"))
    }

    func testEmptyOrDotOnlyFilenamePatternCannotEscapeTheSaveDirectory() {
        let directory = URL(fileURLWithPath: "/tmp/Captures Filename Test", isDirectory: true)

        for pattern in ["", "   ", ".", ".."] {
            let filename = FileNameGenerator.generate(pattern: pattern, mode: .area)
            let outputURL = directory
                .appendingPathComponent(filename)
                .appendingPathExtension("png")

            XCTAssertFalse(filename.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            XCTAssertEqual(outputURL.deletingLastPathComponent(), directory)
        }
    }

    func testFilenamePatternMigratesLegacyDefaultButPreservesCustomPattern() {
        let suiteName = "CapturesTests.filenamePatternMigration.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Expected isolated UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(Constants.Defaults.legacyFilenamePattern, forKey: Constants.Keys.filenamePattern)
        let migratedState = AppState(defaults: defaults)
        XCTAssertEqual(migratedState.filenamePattern, Constants.Defaults.filenamePattern)
        XCTAssertEqual(
            defaults.string(forKey: Constants.Keys.filenamePattern),
            Constants.Defaults.filenamePattern
        )

        let customPattern = "meeting-{date}"
        defaults.set(customPattern, forKey: Constants.Keys.filenamePattern)
        let customState = AppState(defaults: defaults)
        XCTAssertEqual(customState.filenamePattern, customPattern)
    }

    func testBackgroundTemplateBuiltIn() {
        XCTAssertFalse(BackgroundTemplate.builtIn.isEmpty)
        XCTAssertEqual(BackgroundTemplate.builtIn.count, 6)
    }

    func testOverlayCornerCases() {
        XCTAssertEqual(OverlayCorner.allCases.count, 4)
        XCTAssertEqual(OverlayCorner.bottomRight.displayName, "Bottom Right")
    }

    func testRenderFinalImageCropUsesAnnotationCoordinateSpace() {
        let baseImage = makeSolidRGBAImage(width: 100, height: 100, red: 255, green: 255, blue: 255)
        let state = CanvasState(image: baseImage)
        let targetRect = CGRect(x: 10, y: 70, width: 20, height: 20)

        let marker = RectangleAnnotation(
            rect: targetRect,
            strokeColor: .red,
            fillColor: .red,
            strokeWidth: 1
        )
        state.annotations.append(marker)
        state.annotations.append(CropAnnotation(rect: targetRect))

        guard let output = state.renderFinalImage() else {
            XCTFail("Expected rendered image")
            return
        }

        XCTAssertEqual(output.width, 20)
        XCTAssertEqual(output.height, 20)

        let center = rgbaPixel(in: output, x: output.width / 2, y: output.height / 2)
        XCTAssertGreaterThan(center.r, 200)
        XCTAssertLessThan(center.g, 80)
        XCTAssertLessThan(center.b, 80)
    }

    func testApplyActiveCropTransformsCanvasAndAnnotations() {
        let baseImage = makeSolidRGBAImage(width: 100, height: 80, red: 255, green: 255, blue: 255)
        let state = CanvasState(image: baseImage)

        let text = TextAnnotation(
            position: CGPoint(x: 20, y: 18),
            text: "A",
            fontName: "Helvetica",
            fontSize: 12,
            color: .red
        )
        state.annotations.append(text)
        state.annotations.append(CropAnnotation(rect: CGRect(x: 10, y: 8, width: 30, height: 20)))

        XCTAssertTrue(state.applyActiveCrop())
        XCTAssertEqual(state.imageWidth, 30)
        XCTAssertEqual(state.imageHeight, 20)
        XCTAssertFalse(state.annotations.contains { $0 is CropAnnotation })

        guard let movedText = state.annotations.first(where: { $0.id == text.id }) as? TextAnnotation else {
            XCTFail("Expected text annotation to remain after crop")
            return
        }

        XCTAssertEqual(Double(movedText.position.x), 10, accuracy: 0.01)
        XCTAssertEqual(Double(movedText.position.y), 10, accuracy: 0.01)
    }

    func testApplyActiveCropSupportsUndoRedo() {
        let baseImage = makeSolidRGBAImage(width: 120, height: 90, red: 255, green: 255, blue: 255)
        let state = CanvasState(image: baseImage)

        let rectangle = RectangleAnnotation(
            rect: CGRect(x: 40, y: 30, width: 20, height: 10),
            strokeColor: .red,
            fillColor: nil,
            strokeWidth: 2
        )
        let crop = CropAnnotation(rect: CGRect(x: 20, y: 10, width: 50, height: 40))
        state.annotations = [rectangle, crop]

        XCTAssertTrue(state.applyActiveCrop())
        XCTAssertEqual(state.imageWidth, 50)
        XCTAssertEqual(state.imageHeight, 40)
        XCTAssertFalse(state.annotations.contains { $0 is CropAnnotation })

        state.undoManager.undo(state: state)
        XCTAssertEqual(state.imageWidth, 120)
        XCTAssertEqual(state.imageHeight, 90)
        XCTAssertTrue(state.annotations.contains { $0.id == rectangle.id })
        XCTAssertFalse(state.annotations.contains { $0 is CropAnnotation })
        XCTAssertEqual(state.renderFinalImage()?.width, 120)
        XCTAssertEqual(state.renderFinalImage()?.height, 90)

        state.undoManager.redo(state: state)
        XCTAssertEqual(state.imageWidth, 50)
        XCTAssertEqual(state.imageHeight, 40)
        XCTAssertFalse(state.annotations.contains { $0 is CropAnnotation })
    }

    func testTextAnnotationSupportsRotationAndPreservesProperties() {
        let text = TextAnnotation(
            position: CGPoint(x: 24, y: 12),
            text: "Rotate Me",
            fontName: "Helvetica",
            fontSize: 14,
            color: .red
        )
        text.isBold = true
        text.hasBackground = true

        XCTAssertTrue(AnnotationGeometry.supportsRotation(text))

        guard let rotated = AnnotationGeometry.rotated(text, to: 37) as? TextAnnotation else {
            XCTFail("Expected rotated text annotation")
            return
        }

        XCTAssertEqual(Double(rotated.rotationDegrees), 37, accuracy: 0.001)
        XCTAssertEqual(rotated.text, text.text)
        XCTAssertEqual(rotated.fontName, text.fontName)
        XCTAssertEqual(Double(rotated.fontSize), Double(text.fontSize), accuracy: 0.001)
        XCTAssertEqual(rotated.hasBackground, text.hasBackground)
        XCTAssertEqual(rotated.isBold, text.isBold)

        guard let moved = AnnotationGeometry.translated(rotated, by: CGPoint(x: 11, y: -3)) as? TextAnnotation else {
            XCTFail("Expected translated text annotation")
            return
        }

        XCTAssertEqual(Double(moved.position.x), Double(rotated.position.x + 11), accuracy: 0.001)
        XCTAssertEqual(Double(moved.position.y), Double(rotated.position.y - 3), accuracy: 0.001)
        XCTAssertEqual(Double(moved.rotationDegrees), Double(rotated.rotationDegrees), accuracy: 0.001)
    }

    func testPencilAnnotationSupportsRotation() {
        let pencil = PencilAnnotation(
            points: [
                CGPoint(x: 10, y: 10),
                CGPoint(x: 30, y: 22),
                CGPoint(x: 44, y: 36),
            ],
            color: .red,
            strokeWidth: 2
        )

        XCTAssertTrue(AnnotationGeometry.supportsRotation(pencil))

        guard let rotated = AnnotationGeometry.rotated(pencil, to: 90) as? PencilAnnotation else {
            XCTFail("Expected rotated pencil annotation")
            return
        }

        XCTAssertEqual(rotated.points.count, pencil.points.count)
        XCTAssertEqual(rotated.color, pencil.color)
        XCTAssertEqual(Double(rotated.strokeWidth), Double(pencil.strokeWidth), accuracy: 0.001)
        XCTAssertGreaterThan(abs(rotated.points[0].x - pencil.points[0].x), 0.001)
        XCTAssertGreaterThan(abs(rotated.points[0].y - pencil.points[0].y), 0.001)
    }

    func testBringAnnotationToFrontSupportsUndoRedo() {
        let baseImage = makeSolidRGBAImage(width: 120, height: 90, red: 255, green: 255, blue: 255)
        let state = CanvasState(image: baseImage)

        let first = RectangleAnnotation(
            rect: CGRect(x: 10, y: 10, width: 10, height: 10),
            strokeColor: .red,
            fillColor: nil,
            strokeWidth: 1
        )
        first.zOrder = 1
        let second = RectangleAnnotation(
            rect: CGRect(x: 30, y: 10, width: 10, height: 10),
            strokeColor: .green,
            fillColor: nil,
            strokeWidth: 1
        )
        second.zOrder = 2
        let third = RectangleAnnotation(
            rect: CGRect(x: 50, y: 10, width: 10, height: 10),
            strokeColor: .blue,
            fillColor: nil,
            strokeWidth: 1
        )
        third.zOrder = 3

        state.annotations = [first, second, third]
        let initialOrder = state.annotations.map { $0.id }

        XCTAssertTrue(state.bringAnnotationToFront(id: second.id))
        XCTAssertEqual(state.selectedAnnotationID, second.id)
        XCTAssertEqual(state.annotations.last?.id, second.id)
        XCTAssertEqual(state.annotations.map { $0.id }, [first.id, third.id, second.id])
        XCTAssertGreaterThan(second.zOrder, third.zOrder)

        state.undoManager.undo(state: state)
        XCTAssertEqual(state.annotations.map { $0.id }, initialOrder)

        state.undoManager.redo(state: state)
        XCTAssertEqual(state.annotations.map { $0.id }, [first.id, third.id, second.id])
    }

    func testToolManagerMouseUpReturnsCommittedAnnotationID() {
        let image = makeSolidRGBAImage(width: 80, height: 60, red: 255, green: 255, blue: 255)
        let canvasState = CanvasState(image: image)
        let toolManager = ToolManager()
        toolManager.currentTool = .rectangle

        toolManager.mouseDown(at: CGPoint(x: 10, y: 10), canvasState: canvasState)
        toolManager.mouseDragged(to: CGPoint(x: 30, y: 30), canvasState: canvasState)
        let committedID = toolManager.mouseUp(at: CGPoint(x: 30, y: 30), canvasState: canvasState)

        XCTAssertNotNil(committedID)
        XCTAssertEqual(canvasState.selectedAnnotationID, committedID)
        XCTAssertTrue(canvasState.annotations.contains { $0.id == committedID })
    }

    func testHighlighterCapturesAContinuousPointerPathAtTheSelectedWidth() {
        let image = makeSolidRGBAImage(width: 120, height: 90, red: 255, green: 255, blue: 255)
        let canvasState = CanvasState(image: image)
        let toolManager = ToolManager()
        toolManager.currentTool = .highlighter
        toolManager.strokeWidth = 12

        toolManager.mouseDown(at: CGPoint(x: 10, y: 10), canvasState: canvasState)
        toolManager.mouseDragged(to: CGPoint(x: 24, y: 28), canvasState: canvasState)
        toolManager.mouseDragged(to: CGPoint(x: 42, y: 16), canvasState: canvasState)
        _ = toolManager.mouseUp(at: CGPoint(x: 42, y: 16), canvasState: canvasState)

        guard let highlighter = canvasState.annotations.first as? HighlighterAnnotation else {
            XCTFail("Expected a highlighter annotation")
            return
        }

        XCTAssertEqual(highlighter.points.count, 3)
        XCTAssertEqual(Double(highlighter.strokeWidth), 12, accuracy: 0.001)
        XCTAssertEqual(highlighter.points.last, CGPoint(x: 42, y: 16))
    }

    func testBlurNeverReusesProcessedPixelsFromAnotherDocument() throws {
        let rect = CGRect(x: 0, y: 0, width: 64, height: 64)
        let redSource = makeSolidRGBAImage(width: 64, height: 64, red: 255, green: 0, blue: 0)
        let blueSource = makeSolidRGBAImage(width: 64, height: 64, red: 0, green: 0, blue: 255)

        _ = try renderAnnotation(
            BlurAnnotation(rect: rect, intensity: 8, sourceImage: redSource),
            size: rect.size
        )
        let blueOutput = try renderAnnotation(
            BlurAnnotation(rect: rect, intensity: 8, sourceImage: blueSource),
            size: rect.size
        )
        let pixel = rgbaPixel(in: blueOutput, x: 32, y: 32)
        XCTAssertGreaterThan(pixel.b, 220)
        XCTAssertLessThan(pixel.r, 20)
    }

    func testPixelateNeverReusesProcessedPixelsFromAnotherDocument() throws {
        let rect = CGRect(x: 0, y: 0, width: 64, height: 64)
        let redSource = makeSolidRGBAImage(width: 64, height: 64, red: 255, green: 0, blue: 0)
        let blueSource = makeSolidRGBAImage(width: 64, height: 64, red: 0, green: 0, blue: 255)

        _ = try renderAnnotation(
            PixelateAnnotation(rect: rect, blockSize: 10, sourceImage: redSource),
            size: rect.size
        )
        let blueOutput = try renderAnnotation(
            PixelateAnnotation(rect: rect, blockSize: 10, sourceImage: blueSource),
            size: rect.size
        )
        let pixel = rgbaPixel(in: blueOutput, x: 32, y: 32)
        XCTAssertGreaterThan(pixel.b, 220)
        XCTAssertLessThan(pixel.r, 20)
    }

    func testBlurKeepsEveryRedactionEdgeOpaque() throws {
        let rect = CGRect(x: 0, y: 0, width: 64, height: 64)
        let source = makeSolidRGBAImage(width: 64, height: 64, red: 255, green: 0, blue: 0)
        let output = try renderAnnotation(
            BlurAnnotation(rect: rect, intensity: 16, sourceImage: source),
            size: rect.size
        )

        for point in [CGPoint(x: 0, y: 0), CGPoint(x: 63, y: 0), CGPoint(x: 0, y: 63), CGPoint(x: 63, y: 63)] {
            XCTAssertGreaterThan(rgbaPixel(in: output, x: Int(point.x), y: Int(point.y)).a, 250)
        }
    }

    func testHighlighterUsesItsDedicatedColorInsteadOfTheShapeStrokeColor() {
        let image = makeSolidRGBAImage(width: 120, height: 90, red: 255, green: 255, blue: 255)
        let canvasState = CanvasState(image: image)
        let toolManager = ToolManager()
        toolManager.currentTool = .highlighter
        toolManager.strokeColor = .systemRed
        toolManager.highlighterColor = .systemYellow

        toolManager.mouseDown(at: CGPoint(x: 10, y: 10), canvasState: canvasState)
        toolManager.mouseDragged(to: CGPoint(x: 42, y: 16), canvasState: canvasState)
        _ = toolManager.mouseUp(at: CGPoint(x: 42, y: 16), canvasState: canvasState)

        guard let highlighter = canvasState.annotations.first as? HighlighterAnnotation else {
            XCTFail("Expected a highlighter annotation")
            return
        }

        XCTAssertEqual(highlighter.color, .systemYellow)
    }

    func testToolManagerCropDragDoesNotCreateCropAnnotation() {
        let image = makeSolidRGBAImage(width: 120, height: 90, red: 255, green: 255, blue: 255)
        let canvasState = CanvasState(image: image)
        let toolManager = ToolManager()
        toolManager.currentTool = .crop

        toolManager.mouseDown(at: CGPoint(x: 10, y: 10), canvasState: canvasState)
        toolManager.mouseDragged(to: CGPoint(x: 60, y: 40), canvasState: canvasState)
        let committedID = toolManager.mouseUp(at: CGPoint(x: 60, y: 40), canvasState: canvasState)

        XCTAssertNil(committedID)
        XCTAssertFalse(canvasState.annotations.contains { $0 is CropAnnotation })
    }

    func testToolManagerMouseDraggedSelectsActiveAnnotation() {
        let image = makeSolidRGBAImage(width: 120, height: 90, red: 255, green: 255, blue: 255)
        let canvasState = CanvasState(image: image)
        let toolManager = ToolManager()
        toolManager.currentTool = .rectangle

        toolManager.mouseDown(at: CGPoint(x: 10, y: 10), canvasState: canvasState)
        toolManager.mouseDragged(to: CGPoint(x: 60, y: 40), canvasState: canvasState)

        guard let selectedID = canvasState.selectedAnnotationID else {
            XCTFail("Expected active dragged annotation to be selected")
            return
        }

        XCTAssertTrue(canvasState.annotations.contains { $0.id == selectedID })
    }

    private func makePatternImage(width: Int, height: Int) -> CGImage {
        var data = [UInt8](repeating: 0, count: width * height)
        var seed: UInt32 = 0x1234ABCD
        for y in 0..<height {
            seed = seed &* 1664525 &+ 1013904223
            let value = UInt8((seed >> 24) & 0xFF)
            let rowStart = y * width
            for x in 0..<width {
                data[rowStart + x] = value
            }
        }

        let colorSpace = CGColorSpaceCreateDeviceGray()
        let context = CGContext(
            data: &data,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        )!
        return context.makeImage()!
    }

    private func makeVerticalGradientImage(width: Int, height: Int) -> CGImage {
        var data = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            let value = UInt8((Double(y) / Double(max(1, height - 1)) * 255.0).rounded())
            let rowStart = y * width
            for x in 0..<width {
                data[rowStart + x] = value
            }
        }

        let colorSpace = CGColorSpaceCreateDeviceGray()
        let context = CGContext(
            data: &data,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        )!
        return context.makeImage()!
    }

    private func makeSolidRGBAImage(
        width: Int,
        height: Int,
        red: UInt8,
        green: UInt8,
        blue: UInt8
    ) -> CGImage {
        var data = [UInt8](repeating: 0, count: width * height * 4)
        for i in stride(from: 0, to: data.count, by: 4) {
            data[i] = red
            data[i + 1] = green
            data[i + 2] = blue
            data[i + 3] = 255
        }

        let context = CGContext(
            data: &data,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        return context.makeImage()!
    }

    private func extractFrame(from source: CGImage, originY: Int, height: Int) -> CGImage {
        let targetHeight = max(1, min(height, source.height))
        let clampedOrigin = max(0, min(originY, source.height - targetHeight))
        let context = CGContext(
            data: nil,
            width: source.width,
            height: targetHeight,
            bitsPerComponent: source.bitsPerComponent,
            bytesPerRow: 0,
            space: source.colorSpace ?? CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        )!
        context.translateBy(x: 0, y: -CGFloat(clampedOrigin))
        context.draw(source, in: CGRect(x: 0, y: 0, width: source.width, height: source.height))
        return context.makeImage()!
    }

    private func rgbaPixel(in image: CGImage, x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
        let width = image.width
        let height = image.height
        var data = [UInt8](repeating: 0, count: width * height * 4)
        let context = CGContext(
            data: &data,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        let clampedX = max(0, min(x, width - 1))
        let clampedY = max(0, min(y, height - 1))
        let idx = (clampedY * width + clampedX) * 4
        return (data[idx], data[idx + 1], data[idx + 2], data[idx + 3])
    }

    private func renderAnnotation(_ annotation: any Annotation, size: CGSize) throws -> CGImage {
        let width = Int(size.width)
        let height = Int(size.height)
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.clear(CGRect(origin: .zero, size: size))
        annotation.render(in: context)
        return try XCTUnwrap(context.makeImage())
    }
}
