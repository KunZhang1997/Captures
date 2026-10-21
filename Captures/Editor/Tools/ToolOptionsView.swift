import AppKit
import SwiftUI

struct ToolOptionsView: View {
    @Bindable var canvasState: CanvasState
    @Bindable var toolManager: ToolManager
    /// The native editor owns a single contextual tool picker. Keep the legacy
    /// compact picker available for the standalone SwiftUI editor, but do not
    /// repeat it when this view is hosted inside that native surface.
    var showsToolPicker = true
    /// When embedded by the native editor this keeps the parameter strip in
    /// lockstep with the visible top-level section.
    var activeSection: NativeEditorSection? = nil
    var onCanvasChanged: (() -> Void)? = nil
    var onCanvasGeometryChanged: (() -> Void)? = nil
    var onToolChanged: (() -> Void)? = nil
    @State private var hoveredTool: ToolType?
    private let textSizeRange: ClosedRange<CGFloat> = 8...240

    private enum AnnotationSelectionMode {
        case none
        case single(annotation: any Annotation)
        case multipleSameType(primary: any Annotation, count: Int)
        case multipleMixed(count: Int)
    }

    var body: some View {
        HStack(spacing: 10) {
            Spacer(minLength: 0)
            if let activeSection {
                nativeSectionControls(for: activeSection)
            } else {
                switch primaryGroup {
            case .mouse:
                switch selectionMode {
                case .none:
                    Label(L("Select, move, or resize. Double-click text to edit."), systemImage: "cursorarrow")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)

                case .single(let annotation):
                    selectedAnnotationEditor(annotation)

                case .multipleSameType(let primary, let count):
                    Label("\(count) \(annotationTypeLabel(for: primary)) selected", systemImage: "square.on.square")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                    selectedAnnotationEditor(primary)

                case .multipleMixed(let count):
                    Label(
                        "\(count) items selected. Move works for all; property editing works when all selected items share one type.",
                        systemImage: "square.on.square"
                    )
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                }

            case .ocr:
                Label(L("OCR mode: drag over text and press Cmd+C to copy."), systemImage: "text.viewfinder")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)

            case .hand:
                Label(L("Hand mode: drag to pan around the image."), systemImage: "hand.draw")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)

            case .text:
                colorControls(textColorBinding)
                fontPicker(textFontNameBinding)
                sliderWithNumericInput(
                    label: L("Size:"),
                    value: textFontSizeBinding,
                    in: textSizeRange
                )
                defaultTextStyleControls

            case .draw:
                if showsToolPicker {
                    iconToolPicker(group: .draw)
                }
                if toolManager.currentTool == .highlighter {
                    highlighterColorControls($toolManager.highlighterColor)
                } else {
                    colorControls
                }
                strokeWidthControls

            case .shapes:
                if showsToolPicker {
                    iconToolPicker(group: .shapes)
                }
                colorControls
                if showsStrokeWidth {
                    strokeWidthControls
                }

                switch toolManager.currentTool {
                case .arrow:
                    Picker(L("Style"), selection: $toolManager.arrowStyle) {
                        ForEach(ArrowStyle.allCases, id: \.self) { style in
                            Text(Localization.string(style.displayName)).tag(style)
                        }
                    }
                    .frame(width: 120)

                case .rectangle:
                    rectangleFillOptions

                    HStack(spacing: 4) {
                        Text(L("Radius:"))
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                        Slider(value: $toolManager.cornerRadius, in: 0...30)
                            .frame(width: 80)
                    }

                case .ellipse:
                    ellipseFillOptions

                case .line:
                    Toggle(L("Dashed"), isOn: $toolManager.isDashed)

                case .counter:
                    Picker(L("Style"), selection: $toolManager.counterStyle) {
                        ForEach(CounterStyle.allCases, id: \.self) { style in
                            Text(Localization.string(style.displayName)).tag(style)
                        }
                    }
                    .frame(width: 120)

                default:
                    EmptyView()
                }

            case .blur:
                if showsToolPicker {
                    iconToolPicker(group: .blur)
                }

                switch toolManager.currentTool {
                case .blur:
                    HStack(spacing: 4) {
                        Text(L("Intensity:"))
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                        Slider(value: $toolManager.blurIntensity, in: 1...50)
                            .frame(width: 100)
                    }

                case .pixelate:
                    HStack(spacing: 4) {
                        Text(L("Block size:"))
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                        Slider(value: $toolManager.pixelateBlockSize, in: 4...40)
                            .frame(width: 100)
                    }

                case .spotlight:
                    HStack(spacing: 4) {
                        Text(L("Dim:"))
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                        Slider(value: $toolManager.spotlightDimOpacity, in: 0.1...0.9)
                            .frame(width: 100)
                    }

                default:
                    EmptyView()
                }

            case .crop:
                cropControls
                }
            }

            Spacer(minLength: 0)
        }
        .controlSize(.small)
        .font(.system(size: 9))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 12)
    }

    private var primaryGroup: PrimaryToolGroup {
        toolManager.currentTool.primaryGroup
    }

    @ViewBuilder
    private func nativeSectionControls(for section: NativeEditorSection) -> some View {
        switch section {
        case .adjust:
            if toolManager.currentTool == .crop {
                cropControls
            } else {
                Label(L("Adjust"), systemImage: "slider.horizontal.3")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                sliderWithNumericInput(
                    label: L("Brightness:"),
                    value: rasterBinding(\.brightness),
                    in: -1...1,
                    step: 0.05,
                    fractionDigits: 2
                )
                sliderWithNumericInput(
                    label: L("Contrast:"),
                    value: rasterBinding(\.contrast),
                    in: 0.5...2,
                    step: 0.05,
                    fractionDigits: 2
                )
                sliderWithNumericInput(
                    label: L("Saturation:"),
                    value: rasterBinding(\.saturation),
                    in: 0...2,
                    step: 0.05,
                    fractionDigits: 2
                )
                Button(L("Reset Adjustments")) {
                    canvasState.updateRasterAdjustment { $0 = RasterAdjustment() }
                    onCanvasChanged?()
                }
            }

        case .filters:
            if toolManager.currentTool == .pixelate {
                pixelateControls
            } else {
                filterGallery
            }

        case .watermark:
            // A watermark is still an editable text object after it is
            // placed.  Keep its font, color and wording immediately
            // available instead of forcing an unexplained tab detour.
            if let text = selectedAnnotation as? TextAnnotation {
                selectedTextEditor(text)
            } else {
                watermarkControls
            }

        case .resize:
            outputResizeControls

        case .retouch, .annotation:
            EmptyView()
        }
    }

    private var watermarkControls: some View {
        Group {
            Label(L("Text Watermark"), systemImage: "text.badge.plus")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
            TextField(L("Watermark text"), text: $toolManager.watermarkText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 128)
            colorControls($toolManager.strokeColor)
            sliderWithNumericInput(
                label: L("Opacity:"),
                value: $toolManager.watermarkOpacity,
                in: 0.1...1,
                step: 0.05,
                fractionDigits: 2
            )
            Button(L("Add Watermark")) {
                addTextWatermark()
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var outputResizeControls: some View {
        Group {
            Label(L("Export size"), systemImage: "arrow.up.left.and.arrow.down.right")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)

            HStack(spacing: 4) {
                Text(L("Width:"))
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                TextField("", value: outputWidthBinding, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 68)
                Text("px")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 4) {
                Text(L("Height:"))
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                TextField("", value: outputHeightBinding, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 68)
                Text("px")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }

            Toggle(L("Lock aspect ratio"), isOn: outputAspectLockedBinding)
                .toggleStyle(.checkbox)
                .controlSize(.small)
                .font(.system(size: 9))

            Button(L("Reset Size")) {
                canvasState.resetOutputResize()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    private func addTextWatermark() {
        let text = toolManager.watermarkText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        let shortestEdge = CGFloat(min(canvasState.imageWidth, canvasState.imageHeight))
        // Watermarks should identify the image without becoming the visual
        // subject.  Keep the size and inset modest on both small and large
        // captures; the text remains editable after it is placed.
        let fontSize = min(max(shortestEdge * 0.03, 16), 56)
        let margin = min(max(shortestEdge * 0.024, 16), 72)
        let watermark = TextAnnotation(
            position: CGPoint(x: margin, y: margin),
            text: text,
            fontName: toolManager.fontName,
            fontSize: fontSize,
            color: toolManager.strokeColor.withAlphaComponent(toolManager.watermarkOpacity)
        )
        watermark.isBold = true
        watermark.position = CGPoint(
            x: max(margin, CGFloat(canvasState.imageWidth) - margin - watermark.boundingRect.width),
            y: margin
        )
        canvasState.addAnnotation(watermark)
        canvasState.selectedAnnotationID = watermark.id
        canvasState.selectedAnnotationIDs = [watermark.id]
        onCanvasChanged?()
    }

    private var cropControls: some View {
        Group {
            Label(L("Resize/move the crop box directly, then apply."), systemImage: "crop")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)

            Button(L("Apply Crop")) {
                if canvasState.applyActiveCrop() {
                    toolManager.currentTool = .textSelect
                    onCanvasGeometryChanged?()
                }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.return, modifiers: [])
        }
    }

    private var pixelateControls: some View {
        return HStack(spacing: 4) {
            Text(L("Block size:"))
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
            Slider(value: $toolManager.pixelateBlockSize, in: 4...40)
                .frame(width: 100)
        }
    }

    private var filterGallery: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(ImageFilterPreset.allCases, id: \.self) { preset in
                    filterCard(for: preset)
                }

                Divider()
                    .frame(height: 36)
                    .padding(.horizontal, 2)

                Button {
                    toolManager.currentTool = .pixelate
                    onToolChanged?()
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: "squareshape.split.3x3")
                            .font(.system(size: 15, weight: .medium))
                            .frame(width: 108, height: 38)
                            .background(Color.primary.opacity(0.045))
                            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                        Text(L("Pixelate"))
                            .font(.system(size: 8))
                            .lineLimit(1)
                    }
                    .foregroundStyle(.secondary)
                    .frame(width: 116, height: 56)
                    .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .buttonStyle(.plain)
                .help(L("Pixelate"))
            }
            .padding(.vertical, 3)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func filterCard(for preset: ImageFilterPreset) -> some View {
        let isSelected = canvasState.rasterAdjustment.filter == preset
        let preview = NSImage(
            cgImage: canvasState.filterPreviewImage(for: preset),
            size: NSSize(width: 108, height: 38)
        )

        return Button {
            rasterFilterBinding.wrappedValue = preset
        } label: {
            VStack(spacing: 2) {
                Image(nsImage: preview)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 108, height: 38)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.10), lineWidth: 1)
                    }

                Text(preset.localizedDisplayName)
                    .font(.system(size: 8, weight: isSelected ? .medium : .regular))
                    .lineLimit(1)
                    .foregroundStyle(isSelected ? Color.primary : Color.secondary)
            }
            .padding(2)
            .frame(width: 116, height: 56)
            .background {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isSelected ? Color(nsColor: .controlBackgroundColor) : Color.clear)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(isSelected ? Color.primary.opacity(0.16) : Color.clear, lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(preset.localizedDisplayName)
        .accessibilityLabel(preset.localizedDisplayName)
        .accessibilityValue(isSelected ? L("Selected") : "")
    }

    private var rasterFilterBinding: Binding<ImageFilterPreset> {
        Binding(
            get: { canvasState.rasterAdjustment.filter },
            set: { preset in
                canvasState.updateRasterAdjustment { $0.filter = preset }
                onCanvasChanged?()
            }
        )
    }

    private var outputWidthBinding: Binding<Int> {
        Binding(
            get: { canvasState.outputWidth },
            set: { canvasState.setOutputWidth($0) }
        )
    }

    private var outputHeightBinding: Binding<Int> {
        Binding(
            get: { canvasState.outputHeight },
            set: { canvasState.setOutputHeight($0) }
        )
    }

    private var outputAspectLockedBinding: Binding<Bool> {
        Binding(
            get: { canvasState.outputAspectRatioLocked },
            set: { canvasState.setOutputAspectRatioLocked($0) }
        )
    }

    private func rasterBinding(
        _ keyPath: WritableKeyPath<RasterAdjustment, CGFloat>
    ) -> Binding<CGFloat> {
        Binding(
            get: { canvasState.rasterAdjustment[keyPath: keyPath] },
            set: { value in
                canvasState.updateRasterAdjustment { $0[keyPath: keyPath] = value }
                onCanvasChanged?()
            }
        )
    }

    private var selectedAnnotation: (any Annotation)? {
        guard let selectedAnnotationID = canvasState.selectedAnnotationID else {
            return selectedAnnotations.first
        }
        return canvasState.annotations.first(where: { $0.id == selectedAnnotationID })
            ?? selectedAnnotations.first
    }

    private var selectedAnnotations: [any Annotation] {
        canvasState.selectedAnnotations()
    }

    private var editableSelectedAnnotations: [any Annotation] {
        guard let selectedAnnotation else { return [] }
        let annotations = selectedAnnotations
        guard !annotations.isEmpty else { return [] }

        let selectedType = ObjectIdentifier(type(of: selectedAnnotation))
        guard annotations.allSatisfy({ ObjectIdentifier(type(of: $0)) == selectedType }) else {
            return []
        }

        return [selectedAnnotation] + annotations.filter { $0.id != selectedAnnotation.id }
    }

    private var selectionMode: AnnotationSelectionMode {
        let annotations = selectedAnnotations
        guard let selectedAnnotation else { return .none }

        if annotations.count <= 1 {
            return .single(annotation: selectedAnnotation)
        }

        let selectedType = ObjectIdentifier(type(of: selectedAnnotation))
        let isSameTypeSelection = annotations.allSatisfy {
            ObjectIdentifier(type(of: $0)) == selectedType
        }

        if isSameTypeSelection {
            return .multipleSameType(primary: selectedAnnotation, count: annotations.count)
        }

        return .multipleMixed(count: annotations.count)
    }

    private func annotationTypeLabel(for annotation: any Annotation) -> String {
        if annotation is TextAnnotation { return "text item(s)" }
        if annotation is ArrowAnnotation { return "arrow(s)" }
        if annotation is RectangleAnnotation { return "rectangle(s)" }
        if annotation is EllipseAnnotation { return "ellipse(s)" }
        if annotation is LineAnnotation { return "line(s)" }
        if annotation is PencilAnnotation { return "pencil stroke(s)" }
        if annotation is HighlighterAnnotation { return "highlight(s)" }
        if annotation is CounterAnnotation { return "counter(s)" }
        if annotation is BlurAnnotation { return "blur area(s)" }
        if annotation is PixelateAnnotation { return "pixelate area(s)" }
        if annotation is SpotlightAnnotation { return "spotlight area(s)" }
        if annotation is CropAnnotation { return "crop area(s)" }
        return "item(s)"
    }

    @ViewBuilder
    private func selectedAnnotationEditor(_ annotation: any Annotation) -> some View {
        if let text = annotation as? TextAnnotation {
            selectedTextEditor(text)
        } else if let arrow = annotation as? ArrowAnnotation {
            selectedArrowEditor(arrow)
        } else if let rectangle = annotation as? RectangleAnnotation {
            selectedRectangleEditor(rectangle)
        } else if let ellipse = annotation as? EllipseAnnotation {
            selectedEllipseEditor(ellipse)
        } else if let line = annotation as? LineAnnotation {
            selectedLineEditor(line)
        } else if let pencil = annotation as? PencilAnnotation {
            selectedStrokeEditor(
                title: "Pencil",
                iconName: "pencil",
                fallbackColor: pencil.color,
                fallbackWidth: pencil.strokeWidth,
                colorGet: { ($0 as? PencilAnnotation)?.color },
                widthGet: { ($0 as? PencilAnnotation)?.strokeWidth },
                update: { annotation, color, width in
                    guard let pencil = annotation as? PencilAnnotation else { return nil }
                    return PencilAnnotation(
                        id: pencil.id,
                        points: pencil.points,
                        color: color,
                        strokeWidth: width
                    )
                }
            )
        } else if let highlighter = annotation as? HighlighterAnnotation {
            selectedHighlighterEditor(highlighter)
        } else if let counter = annotation as? CounterAnnotation {
            selectedCounterEditor(counter)
        } else if let blur = annotation as? BlurAnnotation {
            selectedBlurEditor(blur)
        } else if let pixelate = annotation as? PixelateAnnotation {
            selectedPixelateEditor(pixelate)
        } else if let spotlight = annotation as? SpotlightAnnotation {
            selectedSpotlightEditor(spotlight)
        } else if let crop = annotation as? CropAnnotation {
            selectedCropEditor(crop)
        } else {
            Label(L("Selected object is editable by drag handles."), systemImage: "cursorarrow")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func selectedTextEditor(_ text: TextAnnotation) -> some View {
        Label(L("Text"), systemImage: "textformat")
            .font(.system(size: 9))
            .foregroundStyle(.secondary)

        TextField(
            L("Text"),
            text: selectedBinding(
                fallback: text.text,
                get: { ($0 as? TextAnnotation)?.text },
                set: { annotation, value in
                    guard let text = annotation as? TextAnnotation else { return nil }
                    return makeTextAnnotation(from: text, text: value)
                }
            )
        )
        .frame(width: 180)

        colorControls(
            selectedBinding(
                fallback: text.color,
                get: { ($0 as? TextAnnotation)?.color },
                set: { annotation, value in
                    guard let text = annotation as? TextAnnotation else { return nil }
                    return makeTextAnnotation(from: text, color: value)
                }
            )
        )

        fontPicker(
            selectedBinding(
                fallback: text.fontName,
                get: { ($0 as? TextAnnotation)?.fontName },
                set: { annotation, value in
                    guard let text = annotation as? TextAnnotation else { return nil }
                    return makeTextAnnotation(from: text, fontName: value)
                }
            )
        )

        let sizeBinding = selectedBinding(
            fallback: text.fontSize,
            get: { ($0 as? TextAnnotation)?.fontSize },
            set: { annotation, value in
                guard let text = annotation as? TextAnnotation else { return nil }
                return makeTextAnnotation(from: text, fontSize: value)
            }
        )
        sliderWithNumericInput(
            label: L("Size:"),
            value: sizeBinding,
            in: textSizeRange
        )

        textStyleControls(
            bold: selectedBinding(
                fallback: text.isBold,
                get: { ($0 as? TextAnnotation)?.isBold },
                set: { annotation, value in
                    guard let text = annotation as? TextAnnotation else { return nil }
                    return makeTextAnnotation(from: text, isBold: value)
                },
                onSet: { toolManager.textIsBold = $0 }
            ),
            italic: selectedBinding(
                fallback: text.isItalic,
                get: { ($0 as? TextAnnotation)?.isItalic },
                set: { annotation, value in
                    guard let text = annotation as? TextAnnotation else { return nil }
                    return makeTextAnnotation(from: text, isItalic: value)
                },
                onSet: { toolManager.textIsItalic = $0 }
            ),
            background: selectedBinding(
                fallback: text.hasBackground,
                get: { ($0 as? TextAnnotation)?.hasBackground },
                set: { annotation, value in
                    guard let text = annotation as? TextAnnotation else { return nil }
                    return makeTextAnnotation(from: text, hasBackground: value)
                },
                onSet: { toolManager.textHasBackground = $0 }
            )
        )
    }

    @ViewBuilder
    private func selectedArrowEditor(_ arrow: ArrowAnnotation) -> some View {
        Label(L("Arrow"), systemImage: "arrow.up.right")
            .font(.system(size: 9))
            .foregroundStyle(.secondary)

        colorControls(
            selectedBinding(
                fallback: arrow.color,
                get: { ($0 as? ArrowAnnotation)?.color },
                set: { annotation, value in
                    guard let arrow = annotation as? ArrowAnnotation else { return nil }
                    return ArrowAnnotation(
                        id: arrow.id,
                        start: arrow.start,
                        end: arrow.end,
                        color: value,
                        strokeWidth: arrow.strokeWidth,
                        style: arrow.style
                    )
                }
            )
        )

        strokeWidthControls(
            selectedBinding(
                fallback: arrow.strokeWidth,
                get: { ($0 as? ArrowAnnotation)?.strokeWidth },
                set: { annotation, value in
                    guard let arrow = annotation as? ArrowAnnotation else { return nil }
                    return ArrowAnnotation(
                        id: arrow.id,
                        start: arrow.start,
                        end: arrow.end,
                        color: arrow.color,
                        strokeWidth: value,
                        style: arrow.style
                    )
                }
            )
        )

        Picker(
            L("Style"),
            selection: selectedBinding(
                fallback: arrow.style,
                get: { ($0 as? ArrowAnnotation)?.style },
                set: { annotation, value in
                    guard let arrow = annotation as? ArrowAnnotation else { return nil }
                    return ArrowAnnotation(
                        id: arrow.id,
                        start: arrow.start,
                        end: arrow.end,
                        color: arrow.color,
                        strokeWidth: arrow.strokeWidth,
                        style: value
                    )
                }
            )
        ) {
            ForEach(ArrowStyle.allCases, id: \.self) { style in
                Text(Localization.string(style.displayName)).tag(style)
            }
        }
        .frame(width: 120)
    }

    @ViewBuilder
    private func selectedRectangleEditor(_ rectangle: RectangleAnnotation) -> some View {
        Label(L("Rectangle"), systemImage: "rectangle")
            .font(.system(size: 9))
            .foregroundStyle(.secondary)

        colorControls(
            selectedBinding(
                fallback: rectangle.strokeColor,
                get: { ($0 as? RectangleAnnotation)?.strokeColor },
                set: { annotation, value in
                    guard let rectangle = annotation as? RectangleAnnotation else { return nil }
                    return RectangleAnnotation(
                        id: rectangle.id,
                        rect: rectangle.rect,
                        strokeColor: value,
                        fillColor: rectangle.fillColor,
                        strokeWidth: rectangle.strokeWidth,
                        cornerRadius: rectangle.cornerRadius,
                        rotationDegrees: rectangle.rotationDegrees
                    )
                }
            )
        )

        strokeWidthControls(
            selectedBinding(
                fallback: rectangle.strokeWidth,
                get: { ($0 as? RectangleAnnotation)?.strokeWidth },
                set: { annotation, value in
                    guard let rectangle = annotation as? RectangleAnnotation else { return nil }
                    return RectangleAnnotation(
                        id: rectangle.id,
                        rect: rectangle.rect,
                        strokeColor: rectangle.strokeColor,
                        fillColor: rectangle.fillColor,
                        strokeWidth: value,
                        cornerRadius: rectangle.cornerRadius,
                        rotationDegrees: rectangle.rotationDegrees
                    )
                }
            )
        )

        let fillEnabledBinding = selectedBinding(
            fallback: rectangle.fillColor != nil,
            get: { ($0 as? RectangleAnnotation).map { $0.fillColor != nil } },
            set: { annotation, value in
                guard let rectangle = annotation as? RectangleAnnotation else { return nil }
                let fill = value ? (rectangle.fillColor ?? rectangle.strokeColor.withAlphaComponent(0.3)) : nil
                return RectangleAnnotation(
                    id: rectangle.id,
                    rect: rectangle.rect,
                    strokeColor: rectangle.strokeColor,
                    fillColor: fill,
                    strokeWidth: rectangle.strokeWidth,
                    cornerRadius: rectangle.cornerRadius,
                    rotationDegrees: rectangle.rotationDegrees
                )
            }
        )
        Toggle(L("Fill"), isOn: fillEnabledBinding)

        if fillEnabledBinding.wrappedValue {
            colorControls(
                selectedBinding(
                    fallback: rectangle.fillColor ?? rectangle.strokeColor.withAlphaComponent(0.3),
                    get: { annotation in
                        guard let rectangle = annotation as? RectangleAnnotation else { return nil }
                        return rectangle.fillColor ?? rectangle.strokeColor.withAlphaComponent(0.3)
                    },
                    set: { annotation, value in
                        guard let rectangle = annotation as? RectangleAnnotation else { return nil }
                        return RectangleAnnotation(
                            id: rectangle.id,
                            rect: rectangle.rect,
                            strokeColor: rectangle.strokeColor,
                            fillColor: value,
                            strokeWidth: rectangle.strokeWidth,
                            cornerRadius: rectangle.cornerRadius,
                            rotationDegrees: rectangle.rotationDegrees
                        )
                    }
                ),
                label: L("Fill:")
            )
        }

        HStack(spacing: 4) {
            Text(L("Radius:"))
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
            Slider(
                value: selectedBinding(
                    fallback: rectangle.cornerRadius,
                    get: { ($0 as? RectangleAnnotation)?.cornerRadius },
                    set: { annotation, value in
                        guard let rectangle = annotation as? RectangleAnnotation else { return nil }
                        return RectangleAnnotation(
                            id: rectangle.id,
                            rect: rectangle.rect,
                            strokeColor: rectangle.strokeColor,
                            fillColor: rectangle.fillColor,
                            strokeWidth: rectangle.strokeWidth,
                            cornerRadius: value,
                            rotationDegrees: rectangle.rotationDegrees
                        )
                    }
                ),
                in: 0...30
            )
            .frame(width: 80)
        }
    }

    @ViewBuilder
    private func selectedEllipseEditor(_ ellipse: EllipseAnnotation) -> some View {
        Label(L("Ellipse"), systemImage: "circle")
            .font(.system(size: 9))
            .foregroundStyle(.secondary)

        colorControls(
            selectedBinding(
                fallback: ellipse.strokeColor,
                get: { ($0 as? EllipseAnnotation)?.strokeColor },
                set: { annotation, value in
                    guard let ellipse = annotation as? EllipseAnnotation else { return nil }
                    return EllipseAnnotation(
                        id: ellipse.id,
                        rect: ellipse.rect,
                        strokeColor: value,
                        fillColor: ellipse.fillColor,
                        strokeWidth: ellipse.strokeWidth,
                        rotationDegrees: ellipse.rotationDegrees
                    )
                }
            )
        )

        strokeWidthControls(
            selectedBinding(
                fallback: ellipse.strokeWidth,
                get: { ($0 as? EllipseAnnotation)?.strokeWidth },
                set: { annotation, value in
                    guard let ellipse = annotation as? EllipseAnnotation else { return nil }
                    return EllipseAnnotation(
                        id: ellipse.id,
                        rect: ellipse.rect,
                        strokeColor: ellipse.strokeColor,
                        fillColor: ellipse.fillColor,
                        strokeWidth: value,
                        rotationDegrees: ellipse.rotationDegrees
                    )
                }
            )
        )

        let fillEnabledBinding = selectedBinding(
            fallback: ellipse.fillColor != nil,
            get: { ($0 as? EllipseAnnotation).map { $0.fillColor != nil } },
            set: { annotation, value in
                guard let ellipse = annotation as? EllipseAnnotation else { return nil }
                let fill = value ? (ellipse.fillColor ?? ellipse.strokeColor.withAlphaComponent(0.3)) : nil
                return EllipseAnnotation(
                    id: ellipse.id,
                    rect: ellipse.rect,
                    strokeColor: ellipse.strokeColor,
                    fillColor: fill,
                    strokeWidth: ellipse.strokeWidth,
                    rotationDegrees: ellipse.rotationDegrees
                )
            }
        )
        Toggle(L("Fill"), isOn: fillEnabledBinding)

        if fillEnabledBinding.wrappedValue {
            colorControls(
                selectedBinding(
                    fallback: ellipse.fillColor ?? ellipse.strokeColor.withAlphaComponent(0.3),
                    get: { annotation in
                        guard let ellipse = annotation as? EllipseAnnotation else { return nil }
                        return ellipse.fillColor ?? ellipse.strokeColor.withAlphaComponent(0.3)
                    },
                    set: { annotation, value in
                        guard let ellipse = annotation as? EllipseAnnotation else { return nil }
                        return EllipseAnnotation(
                            id: ellipse.id,
                            rect: ellipse.rect,
                            strokeColor: ellipse.strokeColor,
                            fillColor: value,
                            strokeWidth: ellipse.strokeWidth,
                            rotationDegrees: ellipse.rotationDegrees
                        )
                    }
                ),
                label: L("Fill:")
            )
        }
    }

    @ViewBuilder
    private func selectedLineEditor(_ line: LineAnnotation) -> some View {
        Label(L("Line"), systemImage: "line.diagonal")
            .font(.system(size: 9))
            .foregroundStyle(.secondary)

        colorControls(
            selectedBinding(
                fallback: line.color,
                get: { ($0 as? LineAnnotation)?.color },
                set: { annotation, value in
                    guard let line = annotation as? LineAnnotation else { return nil }
                    return LineAnnotation(
                        id: line.id,
                        start: line.start,
                        end: line.end,
                        color: value,
                        strokeWidth: line.strokeWidth,
                        isDashed: line.isDashed
                    )
                }
            )
        )

        strokeWidthControls(
            selectedBinding(
                fallback: line.strokeWidth,
                get: { ($0 as? LineAnnotation)?.strokeWidth },
                set: { annotation, value in
                    guard let line = annotation as? LineAnnotation else { return nil }
                    return LineAnnotation(
                        id: line.id,
                        start: line.start,
                        end: line.end,
                        color: line.color,
                        strokeWidth: value,
                        isDashed: line.isDashed
                    )
                }
            )
        )

        Toggle(
            L("Dashed"),
            isOn: selectedBinding(
                fallback: line.isDashed,
                get: { ($0 as? LineAnnotation)?.isDashed },
                set: { annotation, value in
                    guard let line = annotation as? LineAnnotation else { return nil }
                    return LineAnnotation(
                        id: line.id,
                        start: line.start,
                        end: line.end,
                        color: line.color,
                        strokeWidth: line.strokeWidth,
                        isDashed: value
                    )
                }
            )
        )
    }

    @ViewBuilder
    private func selectedStrokeEditor(
        title: String,
        iconName: String,
        fallbackColor: NSColor,
        fallbackWidth: CGFloat,
        colorGet: @escaping ((any Annotation) -> NSColor?),
        widthGet: @escaping ((any Annotation) -> CGFloat?),
        update: @escaping ((any Annotation, NSColor, CGFloat) -> (any Annotation)?)
    ) -> some View {
        Label(L(title), systemImage: iconName)
            .font(.system(size: 9))
            .foregroundStyle(.secondary)

        let colorBinding = selectedBinding(
            fallback: fallbackColor,
            get: colorGet,
            set: { annotation, color in
                update(annotation, color, widthGet(annotation) ?? fallbackWidth)
            }
        )

        let widthBinding = selectedBinding(
            fallback: fallbackWidth,
            get: widthGet,
            set: { annotation, width in
                update(annotation, colorGet(annotation) ?? fallbackColor, width)
            }
        )

        colorControls(colorBinding)
        strokeWidthControls(widthBinding)
    }

    @ViewBuilder
    private func selectedCounterEditor(_ counter: CounterAnnotation) -> some View {
        Label(L("Counter"), systemImage: "number")
            .font(.system(size: 9))
            .foregroundStyle(.secondary)

        colorControls(
            selectedBinding(
                fallback: counter.color,
                get: { ($0 as? CounterAnnotation)?.color },
                set: { annotation, value in
                    guard let counter = annotation as? CounterAnnotation else { return nil }
                    return CounterAnnotation(
                        id: counter.id,
                        position: counter.position,
                        value: counter.value,
                        style: counter.style,
                        color: value
                    )
                }
            )
        )

        Picker(
            L("Style"),
            selection: selectedBinding(
                fallback: counter.style,
                get: { ($0 as? CounterAnnotation)?.style },
                set: { annotation, value in
                    guard let counter = annotation as? CounterAnnotation else { return nil }
                    return CounterAnnotation(
                        id: counter.id,
                        position: counter.position,
                        value: counter.value,
                        style: value,
                        color: counter.color
                    )
                }
            )
        ) {
            ForEach(CounterStyle.allCases, id: \.self) { style in
                Text(Localization.string(style.displayName)).tag(style)
            }
        }
        .frame(width: 120)
    }

    @ViewBuilder
    private func selectedBlurEditor(_ blur: BlurAnnotation) -> some View {
        Label(L("Blur"), systemImage: "drop.halffull")
            .font(.system(size: 9))
            .foregroundStyle(.secondary)

        let intensityBinding = selectedBinding(
            fallback: blur.intensity,
            get: { ($0 as? BlurAnnotation)?.intensity },
            set: { annotation, value in
                guard let blur = annotation as? BlurAnnotation else { return nil }
                return BlurAnnotation(
                    id: blur.id,
                    rect: blur.rect,
                    intensity: value,
                    sourceImage: blur.sourceImage
                )
            }
        )

        HStack(spacing: 4) {
            Text(L("Intensity:"))
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
            Slider(value: intensityBinding, in: 1...50)
                .frame(width: 100)
        }
    }

    @ViewBuilder
    private func selectedPixelateEditor(_ pixelate: PixelateAnnotation) -> some View {
        Label(L("Pixelate"), systemImage: "squareshape.split.3x3")
            .font(.system(size: 9))
            .foregroundStyle(.secondary)

        let blockSizeBinding = selectedBinding(
            fallback: pixelate.blockSize,
            get: { ($0 as? PixelateAnnotation)?.blockSize },
            set: { annotation, value in
                guard let pixelate = annotation as? PixelateAnnotation else { return nil }
                return PixelateAnnotation(
                    id: pixelate.id,
                    rect: pixelate.rect,
                    blockSize: value,
                    sourceImage: pixelate.sourceImage
                )
            }
        )

        HStack(spacing: 4) {
            Text(L("Block size:"))
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
            Slider(value: blockSizeBinding, in: 4...40)
                .frame(width: 100)
        }
    }

    @ViewBuilder
    private func selectedSpotlightEditor(_ spotlight: SpotlightAnnotation) -> some View {
        Label(L("Spotlight"), systemImage: "flashlight.on.fill")
            .font(.system(size: 9))
            .foregroundStyle(.secondary)

        let dimBinding = selectedBinding(
            fallback: spotlight.dimOpacity,
            get: { ($0 as? SpotlightAnnotation)?.dimOpacity },
            set: { annotation, value in
                guard let spotlight = annotation as? SpotlightAnnotation else { return nil }
                return SpotlightAnnotation(
                    id: spotlight.id,
                    rect: spotlight.rect,
                    dimOpacity: value
                )
            }
        )

        HStack(spacing: 4) {
            Text(L("Dim:"))
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
            Slider(value: dimBinding, in: 0.1...0.9)
                .frame(width: 100)
        }
    }

    @ViewBuilder
    private func selectedCropEditor(_ crop: CropAnnotation) -> some View {
        Label(L("Crop"), systemImage: "crop")
            .font(.system(size: 9))
            .foregroundStyle(.secondary)

        Text("\(L("Size:")) \(Int(crop.rect.width)) × \(Int(crop.rect.height))")
            .font(.system(size: 9))
            .foregroundStyle(.secondary)
    }

    private func selectedBinding<Value>(
        fallback: @autoclosure @escaping () -> Value,
        get: @escaping ((any Annotation) -> Value?),
        set: @escaping ((any Annotation, Value) -> (any Annotation)?),
        onSet: ((Value) -> Void)? = nil
    ) -> Binding<Value> {
        Binding(
            get: {
                guard let selectedAnnotation = editableSelectedAnnotations.first else {
                    return fallback()
                }
                return get(selectedAnnotation) ?? fallback()
            },
            set: { newValue in
                onSet?(newValue)
                applyToEditableSelectedAnnotations { annotation in
                    set(annotation, newValue)
                }
            }
        )
    }

    private func applyToEditableSelectedAnnotations(
        _ transform: ((any Annotation) -> (any Annotation)?)
    ) {
        let annotations = editableSelectedAnnotations
        guard !annotations.isEmpty else { return }

        let primaryID = canvasState.selectedAnnotationID
        var didApplyUpdate = false

        for source in annotations {
            guard let updated = transform(source) else { continue }
            updated.zOrder = source.zOrder
            updated.isVisible = source.isVisible
            canvasState.replaceAnnotation(updated, recordUndo: true)
            didApplyUpdate = true
        }

        guard didApplyUpdate else { return }

        let selectionIDs = Set(annotations.map { $0.id })
        canvasState.selectedAnnotationIDs = selectionIDs
        if let primaryID, selectionIDs.contains(primaryID) {
            canvasState.selectedAnnotationID = primaryID
        } else {
            canvasState.selectedAnnotationID = annotations.first?.id
        }
        onCanvasChanged?()
    }

    private func makeTextAnnotation(
        from source: TextAnnotation,
        text: String? = nil,
        fontName: String? = nil,
        fontSize: CGFloat? = nil,
        color: NSColor? = nil,
        isBold: Bool? = nil,
        isItalic: Bool? = nil,
        hasBackground: Bool? = nil
    ) -> TextAnnotation {
        let updated = TextAnnotation(
            id: source.id,
            position: source.position,
            text: text ?? source.text,
            fontName: fontName ?? source.fontName,
            fontSize: fontSize ?? source.fontSize,
            color: color ?? source.color,
            rotationDegrees: source.rotationDegrees
        )
        updated.isBold = isBold ?? source.isBold
        updated.isItalic = isItalic ?? source.isItalic
        updated.hasBackground = hasBackground ?? source.hasBackground
        return updated
    }

    private var colorControls: some View {
        colorControls($toolManager.strokeColor)
    }

    private var textColorBinding: Binding<NSColor> {
        selectedBinding(
            fallback: toolManager.strokeColor,
            get: { ($0 as? TextAnnotation)?.color },
            set: { annotation, value in
                guard let text = annotation as? TextAnnotation else { return nil }
                return makeTextAnnotation(from: text, color: value)
            },
            onSet: { newValue in
                toolManager.strokeColor = newValue
            }
        )
    }

    private var textFontNameBinding: Binding<String> {
        selectedBinding(
            fallback: toolManager.fontName,
            get: { ($0 as? TextAnnotation)?.fontName },
            set: { annotation, value in
                guard let text = annotation as? TextAnnotation else { return nil }
                return makeTextAnnotation(from: text, fontName: value)
            },
            onSet: { newValue in
                toolManager.fontName = newValue
            }
        )
    }

    private var textFontSizeBinding: Binding<CGFloat> {
        selectedBinding(
            fallback: toolManager.fontSize,
            get: { ($0 as? TextAnnotation)?.fontSize },
            set: { annotation, value in
                guard let text = annotation as? TextAnnotation else { return nil }
                return makeTextAnnotation(from: text, fontSize: value)
            },
            onSet: { newValue in
                toolManager.fontSize = newValue
            }
        )
    }

    private var defaultTextStyleControls: some View {
        textStyleControls(
            bold: $toolManager.textIsBold,
            italic: $toolManager.textIsItalic,
            background: $toolManager.textHasBackground
        )
    }

    private func textStyleControls(
        bold: Binding<Bool>,
        italic: Binding<Bool>,
        background: Binding<Bool>
    ) -> some View {
        HStack(spacing: 2) {
            Toggle(isOn: bold) {
                Image(systemName: "bold")
            }
            .help(L("Bold"))

            Toggle(isOn: italic) {
                Image(systemName: "italic")
            }
            .help(L("Italic"))

            Toggle(isOn: background) {
                Image(systemName: "rectangle.fill")
            }
            .help(L("Background"))
        }
        .toggleStyle(.button)
        .controlSize(.small)
        .accessibilityLabel(L("Text style"))
    }

    private func L(_ key: String) -> String {
        Localization.string(key)
    }

    private func colorControls(_ colorBinding: Binding<NSColor>, label: String = "Color:") -> some View {
        HStack(spacing: 4) {
            Text(L(label))
                .font(.system(size: 9))
                .foregroundStyle(.secondary)

            ForEach(HighlighterColorPreset.common) { preset in
                let isSelected = colorsMatch(colorBinding.wrappedValue, preset.color)
                ColorPresetButton(
                    color: preset.color,
                    isSelected: isSelected,
                    accessibilityName: L(preset.name)
                ) {
                    colorBinding.wrappedValue = preset.color
                }
            }

            InlineColorPickerButton(selectedColor: colorBinding)
        }
    }

    private func highlighterColorControls(_ colorBinding: Binding<NSColor>) -> some View {
        colorControls(colorBinding)
    }

    private func colorsMatch(_ lhs: NSColor, _ rhs: NSColor) -> Bool {
        let lhsSRGB = lhs.usingColorSpace(.sRGB) ?? lhs
        let rhsSRGB = rhs.usingColorSpace(.sRGB) ?? rhs
        return lhsSRGB.isEqual(rhsSRGB)
    }

    @ViewBuilder
    private func selectedHighlighterEditor(_ highlighter: HighlighterAnnotation) -> some View {
        Label(L("Highlighter"), systemImage: "highlighter")
            .font(.system(size: 9))
            .foregroundStyle(.secondary)

        highlighterColorControls(
            selectedBinding(
                fallback: highlighter.color,
                get: { ($0 as? HighlighterAnnotation)?.color },
                set: { annotation, color in
                    guard let highlight = annotation as? HighlighterAnnotation else { return nil }
                    return HighlighterAnnotation(
                        id: highlight.id,
                        points: highlight.points,
                        color: color,
                        strokeWidth: highlight.strokeWidth
                    )
                },
                onSet: { toolManager.highlighterColor = $0 }
            )
        )
        strokeWidthControls(
            selectedBinding(
                fallback: highlighter.strokeWidth,
                get: { ($0 as? HighlighterAnnotation)?.strokeWidth },
                set: { annotation, width in
                    guard let highlight = annotation as? HighlighterAnnotation else { return nil }
                    return HighlighterAnnotation(
                        id: highlight.id,
                        points: highlight.points,
                        color: highlight.color,
                        strokeWidth: width
                    )
                }
            )
        )
    }

    private var strokeWidthControls: some View {
        strokeWidthControls($toolManager.strokeWidth)
    }

    private func strokeWidthControls(_ widthBinding: Binding<CGFloat>) -> some View {
        sliderWithNumericInput(label: L("Width:"), value: widthBinding, in: 1...80)
    }

    private func fontPicker(_ selection: Binding<String>) -> some View {
        let fonts = fontOptions(including: selection.wrappedValue)
        return Picker(L("Font"), selection: selection) {
            ForEach(fonts, id: \.self) { fontName in
                Text(fontName).tag(fontName)
            }
        }
        .pickerStyle(.menu)
        .frame(width: 130)
    }

    private func fontOptions(including currentSelection: String) -> [String] {
        // TextAnnotation renders with NSFont(name:), which needs a concrete
        // PostScript name rather than a family such as “Helvetica Neue”.
        // Exposing real faces makes every menu selection visible on canvas.
        var fonts = Set<String>()
        for family in NSFontManager.shared.availableFontFamilies {
            for member in NSFontManager.shared.availableMembers(ofFontFamily: family) ?? [] {
                if let postScriptName = member.first as? String, !postScriptName.isEmpty {
                    fonts.insert(postScriptName)
                }
            }
        }
        if !currentSelection.isEmpty && !fonts.contains(currentSelection) {
            fonts.insert(currentSelection)
        }
        return fonts.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private func sliderWithNumericInput(
        label: String,
        value: Binding<CGFloat>,
        in range: ClosedRange<CGFloat>,
        step: CGFloat = 1,
        fractionDigits: Int = 0
    ) -> some View {
        // Supplying `step` directly to SwiftUI's macOS Slider draws one tick
        // mark for every discrete value.  In a compact toolbar, 80 ticks turn
        // into a distracting gray line below the track.  Snap the binding
        // instead, keeping the same discrete values without showing ticks.
        let steppedValue = Binding<CGFloat>(
            get: { value.wrappedValue },
            set: { candidate in
                let clamped = min(max(candidate, range.lowerBound), range.upperBound)
                let snapped = range.lowerBound + ((clamped - range.lowerBound) / step).rounded() * step
                value.wrappedValue = min(max(snapped, range.lowerBound), range.upperBound)
            }
        )

        return HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
            Slider(value: steppedValue, in: range)
                .frame(width: 72)
            TextField(
                "",
                value: numericInputBinding(for: value, in: range),
                format: .number.precision(.fractionLength(fractionDigits))
            )
            .textFieldStyle(.plain)
            .multilineTextAlignment(.trailing)
            .padding(.horizontal, 6)
            .frame(width: 42, height: 22)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
            }
        }
    }

    private func numericInputBinding(
        for value: Binding<CGFloat>,
        in range: ClosedRange<CGFloat>
    ) -> Binding<Double> {
        Binding<Double>(
            get: { Double(value.wrappedValue) },
            set: { newValue in
                let clamped = min(max(CGFloat(newValue), range.lowerBound), range.upperBound)
                value.wrappedValue = clamped
            }
        )
    }

    private func iconToolPicker(group: PrimaryToolGroup) -> some View {
        let availableTools = ToolType.tools(for: group)
        return HStack(spacing: 6) {
            ForEach(availableTools, id: \.self) { tool in
                let isSelected = toolManager.currentTool == tool
                let isHovered = hoveredTool == tool

                Button {
                    toolManager.currentTool = tool
                } label: {
                    Image(systemName: tool.iconName)
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 26, height: 24)
                        .foregroundStyle(isSelected ? Color.primary : Color.primary.opacity(isHovered ? 0.95 : 0.68))
                        .background {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(
                                    isSelected
                                        ? Color(nsColor: .controlBackgroundColor)
                                        : Color.primary.opacity(isHovered ? 0.10 : 0.04)
                                )
                        }
                        .overlay {
                            if isSelected || isHovered {
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .strokeBorder(
                                        Color.primary.opacity(isSelected ? 0.16 : 0.12),
                                        lineWidth: 1
                                    )
                            }
                        }
                }
                .buttonStyle(.plain)
                .help(tool.localizedDisplayName)
                .onHover { hovering in
                    if hovering {
                        hoveredTool = tool
                    } else if hoveredTool == tool {
                        hoveredTool = nil
                    }
                }
            }
        }
        .padding(.horizontal, 2)
    }

    private var showsStrokeWidth: Bool {
        switch toolManager.currentTool {
        case .arrow, .rectangle, .ellipse, .line, .pencil, .highlighter:
            return true
        default:
            return false
        }
    }

    private var rectangleFillOptions: some View {
        fillOptions(label: L("Fill"))
    }

    private var ellipseFillOptions: some View {
        fillOptions(label: L("Fill"))
    }

    @ViewBuilder
    private func fillOptions(label: String) -> some View {
        Toggle(label, isOn: Binding(
            get: { toolManager.fillColor != nil },
            set: { isEnabled in
                if isEnabled {
                    let opacity = min(max(toolManager.fillOpacity, 0), 1)
                    toolManager.fillColor = toolManager.strokeColor.withAlphaComponent(opacity)
                } else {
                    toolManager.fillColor = nil
                }
            }
        ))

        if toolManager.fillColor != nil {
            colorControls(fillColorBinding, label: L("Fill:"))
        }
    }

    private var fillColorBinding: Binding<NSColor> {
        Binding(
            get: {
                toolManager.fillColor ?? toolManager.strokeColor.withAlphaComponent(min(max(toolManager.fillOpacity, 0), 1))
            },
            set: { newColor in
                toolManager.fillColor = newColor
                toolManager.fillOpacity = newColor.alphaComponent
            }
        )
    }

}

