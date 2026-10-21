import AppKit

final class ScrollStitcher {
    /// Hard ceiling on the stitched output height (pixels) so endless feeds
    /// can't grow memory without bound.
    let maxHeight: Int

    private let initialImage: CGImage
    private var strips: [CGImage] = []
    private var lastAcceptedFrame: CGImage
    private(set) var appendedHeight: Int = 0

    init(initialImage: CGImage, maxHeight: Int = 20_000) {
        self.initialImage = initialImage
        self.lastAcceptedFrame = initialImage
        self.maxHeight = maxHeight
    }

    var hasAppendedContent: Bool {
        appendedHeight > 0
    }

    var currentHeight: Int {
        initialImage.height + appendedHeight
    }

    var reachedMaxHeight: Bool {
        currentHeight >= maxHeight
    }

    var image: CGImage {
        makeImage() ?? initialImage
    }

    /// Builds a bounded thumbnail directly from the retained segments. This
    /// avoids repeatedly allocating the full (potentially 20,000 px tall)
    /// stitched image merely to update the tiny live progress preview.
    func previewImage(
        maxPixelWidth: Int = 104,
        maxPixelHeight: Int = 520
    ) -> CGImage? {
        guard maxPixelWidth > 0, maxPixelHeight > 0 else { return nil }

        let scale = min(
            1,
            min(
                CGFloat(maxPixelWidth) / CGFloat(initialImage.width),
                CGFloat(maxPixelHeight) / CGFloat(currentHeight)
            )
        )
        let previewWidth = max(1, Int((CGFloat(initialImage.width) * scale).rounded()))
        let previewHeight = max(1, Int((CGFloat(currentHeight) * scale).rounded()))

        guard let context = CGContext(
            data: nil,
            width: previewWidth,
            height: previewHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: initialImage.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }

        context.interpolationQuality = .medium
        var segmentTop = CGFloat(previewHeight)
        for segment in [initialImage] + strips {
            let segmentHeight = CGFloat(segment.height) * scale
            context.draw(
                segment,
                in: CGRect(
                    x: 0,
                    y: segmentTop - segmentHeight,
                    width: CGFloat(previewWidth),
                    height: segmentHeight
                )
            )
            segmentTop -= segmentHeight
        }
        return context.makeImage()
    }

    @discardableResult
    func append(frame: CGImage, verticalShift: Int) -> Bool {
        guard frame.width == initialImage.width, !reachedMaxHeight else {
            return false
        }

        let headroom = maxHeight - currentHeight
        let newContentHeight = max(0, min(min(verticalShift, frame.height - 1), headroom))
        guard newContentHeight >= 4 else {
            return false
        }

        let stripRect = CGRect(
            x: 0,
            y: frame.height - newContentHeight,
            width: frame.width,
            height: newContentHeight
        ).integral

        // A second defensive gate protects the final image even if a moving
        // cursor, spinner, or repeating layout fools the motion estimator.
        // When the proposed "new" bottom strip is effectively the same as
        // the previous viewport tail, appending it would create exactly the
        // repeated blocks seen in long captures of live chat pages.
        guard !isNearDuplicateTail(
            previous: lastAcceptedFrame,
            current: frame,
            height: newContentHeight
        ) else {
            return false
        }

        // The same-coordinate tail check above catches stationary frames, but
        // not a reversed/reflowed viewport whose proposed strip has already
        // appeared higher in the last accepted frame. Reject a content-bearing
        // block when it can be located elsewhere in that viewport; otherwise
        // the old paragraph would be appended again before genuinely new text.
        guard !containsPreviouslyVisibleBlock(
            previous: lastAcceptedFrame,
            current: frame,
            stripRect: stripRect
        ) else {
            return false
        }

        // Copy the strip into its own backing store; a bare cropping(to:)
        // would keep the entire source frame alive for the session.
        guard let strip = copyStrip(from: frame, rect: stripRect) else {
            return false
        }

        strips.append(strip)
        appendedHeight += strip.height
        lastAcceptedFrame = frame
        return true
    }

    private func isNearDuplicateTail(
        previous: CGImage,
        current: CGImage,
        height: Int
    ) -> Bool {
        guard previous.width == current.width,
              previous.height == current.height,
              height > 0 else {
            return false
        }

        let rect = CGRect(
            x: 0,
            y: current.height - height,
            width: current.width,
            height: height
        ).integral
        guard let previousStrip = previous.cropping(to: rect),
              let currentStrip = current.cropping(to: rect) else {
            return false
        }

        let sampleWidth = max(1, min(160, current.width))
        let sampleHeight = max(1, min(64, height))
        guard let previousPixels = grayscalePixels(
            from: previousStrip,
            width: sampleWidth,
            height: sampleHeight
        ), let currentPixels = grayscalePixels(
            from: currentStrip,
            width: sampleWidth,
            height: sampleHeight
        ), previousPixels.count == currentPixels.count,
           !previousPixels.isEmpty else {
            return false
        }

        var totalDifference = 0
        var materiallyChangedPixels = 0
        for index in previousPixels.indices {
            let difference = abs(Int(previousPixels[index]) - Int(currentPixels[index]))
            totalDifference += difference
            if difference >= 8 {
                materiallyChangedPixels += 1
            }
        }

        let count = Double(previousPixels.count)
        let meanDifference = Double(totalDifference) / count
        let changedRatio = Double(materiallyChangedPixels) / count
        return meanDifference < 1.25 && changedRatio < 0.02
    }

