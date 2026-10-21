import AppKit
import ImageIO
import XCTest
@testable import Captures

@MainActor
final class SelectionQuickEditorTests: XCTestCase {
    func testUneditedSelectionExportsFrozenPixelsWithoutCreatingDesktopCanvas() throws {
        let snapshot = makeSnapshot()
        let selection = CGRect(x: 40, y: 30, width: 160, height: 100)
        let editor = SelectionQuickEditor(snapshot: snapshot, selectionRect: selection, retinaScale: false)

        XCTAssertNil(editor.canvasState)
        XCTAssertEqual(editor.toolManager.currentTool, .textSelect)
        XCTAssertTrue(editor.canAdjustSelection)
        XCTAssertTrue(editor.canDirectlyMoveSelection)
        XCTAssertTrue(editor.canDirectlyAdjustSelection)
        XCTAssertTrue(editor.canStartLongCapture)
        assertImagesEqual(try XCTUnwrap(editor.exportImage()), try XCTUnwrap(snapshot.image(for: selection, retinaScale: false)))
        XCTAssertNil(editor.canvasState, "Copying without annotations must not allocate an entire desktop canvas")

        let moved = CGRect(x: 80, y: 70, width: 120, height: 80)
        XCTAssertTrue(editor.updateSelection(moved))
        XCTAssertEqual(editor.selectionRect, moved)
        assertImagesEqual(try XCTUnwrap(editor.exportImage()), try XCTUnwrap(snapshot.image(for: moved, retinaScale: false)))
        XCTAssertNil(editor.canvasState)
    }

    func testSelectionAdjustmentLocksWithFirstAnnotationAndUnlocksAfterUndo() throws {
        let snapshot = makeSnapshot()
        let editor = SelectionQuickEditor(
            snapshot: snapshot,
            selectionRect: CGRect(x: 40, y: 20, width: 160, height: 120),
            retinaScale: false
        )
        XCTAssertTrue(editor.selectTool(.rectangle))
        let state = try XCTUnwrap(editor.canvasState)
        let marker = makeMarker(rect: CGRect(x: 90, y: 60, width: 20, height: 20))
        state.addAnnotation(marker)
        XCTAssertFalse(editor.canStartLongCapture)
        XCTAssertFalse(editor.canAdjustSelection)
        assertExport(editor, matches: snapshot, marker: marker)

        let originalSelection = editor.selectionRect
        XCTAssertFalse(editor.updateSelection(CGRect(x: 60, y: 40, width: 120, height: 80)))
        XCTAssertEqual(editor.selectionRect, originalSelection)
        XCTAssertTrue(editor.canvasState === state)
        XCTAssertEqual(try XCTUnwrap(state.annotations.first as? RectangleAnnotation).rect, marker.rect)
        assertExport(editor, matches: snapshot, marker: marker)

        editor.undo()
        XCTAssertTrue(state.annotations.isEmpty)
        XCTAssertTrue(editor.canStartLongCapture)
        XCTAssertTrue(editor.canAdjustSelection)
        let resizedSelection = CGRect(x: 60, y: 40, width: 120, height: 80)
        XCTAssertTrue(editor.updateSelection(resizedSelection))
        XCTAssertEqual(editor.selectionRect, resizedSelection)
        assertImagesEqual(try XCTUnwrap(editor.exportImage()), try XCTUnwrap(snapshot.image(for: editor.selectionRect, retinaScale: false)))

        editor.redo()
        XCTAssertEqual(state.annotations.count, 1)
        XCTAssertFalse(editor.canStartLongCapture)
        XCTAssertFalse(editor.canAdjustSelection)
        assertExport(editor, matches: snapshot, marker: marker)

        XCTAssertFalse(editor.updateSelection(CGRect(x: 130, y: 40, width: 100, height: 80)))
        XCTAssertEqual(editor.selectionRect, resizedSelection)
    }

    func testMouseToolIsDefaultAndMovesOnlyAnUnannotatedSelection() throws {
        let snapshot = makeSnapshot()
        let initialSelection = CGRect(x: 40, y: 20, width: 160, height: 120)
        let movedSelection = CGRect(x: 70, y: 45, width: 160, height: 120)
        let editor = SelectionQuickEditor(
            snapshot: snapshot,
            selectionRect: initialSelection,
            retinaScale: false
        )

        XCTAssertEqual(editor.toolManager.currentTool, .textSelect)
        XCTAssertTrue(editor.canDirectlyMoveSelection,
                      "The default Mouse tool directly moves an unmarked crop")
        XCTAssertTrue(editor.updateSelection(movedSelection))
        XCTAssertEqual(editor.selectionRect, movedSelection)

        XCTAssertTrue(editor.selectTool(.rectangle))
        XCTAssertFalse(editor.canDirectlyMoveSelection,
                       "Choosing a drawing tool reserves the next drag for markup")
        XCTAssertFalse(editor.canDirectlyAdjustSelection,
                       "A rectangle must own a drag that starts on a crop corner")
        let state = try XCTUnwrap(editor.canvasState)
        state.addAnnotation(makeMarker(rect: CGRect(x: 100, y: 70, width: 20, height: 20)))
        XCTAssertTrue(editor.selectTool(.textSelect))
        XCTAssertFalse(editor.canDirectlyMoveSelection,
                       "Once a mark exists, Mouse edits marks and never moves the crop")
        XCTAssertFalse(editor.canDirectlyAdjustSelection)
        XCTAssertFalse(editor.updateSelection(initialSelection))

        editor.undo()
        XCTAssertTrue(editor.canDirectlyMoveSelection,
                      "Undoing back to zero marks restores direct crop movement")
        XCTAssertTrue(editor.canDirectlyAdjustSelection)
    }

    func testRetinaCropHasSamePixelsBeforeAndAfterQuickEditorInitialization() throws {
        let snapshot = makeSnapshot(scale: 2)
        let selection = CGRect(x: 40, y: 30, width: 120, height: 80)
        for retinaScale in [false, true] {
            let editor = SelectionQuickEditor(snapshot: snapshot, selectionRect: selection, retinaScale: retinaScale)
            let initial = try XCTUnwrap(editor.exportImage())
            XCTAssertEqual(initial.width, retinaScale ? 240 : 120)
            XCTAssertEqual(initial.height, retinaScale ? 160 : 80)
            XCTAssertTrue(editor.selectTool(.arrow))
            XCTAssertTrue(editor.canStartLongCapture, "Choosing a tool alone does not edit the capture")
            assertImagesEqual(try XCTUnwrap(editor.exportImage()), initial)
            try XCTUnwrap(editor.canvasState).addAnnotation(makeMarker(rect: CGRect(x: 4, y: 4, width: 4, height: 4)))
            assertImagesEqual(try XCTUnwrap(editor.exportImage()), initial)
        }
    }

