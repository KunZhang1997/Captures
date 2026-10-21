// Deterministic fictional content for the public prototype. Run from repo root.
import AppKit

let width = 1440
let height = 3600
let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
    isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
let context = NSGraphicsContext.current!.cgContext
context.translateBy(x: 0, y: CGFloat(height))
context.scaleBy(x: 1, y: -1)

func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ color: NSColor, radius: CGFloat = 0) {
    color.setFill()
    NSBezierPath(roundedRect: NSRect(x: x, y: y, width: w, height: h), xRadius: radius, yRadius: radius).fill()
}

func label(_ text: String, _ x: CGFloat, _ y: CGFloat, size: CGFloat, color: NSColor, bold: Bool = false) {
    context.saveGState()
    context.translateBy(x: x, y: y)
    context.scaleBy(x: 1, y: -1)
    let font = bold ? NSFont.boldSystemFont(ofSize: size) : NSFont.systemFont(ofSize: size)
    (text as NSString).draw(at: NSPoint(x: 0, y: -font.ascender), withAttributes: [.font: font, .foregroundColor: color])
    context.restoreGState()
}

let ink = NSColor(calibratedRed: 0.12, green: 0.17, blue: 0.25, alpha: 1)
let muted = NSColor(calibratedWhite: 0.44, alpha: 1)
let blue = NSColor(calibratedRed: 0.16, green: 0.39, blue: 0.89, alpha: 1)
rect(0, 0, CGFloat(width), CGFloat(height), NSColor(calibratedWhite: 0.96, alpha: 1))
rect(0, 0, CGFloat(width), 90, ink)
label("Captures  /  Sample workspace", 72, 35, size: 25, color: .white, bold: true)
label("FICTIONAL DEMO CONTENT", 1000, 38, size: 17, color: .white)
rect(64, 126, 1312, 300, .white, radius: 22)
label("Project Atlas", 104, 176, size: 46, color: ink, bold: true)
label("A sample project journal for capture, OCR and annotation demos.", 104, 248, size: 24, color: muted)
label("Everything below is invented. No accounts, messages or browsing history.", 104, 295, size: 22, color: muted)
label("12 notes     4 milestones     Local workspace", 104, 363, size: 20, color: blue)

let titles = ["Plan the first version", "Sketch the workflow", "Collect sample material", "Make the details clear", "Review the long page", "Prepare the handoff"]
let bodies = [
    ["Start with a small, useful workflow.", "Capture the idea, add a note, and keep the result close by.", "Use fictional material while trying different layouts."],
    ["Choose a region or click a highlighted window.", "Add an arrow or a short label to explain the important part.", "Copy, save, edit or keep the image floating on the page."],
    ["This document is a generated test fixture.", "Its headings and cards give scrolling capture clear visual anchors.", "No external service is needed to generate these pixels."],
    ["Readable type and quiet spacing make a reference useful.", "Keep colors consistent and labels short.", "OCR can extract the sample text directly on this Mac."],
    ["Scroll down at a steady pace and inspect the stitched result.", "Repeated rows have different positions and progress values.", "Stop by choosing a result action when the full section is captured."],
    ["Export a clean image and include only the necessary context.", "Keep source, prototype and release verification easy to distinguish.", "The next person should be able to reproduce the example."]
]
for i in 0..<titles.count {
    let top = CGFloat(470 + i * 490)
    rect(64, top, 1312, 452, .white, radius: 22)
    rect(104, top + 36, 64, 40, NSColor(calibratedRed: 0.91, green: 0.94, blue: 1, alpha: 1), radius: 10)
    label(String(format: "%02d", i + 1), 119, top + 45, size: 20, color: blue, bold: true)
    label(titles[i], 190, top + 41, size: 31, color: ink, bold: true)
    for (row, text) in bodies[i].enumerated() {
        label(text, 104, top + CGFloat(118 + row * 45), size: 24, color: muted)
    }
    for column in 0..<3 {
        let left = CGFloat(104 + column * 410)
        rect(left, top + 285, 380, 120, NSColor(calibratedWhite: 0.965, alpha: 1), radius: 12)
        label(["Research", "Build", "Review"][column], left + 20, top + 305, size: 20, color: ink, bold: true)
        rect(left + 20, top + 359, 335, 9, NSColor(calibratedWhite: 0.88, alpha: 1), radius: 4)
        rect(left + 20, top + 359, CGFloat(65 + ((i * 61 + column * 83) % 260)), 9, blue, radius: 4)
    }
}
label("End of fictional sample  /  Generated locally for Captures", 72, 3485, size: 22, color: muted)
NSGraphicsContext.restoreGraphicsState()
let destination = URL(fileURLWithPath: "design/scroll-capture-reference.png")
try bitmap.representation(using: .png, properties: [:])!.write(to: destination)
print("Generated fictional reference: \(width) x \(height)")
