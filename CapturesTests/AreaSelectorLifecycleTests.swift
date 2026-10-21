import AppKit
import XCTest
@testable import Captures

@MainActor
final class AreaSelectorLifecycleTests: XCTestCase {
    func testReadySelectionKeepsTheSourceAppFrontmostAndReceivesEscape() async throws {
        let snapshot = try makeSnapshot()
        let ready = expectation(description: "Screen pixels prepared")
        let cancelled = expectation(description: "Escape dismisses selection")
        let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let controller = AreaSelectorWindowController(
            snapshotProvider: {
                ready.fulfill()
                return snapshot
            },
            screenCaptureAccess: { true }
        ) { result in
            XCTAssertNil(result)
            cancelled.fulfill()
        }
        defer { controller.close() }

        controller.show(freezeScreen: true)
        await fulfillment(of: [ready], timeout: 2)
        let panel = try XCTUnwrap(controller.overlayWindows.first as? AreaSelectorWindow)
        XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel))
        XCTAssertTrue(panel.canBecomeKey, "Escape and inline markup must still receive keys")
        XCTAssertFalse(panel.canBecomeMain)
        XCTAssertFalse(panel.hidesOnDeactivate)
        XCTAssertTrue(panel.collectionBehavior.contains(.canJoinAllApplications))
        XCTAssertEqual(NSWorkspace.shared.frontmostApplication?.processIdentifier, frontmostPID,
                       "The selector must not activate Captures or switch away from the source app")
        let overlay = try XCTUnwrap(panel.contentView as? AreaSelectorOverlayView)
        XCTAssertTrue(overlay.frozenImage === snapshot.displays.first?.image)

        let escape = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: panel.windowNumber, context: nil,
            characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
            isARepeat: false, keyCode: 53
        ))
        panel.sendEvent(escape)
        await fulfillment(of: [cancelled], timeout: 2)
        XCTAssertTrue(controller.overlayWindows.isEmpty)
    }

    func testSnapshotFailureLeavesAllWindowsUncovered() async {
        let cancelled = expectation(description: "Capture preparation fails closed")
        let controller = AreaSelectorWindowController(
            snapshotProvider: { throw CaptureError.noDisplay },
            screenCaptureAccess: { true }
        ) { result in
            XCTAssertNil(result)
            cancelled.fulfill()
        }
        defer { controller.close() }

        controller.show(freezeScreen: true)
        await fulfillment(of: [cancelled], timeout: 2)
        XCTAssertTrue(controller.overlayWindows.isEmpty)
    }

    func testPartialSnapshotNeverCoversTheOtherDisplays() async {
        let cancelled = expectation(description: "Incomplete snapshot rejected")
        let controller = AreaSelectorWindowController(
            snapshotProvider: { FrozenScreenSnapshot(displays: []) },
            screenCaptureAccess: { true }
        ) { result in
            XCTAssertNil(result)
            cancelled.fulfill()
        }
        defer { controller.close() }

        controller.show(freezeScreen: true)
        await fulfillment(of: [cancelled], timeout: 2)
        XCTAssertTrue(controller.overlayWindows.isEmpty)
    }

    func testClosingDuringPreparationCannotResurrectTheOverlay() async throws {
        let requested = expectation(description: "Snapshot request started")
        let delivered = expectation(description: "Late snapshot delivered")
        var continuation: CheckedContinuation<FrozenScreenSnapshot, Never>?
        let controller = AreaSelectorWindowController(
            snapshotProvider: {
                let snapshot = await withCheckedContinuation { pending in
                    continuation = pending
                    requested.fulfill()
                }
                delivered.fulfill()
                return snapshot
            },
            screenCaptureAccess: { true }
        ) { _ in
            XCTFail("A closed selector cannot resolve an obsolete capture")
        }
        controller.show(freezeScreen: true)
        await fulfillment(of: [requested], timeout: 2)
        controller.close()
        continuation?.resume(returning: try makeSnapshot())
        await fulfillment(of: [delivered], timeout: 2)
        XCTAssertTrue(controller.overlayWindows.isEmpty)
    }

    private func makeSnapshot() throws -> FrozenScreenSnapshot {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 8, height: 8,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(NSColor.systemGreen.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        let image = try XCTUnwrap(context.makeImage())
        return FrozenScreenSnapshot(displays: NSScreen.screens.map {
            .init(frame: $0.frame, image: image)
        })
    }
}