    func testMixedScaleNegativeOriginDisplaysRetainCropScaleAndPixels() throws {
        let snapshot = FrozenScreenSnapshot(displays: [
            .init(frame: CGRect(x: -100, y: 0, width: 100, height: 100), image: makeImage(width: 200, height: 200) { _, _ in (255, 0, 0) }),
            .init(frame: CGRect(x: 0, y: 0, width: 100, height: 100), image: makeImage(width: 100, height: 100) { _, _ in (0, 0, 255) }),
        ])
        let editor = SelectionQuickEditor(
            snapshot: snapshot,
            selectionRect: CGRect(x: -20, y: 20, width: 40, height: 30),
            retinaScale: true
        )
        let spanning = try XCTUnwrap(editor.exportImage())
        XCTAssertEqual(spanning.width, 80)
        XCTAssertEqual(spanning.height, 60)
        XCTAssertTrue(editor.selectTool(.rectangle))
        assertImagesEqual(try XCTUnwrap(editor.exportImage()), spanning)
        // A mark outside this crop forces the annotation export path without
        // changing any of its expected frozen pixels.
        try XCTUnwrap(editor.canvasState).addAnnotation(makeMarker(rect: CGRect(x: 4, y: 4, width: 4, height: 4)))
        assertImagesEqual(try XCTUnwrap(editor.exportImage()), spanning)

        editor.undo()
        XCTAssertTrue(editor.canAdjustSelection)
        XCTAssertTrue(editor.updateSelection(CGRect(x: 20, y: 20, width: 40, height: 30)))
        let oneTimesOutput = try XCTUnwrap(editor.exportImage())
        XCTAssertEqual(oneTimesOutput.width, 40, "An unrelated Retina display must not change this display's export scale")
        XCTAssertEqual(oneTimesOutput.height, 30)
        assertImagesEqual(oneTimesOutput, try XCTUnwrap(snapshot.image(for: editor.selectionRect, retinaScale: true)))
    }

