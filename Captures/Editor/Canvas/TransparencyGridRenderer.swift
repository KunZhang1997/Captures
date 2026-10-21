import AppKit

/// A preview-only transparency grid. It is painted underneath the source
/// image in the editor canvas and is never passed to export or clipboard
/// rendering, so transparent PNG pixels remain transparent after saving.
enum TransparencyGridRenderer {
    static func draw(in context: CGContext, rect: CGRect, tileSize: CGFloat) {
        guard !rect.isEmpty, tileSize > 0 else { return }

        let light = NSColor(calibratedWhite: 0.96, alpha: 1).cgColor
        let dark = NSColor(calibratedWhite: 0.84, alpha: 1).cgColor
        let firstColumn = Int(floor(rect.minX / tileSize))
        let firstRow = Int(floor(rect.minY / tileSize))
        let lastColumn = Int(ceil(rect.maxX / tileSize))
        let lastRow = Int(ceil(rect.maxY / tileSize))

        for row in firstRow..<lastRow {
            for column in firstColumn..<lastColumn {
                let tileRect = CGRect(
                    x: CGFloat(column) * tileSize,
                    y: CGFloat(row) * tileSize,
                    width: tileSize,
                    height: tileSize
                ).intersection(rect)
                guard !tileRect.isEmpty else { continue }
                context.setFillColor((column + row).isMultiple(of: 2) ? light : dark)
                context.fill(tileRect)
            }
        }
    }
}
