import AppKit

@Observable
final class ToolManager {
    var currentTool: ToolType = .textSelect
    var strokeColor: NSColor = .systemRed {
        didSet {
            // Keep fill color in sync with stroke hue when fill is enabled.
            guard let fill = fillColor else { return }
            let alpha = fill.alphaComponent
            fillColor = strokeColor.withAlphaComponent(alpha)
        }
    }
    /// Highlighting has its own palette so annotation shapes can keep their
    /// conventional stroke color while the marker starts with yellow.
    var highlighterColor: NSColor = .systemYellow
    // Keep the first annotation light enough for screenshots opened at a
    // comfortable zoom.  Users can still increase it from the contextual
    // width control when a heavier mark is needed.
    var strokeWidth: CGFloat = 6.0
    var fillColor: NSColor? = nil
    var fillOpacity: CGFloat = 0.3 {
        didSet {
            let clampedOpacity = min(max(fillOpacity, 0), 1)
            guard let fill = fillColor else { return }
            fillColor = fill.withAlphaComponent(clampedOpacity)
        }
    }
    var fontSize: CGFloat = 18
    var fontName: String = "Helvetica"
    /// Quick-capture text is provisional until the field editor commits it.
    var defersTextUndoUntilCommit = false
    /// Text defaults belong to the active tool, so formatting is visible and
    /// selectable before the user places a new text annotation.
    var textIsBold = false
    var textIsItalic = false
    var textHasBackground = false
    var watermarkText: String = "© Captures"
    var watermarkOpacity: CGFloat = 0.55
    var arrowStyle: ArrowStyle = .straight
    var cornerRadius: CGFloat = 0
    var isDashed: Bool = false
    var blurIntensity: CGFloat = 10
    var pixelateBlockSize: CGFloat = 10
    var spotlightDimOpacity: CGFloat = 0.45
    var counterStyle: CounterStyle = .numbers

    // Active drawing state
    private var activeAnnotation: (any Annotation)?
    private var dragStartPoint: NSPoint?
    private var pencilPoints: [NSPoint] = []
    private var highlighterPoints: [NSPoint] = []
    private var counterValue: Int = 1

    func mouseDown(at point: NSPoint, canvasState: CanvasState) {
        dragStartPoint = point

        switch currentTool {
        case .textSelect:
            break
        case .ocr:
            break
        case .hand:
            break
        case .pencil:
            pencilPoints = [point]
        case .highlighter:
            highlighterPoints = [point]
        case .text:
            let annotation = TextAnnotation(
                position: point,
                text: defersTextUndoUntilCommit ? "" : "Text",
                fontName: fontName,
                fontSize: fontSize,
                color: strokeColor
            )
            annotation.isBold = textIsBold
            annotation.isItalic = textIsItalic
            annotation.hasBackground = textHasBackground
            if defersTextUndoUntilCommit { canvasState.annotations.append(annotation) }
            else { canvasState.addAnnotation(annotation) }
            canvasState.selectedAnnotationID = annotation.id
            canvasState.selectedAnnotationIDs = [annotation.id]
        case .counter:
            let annotation = CounterAnnotation(
                position: point,
                value: counterValue,
                style: counterStyle,
                color: strokeColor
            )
            canvasState.addAnnotation(annotation)
            canvasState.selectedAnnotationID = annotation.id
            canvasState.selectedAnnotationIDs = [annotation.id]
            counterValue += 1
        default:
            break
        }
    }