private struct InlineColorPickerButton: View {
    @Binding var selectedColor: NSColor
    @State private var isPickerPresented = false

    var body: some View {
        Button {
            isPickerPresented.toggle()
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color(nsColor: selectedColor))
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.30), lineWidth: 1)
                Image(systemName: "ellipsis")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Color.primary.opacity(0.72))
            }
            .frame(width: 22, height: 22)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Localization.string("Custom Color"))
        .popover(isPresented: $isPickerPresented, arrowEdge: .bottom) {
            InlineHSBColorPicker(selectedColor: $selectedColor)
                .padding(12)
        }
    }
}

private struct ColorPresetButton: View {
    let color: NSColor
    let isSelected: Bool
    let accessibilityName: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Color(nsColor: color))
                .overlay {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(
                            isSelected ? Color.primary.opacity(0.82) : Color.primary.opacity(0.22),
                            lineWidth: isSelected ? 2 : 1
                        )
                }
                .frame(width: 22, height: 22)
        }
        .buttonStyle(.plain)
        .help(accessibilityName)
        .accessibilityLabel(accessibilityName)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct InlineHSBColorPicker: View {
    @Binding var selectedColor: NSColor
    @State private var hue: CGFloat = 0
    @State private var saturation: CGFloat = 1
    @State private var brightness: CGFloat = 1
    @State private var opacity: CGFloat = 1
    @State private var isSynchronizing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(Localization.string("Pick Color"))
                .font(.system(size: 9))
                .foregroundStyle(.secondary)

            SaturationBrightnessField(
                hue: hue,
                saturation: $saturation,
                brightness: $brightness
            )
            .frame(width: 180, height: 120)

            HueField(hue: $hue)
                .frame(width: 180, height: 14)

            HStack(spacing: 8) {
                Text(Localization.string("Opacity"))
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .frame(width: 48, alignment: .leading)
                Slider(value: $opacity, in: 0...1)
                    .frame(width: 110)
                Text("\(Int(opacity * 100))%")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 36, alignment: .trailing)
            }
        }
        .onAppear {
            syncFromSelectedColor()
        }
        .onChange(of: hue) { _, _ in
            applyColor()
        }
        .onChange(of: saturation) { _, _ in
            applyColor()
        }
        .onChange(of: brightness) { _, _ in
            applyColor()
        }
        .onChange(of: opacity) { _, _ in
            applyColor()
        }
    }

    private func syncFromSelectedColor() {
        guard !isSynchronizing else { return }
        isSynchronizing = true

        let rgb = selectedColor.usingColorSpace(.deviceRGB) ?? selectedColor
        var h: CGFloat = 0
        var s: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 1
        rgb.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        hue = h
        saturation = s
        brightness = b
        opacity = a

        isSynchronizing = false
    }

    private func applyColor() {
        guard !isSynchronizing else { return }
        selectedColor = NSColor(
            calibratedHue: clamp01(hue),
            saturation: clamp01(saturation),
            brightness: clamp01(brightness),
            alpha: clamp01(opacity)
        )
    }

    private func clamp01(_ value: CGFloat) -> CGFloat {
        min(max(value, 0), 1)
    }
}

