import AppKit
import Carbon.HIToolbox
import CoreGraphics
import XCTest
@testable import Captures

final class BugFixTests: XCTestCase {
    // MARK: - Scroll capture session controls

    func testScrollCaptureActionsStayAboveSelectionChrome() {
        XCTAssertGreaterThan(
            PostCaptureChooserManager.windowLevel.rawValue,
            ScrollCaptureSelectionOverlay.windowLevel.rawValue
        )
        XCTAssertNotEqual(
            ScrollCaptureSelectionOverlay.windowLevel.rawValue,
            Int(CGWindowLevelForKey(.maximumWindow))
        )
    }

    func testLiveScrollPreviewGrowsWithTheStitchedResultAndThenCaps() {
        let initialHeight = ScrollCaptureProgressPreviewLayout.panelHeight(
            for: CGSize(width: 1_250, height: 800)
        )
        let growingHeight = ScrollCaptureProgressPreviewLayout.panelHeight(
            for: CGSize(width: 1_250, height: 3_200)
        )
        let extremeHeight = ScrollCaptureProgressPreviewLayout.panelHeight(
            for: CGSize(width: 1_250, height: 20_000)
        )

        XCTAssertGreaterThan(growingHeight, initialHeight)
        XCTAssertEqual(
            extremeHeight,
            ScrollCaptureProgressPreviewLayout.maximumHeight
        )
    }

    func testLongCapturePreviewAlignsWithTheSelectedFrameAtTheScreenEdge() {
        let screen = CGRect(x: 0, y: 0, width: 1_200, height: 800)
        let selection = CGRect(x: 240, y: 690, width: 640, height: 80)
        let frames = ScrollCaptureSessionChromeLayout.frames(
            for: CGSize(width: 1_250, height: 6_000),
            anchoredTo: selection,
            chooserSize: PostCaptureChooserLayout.panelSize(
                for: PostCaptureChooserConfiguration.longCaptureActive.controlCount
            ),
            within: screen
        )

        XCTAssertEqual(frames.preview.maxY, selection.maxY)
        XCTAssertTrue(screen.insetBy(dx: 8, dy: 8).contains(frames.chooser))
        XCTAssertTrue(screen.insetBy(dx: 8, dy: 8).contains(frames.preview))
        XCTAssertFalse(frames.preview.intersects(frames.chooser))
    }

    func testLongCaptureResultActionEndsCaptureWithoutSeparateStop() async {
        let state = LockedScrollCaptureSessionState()
        state.resolve(.clipboard)
        await state.waitForResolution()
        XCTAssertEqual(state.state, .selected(.clipboard))
        XCTAssertFalse(state.isCapturing)
    }

    func testLongCaptureKeepsResultActionsAvailableAtSafetyLimit() async {
        let state = LockedScrollCaptureSessionState()
        XCTAssertTrue(state.reachSafetyLimit())
        XCTAssertEqual(state.state, .awaitingAction)
        XCTAssertFalse(state.reachSafetyLimit())

        state.resolve(.ocr)
        await state.waitForResolution()
        XCTAssertEqual(state.state, .selected(.ocr))
    }

    func testLongCaptureCanCancelWhileCapturingManualScrolling() async {
        let state = LockedScrollCaptureSessionState()
        state.cancel()
        await state.waitForResolution()
        XCTAssertEqual(state.state, .cancelled)
        XCTAssertFalse(state.isCapturing)
    }

    func testLongCaptureOnlyAcceptsTheFirstDirectAction() async {
        let state = LockedScrollCaptureSessionState()
        state.resolve(.clipboard)
        state.resolve(.editor)
        state.cancel()
        await state.waitForResolution()

        XCTAssertEqual(state.state, .selected(.clipboard))
    }

    func testLongCaptureCancelCannotBeReplacedByALateAction() async {
        let state = LockedScrollCaptureSessionState()
        state.cancel()
        state.resolve(.clipboard)
        await state.waitForResolution()

        XCTAssertEqual(state.state, .cancelled)
    }

    func testLongCaptureUsesManualScrollingInsteadOfSyntheticInput() {
        XCTAssertEqual(ScrollCaptureTargetController.inputMode, .manual)
    }

    func testPostCaptureActionBarsExposeTheRightActionsForEachStage() {
        XCTAssertEqual(
            PostCaptureChoice.resultChoices,
            [.editor, .ocr, .preview, .save, .clipboard]
        )
        XCTAssertTrue(PostCaptureChooserConfiguration.result.showsCloseButton)
        XCTAssertEqual(PostCaptureChooserConfiguration.result.controlCount, 6)
        XCTAssertEqual(
            PostCaptureChooserConfiguration.areaSelection.choices,
            [.scroll, .editor, .ocr, .preview, .save, .clipboard]
        )
        XCTAssertEqual(PostCaptureChooserConfiguration.areaSelection.controlCount, 7)
        XCTAssertEqual(
            PostCaptureChooserConfiguration.longCaptureActive.choices,
            [.editor, .ocr, .save, .clipboard]
        )
        XCTAssertTrue(PostCaptureChooserConfiguration.longCaptureActive.showsCloseButton)
        XCTAssertEqual(PostCaptureChooserConfiguration.longCaptureActive.controlCount, 5)
        XCTAssertEqual(PostCaptureChoice.preview.iconName, "pin")
        XCTAssertEqual(CaptureMode.scroll.iconName, "scroll")
        XCTAssertEqual(PostCaptureChoice.scroll.iconName, CaptureMode.scroll.iconName)
        XCTAssertNotNil(NSImage(systemSymbolName: CaptureMode.scroll.iconName, accessibilityDescription: nil))
        XCTAssertNotEqual(PostCaptureChoice.scroll.iconName, PostCaptureChoice.save.iconName)
        XCTAssertEqual(PostCaptureChoice.save.iconName, "square.and.arrow.down")
        XCTAssertNil(PostCaptureChoice.ocr.resultMode)
        XCTAssertNil(PostCaptureChoice.scroll.resultMode)
        XCTAssertEqual(PostCaptureChoice.editor.resultMode, .editor)
        XCTAssertEqual(PostCaptureChoice.save.resultMode, .file)
        XCTAssertEqual(PostCaptureChoice.clipboard.actionTitle, Localization.string("Copy"))
        XCTAssertEqual(PostCaptureChoice.preview.actionTitle, Localization.string("Pin"))
        XCTAssertEqual(PostCaptureChoice.scroll.actionTitle, Localization.string("Long Capture"))
        XCTAssertEqual(PostCaptureChoice.save.actionTitle, Localization.string("Download"))

        let resultPanel = PostCaptureChooserLayout.panelSize(
            for: PostCaptureChooserConfiguration.result.controlCount
        )
        XCTAssertEqual(resultPanel, PostCaptureChooserLayout.panelSize)
        XCTAssertGreaterThan(resultPanel.width, 300)
    }