    func testCaptureViewportMapsSourcePixelsWithoutPaddingAndIgnoresZoomKeys() throws {
        let editor = SelectionQuickEditor(
            snapshot: makeSnapshot(scale: 2),
            selectionRect: CGRect(x: 40, y: 30, width: 120, height: 80),
            retinaScale: true
        )
        XCTAssertTrue(editor.selectTool(.rectangle))
        let canvas = try XCTUnwrap(editor.makeCanvasView())
        let window = makeWindow(canvas: canvas, size: editor.selectionRect.size)
        defer { window.close() }
        canvas.layoutSubtreeIfNeeded()
        let viewport = try XCTUnwrap(canvas.captureSelectionViewport)
        XCTAssertEqual(viewport, CGRect(x: 80, y: 60, width: 240, height: 160))
        XCTAssertEqual(canvas.canvasState.zoomLevel, 0.5, accuracy: 0.0001)
        XCTAssertEqual(canvas.canvasState.panOffset.x, -40, accuracy: 0.0001)
        XCTAssertEqual(canvas.canvasState.panOffset.y, -30, accuracy: 0.0001)

        let zoom = canvas.canvasState.zoomLevel
        let offset = canvas.canvasState.panOffset
        for (characters, keyCode) in [("+", UInt16(24)), ("-", UInt16(27)), ("0", UInt16(29))] {
            let event = try XCTUnwrap(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: characters,
                charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode
            ))
            canvas.keyDown(with: event)
            XCTAssertEqual(canvas.canvasState.zoomLevel, zoom, accuracy: 0.0001)
            XCTAssertEqual(canvas.canvasState.panOffset, offset)
        }
        let wheel = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: 30, wheel2: 12, wheel3: 0))
        canvas.scrollWheel(with: try XCTUnwrap(NSEvent(cgEvent: wheel)))
        XCTAssertEqual(canvas.canvasState.zoomLevel, zoom, accuracy: 0.0001)
        XCTAssertEqual(canvas.canvasState.panOffset, offset)
    }

    func testRepeatedOverlappingQuickAnnotationsKeepTheChosenTool() throws {
        for tool in [ToolType.arrow, .rectangle, .ellipse, .pencil, .pixelate] {
            let editor = SelectionQuickEditor(
                snapshot: makeSnapshot(),
                selectionRect: CGRect(x: 40, y: 30, width: 180, height: 140),
                retinaScale: false
            )
            XCTAssertTrue(editor.selectTool(tool))
            let canvas = try XCTUnwrap(editor.makeCanvasView())
            let window = makeWindow(canvas: canvas, size: editor.selectionRect.size)
            defer { window.close() }
            for count in 1...3 {
                canvas.mouseDown(with: try mouseEvent(.leftMouseDown, at: CGPoint(x: 70, y: 60), canvas: canvas))
                canvas.mouseDragged(with: try mouseEvent(.leftMouseDragged, at: CGPoint(x: 150, y: 100), canvas: canvas))
                canvas.mouseUp(with: try mouseEvent(.leftMouseUp, at: CGPoint(x: 150, y: 100), canvas: canvas))
                XCTAssertEqual(editor.toolManager.currentTool, tool)
                XCTAssertFalse(editor.canAdjustSelection)
                XCTAssertEqual(canvas.canvasState.annotations.count, count)
            }
        }
    }

    func testExportCommitsTheLiveInlineTextInsteadOfThePlaceholder() throws {
        let editor = SelectionQuickEditor(
            snapshot: makeSnapshot(),
            selectionRect: CGRect(x: 40, y: 30, width: 220, height: 150),
            retinaScale: false
        )
        XCTAssertTrue(editor.selectTool(.text))
        let canvas = try XCTUnwrap(editor.makeCanvasView())
        let window = makeWindow(canvas: canvas, size: editor.selectionRect.size)
        defer { window.close() }
        canvas.mouseDown(with: try mouseEvent(.leftMouseDown, at: CGPoint(x: 70, y: 70), canvas: canvas))
        canvas.mouseUp(with: try mouseEvent(.leftMouseUp, at: CGPoint(x: 70, y: 70), canvas: canvas))
        let textField = try XCTUnwrap(canvas.subviews.compactMap { $0 as? NSTextField }.first)
        textField.stringValue = "即时标注"
        XCTAssertNotNil(editor.exportImage())
        XCTAssertEqual(try XCTUnwrap(canvas.canvasState.annotations.first as? TextAnnotation).text, "即时标注")
        XCTAssertTrue(canvas.subviews.compactMap { $0 as? NSTextField }.isEmpty)
        XCTAssertEqual(editor.toolManager.currentTool, .text)
    }

    func testMosaicSamplesTheSelectedTopRegionNotTheMirroredBottomRegion() throws {
        let snapshot = FrozenScreenSnapshot(displays: [
            .init(frame: CGRect(x: 0, y: 0, width: 200, height: 200), image: makeImage(width: 200, height: 200) { _, row in
                row < 100 ? (255, 0, 0) : (0, 0, 255)
            }),
        ])
        let editor = SelectionQuickEditor(
            snapshot: snapshot,
            selectionRect: CGRect(x: 0, y: 100, width: 200, height: 100),
            retinaScale: false
        )
        XCTAssertTrue(editor.selectTool(.pixelate))
        let state = try XCTUnwrap(editor.canvasState)
        state.addAnnotation(PixelateAnnotation(
            rect: CGRect(x: 30, y: 130, width: 40, height: 40),
            blockSize: 8, sourceImage: state.baseImage
        ))
        let image = try XCTUnwrap(editor.exportImage())
        let pixels = rasterBytes(image)
        let bluePixels = stride(from: 0, to: pixels.count, by: 4).filter { pixels[$0 + 2] > 200 && pixels[$0] < 50 }.count
        XCTAssertEqual(bluePixels, 0, "Mosaic must sample the frozen pixels underneath its own on-screen rectangle")
    }

    func testCompactToolbarKeepsAllActionsWithinBoundsAtNarrowWidths() {
        for availableWidth: CGFloat in [140, 180, 320, 800] {
            let editor = SelectionQuickEditor(snapshot: makeSnapshot(), selectionRect: CGRect(x: 40, y: 30, width: 120, height: 80), retinaScale: false)
            let toolbar = SelectionQuickEditToolbar(editor: editor, onChoose: { _ in }, availableWidth: availableWidth)
            XCTAssertLessThanOrEqual(toolbar.preferredSize.width, availableWidth)
            let controls = toolbar.subviews.compactMap { $0 as? NSControl }
            XCTAssertGreaterThan(controls.count, 10)
            for control in controls {
                XCTAssertTrue(toolbar.bounds.contains(control.frame), "Clipped action at width \(availableWidth): \(control.toolTip ?? control.description)")
            }
        }
    }

    func testNativeQuickSelectionLightAndDarkSnapshotsAndToolbarActions() throws {
        for (name, appearanceName) in [("light", NSAppearance.Name.aqua), ("dark", NSAppearance.Name.darkAqua)] {
            let desktopSize = CGSize(width: 900, height: 620)
            let selectedRect = CGRect(x: 70, y: 100, width: 760, height: 410)
            let source = makeDocumentImage(size: desktopSize, dark: name == "dark")
            let snapshot = FrozenScreenSnapshot(displays: [.init(frame: CGRect(origin: .zero, size: desktopSize), image: source)])
            let editor = SelectionQuickEditor(snapshot: snapshot, selectionRect: selectedRect, retinaScale: false)
            var choices: [PostCaptureChoice?] = []
            let toolbar = SelectionQuickEditToolbar(editor: editor, onChoose: { choices.append($0) }, availableWidth: desktopSize.width - 16)
            let overlay = AreaSelectorOverlayView(frame: CGRect(origin: .zero, size: desktopSize))
            overlay.holdSelectionForResultChoice(frozenImage: source, visibleSelectionRect: selectedRect, selectionFrame: selectedRect)
            let window = NSWindow(contentRect: overlay.bounds, styleMask: .borderless, backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false
            defer { window.close() }
            window.appearance = try XCTUnwrap(NSAppearance(named: appearanceName))
            window.contentView = overlay
            toolbar.frame = SelectionQuickEditToolbar.anchoredFrame(to: selectedRect, size: toolbar.preferredSize, within: overlay.bounds)
            overlay.addSubview(toolbar)

            let mouse = try toolButton(.textSelect, in: toolbar)
            let rectangle = try toolButton(.rectangle, in: toolbar)
            XCTAssertEqual(editor.toolManager.currentTool, .textSelect)
            XCTAssertEqual(mouse.state, .on, "Mouse is the default quick-markup tool")
            XCTAssertEqual(rectangle.state, .off)
            XCTAssertNil(toolbar.subviews.compactMap { $0 as? NSButton }.first {
                $0.action == NSSelectorFromString("adjust")
                    || $0.toolTip == Localization.string("Adjust Selection")
            }, "Selection resizing is direct manipulation and must not occupy a toolbar button")
            rectangle.performClick(nil)
            XCTAssertEqual(editor.toolManager.currentTool, .rectangle)
            XCTAssertEqual(rectangle.state, .on)
            XCTAssertEqual(mouse.state, .off)
            let canvas = try XCTUnwrap(editor.makeCanvasView())
            canvas.frame = selectedRect
            overlay.addSubview(canvas, positioned: .below, relativeTo: toolbar)
            try drawStroke(from: CGPoint(x: 88, y: 325), to: CGPoint(x: 556, y: 378), canvas: canvas)
            XCTAssertEqual(canvas.canvasState.annotations.count, 1)

            let undo = try actionButton("undo", in: toolbar)
            let redo = try actionButton("redo", in: toolbar)
            let longCapture = try actionButton("longCapture", in: toolbar)
            XCTAssertTrue(undo.isEnabled)
            XCTAssertFalse(longCapture.isEnabled)
            longCapture.performClick(nil)
            XCTAssertTrue(choices.isEmpty, "Disabled long capture must not discard annotations or route a result")
            undo.performClick(nil)
            XCTAssertTrue(canvas.canvasState.annotations.isEmpty)
            XCTAssertTrue(longCapture.isEnabled)
            XCTAssertTrue(redo.isEnabled)
            redo.performClick(nil)
            XCTAssertEqual(canvas.canvasState.annotations.count, 1)
            XCTAssertFalse(longCapture.isEnabled)

            let arrow = try toolButton(.arrow, in: toolbar)
            arrow.performClick(nil)
            XCTAssertEqual(arrow.state, .on)
            XCTAssertEqual(rectangle.state, .off)
            try drawStroke(from: CGPoint(x: 710, y: 422), to: CGPoint(x: 569, y: 354), canvas: canvas)
            let text = try toolButton(.text, in: toolbar)
            text.performClick(nil)
            canvas.mouseDown(with: try mouseEvent(.leftMouseDown, at: CGPoint(x: 590, y: 260), canvas: canvas))
            canvas.mouseUp(with: try mouseEvent(.leftMouseUp, at: CGPoint(x: 590, y: 260), canvas: canvas))
            let textField = try XCTUnwrap(canvas.subviews.compactMap { $0 as? NSTextField }.first)
            textField.stringValue = "Review this section"
            editor.commitPendingEdits()
            XCTAssertEqual(canvas.canvasState.annotations.count, 3)
            XCTAssertEqual(text.state, .on)
            XCTAssertFalse(longCapture.isEnabled)
            rectangle.performClick(nil)
            XCTAssertEqual(rectangle.state, .on)
            XCTAssertEqual(text.state, .off)
            XCTAssertTrue(overlay.bounds.contains(toolbar.frame))
            XCTAssertFalse(toolbar.frame.intersects(selectedRect))
            XCTAssertGreaterThan(toolbar.frame.minY, selectedRect.maxY)
            try attachSnapshot(of: overlay, named: "native-quick-selection-\(name)-900x620")

            try actionButton("copyCapture", in: toolbar).performClick(nil)
            XCTAssertEqual(choices, [.clipboard])
            let output = try XCTUnwrap(editor.exportImage())
            XCTAssertEqual(output.width, Int(selectedRect.width))
            XCTAssertEqual(output.height, Int(selectedRect.height))
        }
    }

    func testNativeQuickToolbarFallsBelowSmallTopEdgeSelectionWithoutCoveringIt() throws {
        let desktopSize = CGSize(width: 420, height: 620)
        let selectedRect = CGRect(x: 246, y: 470, width: 164, height: 140)
        let source = makeDocumentImage(size: desktopSize, dark: false)
        let snapshot = FrozenScreenSnapshot(displays: [.init(frame: CGRect(origin: .zero, size: desktopSize), image: source)])
        let editor = SelectionQuickEditor(snapshot: snapshot, selectionRect: selectedRect, retinaScale: false)
        let toolbar = SelectionQuickEditToolbar(editor: editor, onChoose: { _ in }, availableWidth: desktopSize.width - 16)
        let overlay = AreaSelectorOverlayView(frame: CGRect(origin: .zero, size: desktopSize))
        overlay.holdSelectionForResultChoice(frozenImage: source, visibleSelectionRect: selectedRect, selectionFrame: selectedRect)
        let window = NSWindow(contentRect: overlay.bounds, styleMask: .borderless, backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.appearance = try XCTUnwrap(NSAppearance(named: .aqua))
        window.contentView = overlay
        toolbar.frame = SelectionQuickEditToolbar.anchoredFrame(to: selectedRect, size: toolbar.preferredSize, within: overlay.bounds)
        overlay.addSubview(toolbar)
        XCTAssertTrue(overlay.bounds.insetBy(dx: 8, dy: 8).contains(toolbar.frame))
        XCTAssertLessThan(toolbar.frame.maxY, selectedRect.minY)
        XCTAssertFalse(toolbar.frame.intersects(selectedRect), "A tiny top-edge crop must stay unobscured when the toolbar fits below it")
        for control in toolbar.subviews.compactMap({ $0 as? NSControl }) {
            XCTAssertTrue(toolbar.bounds.contains(control.frame))
        }
        try attachSnapshot(of: overlay, named: "native-quick-selection-small-top-edge-420x620")
    }

    func testQuickSelectionKeyboardLeavesTextInputWithTheFieldEditor() throws {
        let editor = SelectionQuickEditor(snapshot: makeSnapshot(), selectionRect: CGRect(x: 40, y: 30, width: 220, height: 150), retinaScale: false)
        XCTAssertTrue(editor.selectTool(.text))
        let canvas = try XCTUnwrap(editor.makeCanvasView())
        let window = makeWindow(canvas: canvas, size: editor.selectionRect.size)
        defer { window.close() }
        let textInput = NSTextView(frame: CGRect(x: 10, y: 10, width: 180, height: 35))
        canvas.addSubview(textInput)
        XCTAssertTrue(window.makeFirstResponder(textInput))
        var choices: [PostCaptureChoice?] = []
        for (characters, keyCode) in [("a", UInt16(0)), ("r", UInt16(15)), ("c", UInt16(8)), ("\r", UInt16(36))] {
            let event = try XCTUnwrap(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: characters,
                charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode
            ))
            XCTAssertFalse(editor.handleKey(event, choose: { choices.append($0) }))
            XCTAssertEqual(editor.toolManager.currentTool, .text)
        }
        XCTAssertTrue(choices.isEmpty)
        XCTAssertTrue(window.makeFirstResponder(canvas))
        let escape = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "\u{1B}",
            charactersIgnoringModifiers: "\u{1B}", isARepeat: false, keyCode: 53
        ))
        XCTAssertTrue(editor.handleKey(escape, choose: { choices.append($0) }))
        XCTAssertEqual(choices.count, 1)
        XCTAssertNil(choices[0])
    }

    func testCancelProvisionalQuickTextPreservesExistingRedoWithoutGhosts() throws {
        let editor = SelectionQuickEditor(snapshot: makeSnapshot(), selectionRect: CGRect(x: 40, y: 30, width: 220, height: 150), retinaScale: false)
        XCTAssertTrue(editor.selectTool(.rectangle))
        let state = try XCTUnwrap(editor.canvasState)
        let marker = makeMarker(rect: CGRect(x: 70, y: 70, width: 30, height: 20))
        state.addAnnotation(marker)
        editor.undo()
        XCTAssertTrue(state.undoManager.canRedo)
        XCTAssertTrue(editor.selectTool(.text))
        XCTAssertTrue(editor.toolManager.defersTextUndoUntilCommit)
        let canvas = try XCTUnwrap(editor.makeCanvasView())
        let window = makeWindow(canvas: canvas, size: editor.selectionRect.size)
        defer { window.close() }
        let field = try beginText(at: CGPoint(x: 130, y: 90), canvas: canvas)
        XCTAssertEqual(try XCTUnwrap(state.annotations.first as? TextAnnotation).text, "")
        XCTAssertFalse(state.undoManager.canUndo)
        XCTAssertTrue(state.undoManager.canRedo)
        let fieldEditor = try nativeFieldEditor(for: field, in: window)
        field.stringValue = "Discard this draft"
        XCTAssertTrue(canvas.control(field, textView: fieldEditor, doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        XCTAssertTrue(state.annotations.isEmpty)
        XCTAssertTrue(editor.canStartLongCapture)
        XCTAssertFalse(state.undoManager.canUndo)
        XCTAssertTrue(state.undoManager.canRedo)
        editor.redo()
        XCTAssertEqual(state.annotations.count, 1)
        XCTAssertEqual(state.annotations.first?.id, marker.id)
        XCTAssertFalse(state.annotations.contains { $0 is TextAnnotation })
    }

    func testBlankQuickTextCommitLeavesNoAnnotationOrUndoEntry() throws {
        for blank in ["", "   \n  "] {
            let snapshot = makeSnapshot()
            let editor = SelectionQuickEditor(snapshot: snapshot, selectionRect: CGRect(x: 40, y: 30, width: 220, height: 150), retinaScale: false)
            XCTAssertTrue(editor.selectTool(.text))
            let canvas = try XCTUnwrap(editor.makeCanvasView())
            let window = makeWindow(canvas: canvas, size: editor.selectionRect.size)
            defer { window.close() }
            let field = try beginText(at: CGPoint(x: 70, y: 70), canvas: canvas)
            field.stringValue = blank
            let exported = try XCTUnwrap(editor.exportImage())
            XCTAssertTrue(canvas.canvasState.annotations.isEmpty)
            XCTAssertFalse(canvas.canvasState.undoManager.canUndo)
            XCTAssertFalse(canvas.canvasState.undoManager.canRedo)
            XCTAssertTrue(editor.canStartLongCapture)
            editor.undo()
            editor.redo()
            XCTAssertTrue(canvas.canvasState.annotations.isEmpty)
            assertImagesEqual(exported, try XCTUnwrap(snapshot.image(for: editor.selectionRect, retinaScale: false)))
        }
    }

    func testReturnCommitsNewQuickTextAsOneUndoableAnnotation() throws {
        let editor = SelectionQuickEditor(snapshot: makeSnapshot(), selectionRect: CGRect(x: 40, y: 30, width: 220, height: 150), retinaScale: false)
        XCTAssertTrue(editor.selectTool(.text))
        let canvas = try XCTUnwrap(editor.makeCanvasView())
        let window = makeWindow(canvas: canvas, size: editor.selectionRect.size)
        defer { window.close() }
        let field = try beginText(at: CGPoint(x: 70, y: 70), canvas: canvas)
        let fieldEditor = try nativeFieldEditor(for: field, in: window)
        field.stringValue = "需要确认的内容"
        XCTAssertTrue(canvas.control(field, textView: fieldEditor, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        XCTAssertEqual(try XCTUnwrap(canvas.canvasState.annotations.first as? TextAnnotation).text, "需要确认的内容")
        XCTAssertTrue(canvas.canvasState.undoManager.canUndo)
        XCTAssertFalse(canvas.canvasState.undoManager.canRedo)
        XCTAssertTrue(canvas.subviews.compactMap { $0 as? NSTextField }.isEmpty)
        editor.undo()
        XCTAssertTrue(canvas.canvasState.annotations.isEmpty, "One undo must remove the complete text, not restore a placeholder")
        XCTAssertFalse(canvas.canvasState.undoManager.canUndo)
        editor.redo()
        XCTAssertEqual(canvas.canvasState.annotations.count, 1)
        XCTAssertEqual(try XCTUnwrap(canvas.canvasState.annotations.first as? TextAnnotation).text, "需要确认的内容")
        XCTAssertEqual(editor.toolManager.currentTool, .text)
    }

    func testForwardedPointerReleaseKeepsQuickTextFieldFocused() throws {
        let editor = SelectionQuickEditor(snapshot: makeSnapshot(), selectionRect: CGRect(x: 40, y: 30, width: 220, height: 150), retinaScale: false)
        XCTAssertTrue(editor.selectTool(.text))
        let canvas = try XCTUnwrap(editor.makeCanvasView())
        let window = makeWindow(canvas: canvas, size: editor.selectionRect.size)
        defer { window.close() }

        let point = CGPoint(x: 70, y: 70)
        canvas.handleQuickMarkupPointerEvent(try mouseEvent(.leftMouseDown, at: point, canvas: canvas))
        let field = try XCTUnwrap(canvas.subviews.compactMap { $0 as? NSTextField }.first)
        let fieldEditor = try nativeFieldEditor(for: field, in: window)
        XCTAssertTrue(editor.isEditingInlineText)

        // This is the same forwarded release that previously forced the
        // canvas back to first responder and destroyed an empty text draft.
        canvas.handleQuickMarkupPointerEvent(try mouseEvent(.leftMouseUp, at: point, canvas: canvas))
        XCTAssertTrue(editor.isEditingInlineText)
        XCTAssertTrue(field.superview === canvas)
        XCTAssertTrue(window.firstResponder === field || window.firstResponder === fieldEditor)

        var choices: [PostCaptureChoice?] = []
        let toolKey = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, characters: "r",
            charactersIgnoringModifiers: "r", isARepeat: false, keyCode: 15
        ))
        XCTAssertFalse(editor.handleKey(toolKey, choose: { choices.append($0) }))
        XCTAssertTrue(choices.isEmpty)
        XCTAssertEqual(editor.toolManager.currentTool, .text)

        field.stringValue = "可以继续输入"
        XCTAssertTrue(canvas.control(field, textView: fieldEditor, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        XCTAssertEqual(try XCTUnwrap(canvas.canvasState.annotations.first as? TextAnnotation).text, "可以继续输入")
    }

    func testMarkedTextKeepsReturnAndEscapeWithTheInputMethodUntilCommitted() throws {
        let editor = SelectionQuickEditor(snapshot: makeSnapshot(), selectionRect: CGRect(x: 40, y: 30, width: 220, height: 150), retinaScale: false)
        XCTAssertTrue(editor.selectTool(.text))
        let canvas = try XCTUnwrap(editor.makeCanvasView())
        let window = makeWindow(canvas: canvas, size: editor.selectionRect.size)
        defer { window.close() }
        let field = try beginText(at: CGPoint(x: 70, y: 70), canvas: canvas)
        let fieldEditor = try nativeFieldEditor(for: field, in: window)
        fieldEditor.setMarkedText("zhongwen", selectedRange: NSRange(location: 8, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(fieldEditor.hasMarkedText())
        for command in [#selector(NSResponder.insertNewline(_:)), #selector(NSResponder.cancelOperation(_:))] {
            XCTAssertFalse(canvas.control(field, textView: fieldEditor, doCommandBy: command))
            XCTAssertTrue(fieldEditor.hasMarkedText())
            XCTAssertTrue(field.superview === canvas)
            XCTAssertEqual(canvas.canvasState.annotations.count, 1)
            XCTAssertEqual(try XCTUnwrap(canvas.canvasState.annotations.first as? TextAnnotation).text, "")
            XCTAssertFalse(canvas.canvasState.undoManager.canUndo)
        }
        fieldEditor.unmarkText()
        field.stringValue = "中文"
        XCTAssertTrue(canvas.control(field, textView: fieldEditor, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        XCTAssertEqual(try XCTUnwrap(canvas.canvasState.annotations.first as? TextAnnotation).text, "中文")
        editor.undo()
        XCTAssertTrue(canvas.canvasState.annotations.isEmpty)
    }

    func testFullEditorTextCreationKeepsItsExistingImmediateUndoContract() throws {
        let state = CanvasState(image: try XCTUnwrap(makeSnapshot().image(for: CGRect(x: 0, y: 0, width: 320, height: 240), retinaScale: false)))
        let tool = ToolManager()
        XCTAssertFalse(tool.defersTextUndoUntilCommit)
        tool.currentTool = .text
        tool.mouseDown(at: CGPoint(x: 40, y: 60), canvasState: state)
        XCTAssertEqual(try XCTUnwrap(state.annotations.first as? TextAnnotation).text, "Text")
        XCTAssertTrue(state.undoManager.canUndo)
        state.undoManager.undo(state: state)
        XCTAssertTrue(state.annotations.isEmpty)
        state.undoManager.redo(state: state)
        XCTAssertEqual(try XCTUnwrap(state.annotations.first as? TextAnnotation).text, "Text")
    }

    func testRebuildingToolbarForNarrowDisplayPreservesSessionAndRedoHistory() throws {
        let editor = SelectionQuickEditor(snapshot: makeSnapshot(), selectionRect: CGRect(x: 40, y: 30, width: 220, height: 150), retinaScale: false)
        let wide = SelectionQuickEditToolbar(editor: editor, onChoose: { _ in }, availableWidth: 800)
        XCTAssertEqual(wide.preferredSize, SelectionQuickEditToolbar.size(for: 800))
        try toolButton(.arrow, in: wide).performClick(nil)
        editor.setColor(.systemBlue)
        editor.setSize(5)
        let canvas = try XCTUnwrap(editor.makeCanvasView())
        let state = canvas.canvasState
        let window = makeWindow(canvas: canvas, size: editor.selectionRect.size)
        defer { window.close() }
        try drawStroke(from: CGPoint(x: 70, y: 70), to: CGPoint(x: 170, y: 120), canvas: canvas)
        let markedImage = try XCTUnwrap(editor.exportImage())
        try actionButton("undo", in: wide).performClick(nil)
        XCTAssertTrue(state.annotations.isEmpty)
        XCTAssertTrue(state.undoManager.canRedo)

        let narrow = SelectionQuickEditToolbar(editor: editor, onChoose: { _ in }, availableWidth: 320)
        XCTAssertEqual(narrow.preferredSize, SelectionQuickEditToolbar.size(for: 320))
        XCTAssertLessThan(narrow.preferredSize.width, wide.preferredSize.width)
        XCTAssertTrue(editor.canvasState === state)
        XCTAssertEqual(editor.toolManager.currentTool, .arrow)
        XCTAssertTrue(editor.toolManager.strokeColor.isEqual(NSColor.systemBlue))
        XCTAssertEqual(editor.sizeInPoints, 5, accuracy: 0.001)
        XCTAssertEqual(try toolButton(.arrow, in: narrow).state, .on)
        let color = try XCTUnwrap(narrow.subviews.compactMap { $0 as? NSPopUpButton }.first { $0.action == NSSelectorFromString("changeColor") })
        XCTAssertEqual(color.indexOfSelectedItem, 2)
        let size = try XCTUnwrap(narrow.subviews.compactMap { $0 as? NSPopUpButton }.first { $0.action == NSSelectorFromString("changeSize") })
        XCTAssertEqual(size.titleOfSelectedItem, "5")
        let redo = try actionButton("redo", in: narrow)
        XCTAssertTrue(redo.isEnabled)
        redo.performClick(nil)
        XCTAssertEqual(state.annotations.count, 1)
        XCTAssertEqual(try XCTUnwrap(state.annotations.first as? ArrowAnnotation).strokeWidth, 5)
        XCTAssertTrue(try XCTUnwrap(state.annotations.first as? ArrowAnnotation).color.isEqual(NSColor.systemBlue))
        assertImagesEqual(try XCTUnwrap(editor.exportImage()), markedImage)
        XCTAssertFalse(try actionButton("longCapture", in: narrow).isEnabled)
        XCTAssertTrue(try actionButton("undo", in: narrow).isEnabled)
    }

    func testDownloadButtonWritesAnnotatedPNGWithoutOpeningEditorOrPreview() async throws {
        let directory = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("captures-quick-download-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let suiteName = "SelectionQuickEditorTests.download.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let appState = AppState(defaults: defaults)
        let notificationCenter = NotificationCenter()
        let coordinator = CaptureCoordinator(
            appState: appState, notificationCenter: notificationCenter,
            recoveryDirectory: directory.appendingPathComponent("recovery", isDirectory: true),
            previewCacheDirectory: directory.appendingPathComponent("preview", isDirectory: true)
        )
        let original = CaptureOptions(
            playSound: false, copyToClipboard: true, resultMode: .ask, saveToFile: false,
            format: .png, saveDirectory: directory, filenamePattern: "quick-markup-download",
            includeShadow: false, retina2x: false
        )
        let savedDefaults = defaults.persistentDomain(forName: suiteName) ?? [:]
        let completed = expectation(description: "Annotated Download completes actual PNG output")
        var completedInfo: CaptureCompletedInfo?
        var previewNotifications = 0
        var editorNotifications = 0
        let outputToken = notificationCenter.addObserver(forName: .captureCompleted, object: nil, queue: .main) { notification in
            completedInfo = notification.object as? CaptureCompletedInfo
            completed.fulfill()
        }
        let previewToken = notificationCenter.addObserver(forName: .showFloatingCapture, object: nil, queue: .main) { _ in previewNotifications += 1 }
        let editorToken = NotificationCenter.default.addObserver(forName: .editorWillOpen, object: nil, queue: .main) { _ in editorNotifications += 1 }
        defer {
            notificationCenter.removeObserver(outputToken)
            notificationCenter.removeObserver(previewToken)
            NotificationCenter.default.removeObserver(editorToken)
        }

        let editor = SelectionQuickEditor(snapshot: makeSnapshot(), selectionRect: CGRect(x: 40, y: 30, width: 220, height: 150), retinaScale: false)
        var chosenActions: [PostCaptureChoice?] = []
        var expectedImage: CGImage?
        let toolbar = SelectionQuickEditToolbar(editor: editor, onChoose: { choice in
            chosenActions.append(choice)
            guard choice == .save, let mode = choice?.resultMode, let image = editor.exportImage() else {
                XCTFail("Download must provide a composited image and the file route")
                return
            }
            let routed = PostCaptureRoutingPolicy.resolvedOptions(from: original, choice: mode)
            XCTAssertEqual(routed.resultMode, .file)
            XCTAssertTrue(routed.saveToFile)
            XCTAssertFalse(routed.copyToClipboard)
            // If routing regresses, fail safely rather than touching the
            // user's clipboard or creating a real editor/preview window.
            guard routed.resultMode == .file, routed.saveToFile, !routed.copyToClipboard else { return }
            expectedImage = image
            coordinator.finishCapture(result: CaptureResult(
                image: image, mode: .area, timestamp: Date(), sourceRect: editor.selectionRect,
                windowName: nil, applicationName: nil, scale: 1
            ), options: routed)
        }, availableWidth: 800)
        try toolButton(.rectangle, in: toolbar).performClick(nil)
        let canvas = try XCTUnwrap(editor.makeCanvasView())
        let window = makeWindow(canvas: canvas, size: editor.selectionRect.size)
        defer { window.close() }
        try drawStroke(from: CGPoint(x: 70, y: 70), to: CGPoint(x: 170, y: 120), canvas: canvas)
        XCTAssertEqual(canvas.canvasState.annotations.count, 1)
        XCTAssertFalse(try actionButton("longCapture", in: toolbar).isEnabled)
        let download = try actionButton("downloadCapture", in: toolbar)
        XCTAssertTrue(download.isEnabled, "Download stays available while annotations exist")
        download.performClick(nil)
        await fulfillment(of: [completed], timeout: 5)

        XCTAssertEqual(chosenActions, [.save])
        let info = try XCTUnwrap(completedInfo)
        let savedURL = try XCTUnwrap(info.savedURL)
        XCTAssertEqual(savedURL.deletingLastPathComponent().standardizedFileURL, directory.standardizedFileURL)
        XCTAssertEqual(savedURL.lastPathComponent, "quick-markup-download.png")
        XCTAssertEqual(info.resultMode, .file)
        XCTAssertNil(info.managedPreviewURL)
        XCTAssertNil(info.saveFailure)
        XCTAssertGreaterThan(info.fileSize, 0)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(savedURL as CFURL, nil))
        let savedImage = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        assertImagesEqual(savedImage, try XCTUnwrap(expectedImage))
        XCTAssertEqual(previewNotifications, 0)
        XCTAssertEqual(editorNotifications, 0)
        XCTAssertEqual(original.resultMode, .ask)
        XCTAssertFalse(original.saveToFile)
        XCTAssertTrue(original.copyToClipboard)
        XCTAssertEqual(original.saveDirectory, directory)
        XCTAssertTrue(NSDictionary(dictionary: defaults.persistentDomain(forName: suiteName) ?? [:]).isEqual(to: savedDefaults))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("preview").path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["quick-markup-download.png"])
    }

    func testDownloadAndCopyStayVisibleAndOrderedOnNarrowToolbars() throws {
        for availableWidth: CGFloat in [140, 180, 260, 320, 420, 800] {
            let editor = SelectionQuickEditor(snapshot: makeSnapshot(), selectionRect: CGRect(x: 40, y: 30, width: 220, height: 150), retinaScale: false)
            let toolbar = SelectionQuickEditToolbar(editor: editor, onChoose: { _ in }, availableWidth: availableWidth)
            let pin = try actionButton("pin", in: toolbar)
            let download = try actionButton("downloadCapture", in: toolbar)
            let copy = try actionButton("copyCapture", in: toolbar)
            for control in [pin, download, copy] {
                XCTAssertTrue(toolbar.bounds.contains(control.frame), "Result action clipped at width \(availableWidth)")
            }
            XCTAssertTrue(precedes(pin.frame, download.frame))
            XCTAssertTrue(precedes(download.frame, copy.frame))
            XCTAssertFalse(download.frame.intersects(copy.frame))
            if toolbar.preferredSize.width >= 7 * 34 + 12 {
                XCTAssertEqual(copy.frame.maxX, toolbar.bounds.maxX - 8, accuracy: 0.001, "Copy remains the rightmost grouped result action")
            }
            XCTAssertEqual(download.toolTip, Localization.string("Download"))
            XCTAssertNotNil(download.image)
        }
    }

    func testCommandSDownloadsOnlyWhenTextInputDoesNotOwnTheEvent() throws {
        let editor = SelectionQuickEditor(snapshot: makeSnapshot(), selectionRect: CGRect(x: 40, y: 30, width: 220, height: 150), retinaScale: false)
        XCTAssertTrue(editor.selectTool(.text))
        let canvas = try XCTUnwrap(editor.makeCanvasView())
        let window = makeWindow(canvas: canvas, size: editor.selectionRect.size)
        defer { window.close() }
        let input = NSTextView(frame: CGRect(x: 10, y: 10, width: 180, height: 35))
        canvas.addSubview(input)
        XCTAssertTrue(window.makeFirstResponder(input))
        var choices: [PostCaptureChoice?] = []
        func saveKey(modifiers: NSEvent.ModifierFlags) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: "s",
                charactersIgnoringModifiers: "s", isARepeat: false, keyCode: 1
            ))
        }
        for composing in [false, true] {
            if composing { input.setMarkedText("shi", selectedRange: NSRange(location: 3, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0)) }
            XCTAssertFalse(editor.handleKey(try saveKey(modifiers: [.command]), choose: { choices.append($0) }))
            XCTAssertTrue(choices.isEmpty)
            XCTAssertEqual(editor.toolManager.currentTool, .text)
        }
        input.unmarkText()
        XCTAssertTrue(window.makeFirstResponder(canvas))
        XCTAssertFalse(editor.handleKey(try saveKey(modifiers: []), choose: { choices.append($0) }))
        XCTAssertFalse(editor.handleKey(try saveKey(modifiers: [.control]), choose: { choices.append($0) }))
        XCTAssertTrue(choices.isEmpty)
        XCTAssertTrue(editor.handleKey(try saveKey(modifiers: [.command]), choose: { choices.append($0) }))
        XCTAssertEqual(choices, [.save])
    }

    private func precedes(_ first: CGRect, _ second: CGRect) -> Bool {
        first.minY > second.minY || (first.minY == second.minY && first.maxX <= second.minX)
    }

    private func beginText(at point: CGPoint, canvas: CanvasNSView) throws -> NSTextField {
        canvas.mouseDown(with: try mouseEvent(.leftMouseDown, at: point, canvas: canvas))
        canvas.mouseUp(with: try mouseEvent(.leftMouseUp, at: point, canvas: canvas))
        return try XCTUnwrap(canvas.subviews.compactMap { $0 as? NSTextField }.first)
    }

    private func nativeFieldEditor(for field: NSTextField, in window: NSWindow) throws -> NSTextView {
        if let current = field.currentEditor() as? NSTextView { return current }
        // AppKit still supplies its real shared field editor to a non-key test
        // window; no fake input-method object is needed for delegate commands.
        return try XCTUnwrap(window.fieldEditor(true, for: field) as? NSTextView)
    }

    private func actionButton(_ selector: String, in toolbar: SelectionQuickEditToolbar) throws -> NSButton {
        try XCTUnwrap(toolbar.subviews.compactMap { $0 as? NSButton }.first { $0.action == NSSelectorFromString(selector) })
    }

    private func toolButton(_ tool: ToolType, in toolbar: SelectionQuickEditToolbar) throws -> NSButton {
        try XCTUnwrap(toolbar.subviews.compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == tool.rawValue })
    }

    private func drawStroke(from start: CGPoint, to end: CGPoint, canvas: CanvasNSView) throws {
        canvas.mouseDown(with: try mouseEvent(.leftMouseDown, at: start, canvas: canvas))
        canvas.mouseDragged(with: try mouseEvent(.leftMouseDragged, at: end, canvas: canvas))
        canvas.mouseUp(with: try mouseEvent(.leftMouseUp, at: end, canvas: canvas))
    }

    private func attachSnapshot(of view: NSView, named name: String) throws {
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let image = NSImage(size: view.bounds.size)
        image.addRepresentation(bitmap)
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func makeDocumentImage(size: CGSize, dark: Bool) -> CGImage {
        let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
                                bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        defer { NSGraphicsContext.restoreGraphicsState() }
        let background = dark ? NSColor(srgbRed: 0.11, green: 0.12, blue: 0.14, alpha: 1) : NSColor(srgbRed: 0.94, green: 0.95, blue: 0.97, alpha: 1)
        let paper = dark ? NSColor(srgbRed: 0.17, green: 0.18, blue: 0.20, alpha: 1) : NSColor.white
        let primary = dark ? NSColor(srgbRed: 0.92, green: 0.93, blue: 0.95, alpha: 1) : NSColor(srgbRed: 0.13, green: 0.14, blue: 0.16, alpha: 1)
        let secondary = dark ? NSColor(srgbRed: 0.66, green: 0.69, blue: 0.73, alpha: 1) : NSColor(srgbRed: 0.40, green: 0.43, blue: 0.48, alpha: 1)
        background.setFill()
        NSBezierPath(rect: CGRect(origin: .zero, size: size)).fill()
        paper.setFill()
        NSBezierPath(roundedRect: CGRect(x: 48, y: 55, width: size.width - 96, height: size.height - 110), xRadius: 12, yRadius: 12).fill()
        func text(_ value: String, x: CGFloat, y: CGFloat, fontSize: CGFloat = 14, bold: Bool = false, muted: Bool = false) {
            (value as NSString).draw(at: CGPoint(x: x, y: y), withAttributes: [
                .font: NSFont.systemFont(ofSize: fontSize, weight: bold ? .semibold : .regular),
                .foregroundColor: muted ? secondary : primary,
            ])
        }
        text("Project review", x: 88, y: 487, fontSize: 25, bold: true)
        text("Capture a region. Add a note. Share when ready.", x: 88, y: 456, muted: true)
        text("Release readiness", x: 88, y: 411, fontSize: 16, bold: true)
        text("Item", x: 101, y: 382, fontSize: 12, bold: true, muted: true)
        text("Status", x: 410, y: 382, fontSize: 12, bold: true, muted: true)
        for (row, values) in [("Selection & annotations", "Ready"), ("Keyboard shortcuts", "Review"), ("Export quality", "Ready")].enumerated() {
            let y = CGFloat(349 - row * 42)
            context.setStrokeColor(secondary.withAlphaComponent(0.16).cgColor)
            context.move(to: CGPoint(x: 88, y: y - 10))
            context.addLine(to: CGPoint(x: min(size.width - 88, 554), y: y - 10))
            context.strokePath()
            text(values.0, x: 101, y: y)
            text(values.1, x: 410, y: y, muted: true)
        }
        text("Notes", x: 88, y: 214, fontSize: 16, bold: true)
        text("Keep the original image clear and the editing controls nearby.", x: 88, y: 183, muted: true)
        text("All content in this sample is fictional.", x: 88, y: 140, fontSize: 12, muted: true)
        return context.makeImage()!
    }

    private func assertExport(_ editor: SelectionQuickEditor, matches snapshot: FrozenScreenSnapshot, marker: RectangleAnnotation, file: StaticString = #filePath, line: UInt = #line) {
        guard let source = snapshot.image(for: editor.selectionRect, retinaScale: false), let actual = editor.exportImage() else {
            XCTFail("Missing output image", file: file, line: line)
            return
        }
        let expected = CanvasState(image: source)
        expected.annotations = [makeMarker(rect: marker.rect.offsetBy(dx: -editor.selectionRect.minX, dy: -editor.selectionRect.minY))]
        guard let expectedImage = expected.renderFinalImage() else {
            XCTFail("Missing reference image", file: file, line: line)
            return
        }
        assertImagesEqual(actual, expectedImage, file: file, line: line)
    }

    private func makeMarker(rect: CGRect) -> RectangleAnnotation {
        RectangleAnnotation(rect: rect, strokeColor: .red, fillColor: .red, strokeWidth: 2)
    }

    private func makeSnapshot(scale: Int = 1) -> FrozenScreenSnapshot {
        FrozenScreenSnapshot(displays: [
            .init(frame: CGRect(x: 0, y: 0, width: 320, height: 240), image: makeImage(width: 320 * scale, height: 240 * scale) { column, row in
                let x = column / scale
                let y = row / scale
                return (UInt8(180 + x / 8), UInt8(160 + y / 8), 210)
            }),
        ])
    }

    private func makeImage(width: Int, height: Int, color: (Int, Int) -> (UInt8, UInt8, UInt8)) -> CGImage {
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for row in 0..<height {
            for column in 0..<width {
                let (red, green, blue) = color(column, row)
                let index = (row * width + column) * 4
                pixels[index] = red
                pixels[index + 1] = green
                pixels[index + 2] = blue
            }
        }
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: CGDataProvider(data: Data(pixels) as CFData)!, decode: nil,
            shouldInterpolate: false, intent: .defaultIntent
        )!
    }

    private func makeWindow(canvas: CanvasNSView, size: CGSize) -> NSWindow {
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = canvas
        canvas.frame = CGRect(origin: .zero, size: size)
        canvas.layoutSubtreeIfNeeded()
        return window
    }

    private func mouseEvent(_ type: NSEvent.EventType, at point: CGPoint, canvas: CanvasNSView) throws -> NSEvent {
        let state = canvas.canvasState
        let location = CGPoint(x: point.x * state.zoomLevel + state.panOffset.x, y: point.y * state.zoomLevel + state.panOffset.y)
        return try XCTUnwrap(NSEvent.mouseEvent(
            with: type, location: canvas.convert(location, to: nil), modifierFlags: [],
            timestamp: 0, windowNumber: canvas.window?.windowNumber ?? 0, context: nil,
            eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1
        ))
    }

    private func rasterBytes(_ image: CGImage) -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = CGContext(
            data: &pixels, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return pixels
    }

    private func assertImagesEqual(_ actual: CGImage, _ expected: CGImage, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.width, expected.width, file: file, line: line)
        XCTAssertEqual(actual.height, expected.height, file: file, line: line)
        XCTAssertTrue(rasterBytes(actual) == rasterBytes(expected), "Exported pixels differ from the frozen source plus committed annotations", file: file, line: line)
    }
}
