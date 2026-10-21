import AppKit

final class HighlighterAnnotation: Annotation {
    let id: UUID
    let type: ToolType = .highlighter
    var zOrder: Int = 0
    var isVisible: Bool = true

    let points: [NSPoint]
    let color: NSColor
    let strokeWidth: CGFloat

    var start: NSPoint { points.first ?? .zero }
    var end: NSPoint { points.last ?? .zero }

    var boundingRect: CGRect {
        guard let first = points.first else { return .zero }
        var minX = first.x, maxX = first.x
        var minY = first.y, maxY = first.y
        for point in points {
            minX = min(minX, point.x)
            maxX = max(maxX, point.x)
            minY = min(minY, point.y)
            maxY = max(maxY, point.y)
        }
        return CGRect(
            x: minX - strokeWidth / 2,
            y: minY - strokeWidth / 2,
            width: maxX - minX + strokeWidth,
            height: maxY - minY + strokeWidth
        )
    }

    init(
        id: UUID = UUID(),
        points: [NSPoint],
        color: NSColor,
        strokeWidth: CGFloat
    ) {
        self.id = id
        self.points = points
        self.color = color
        self.strokeWidth = strokeWidth
    }

    func render(in context: CGContext) {
        guard let first = points.first else { return }

        context.saveGState()
        context.setBlendMode(.multiply)
        context.setStrokeColor(color.withAlphaComponent(0.4).cgColor)
        context.setLineWidth(strokeWidth)
        context.setLineCap(.round)
        context.setLineJoin(.round)

        context.move(to: first)
        for point in points.dropFirst() {
            context.addLine(to: point)
        }
        context.strokePath()
        context.restoreGState()
    }

    func duplicate() -> any Annotation {
        HighlighterAnnotation(
            id: id,
            points: points,
            color: color,
            strokeWidth: strokeWidth
        )
    }
}