    private func containsPreviouslyVisibleBlock(
        previous: CGImage,
        current: CGImage,
        stripRect: CGRect
    ) -> Bool {
        guard previous.width == current.width,
              previous.height == current.height,
              stripRect.height > 0,
              let candidateStrip = current.cropping(to: stripRect) else {
            return false
        }

        let sampleWidth = max(1, min(160, current.width))
        // Preserve native vertical rows so a previously rendered paragraph
        // keeps the same row sequence. Only horizontal downsampling is needed
        // to keep this guard inexpensive.
        let minimumProbeHeight = 24
        guard candidateStrip.height >= minimumProbeHeight,
              let previousPixels = grayscalePixels(
                from: previous,
                width: sampleWidth,
                height: previous.height
              ), let candidatePixels = grayscalePixels(
                from: candidateStrip,
                width: sampleWidth,
                height: candidateStrip.height
              ) else {
            return false
        }

        let xStart = max(0, Int(CGFloat(sampleWidth) * 0.08))
        let xEnd = min(sampleWidth, sampleWidth - xStart)
        guard xEnd - xStart >= 8 else { return false }

        let previousRows = visualRows(
            pixels: previousPixels,
            width: sampleWidth,
            height: previous.height,
            xStart: xStart,
            xEnd: xEnd
        )
        let candidateRows = visualRows(
            pixels: candidatePixels,
            width: sampleWidth,
            height: candidateStrip.height,
            xStart: xStart,
            xEnd: xEnd
        )

        let probeHeight = min(96, max(minimumProbeHeight, candidateRows.count / 2))
        let maximumCandidateStart = candidateRows.count - probeHeight
        let candidateStarts = Array(
            Set([0, maximumCandidateStart / 2, maximumCandidateStart])
        ).sorted()

        for candidateStart in candidateStarts {
            let candidateProbe = candidateRows[candidateStart..<(candidateStart + probeHeight)]
            let detailedRows = candidateProbe.filter(\.hasDetail).count
            guard detailedRows >= max(3, probeHeight / 20) else { continue }

            for previousStart in 0...(previousRows.count - probeHeight) {
                var matchingRows = 0
                var matchingDetailedRows = 0
                for rowOffset in 0..<probeHeight {
                    let candidateRow = candidateRows[candidateStart + rowOffset]
                    let previousRow = previousRows[previousStart + rowOffset]
                    if candidateRow.fingerprint == previousRow.fingerprint {
                        matchingRows += 1
                        if candidateRow.hasDetail {
                            matchingDetailedRows += 1
                        }
                    }
                }

                if matchingRows * 100 >= probeHeight * 86,
                   matchingDetailedRows * 100 >= detailedRows * 75 {
                    return true
                }
            }
        }
        return false
    }

    private func visualRows(
        pixels: [UInt8],
        width: Int,
        height: Int,
        xStart: Int,
        xEnd: Int
    ) -> [VisualRow] {
        let binCount = 16
        let usableWidth = xEnd - xStart
        var rows: [VisualRow] = []
        rows.reserveCapacity(height)

        for y in 0..<height {
            let row = y * width
            var fingerprint: UInt64 = 14_695_981_039_346_656_037
            var edgeCount = 0

            for bin in 0..<binCount {
                let binStart = xStart + (usableWidth * bin / binCount)
                let binEnd = xStart + (usableWidth * (bin + 1) / binCount)
                var luminanceTotal = 0
                for x in binStart..<binEnd {
                    luminanceTotal += Int(pixels[row + x])
                    if x > xStart,
                       abs(Int(pixels[row + x]) - Int(pixels[row + x - 1])) >= 8 {
                        edgeCount += 1
                    }
                }
                let count = max(1, binEnd - binStart)
                let quantizedAverage = UInt64((luminanceTotal / count) / 8)
                fingerprint ^= quantizedAverage
                fingerprint &*= 1_099_511_628_211
            }

            rows.append(VisualRow(fingerprint: fingerprint, hasDetail: edgeCount >= 2))
        }
        return rows
    }

    private func grayscalePixels(
        from image: CGImage,
        width: Int,
        height: Int
    ) -> [UInt8]? {
        let byteCount = width * height
        guard let data = CFDataCreateMutable(nil, byteCount) else {
            return nil
        }
        CFDataSetLength(data, byteCount)
        guard let pointer = CFDataGetMutableBytePtr(data),
              let context = CGContext(
                data: pointer,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
              ) else {
            return nil
        }

        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return Array(UnsafeBufferPointer(start: pointer, count: byteCount))
    }

    private func copyStrip(from frame: CGImage, rect: CGRect) -> CGImage? {
        guard let cropped = frame.cropping(to: rect),
              let context = CGContext(
                data: nil,
                width: cropped.width,
                height: cropped.height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: frame.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            return nil
        }
        context.interpolationQuality = .none
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: cropped.width, height: cropped.height))
        return context.makeImage()
    }

    /// Composites the initial frame plus all appended strips top-to-bottom.
    /// Positions are computed in native CG space (bottom-left origin) with no
    /// flip transform, so every segment renders upright.
    private func makeImage() -> CGImage? {
        guard hasAppendedContent else { return initialImage }

        let totalHeight = currentHeight
        guard let context = CGContext(
            data: nil,
            width: initialImage.width,
            height: totalHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: initialImage.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }

        context.interpolationQuality = .high

        var segmentTop = totalHeight
        for segment in [initialImage] + strips {
            context.draw(
                segment,
                in: CGRect(
                    x: 0,
                    y: segmentTop - segment.height,
                    width: segment.width,
                    height: segment.height
                )
            )
            segmentTop -= segment.height
        }

        return context.makeImage()
    }
}

private struct VisualRow {
    let fingerprint: UInt64
    let hasDetail: Bool
}