    func mouseDragged(to point: NSPoint, canvasState: CanvasState) {
        guard let start = dragStartPoint else { return }

        // Remove previous in-progress annotation
        if let active = activeAnnotation {
            canvasState.annotations.removeAll { $0.id == active.id }
        }

        let annotation: (any Annotation)?

        switch currentTool {
        case .textSelect:
            annotation = nil
        case .ocr:
            annotation = nil
        case .hand:
            annotation = nil
        case .arrow:
            annotation = ArrowAnnotation(
                start: start,
                end: point,
                color: strokeColor,
                strokeWidth: strokeWidth,
                style: arrowStyle
            )
        case .rectangle:
            let rect = CGRect(
                x: min(start.x, point.x),
                y: min(start.y, point.y),
                width: abs(point.x - start.x),
                height: abs(point.y - start.y)
            )
            annotation = RectangleAnnotation(
                rect: rect,
                strokeColor: strokeColor,
                fillColor: fillColor,
                strokeWidth: strokeWidth,
                cornerRadius: cornerRadius
            )
        case .ellipse:
            let rect = CGRect(
                x: min(start.x, point.x),
                y: min(start.y, point.y),
                width: abs(point.x - start.x),
                height: abs(point.y - start.y)
            )
            annotation = EllipseAnnotation(
                rect: rect,
                strokeColor: strokeColor,
                fillColor: fillColor,
                strokeWidth: strokeWidth
            )
        case .line:
            annotation = LineAnnotation(
                start: start,
                end: point,
                color: strokeColor,
                strokeWidth: strokeWidth,
                isDashed: isDashed
            )
        case .pencil:
            pencilPoints.append(point)
            annotation = PencilAnnotation(
                points: pencilPoints,
                color: strokeColor,
                strokeWidth: strokeWidth
            )
        case .highlighter:
            highlighterPoints.append(point)
            annotation = HighlighterAnnotation(
                points: highlighterPoints,
                color: highlighterColor,
                strokeWidth: strokeWidth
            )
        case .blur:
            let rect = CGRect(
                x: min(start.x, point.x),
                y: min(start.y, point.y),
                width: abs(point.x - start.x),
                height: abs(point.y - start.y)
            )
            annotation = BlurAnnotation(
                rect: rect,
                intensity: blurIntensity,
                sourceImage: canvasState.renderedBaseImage()
            )
        case .pixelate:
            let rect = CGRect(
                x: min(start.x, point.x),
                y: min(start.y, point.y),
                width: abs(point.x - start.x),
                height: abs(point.y - start.y)
            )
            annotation = PixelateAnnotation(
                rect: rect,
                blockSize: pixelateBlockSize,
                sourceImage: canvasState.renderedBaseImage()
            )
        case .spotlight:
            let rect = CGRect(
                x: min(start.x, point.x),
                y: min(start.y, point.y),
                width: abs(point.x - start.x),
                height: abs(point.y - start.y)
            )
            annotation = SpotlightAnnotation(rect: rect, dimOpacity: spotlightDimOpacity)
        case .crop:
            annotation = nil
        default:
            annotation = nil
        }

        if let annotation {
            activeAnnotation = annotation
            canvasState.annotations.append(annotation)
            canvasState.selectedAnnotationID = annotation.id
        }
    }

    @discardableResult
    func mouseUp(at point: NSPoint, canvasState: CanvasState) -> UUID? {
        var committedAnnotationID: UUID?

        if let active = activeAnnotation {
            // Commit the annotation properly via addAnnotation for undo support
            canvasState.annotations.removeAll { $0.id == active.id }
            if active is CropAnnotation {
                canvasState.annotations.removeAll { $0 is CropAnnotation }
            }
            canvasState.addAnnotation(active)
            canvasState.selectedAnnotationID = active.id
            canvasState.selectedAnnotationIDs = [active.id]
            committedAnnotationID = active.id
        }
        activeAnnotation = nil
        dragStartPoint = nil
        pencilPoints = []
        highlighterPoints = []
        return committedAnnotationID
    }
}

struct HighlighterColorPreset: Identifiable {
    let id: String
    let name: String
    let color: NSColor

    static let common: [HighlighterColorPreset] = [
        .init(id: "yellow", name: "Yellow", color: .systemYellow),
        .init(id: "green", name: "Green", color: .systemGreen),
        .init(id: "blue", name: "Blue", color: .systemBlue),
        .init(id: "pink", name: "Pink", color: .systemPink),
        .init(id: "orange", name: "Orange", color: .systemOrange),
    ]
}

enum ArrowStyle: String, CaseIterable, Codable {
    case straight, curved, tapered, outlined

    var displayName: String { rawValue.capitalized }
}

enum CounterStyle: String, CaseIterable, Codable {
    case numbers, letters, roman

    var displayName: String { rawValue.capitalized }

    func display(for value: Int) -> String {
        switch self {
        case .numbers: return "\(value)"
        case .letters:
            let letter = Character(UnicodeScalar(64 + min(value, 26))!)
            return String(letter)
        case .roman: return romanNumeral(value)
        }
    }

    private func romanNumeral(_ num: Int) -> String {
        let values = [1000, 900, 500, 400, 100, 90, 50, 40, 10, 9, 5, 4, 1]
        let symbols = ["M", "CM", "D", "CD", "C", "XC", "L", "XL", "X", "IX", "V", "IV", "I"]
        var result = ""
        var remaining = num
        for (i, value) in values.enumerated() {
            while remaining >= value {
                result += symbols[i]
                remaining -= value
            }
        }
        return result
    }
}