    func testLongCaptureMaskBlocksOnlyTheFourAreasOutsideSelection() {
        let screen = CGRect(x: 0, y: 0, width: 1_200, height: 800)
        let selection = CGRect(x: 280, y: 160, width: 640, height: 420)
        let frames = ScrollCaptureMaskLayout.blockingFrames(for: selection, in: screen)

        XCTAssertEqual(
            frames,
            [
                CGRect(x: 0, y: 580, width: 1_200, height: 220),
                CGRect(x: 0, y: 0, width: 1_200, height: 160),
                CGRect(x: 0, y: 160, width: 280, height: 420),
                CGRect(x: 920, y: 160, width: 280, height: 420),
            ]
        )
        XCTAssertTrue(frames.allSatisfy { !$0.intersects(selection) })
        XCTAssertEqual(
            frames.reduce(CGFloat.zero) { $0 + $1.width * $1.height },
            screen.width * screen.height - selection.width * selection.height
        )
        XCTAssertEqual(
            ScrollCaptureMaskLayout.blockingFrames(
                for: CGRect(x: 1_300, y: 0, width: 20, height: 20),
                in: screen
            ),
            [screen]
        )
        XCTAssertEqual(
            ScrollCaptureMaskLayout.transparentRect(for: selection, in: screen),
            selection
        )
        XCTAssertNil(
            ScrollCaptureMaskLayout.transparentRect(
                for: CGRect(x: 1_300, y: 0, width: 20, height: 20),
                in: screen
            )
        )
    }

    // MARK: - Capture readiness feedback

    func testAreaSelectorInvertsCornerColorForSystemAppearance() throws {
        let lightAppearance = try XCTUnwrap(NSAppearance(named: .aqua))
        let darkAppearance = try XCTUnwrap(NSAppearance(named: .darkAqua))
        let lightCorner = try XCTUnwrap(
            AreaSelectorOverlayView.selectionAccentColor(for: lightAppearance)
                .usingColorSpace(.sRGB)
        )
        let darkCorner = try XCTUnwrap(
            AreaSelectorOverlayView.selectionAccentColor(for: darkAppearance)
                .usingColorSpace(.sRGB)
        )
        let lightOutline = try XCTUnwrap(
            AreaSelectorOverlayView.selectionOutlineColor(for: lightAppearance)
                .usingColorSpace(.sRGB)
        )
        let darkOutline = try XCTUnwrap(
            AreaSelectorOverlayView.selectionOutlineColor(for: darkAppearance)
                .usingColorSpace(.sRGB)
        )
        XCTAssertEqual(lightCorner.redComponent, 31.0 / 255.0, accuracy: 0.001)
        XCTAssertEqual(lightCorner.greenComponent, 31.0 / 255.0, accuracy: 0.001)
        XCTAssertEqual(lightCorner.blueComponent, 33.0 / 255.0, accuracy: 0.001)
        XCTAssertEqual(darkCorner.redComponent, 1, accuracy: 1.0 / 255.0)
        XCTAssertEqual(lightCorner.alphaComponent, 0.92, accuracy: 0.001)
        XCTAssertEqual(darkCorner.alphaComponent, 0.96, accuracy: 0.001)
        XCTAssertEqual(lightOutline.redComponent, 1, accuracy: 1.0 / 255.0)
        XCTAssertEqual(lightOutline.greenComponent, 1, accuracy: 1.0 / 255.0)
        XCTAssertEqual(lightOutline.blueComponent, 1, accuracy: 1.0 / 255.0)
        XCTAssertEqual(lightOutline.alphaComponent, 0.96, accuracy: 0.001)
        XCTAssertEqual(darkOutline.redComponent, 31.0 / 255.0, accuracy: 0.001)
        XCTAssertEqual(darkOutline.greenComponent, 31.0 / 255.0, accuracy: 0.001)
        XCTAssertEqual(darkOutline.blueComponent, 33.0 / 255.0, accuracy: 0.001)
        XCTAssertEqual(darkOutline.alphaComponent, 0.92, accuracy: 0.001)
    }

    func testAreaSelectorUsesFourCornersWithoutConnectingEdges() {
        XCTAssertEqual(AreaSelectorOverlayView.selectionEdgeLineWidth, 0)
        XCTAssertEqual(AreaSelectorOverlayView.selectionCornerLineWidth, 6)
        XCTAssertEqual(AreaSelectorOverlayView.selectionCornerOutlineLineWidth, 8)
        XCTAssertEqual(AreaSelectorOverlayView.selectionCornerLength, 18)
        XCTAssertEqual(AreaSelectorOverlayView.selectionCornerRadius, 6)
        XCTAssertGreaterThan(
            AreaSelectorOverlayView.selectionCornerLineWidth,
            AreaSelectorOverlayView.selectionEdgeLineWidth
        )
        XCTAssertLessThan(
            AreaSelectorOverlayView.selectionCornerRadius,
            AreaSelectorOverlayView.selectionCornerLength
        )
    }

    func testSelectionCornersRenderFullerArmsWithoutConnectingEdgesAcrossAppearancesAndScales() throws {
        let appearances: [NSAppearance.Name] = [
            .aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua,
        ]
        let rect = CGRect(x: 32, y: 32, width: 96, height: 96)
        for name in appearances {
            let appearance = try XCTUnwrap(NSAppearance(named: name))
            for scale in [1, 2] {
                let pixels = try renderSelectionCornerPixels(rect: rect, appearance: appearance, scale: scale)
                let pixelWidth = 160 * scale
                func alpha(x: Int, y: Int) -> UInt8 {
                    pixels[(y * pixelWidth + x) * 4 + 3]
                }
                let context = "\(name.rawValue), \(scale)x"
                // Sample the straight part of the left arm, away from its
                // rounded turn/cap. A crisp one-point surround expands the
                // six-point primary stroke to eight points without a shadow.
                let solidArmPixels = (24 * scale..<48 * scale).filter {
                    alpha(x: $0, y: 45 * scale) > 230
                }.count
                XCTAssertEqual(solidArmPixels, 8 * scale, context)

                // The outline is part of the actual raster, not merely a
                // colour-token promise: both opposite colours must appear in
                // the straight arm in light and dark appearances.
                let armColors = (24 * scale..<48 * scale).map { x -> (UInt8, UInt8, UInt8) in
                    let offset = (45 * scale * pixelWidth + x) * 4
                    return (pixels[offset], pixels[offset + 1], pixels[offset + 2])
                }
                XCTAssertTrue(armColors.contains { $0.0 > 220 && $0.1 > 220 && $0.2 > 220 }, context)
                XCTAssertTrue(armColors.contains { $0.0 < 70 && $0.1 < 70 && $0.2 < 70 }, context)

                for point in [
                    CGPoint(x: 80, y: 35), CGPoint(x: 80, y: 125),
                    CGPoint(x: 35, y: 80), CGPoint(x: 125, y: 80),
                    CGPoint(x: 80, y: 80),
                ] {
                    XCTAssertEqual(
                        alpha(x: Int(point.x) * scale, y: Int(point.y) * scale),
                        0,
                        "The center and middle of each edge must stay transparent: \(context)"
                    )
                }
            }
        }
    }

