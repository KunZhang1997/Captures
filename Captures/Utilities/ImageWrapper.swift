import AppKit

final class ImageWrapper: NSObject {
    let image: CGImage
    /// Backing scale of the image's source display (1 when unknown).
    let scale: CGFloat

    init(_ image: CGImage, scale: CGFloat = 1) {
        self.image = image
        self.scale = scale
    }
}

/// Synchronous handoff used when the source capture must stay alive until a
/// persistent pin has been written successfully.
final class PinScreenshotRequest: NSObject {
    let image: CGImage
    let scale: CGFloat
    var succeeded = false

    init(_ image: CGImage, scale: CGFloat) {
        self.image = image
        self.scale = scale
    }
}