private struct SaturationBrightnessField: View {
    let hue: CGFloat
    @Binding var saturation: CGFloat
    @Binding var brightness: CGFloat

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let height = proxy.size.height
            let knobX = min(max(saturation * width, 0), width)
            let knobY = min(max((1 - brightness) * height, 0), height)

            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(nsColor: NSColor(calibratedHue: hue, saturation: 1, brightness: 1, alpha: 1)))

                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [.white, .clear],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )

                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [.clear, .black],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )

                Circle()
                    .strokeBorder(Color.white.opacity(0.95), lineWidth: 2)
                    .background(Circle().fill(Color.clear))
                    .frame(width: 12, height: 12)
                    .shadow(color: .black.opacity(0.45), radius: 2, y: 1)
                    .position(x: knobX, y: knobY)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.black.opacity(0.28), lineWidth: 1)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let x = min(max(value.location.x, 0), width)
                        let y = min(max(value.location.y, 0), height)
                        saturation = width > 0 ? (x / width) : 0
                        brightness = height > 0 ? (1 - y / height) : 1
                    }
            )
        }
    }
}

private struct HueField: View {
    @Binding var hue: CGFloat

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let knobX = min(max(hue * width, 0), width)

            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [.red, .yellow, .green, .cyan, .blue, .purple, .red],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )

                Circle()
                    .strokeBorder(Color.white.opacity(0.95), lineWidth: 2)
                    .background(Circle().fill(Color.clear))
                    .frame(width: 12, height: 12)
                    .shadow(color: .black.opacity(0.45), radius: 2, y: 1)
                    .position(x: knobX, y: proxy.size.height / 2)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(Color.black.opacity(0.28), lineWidth: 1)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let x = min(max(value.location.x, 0), width)
                        hue = width > 0 ? (x / width) : 0
                    }
            )
        }
    }
}
