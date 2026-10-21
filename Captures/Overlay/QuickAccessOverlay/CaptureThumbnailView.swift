import SwiftUI
import UniformTypeIdentifiers

struct CaptureThumbnailView: View {
    let capture: QuickAccessCapture
    let manager: QuickAccessManager
    let thumbnailWidth: CGFloat
    @State private var isHovering = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color(nsColor: .windowBackgroundColor)

            Image(capture.thumbnail, scale: 1.0, label: Text("Screenshot"))
                .resizable()
                .interpolation(.high)
                .antialiased(true)
                .aspectRatio(contentMode: .fit)
                .frame(width: thumbnailWidth, height: imageHeight)
                .contentShape(Rectangle())
                .onTapGesture {
                    manager.showOnPage(capture)
                }
                .help("Show on Page")

            Button {
                manager.removeCapture(capture.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Color.white)
                    .frame(width: 18, height: 18)
                    .background(Color.red.opacity(0.92), in: Circle())
                    .overlay {
                        Circle()
                            .strokeBorder(Color.white.opacity(0.7), lineWidth: 0.5)
                    }
            }
            .buttonStyle(.plain)
            .help(Localization.string("Close Quick Preview"))
            .padding(8)

            HStack(spacing: 4) {
                quickAction(
                    title: Localization.string("Edit"),
                    icon: "pencil",
                    action: { manager.openInEditor(capture) }
                )
                quickAction(
                    title: Localization.string("OCR"),
                    icon: "text.viewfinder",
                    action: { manager.showOnPage(capture, showingOCR: true) }
                )
                quickAction(
                    title: Localization.string("Pin"),
                    icon: "pin",
                    action: { manager.pin(capture) }
                )
                quickAction(
                    title: Localization.string("Copy"),
                    icon: "doc.on.doc",
                    action: { manager.copy(capture) }
                )
            }
            .padding(4)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.5), lineWidth: 0.5)
            }
            .padding(8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        }
        .clipShape(RoundedRectangle(cornerRadius: CapturesWindowStyle.cornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: CapturesWindowStyle.cornerRadius, style: .continuous)
                .strokeBorder(
                    Color(nsColor: .separatorColor).opacity(isHovering ? 1 : 0.82),
                    lineWidth: 1
                )
        }
        .shadow(color: Color.black.opacity(0.16), radius: 8, y: 3)
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovering = hovering
            }
        }
        .onDrag {
            dragItemProvider()
        }
        .contextMenu {
            Button("Copy") {
                manager.copy(capture)
            }
            Button("Reveal File") {
                manager.reveal(capture)
            }
            Divider()
            Button("Delete", role: .destructive) {
                if !manager.delete(capture) {
                    manager.presentDeleteFailure()
                }
            }
        }
        .transition(
            .asymmetric(
                insertion: .offset(y: -12)
                    .combined(with: .opacity)
                    .combined(with: .scale(scale: 0.97, anchor: .top)),
                removal: .offset(x: 20)
                    .combined(with: .opacity)
            )
        )
    }

    private var imageHeight: CGFloat {
        let ratio = CGFloat(capture.height) / max(1, CGFloat(capture.width))
        return min(170, max(56, thumbnailWidth * ratio))
    }

    private func quickAction(title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color(nsColor: .labelColor))
        .help(title)
    }

    private func dragItemProvider() -> NSItemProvider {
        // Prefer file URL drags when available; external apps usually preserve metadata better.
        if let savedURL = capture.verifiedSavedURL() {
            return NSItemProvider(object: savedURL as NSURL)
        }

        guard let image = capture.resolvedImage() else {
            return NSItemProvider()
        }
        let pointScale = capture.scale > 0 ? capture.scale : 1
        let nsImage = NSImage(
            cgImage: image,
            size: NSSize(
                width: CGFloat(image.width) / pointScale,
                height: CGFloat(image.height) / pointScale
            )
        )
        let provider = NSItemProvider(object: nsImage)
        provider.suggestedName = "Captures Screenshot"

        if let tiffData = nsImage.tiffRepresentation,
           let bitmap = NSBitmapImageRep(data: tiffData),
           let pngData = bitmap.representation(using: .png, properties: [:]) {
            provider.registerDataRepresentation(
                forTypeIdentifier: UTType.png.identifier,
                visibility: .all
            ) { completion in
                completion(pngData, nil)
                return nil
            }
        }

        return provider
    }
}

extension Notification.Name {
    static let openEditor = Notification.Name("openEditor")
    static let editorWillOpen = Notification.Name("editorWillOpen")
    static let pinScreenshot = Notification.Name("pinScreenshot")
}
