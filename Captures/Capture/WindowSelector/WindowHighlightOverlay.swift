import AppKit

final class WindowHighlightOverlay: NSView {
    /// Highlight rect in AppKit's global screen coordinate space.
    var highlightScreenFrame: CGRect?
    var highlightTitle: String?
    var isSelectionLocked = false

    private let outsideDimColor = NSColor.black.withAlphaComponent(0.30)
    private let titleFont = NSFont.systemFont(ofSize: 12, weight: .medium)

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    func setHighlight(
        screenFrame: CGRect?,
        title: String?,
        isSelectionLocked: Bool = false
    ) {
        guard highlightScreenFrame != screenFrame
            || highlightTitle != title
            || self.isSelectionLocked != isSelectionLocked else {
            return
        }

        highlightScreenFrame = screenFrame
        highlightTitle = title
        self.isSelectionLocked = isSelectionLocked
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let context = NSGraphicsContext.current?.cgContext,
              let screenFrame = highlightScreenFrame,
              let window else { return }

        // ScreenCaptureKit frames are converted to global AppKit coordinates by
        // the controller. Convert once more through this overlay's window so
        // highlights land correctly on every display, not just the primary one.
        let windowFrame = window.convertFromScreen(screenFrame)
        let viewFrame = convert(windowFrame, from: nil).intersection(bounds)
        guard !viewFrame.isNull, !viewFrame.isEmpty else { return }

        // Keep the pointed-to window readable while the rest of the desktop
        // recedes. This gives the selection the same spatial clarity as the
        // area selector without introducing a second visual language.
        context.saveGState()
        context.addRect(bounds)
        context.addPath(CaptureSelectionFrameStyle.cutoutPath(for: viewFrame))
        context.clip(using: .evenOdd)
        context.setFillColor(outsideDimColor.cgColor)
        context.fill(bounds)
        context.restoreGState()

        CaptureSelectionFrameStyle.drawCorners(
            context: context,
            rect: viewFrame,
            appearance: effectiveAppearance
        )

        drawTitle(in: context, alignedTo: viewFrame)
    }

    private func drawTitle(in context: CGContext, alignedTo rect: CGRect) {
        guard let title = highlightTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty,
              rect.width >= 72,
              rect.height >= 28 else {
            return
        }

        let attributes: [NSAttributedString.Key: Any] = [
            .font: titleFont,
            .foregroundColor: NSColor.white,
        ]
        let maxWidth = max(40, rect.width - 20)
        let renderedTitle = title.truncated(to: maxWidth, attributes: attributes)
        let titleSize = (renderedTitle as NSString).size(withAttributes: attributes)
        let labelRect = NSRect(
            x: rect.minX + 8,
            y: rect.maxY - titleSize.height - 12,
            width: min(maxWidth, titleSize.width) + 12,
            height: titleSize.height + 8
        )

        context.setFillColor(NSColor.black.withAlphaComponent(0.58).cgColor)
        context.addPath(CGPath(
            roundedRect: labelRect,
            cornerWidth: 5,
            cornerHeight: 5,
            transform: nil
        ))
        context.fillPath()
        (renderedTitle as NSString).draw(
            at: NSPoint(x: labelRect.minX + 6, y: labelRect.minY + 4),
            withAttributes: attributes
        )
    }
}

private extension String {
    func truncated(
        to maximumWidth: CGFloat,
        attributes: [NSAttributedString.Key: Any]
    ) -> String {
        guard (self as NSString).size(withAttributes: attributes).width > maximumWidth else {
            return self
        }

        let ellipsis = "…"
        var result = ""
        for character in self {
            let candidate = result + String(character) + ellipsis
            guard (candidate as NSString).size(withAttributes: attributes).width <= maximumWidth else {
                break
            }
            result.append(character)
        }
        return result.isEmpty ? ellipsis : result + ellipsis
    }
}