    func testSelectionCornersKeepSmallSelectionsBoundedAcrossAppearancesAndScales() throws {
        let appearances: [NSAppearance.Name] = [
            .aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua,
        ]
        for name in appearances {
            let appearance = try XCTUnwrap(NSAppearance(named: name))
            for scale in [1, 2] {
                for side in [4, 8, 16, 32] {
                    let rect = CGRect(x: 80 - side / 2, y: 80 - side / 2, width: side, height: side)
                    let pixels = try renderSelectionCornerPixels(rect: rect, appearance: appearance, scale: scale)
                    let pixelWidth = 160 * scale
                    let visiblePixels = stride(from: 3, to: pixels.count, by: 4).filter { pixels[$0] > 0 }
                    let context = "\(name.rawValue), \(scale)x, \(side)pt"
                    if side <= 6 {
                        XCTAssertTrue(visiblePixels.isEmpty, context)
                    } else {
                        XCTAssertFalse(visiblePixels.isEmpty, context)
                    }
                    // Antialiasing may touch the crop boundary, but a collapsed
                    // corner must never paint elsewhere on screen.
                    let permittedBounds = rect.insetBy(dx: -1, dy: -1)
                    XCTAssertTrue(visiblePixels.allSatisfy { alphaIndex in
                        let pixelIndex = alphaIndex / 4
                        return permittedBounds.contains(CGPoint(
                            x: CGFloat(pixelIndex % pixelWidth) / CGFloat(scale),
                            y: CGFloat(pixelIndex / pixelWidth) / CGFloat(scale)
                        ))
                    }, context)
                }
            }
        }
    }

