import AppKit

struct SymbolAsset {
    let symbolName: String
    let fileName: String
}

let outputDirectory = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "design/post-capture-icons", isDirectory: true)
let assets = [
    SymbolAsset(symbolName: "pencil", fileName: "edit.png"),
    SymbolAsset(symbolName: "pin.fill", fileName: "pin.png"),
    SymbolAsset(symbolName: "doc.on.doc", fileName: "copy.png"),
]

try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

for asset in assets {
    guard let baseImage = NSImage(systemSymbolName: asset.symbolName, accessibilityDescription: nil) else {
        throw NSError(domain: "CapturesPrototypeIcons", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing SF Symbol: \(asset.symbolName)"])
    }

    let pointConfiguration = NSImage.SymbolConfiguration(pointSize: 16, weight: .medium)
    let colorConfiguration = NSImage.SymbolConfiguration(hierarchicalColor: NSColor.black)
    guard let image = baseImage.withSymbolConfiguration(pointConfiguration.applying(colorConfiguration)) else {
        throw NSError(domain: "CapturesPrototypeIcons", code: 2, userInfo: [NSLocalizedDescriptionKey: "Could not configure SF Symbol: \(asset.symbolName)"])
    }

    let logicalSize = NSSize(width: 24, height: 24)
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: 72,
        pixelsHigh: 72,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        throw NSError(domain: "CapturesPrototypeIcons", code: 3, userInfo: [NSLocalizedDescriptionKey: "Could not allocate icon bitmap"])
    }

    bitmap.size = logicalSize
    NSGraphicsContext.saveGraphicsState()
    let context = NSGraphicsContext(bitmapImageRep: bitmap)
    NSGraphicsContext.current = context
    context?.imageInterpolation = .high
    NSColor.clear.setFill()
    NSBezierPath(rect: NSRect(origin: .zero, size: logicalSize)).fill()

    let available = NSSize(width: 16, height: 16)
    let scale = min(available.width / image.size.width, available.height / image.size.height)
    let rendered = NSSize(width: image.size.width * scale, height: image.size.height * scale)
    let rect = NSRect(
        x: (logicalSize.width - rendered.width) / 2,
        y: (logicalSize.height - rendered.height) / 2,
        width: rendered.width,
        height: rendered.height
    )
    image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 0.88)
    NSGraphicsContext.restoreGraphicsState()

    guard let data = bitmap.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "CapturesPrototypeIcons", code: 4, userInfo: [NSLocalizedDescriptionKey: "Could not encode icon: \(asset.symbolName)"])
    }
    try data.write(to: outputDirectory.appendingPathComponent(asset.fileName))
}