    private func renderSelectionCornerPixels(
        rect: CGRect,
        appearance: NSAppearance,
        scale: Int
    ) throws -> [UInt8] {
        let pixelWidth = 160 * scale
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: pixelWidth,
            height: pixelWidth,
            bitsPerComponent: 8,
            bytesPerRow: pixelWidth * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        ))
        context.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
        CaptureSelectionFrameStyle.drawCorners(context: context, rect: rect, appearance: appearance)
        let data = try XCTUnwrap(context.data)
        return Array(UnsafeBufferPointer(
            start: data.assumingMemoryBound(to: UInt8.self),
            count: pixelWidth * pixelWidth * 4
        ))
    }

    @MainActor
    func testPostCaptureChooserAppearsAgainAfterThePreviousChoice() {
        let manager = PostCaptureChooserManager()
        let anchor = NSRect(x: 160, y: 160, width: 320, height: 180)
        var receivedChoices: [PostCaptureChoice?] = []

        let firstID = manager.show(anchoredTo: anchor) { choice in
            receivedChoices.append(choice)
        }
        guard let firstPanel = NSApp.windows.first(where: {
            $0.identifier == PostCaptureChooserManager.panelIdentifier(for: firstID)
        }) as? NSPanel else {
            return XCTFail("The first post-capture chooser was not registered with AppKit")
        }

        XCTAssertTrue(firstPanel.isVisible)
        XCTAssertEqual(firstPanel.level, .statusBar)
        firstPanel.cancelOperation(nil)
        XCTAssertEqual(receivedChoices.count, 1)
        XCTAssertNil(receivedChoices[0])
        XCTAssertFalse(firstPanel.isVisible)
        XCTAssertNil(firstPanel.contentView)

        let secondID = manager.show(anchoredTo: anchor) { choice in
            receivedChoices.append(choice)
        }
        guard let secondPanel = NSApp.windows.first(where: {
            $0.identifier == PostCaptureChooserManager.panelIdentifier(for: secondID)
        }) as? NSPanel else {
            return XCTFail("The second post-capture chooser was not registered with AppKit")
        }

        XCTAssertFalse(firstPanel === secondPanel)
        XCTAssertTrue(secondPanel.isVisible)
        XCTAssertEqual(secondPanel.level, .statusBar)
        secondPanel.cancelOperation(nil)
        XCTAssertEqual(receivedChoices.count, 2)
        XCTAssertNil(receivedChoices[1])
    }

    @MainActor
    func testEscapeDiscardsThePendingPostCaptureWithoutRoutingIt() throws {
        let manager = PostCaptureChooserManager()
        let anchor = NSRect(x: 160, y: 160, width: 320, height: 180)
        var receivedChoices: [PostCaptureChoice?] = []
        let chooserID = manager.show(anchoredTo: anchor) { choice in
            receivedChoices.append(choice)
        }
        let panel = try XCTUnwrap(
            NSApp.windows.first(where: {
                $0.identifier == PostCaptureChooserManager.panelIdentifier(for: chooserID)
            }) as? NSPanel
        )
        let escape = try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: panel.windowNumber,
                context: nil,
                characters: "\u{1B}",
                charactersIgnoringModifiers: "\u{1B}",
                isARepeat: false,
                keyCode: 53
            )
        )

        panel.sendEvent(escape)

        XCTAssertEqual(receivedChoices.count, 1)
        XCTAssertNil(receivedChoices[0])
        XCTAssertFalse(panel.isVisible)
        XCTAssertNil(panel.contentView)
    }

    @MainActor
    func testLongCaptureFiveActionCapsuleRendersInDarkMode() throws {
        let manager = PostCaptureChooserManager()
        let anchor = NSRect(x: 160, y: 160, width: 320, height: 180)
        let chooserID = manager.show(
            anchoredTo: anchor,
            configuration: .longCaptureActive,
            completion: { _ in }
        )
        defer { manager.dismiss(id: chooserID) }

        let panel = try XCTUnwrap(
            NSApp.windows.first(where: {
                $0.identifier == PostCaptureChooserManager.panelIdentifier(for: chooserID)
            }) as? NSPanel
        )
        let contentView = try XCTUnwrap(panel.contentView)
        panel.appearance = try XCTUnwrap(NSAppearance(named: .darkAqua))
        contentView.layoutSubtreeIfNeeded()
        contentView.displayIfNeeded()

        XCTAssertEqual(
            panel.frame.size,
            PostCaptureChooserLayout.panelSize(
                for: PostCaptureChooserConfiguration.longCaptureActive.controlCount
            )
        )

        let bitmap = try XCTUnwrap(
            contentView.bitmapImageRepForCachingDisplay(in: contentView.bounds)
        )
        contentView.cacheDisplay(in: contentView.bounds, to: bitmap)
        let snapshot = NSImage(size: contentView.bounds.size)
        snapshot.addRepresentation(bitmap)
        let attachment = XCTAttachment(image: snapshot)
        attachment.name = "long-capture-five-action-capsule-dark"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func testRegularCaptureSixActionCapsuleRendersInDarkMode() throws {
        let manager = PostCaptureChooserManager()
        let anchor = NSRect(x: 160, y: 160, width: 320, height: 180)
        let chooserID = manager.show(
            anchoredTo: anchor,
            configuration: .result,
            completion: { _ in }
        )
        defer { manager.dismiss(id: chooserID) }

        let panel = try XCTUnwrap(
            NSApp.windows.first(where: {
                $0.identifier == PostCaptureChooserManager.panelIdentifier(for: chooserID)
            }) as? NSPanel
        )
        let contentView = try XCTUnwrap(panel.contentView)
        panel.appearance = try XCTUnwrap(NSAppearance(named: .darkAqua))
        contentView.layoutSubtreeIfNeeded()
        contentView.displayIfNeeded()

        XCTAssertEqual(
            panel.frame.size,
            PostCaptureChooserLayout.panelSize(
                for: PostCaptureChooserConfiguration.result.controlCount
            )
        )

        let bitmap = try XCTUnwrap(
            contentView.bitmapImageRepForCachingDisplay(in: contentView.bounds)
        )
        contentView.cacheDisplay(in: contentView.bounds, to: bitmap)
        let snapshot = NSImage(size: contentView.bounds.size)
        snapshot.addRepresentation(bitmap)
        let attachment = XCTAttachment(image: snapshot)
        attachment.name = "regular-capture-six-action-capsule-dark"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func testAreaSelectorMakesItsReadyStateVisibleBeforeTheFirstDrag() {
        let overlay = AreaSelectorOverlayView(
            frame: NSRect(x: 0, y: 0, width: 320, height: 180)
        )

        XCTAssertFalse(overlay.isShowingReadyFeedback)

        overlay.showReadyFeedback()
        XCTAssertTrue(overlay.isShowingReadyFeedback)

        overlay.setSelectionRect(
            NSRect(x: 20, y: 20, width: 160, height: 90),
            pixelSize: CGSize(width: 320, height: 180)
        )
        XCTAssertFalse(overlay.isShowingReadyFeedback)

        let heldFrame = NSRect(x: 20, y: 20, width: 160, height: 90)
        overlay.holdSelectionForResultChoice(
            frozenImage: nil,
            visibleSelectionRect: heldFrame,
            selectionFrame: heldFrame
        )
        XCTAssertTrue(overlay.isAwaitingResultChoice)
        XCTAssertEqual(overlay.heldSelectionDestinationRect, heldFrame)

        let movedFrame = NSRect(x: 80, y: 50, width: 160, height: 90)
        overlay.updateHeldSelection(
            visibleSelectionRect: movedFrame,
            selectionFrame: movedFrame
        )
        XCTAssertEqual(overlay.heldSelectionDestinationRect, movedFrame)

        XCTAssertTrue(overlay.clearSelection())
        XCTAssertFalse(overlay.isAwaitingResultChoice)
    }

    @MainActor
    func testAreaSelectorCanPreviewAWindowBeforeARegionDrag() {
        let overlay = AreaSelectorOverlayView(
            frame: NSRect(x: 0, y: 0, width: 640, height: 360)
        )
        let windowFrame = NSRect(x: 80, y: 50, width: 420, height: 240)

        overlay.setWindowHoverRect(windowFrame)
        XCTAssertEqual(overlay.windowHoverRect, windowFrame)

        overlay.setSelectionRect(
            NSRect(x: 100, y: 70, width: 180, height: 120),
            pixelSize: CGSize(width: 360, height: 240)
        )
        XCTAssertNil(overlay.windowHoverRect)
    }

    func testPendingSelectionMovementStaysInsideVirtualDesktopBounds() {
        let desktop = NSRect(x: -1_920, y: 0, width: 3_840, height: 1_080)

        XCTAssertEqual(
            PendingSelectionLayout.constrainedFrame(
                NSRect(x: -2_050, y: -100, width: 500, height: 300),
                within: desktop
            ),
            NSRect(x: -1_920, y: 0, width: 500, height: 300)
        )
        XCTAssertEqual(
            PendingSelectionLayout.constrainedFrame(
                NSRect(x: 1_800, y: 950, width: 500, height: 300),
                within: desktop
            ),
            NSRect(x: 1_420, y: 780, width: 500, height: 300)
        )
    }

    func testPendingSelectionCanResizeAroundTheOppositeCorner() {
        let desktop = NSRect(x: 0, y: 0, width: 1_440, height: 900)

        XCTAssertEqual(
            PendingSelectionLayout.resizedFrame(
                fixedPoint: NSPoint(x: 800, y: 300),
                draggedPoint: NSPoint(x: 320, y: 760),
                within: desktop
            ),
            NSRect(x: 320, y: 300, width: 480, height: 460)
        )
    }

    func testPendingSelectionResizeKeepsAMinimumSizeAtScreenEdges() {
        let desktop = NSRect(x: 0, y: 0, width: 1_440, height: 900)

        XCTAssertEqual(
            PendingSelectionLayout.resizedFrame(
                fixedPoint: NSPoint(x: 1_440, y: 900),
                draggedPoint: NSPoint(x: 1_439, y: 899),
                within: desktop
            ),
            NSRect(x: 1_416, y: 876, width: 24, height: 24)
        )
    }

    func testSelectedMarkupOwnsPointerEvenWhenAnOldCropDragExists() {
        XCTAssertEqual(
            HeldSelectionPointerRouter.target(
                canDirectlyAdjustSelection: false,
                hasPendingCropDrag: true,
                hasActiveMarkupDrag: false,
                isCropGeometryHit: true,
                isInsideSelection: true
            ),
            .markupCanvas,
            "Selecting Rectangle or Ellipse must not let a previous crop drag swallow its first gesture"
        )

        XCTAssertEqual(
            HeldSelectionPointerRouter.target(
                canDirectlyAdjustSelection: true,
                hasPendingCropDrag: true,
                hasActiveMarkupDrag: false,
                isCropGeometryHit: false,
                isInsideSelection: false
            ),
            .cropGeometry
        )

        XCTAssertEqual(
            HeldSelectionPointerRouter.target(
                canDirectlyAdjustSelection: false,
                hasPendingCropDrag: false,
                hasActiveMarkupDrag: true,
                isCropGeometryHit: false,
                isInsideSelection: false
            ),
            .markupCanvas,
            "A started mark can finish cleanly after leaving the selected frame"
        )
    }

    // MARK: - Coordinate space

    func testAppKitToCGFlipsAroundPrimaryScreen() {
        // On a 1000pt-tall primary screen, an AppKit rect near the top
        // (minY 800, maxY 850) is 150pt from the top in CG space.
        let rect = CGRect(x: 10, y: 800, width: 100, height: 50)
        let converted = CoordinateSpace.appKitToCG(rect, primaryScreenMaxY: 1000)
        XCTAssertEqual(converted, CGRect(x: 10, y: 150, width: 100, height: 50))
    }

    func testAppKitToCGIsItsOwnInverse() {
        let rect = CGRect(x: -320, y: 250, width: 640, height: 400)
        let roundTripped = CoordinateSpace.appKitToCG(
            CoordinateSpace.appKitToCG(rect, primaryScreenMaxY: 900),
            primaryScreenMaxY: 900
        )
        XCTAssertEqual(roundTripped, rect)
    }

    func testAppKitToCGPointConversion() {
        let point = CGPoint(x: 42, y: 100)
        XCTAssertEqual(
            CoordinateSpace.appKitToCG(point, primaryScreenMaxY: 900),
            CGPoint(x: 42, y: 800)
        )
    }

    // MARK: - Fullscreen capture composition

    func testDisplayCompositionPreservesSingleDisplayOrientation() throws {
        let displayImage = makeTwoBandImage(
            width: 4,
            height: 4,
            top: (255, 0, 0),
            bottom: (0, 0, 255)
        )

        let capture = try ScreenCaptureService.composeDisplays([
            .init(frame: CGRect(x: 0, y: 0, width: 4, height: 4), scale: 1, image: displayImage),
        ])

        XCTAssertEqual(rawPixel(in: capture.image, x: 2, y: 0).red, 255)
        XCTAssertEqual(rawPixel(in: capture.image, x: 2, y: 0).blue, 0)
        XCTAssertEqual(rawPixel(in: capture.image, x: 2, y: 3).red, 0)
        XCTAssertEqual(rawPixel(in: capture.image, x: 2, y: 3).blue, 255)
    }

    func testDisplayCompositionPlacesVerticalDisplaysWithoutMirroring() throws {
        let topDisplay = makeTwoBandImage(
            width: 4,
            height: 4,
            top: (255, 0, 0),
            bottom: (0, 0, 255)
        )
        let bottomDisplay = makeTwoBandImage(
            width: 4,
            height: 4,
            top: (0, 255, 0),
            bottom: (255, 255, 0)
        )

        let capture = try ScreenCaptureService.composeDisplays([
            .init(frame: CGRect(x: 0, y: 0, width: 4, height: 4), scale: 1, image: topDisplay),
            .init(frame: CGRect(x: 0, y: 4, width: 4, height: 4), scale: 1, image: bottomDisplay),
        ])

        let topEdge = rawPixel(in: capture.image, x: 2, y: 0)
        XCTAssertEqual(topEdge.red, 255)
        XCTAssertEqual(topEdge.green, 0)
        XCTAssertEqual(topEdge.blue, 0)

        let topDisplayBottomEdge = rawPixel(in: capture.image, x: 2, y: 3)
        XCTAssertEqual(topDisplayBottomEdge.red, 0)
        XCTAssertEqual(topDisplayBottomEdge.green, 0)
        XCTAssertEqual(topDisplayBottomEdge.blue, 255)

        let bottomDisplayTopEdge = rawPixel(in: capture.image, x: 2, y: 4)
        XCTAssertEqual(bottomDisplayTopEdge.red, 0)
        XCTAssertEqual(bottomDisplayTopEdge.green, 255)
        XCTAssertEqual(bottomDisplayTopEdge.blue, 0)

        let bottomEdge = rawPixel(in: capture.image, x: 2, y: 7)
        XCTAssertEqual(bottomEdge.red, 255)
        XCTAssertEqual(bottomEdge.green, 255)
        XCTAssertEqual(bottomEdge.blue, 0)
    }

    // MARK: - Frozen area capture

    func testFrozenSnapshotCropsTheFrameCapturedAtSelectionStart() throws {
        let displayImage = makeTwoBandImage(
            width: 8,
            height: 8,
            top: (255, 0, 0),
            bottom: (0, 0, 255)
        )
        let snapshot = FrozenScreenSnapshot(displays: [
            .init(frame: CGRect(x: 0, y: 0, width: 4, height: 4), image: displayImage),
        ])

        let topHalf = try XCTUnwrap(snapshot.image(
            for: CGRect(x: 0, y: 2, width: 4, height: 2),
            retinaScale: true
        ))
        XCTAssertEqual(topHalf.width, 8)
        XCTAssertEqual(topHalf.height, 4)
        XCTAssertEqual(pixel(in: topHalf, x: 4, y: 2).red, 255)
        XCTAssertEqual(pixel(in: topHalf, x: 4, y: 2).blue, 0)

        let bottomHalf = try XCTUnwrap(snapshot.image(
            for: CGRect(x: 0, y: 0, width: 4, height: 2),
            retinaScale: true
        ))
        XCTAssertEqual(pixel(in: bottomHalf, x: 4, y: 2).red, 0)
        XCTAssertEqual(pixel(in: bottomHalf, x: 4, y: 2).blue, 255)
    }

    func testFrozenSnapshotPreservesVerticalOrientation() throws {
        let displayImage = makeTwoBandImage(
            width: 4,
            height: 4,
            top: (255, 0, 0),
            bottom: (0, 0, 255)
        )
        let snapshot = FrozenScreenSnapshot(displays: [
            .init(frame: CGRect(x: 0, y: 0, width: 4, height: 4), image: displayImage),
        ])

        let image = try XCTUnwrap(snapshot.image(
            for: CGRect(x: 0, y: 0, width: 4, height: 4),
            retinaScale: false
        ))

        XCTAssertEqual(rawPixel(in: image, x: 2, y: 0).red, 255)
        XCTAssertEqual(rawPixel(in: image, x: 2, y: 0).blue, 0)
        XCTAssertEqual(rawPixel(in: image, x: 2, y: 3).red, 0)
        XCTAssertEqual(rawPixel(in: image, x: 2, y: 3).blue, 255)
    }

    func testFrozenSnapshotComposesSelectionsAcrossDisplays() throws {
        let snapshot = FrozenScreenSnapshot(displays: [
            .init(
                frame: CGRect(x: 0, y: 0, width: 4, height: 4),
                image: makeSolidImage(width: 8, height: 8, red: 255, green: 0, blue: 0)
            ),
            .init(
                frame: CGRect(x: 4, y: 0, width: 4, height: 4),
                image: makeSolidImage(width: 8, height: 8, red: 0, green: 255, blue: 0)
            ),
        ])

        let image = try XCTUnwrap(snapshot.image(
            for: CGRect(x: 2, y: 1, width: 4, height: 2),
            retinaScale: false
        ))
        XCTAssertEqual(image.width, 4)
        XCTAssertEqual(image.height, 2)
        XCTAssertEqual(pixel(in: image, x: 0, y: 1).red, 255)
        XCTAssertEqual(pixel(in: image, x: 3, y: 1).green, 255)
    }

    func testFrozenSnapshotComposesVerticallyArrangedDisplaysUpright() throws {
        let snapshot = FrozenScreenSnapshot(displays: [
            .init(
                frame: CGRect(x: 0, y: 0, width: 4, height: 4),
                image: makeSolidImage(width: 4, height: 4, red: 255, green: 0, blue: 0)
            ),
            .init(
                frame: CGRect(x: 0, y: 4, width: 4, height: 4),
                image: makeSolidImage(width: 4, height: 4, red: 0, green: 255, blue: 0)
            ),
        ])

        let image = try XCTUnwrap(snapshot.image(
            for: CGRect(x: 0, y: 2, width: 4, height: 4),
            retinaScale: false
        ))

        XCTAssertEqual(rawPixel(in: image, x: 2, y: 0).green, 255)
        XCTAssertEqual(rawPixel(in: image, x: 2, y: 3).red, 255)
    }

    func testFreezeScreenDefaultsOnButRespectsAnExplicitPreference() {
        let suiteName = "BugFixTests.freezeScreen.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertTrue(AppState(defaults: defaults).freezeScreen)
        defaults.set(false, forKey: Constants.Keys.freezeScreen)
        XCTAssertFalse(AppState(defaults: defaults).freezeScreen)
    }

    // MARK: - Filename collisions

    func testUniqueURLAppendsCounterOnCollision() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = directory.appendingPathComponent("shot.png")
        XCTAssertEqual(FileManager.default.uniqueURL(for: url), url)

        FileManager.default.createFile(atPath: url.path, contents: Data())
        let second = FileManager.default.uniqueURL(for: url)
        XCTAssertEqual(second.lastPathComponent, "shot 2.png")

        FileManager.default.createFile(atPath: second.path, contents: Data())
        XCTAssertEqual(FileManager.default.uniqueURL(for: url).lastPathComponent, "shot 3.png")
    }

    @MainActor
    func testBackToBackCapturesCannotReuseTheSameOutputPath() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let suiteName = "BugFixTests.captureOutput.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let notificationCenter = NotificationCenter()
        let coordinator = CaptureCoordinator(
            appState: AppState(defaults: defaults),
            notificationCenter: notificationCenter
        )
        let completed = expectation(description: "Both capture outputs complete")
        completed.expectedFulfillmentCount = 2
        var outputURLs: [URL] = []
        let token = notificationCenter.addObserver(
            forName: .captureCompleted,
            object: nil,
            queue: .main
        ) { notification in
            if let info = notification.object as? CaptureCompletedInfo,
               let savedURL = info.savedURL {
                outputURLs.append(savedURL)
            }
            completed.fulfill()
        }
        defer { notificationCenter.removeObserver(token) }

        let image = makeSolidImage(width: 2_400, height: 2_400, red: 20, green: 80, blue: 160)
        let result = CaptureResult(
            image: image,
            mode: .area,
            timestamp: Date(),
            sourceRect: CGRect(x: 0, y: 0, width: 1_200, height: 1_200),
            windowName: nil,
            applicationName: nil,
            scale: 2
        )
        let options = CaptureOptions(
            freezeScreen: false,
            showMagnifier: false,
            playSound: false,
            copyToClipboard: false,
            resultMode: .preview,
            saveToFile: true,
            format: .png,
            saveDirectory: directory,
            filenamePattern: "same-name",
            includeShadow: false,
            retina2x: true,
            jpegQuality: 0.9
        )

        coordinator.finishCapture(result: result, options: options)
        coordinator.finishCapture(result: result, options: options)
        await fulfillment(of: [completed], timeout: 10)

        XCTAssertEqual(outputURLs.count, 2)
        XCTAssertEqual(Set(outputURLs).count, 2)
        XCTAssertTrue(outputURLs.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
    }

    @MainActor
    func testCopyOnlyDoesNotPublishPixelsForHistoryPersistence() async throws {
        let suiteName = "BugFixTests.copyOnlyPrivacy.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let notificationCenter = NotificationCenter()
        let coordinator = CaptureCoordinator(
            appState: AppState(defaults: defaults),
            notificationCenter: notificationCenter
        )
        let completed = expectation(description: "Copy Only must not feed persistent history")
        completed.isInverted = true
        let token = notificationCenter.addObserver(
            forName: .captureCompleted,
            object: nil,
            queue: .main
        ) { _ in
            completed.fulfill()
        }
        defer { notificationCenter.removeObserver(token) }

        let image = makeSolidImage(width: 20, height: 20, red: 40, green: 80, blue: 120)
        let result = CaptureResult(
            image: image,
            mode: .area,
            timestamp: Date(),
            sourceRect: CGRect(x: 0, y: 0, width: 10, height: 10),
            windowName: nil,
            applicationName: nil,
            scale: 2
        )
        let options = CaptureOptions(
            freezeScreen: false,
            showMagnifier: false,
            playSound: false,
            copyToClipboard: false,
            resultMode: .clipboard,
            saveToFile: true,
            format: .png,
            saveDirectory: FileManager.default.temporaryDirectory,
            filenamePattern: "must-not-persist",
            includeShadow: false,
            retina2x: true,
            jpegQuality: 0.9
        )

        coordinator.finishCapture(result: result, options: options)

        await fulfillment(of: [completed], timeout: 0.25)
    }

    @MainActor
    func testUnsavedPreviewUsesADeletableDiskBackingInsteadOfUnboundedImageMemory() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let previewCacheDirectory = directory.appendingPathComponent("preview-cache", isDirectory: true)
        let suiteName = "BugFixTests.previewBacking.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let notificationCenter = NotificationCenter()
        let coordinator = CaptureCoordinator(
            appState: AppState(defaults: defaults),
            notificationCenter: notificationCenter,
            previewCacheDirectory: previewCacheDirectory
        )
        let completed = expectation(description: "Unsaved preview backing completes")
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
        let image = makeSolidImage(width: 640, height: 480, red: 30, green: 60, blue: 90)
        let result = CaptureResult(
            image: image,
            mode: .area,
            timestamp: Date(),
            sourceRect: CGRect(x: 0, y: 0, width: 640, height: 480),
            windowName: nil,
            applicationName: nil,
            scale: 1
        )
        let options = CaptureOptions(
            freezeScreen: false,
            showMagnifier: false,
            playSound: false,
            copyToClipboard: false,
            resultMode: .preview,
            saveToFile: false,
            format: .png,
            saveDirectory: directory,
            filenamePattern: "unsaved",
            includeShadow: false,
            retina2x: false,
            jpegQuality: 0.9
        )

        coordinator.finishCapture(result: result, options: options)
        await fulfillment(of: [completed], timeout: 5)

        let info = try XCTUnwrap(completedInfo)
        let backingURL = try XCTUnwrap(info.managedPreviewURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: backingURL.path))
        let capture = QuickAccessCapture(
            id: UUID(),
            recordID: info.recordID,
            inMemoryImage: nil,
            thumbnail: info.thumbnail ?? image,
            mode: result.mode,
            timestamp: result.timestamp,
            savedURL: nil,
            managedBackingURL: backingURL,
            width: result.width,
            height: result.height,
            fileSize: 0,
            scale: result.scale
        )
        XCTAssertNil(capture.inMemoryImage)
        XCTAssertNotNil(capture.resolvedImage())

        let manager = QuickAccessManager(appState: AppState(defaults: defaults))
        manager.captures = [capture]
        manager.removeCapture(capture.id)

        XCTAssertFalse(FileManager.default.fileExists(atPath: backingURL.path))
    }

    @MainActor
    func testPendingOutputDrainWaitsUntilTheCaptureFileIsReadable() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let suiteName = "BugFixTests.captureDrain.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let notificationCenter = NotificationCenter()
        let coordinator = CaptureCoordinator(
            appState: AppState(defaults: defaults),
            notificationCenter: notificationCenter
        )
        let completed = expectation(description: "Capture output completed")
        let drained = expectation(description: "Output queue drained")
        var savedURL: URL?
        let token = notificationCenter.addObserver(
            forName: .captureCompleted,
            object: nil,
            queue: .main
        ) { notification in
            savedURL = (notification.object as? CaptureCompletedInfo)?.savedURL
            completed.fulfill()
        }
        defer { notificationCenter.removeObserver(token) }

        let image = makeSolidImage(width: 3_000, height: 3_000, red: 10, green: 90, blue: 170)
        let result = CaptureResult(
            image: image,
            mode: .fullscreen,
            timestamp: Date(),
            sourceRect: CGRect(x: 0, y: 0, width: 1_500, height: 1_500),
            windowName: nil,
            applicationName: nil,
            scale: 2
        )
        let options = CaptureOptions(
            freezeScreen: false,
            showMagnifier: false,
            playSound: false,
            copyToClipboard: false,
            resultMode: .preview,
            saveToFile: true,
            format: .png,
            saveDirectory: directory,
            filenamePattern: "drain-test",
            includeShadow: false,
            retina2x: true,
            jpegQuality: 0.9
        )

        coordinator.finishCapture(result: result, options: options)
        coordinator.finishPendingOutput {
            guard let savedURL else {
                XCTFail("The queued save must finish before the drain callback")
                drained.fulfill()
                return
            }
            XCTAssertNotNil(NSImage(contentsOf: savedURL))
            drained.fulfill()
        }

        await fulfillment(of: [completed, drained], timeout: 10, enforceOrder: true)
    }

    @MainActor
    func testFailedRequestedSaveCreatesAFullResolutionRecoveryCopy() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let unavailableDirectory = directory.appendingPathComponent("not-a-directory")
        try Data("file blocks directory creation".utf8).write(to: unavailableDirectory)
        let recoveryDirectory = directory.appendingPathComponent("recovery", isDirectory: true)
        let suiteName = "BugFixTests.captureRecovery.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let notificationCenter = NotificationCenter()
        let coordinator = CaptureCoordinator(
            appState: AppState(defaults: defaults),
            notificationCenter: notificationCenter,
            recoveryDirectory: recoveryDirectory
        )
        let completed = expectation(description: "Recovered capture completed")
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

        let image = makeSolidImage(width: 640, height: 480, red: 25, green: 100, blue: 200)
        let result = CaptureResult(
            image: image,
            mode: .area,
            timestamp: Date(),
            sourceRect: CGRect(x: 0, y: 0, width: 640, height: 480),
            windowName: nil,
            applicationName: nil,
            scale: 1
        )
        let options = CaptureOptions(
            freezeScreen: false,
            showMagnifier: false,
            playSound: false,
            copyToClipboard: false,
            resultMode: .preview,
            saveToFile: true,
            format: .png,
            saveDirectory: unavailableDirectory,
            filenamePattern: "recovered",
            includeShadow: false,
            retina2x: false,
            jpegQuality: 0.9
        )

        coordinator.finishCapture(result: result, options: options)
        await fulfillment(of: [completed], timeout: 5)

        let info = try XCTUnwrap(completedInfo)
        let recoveredURL = try XCTUnwrap(info.savedURL)
        XCTAssertEqual(recoveredURL.deletingLastPathComponent(), recoveryDirectory)
        XCTAssertEqual(info.saveFailure?.recoveredURL, recoveredURL)
        XCTAssertEqual(
            info.saveFailure?.requestedURL.deletingLastPathComponent().path,
            unavailableDirectory.path
        )
        let recoveredImage = try XCTUnwrap(NSImage(contentsOf: recoveredURL))
        XCTAssertEqual(recoveredImage.representations.first?.pixelsWide, image.width)
        XCTAssertEqual(recoveredImage.representations.first?.pixelsHigh, image.height)
    }

    func testAnnotatedSavePatternContainsNoPathSeparators() {
        let name = FileNameGenerator.generate(
            pattern: "Captures Annotated {date} at {time}",
            mode: .area
        )
        XCTAssertFalse(name.contains("/"))
        XCTAssertFalse(name.contains(":"))
        XCTAssertTrue(name.hasPrefix("Captures Annotated"))
    }

    // MARK: - Hotkey matching

    func testHotkeyBindingRequiresExactModifiers() {
        let binding = HotkeyBinding(keyCode: kVK_ANSI_4, modifiers: [.maskCommand, .maskShift])

        XCTAssertTrue(binding.matches(keyCode: kVK_ANSI_4, flags: [.maskCommand, .maskShift]))
        // ⌘⌃⇧4 is macOS's clipboard-screenshot shortcut and must not match.
        XCTAssertFalse(binding.matches(keyCode: kVK_ANSI_4, flags: [.maskCommand, .maskShift, .maskControl]))
        XCTAssertFalse(binding.matches(keyCode: kVK_ANSI_4, flags: [.maskCommand, .maskShift, .maskAlternate]))
        XCTAssertFalse(binding.matches(keyCode: kVK_ANSI_4, flags: [.maskCommand]))
        XCTAssertFalse(binding.matches(keyCode: kVK_ANSI_3, flags: [.maskCommand, .maskShift]))
    }

    func testHotkeyBindingIgnoresDeviceDependentFlags() {
        let binding = HotkeyBinding(keyCode: kVK_ANSI_3, modifiers: [.maskCommand, .maskShift])
        let flags: CGEventFlags = [.maskCommand, .maskShift, .maskNonCoalesced]
        XCTAssertTrue(binding.matches(keyCode: kVK_ANSI_3, flags: flags))
    }

    func testHotkeyBindingsRoundTripThroughJSON() throws {
        let original = HotkeyBinding.defaultBindings
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode([HotkeyAction: HotkeyBinding].self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testDefaultHotkeysPrioritizeAreaCaptureAndCoverSecondaryModes() {
        let defaults = HotkeyBinding.defaultBindings

        XCTAssertEqual(defaults[.captureArea]?.displayString, "⇧⌘A")
        XCTAssertEqual(defaults[.captureFullscreen]?.displayString, "⌥⌘F")
        XCTAssertEqual(defaults[.captureWindow]?.displayString, "⌥⌘W")
        XCTAssertEqual(defaults[.captureScroll]?.displayString, "⌥⌘S")
    }

    // MARK: - Scroll stitcher

    func testScrollStitcherStopsAtMaxHeight() {
        let initial = makeSolidImage(width: 8, height: 8, red: 255, green: 255, blue: 255)
        let frame = makeSolidImage(width: 8, height: 8, red: 0, green: 0, blue: 0)
        let stitcher = ScrollStitcher(initialImage: initial, maxHeight: 14)

        XCTAssertTrue(stitcher.append(frame: frame, verticalShift: 6))
        XCTAssertTrue(stitcher.reachedMaxHeight)
        XCTAssertFalse(stitcher.append(frame: frame, verticalShift: 6))
        XCTAssertEqual(stitcher.image.height, 14)
    }

    func testScrollStitcherKeepsSegmentsUpright() {
        // Initial: top half white, bottom half black. Second frame carries a
        // green strip in its bottom 4 rows. The composite must read
        // white / black / green from top to bottom with no mirroring.
        let initial = makeTwoBandImage(
            width: 8, height: 8,
            top: (255, 255, 255), bottom: (0, 0, 0)
        )
        let frame = makeTwoBandImage(
            width: 8, height: 8,
            top: (128, 128, 128), bottom: (0, 255, 0)
        )
        let stitcher = ScrollStitcher(initialImage: initial)

        XCTAssertTrue(stitcher.append(frame: frame, verticalShift: 4))
        let composite = stitcher.image
        XCTAssertEqual(composite.height, 12)

        XCTAssertEqual(pixel(in: composite, x: 4, y: 1).red, 255, "top of initial frame should stay on top")
        XCTAssertEqual(pixel(in: composite, x: 4, y: 6).red, 0, "bottom of initial frame should stay above the strip")
        let stripPixel = pixel(in: composite, x: 4, y: 10)
        XCTAssertEqual(stripPixel.green, 255, "appended strip should be the frame's bottom rows")
        XCTAssertEqual(stripPixel.red, 0)
    }

    // MARK: - Scroll frame store

    func testScrollFrameStoreNeverRegressesToStaleFrames() async {
        let store = ScrollFrameStore()
        let image = makeSolidImage(width: 2, height: 2, red: 0, green: 0, blue: 0)

        await store.store(ScrollCapturedFrame(sequence: 2, image: image))
        await store.store(ScrollCapturedFrame(sequence: 1, image: image))

        let frame = await store.waitForNextFrame(after: 0, timeout: 0.2)
        XCTAssertEqual(frame?.sequence, 2)
    }

    func testScrollFrameStoreWaiterTimesOut() async {
        let store = ScrollFrameStore()
        let frame = await store.waitForNextFrame(after: 0, timeout: 0.1)
        XCTAssertNil(frame)
    }

    // MARK: - Thumbnails

    func testGenerateThumbnailRejectsZeroSizedImages() {
        let image = makeSolidImage(width: 1, height: 1, red: 0, green: 0, blue: 0)
        XCTAssertNil(ImageUtils.resize(image, to: .zero))
        XCTAssertNotNil(ImageUtils.generateThumbnail(image))
    }

    func testQuickAccessRejectsAReusedOutputPathInsteadOfReturningAnotherCapture() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("reused.png")

        let firstImage = makeSolidImage(width: 8, height: 8, red: 255, green: 0, blue: 0)
        XCTAssertTrue(ImageUtils.save(firstImage, to: url, format: .png))
        let firstCapture = makeQuickAccessCapture(image: firstImage, savedURL: url)
        XCTAssertEqual(pixel(in: try XCTUnwrap(firstCapture.resolvedImage()), x: 4, y: 4).red, 255)

        try FileManager.default.removeItem(at: url)
        let secondImage = makeSolidImage(width: 8, height: 8, red: 0, green: 0, blue: 255)
        XCTAssertTrue(ImageUtils.save(secondImage, to: url, format: .png))
        XCTAssertNil(
            firstCapture.resolvedImage(),
            "An old card must not copy or edit pixels from a new file that reused its path"
        )
        let secondCapture = makeQuickAccessCapture(image: secondImage, savedURL: url)
        let resolved = try XCTUnwrap(secondCapture.resolvedImage())
        XCTAssertEqual(pixel(in: resolved, x: 4, y: 4).red, 0)
        XCTAssertEqual(pixel(in: resolved, x: 4, y: 4).blue, 255)
    }

    @MainActor
    func testQuickAccessPinRouteCreatesAScaledPersistentPinRequest() throws {
        let image = makeSolidImage(width: 8, height: 8, red: 20, green: 40, blue: 60)
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
            scale: 2
        )
        let suiteName = "CapturesTests.pinRoute.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let manager = QuickAccessManager(appState: AppState(defaults: defaults))
        manager.captures = [capture]
        var postedRequest: PinScreenshotRequest?
        manager.pin(capture) { request in
            postedRequest = request
            request.succeeded = true
        }

        XCTAssertTrue(manager.captures.isEmpty)
        XCTAssertEqual(postedRequest?.scale, 2)
        XCTAssertEqual(postedRequest?.image.width, image.width)
    }

    @MainActor
    func testQuickAccessRetainsItsOnlyBackingWhenPersistentPinSaveFails() throws {
        let image = makeSolidImage(width: 8, height: 8, red: 20, green: 40, blue: 60)
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
            scale: 2
        )
        let suiteName = "CapturesTests.pinFailure.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let manager = QuickAccessManager(appState: AppState(defaults: defaults))
        manager.captures = [capture]

        manager.pin(capture) { _ in }

        XCTAssertEqual(manager.captures.map(\.id), [capture.id])
    }

    @MainActor
    func testQuickAccessDeleteKeepsTheRecordVisibleUntilFileRemovalSucceeds() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Captures-Delete-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("capture.png")
        let image = makeSolidImage(width: 8, height: 8, red: 20, green: 40, blue: 60)
        XCTAssertTrue(ImageUtils.save(image, to: fileURL, format: .png))

        let capture = makeQuickAccessCapture(image: image, savedURL: fileURL)
        let suiteName = "CapturesTests.deleteFailure.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let manager = QuickAccessManager(appState: AppState(defaults: defaults))
        manager.captures = [capture]
        var historyDeletionCount = 0
        let token = NotificationCenter.default.addObserver(
            forName: .deleteHistoryRecord,
            object: nil,
            queue: .main
        ) { _ in
            historyDeletionCount += 1
        }
        defer { NotificationCenter.default.removeObserver(token) }

        let failed = manager.delete(capture) { _ in
            throw CocoaError(.fileWriteNoPermission)
        }

        XCTAssertFalse(failed)
        XCTAssertEqual(manager.captures.map(\.id), [capture.id])
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertEqual(historyDeletionCount, 0)

        XCTAssertTrue(manager.delete(capture))
        XCTAssertTrue(manager.captures.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertEqual(historyDeletionCount, 1)
    }

    // MARK: - Helpers

    private func makeQuickAccessCapture(image: CGImage, savedURL: URL) -> QuickAccessCapture {
        QuickAccessCapture(
            id: UUID(),
            recordID: UUID(),
            inMemoryImage: nil,
            thumbnail: image,
            mode: .area,
            timestamp: Date(),
            savedURL: savedURL,
            width: image.width,
            height: image.height,
            fileSize: 0,
            scale: 1
        )
    }

    private func makeSolidImage(width: Int, height: Int, red: UInt8, green: UInt8, blue: UInt8) -> CGImage {
        makeTwoBandImage(width: width, height: height, top: (red, green, blue), bottom: (red, green, blue))
    }

    private func makeTwoBandImage(
        width: Int,
        height: Int,
        top: (UInt8, UInt8, UInt8),
        bottom: (UInt8, UInt8, UInt8)
    ) -> CGImage {
        let bytesPerRow = width * 4
        var data = [UInt8](repeating: 0, count: height * bytesPerRow)
        for y in 0..<height {
            let color = y < height / 2 ? top : bottom
            for x in 0..<width {
                let index = y * bytesPerRow + x * 4
                data[index] = color.0
                data[index + 1] = color.1
                data[index + 2] = color.2
                data[index + 3] = 255
            }
        }

        let provider = CGDataProvider(data: Data(data) as CFData)!
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

    private func pixel(in image: CGImage, x: Int, y: Int) -> (red: UInt8, green: UInt8, blue: UInt8) {
        var data = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = CGContext(
            data: &data,
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bytesPerRow: image.width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let index = (y * image.width + x) * 4
        return (data[index], data[index + 1], data[index + 2])
    }

    private func rawPixel(in image: CGImage, x: Int, y: Int) -> (red: UInt8, green: UInt8, blue: UInt8) {
        let data = image.dataProvider?.data as Data?
        guard let data else { return (0, 0, 0) }
        let index = y * image.bytesPerRow + x * 4
        return (data[index], data[index + 1], data[index + 2])
    }
}
