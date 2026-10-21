import AppKit

struct ScrollMotionEstimate {
    let verticalShift: Int
    let confidence: Double
}

struct ScrollMotionEstimator {
    var workingWidth: Int = 360
    var minShift: Int = 14
    var maxShiftRatio: CGFloat = 0.42
    var topInsetRatio: CGFloat = 0.14
    var bottomInsetRatio: CGFloat = 0.12
    var sideInsetRatio: CGFloat = 0.08
    var rowStride: Int = 2
    var columnStride: Int = 3

    func estimate(previous: CGImage, current: CGImage) -> ScrollMotionEstimate? {
        guard let previousFrame = preprocess(previous),
              let currentFrame = preprocess(current),
              previousFrame.width == currentFrame.width,
              previousFrame.height == currentFrame.height else {
            return nil
        }

        let width = previousFrame.width
        let height = previousFrame.height
        let xStart = max(0, Int(CGFloat(width) * sideInsetRatio))
        let xEnd = min(width, width - xStart)
        let yStart = max(0, Int(CGFloat(height) * topInsetRatio))
        let yEnd = min(height, height - Int(CGFloat(height) * bottomInsetRatio))
        let usableHeight = yEnd - yStart
        let maxShift = max(minShift + 1, min(Int(CGFloat(height) * maxShiftRatio), usableHeight - 2))

        guard xEnd - xStart >= 8, usableHeight > minShift else {
            return nil
        }

        var bestShift = 0
        var bestScore = Double.greatestFiniteMagnitude
        var shiftScores: [(shift: Int, score: Double)] = []

        for shift in minShift...maxShift {
            let score = differenceScore(
                previous: previousFrame,
                current: currentFrame,
                xStart: xStart,
                xEnd: xEnd,
                yStart: yStart,
                yEnd: yEnd,
                shift: shift
            )
            guard score.isFinite else { continue }
            shiftScores.append((shift, score))

            if score < bestScore {
                bestScore = score
                bestShift = shift
            }
        }

        guard bestShift > 0, bestScore.isFinite else {
            return nil
        }

        // This stitcher only grows downward. Compare the best forward match
        // with the opposite direction explicitly; otherwise a reverse wheel
        // gesture on a repetitive page can alias to a large positive shift.
        var bestReverseScore = Double.greatestFiniteMagnitude
        for shift in minShift...maxShift {
            let score = differenceScore(
                previous: currentFrame,
                current: previousFrame,
                xStart: xStart,
                xEnd: xEnd,
                yStart: yStart,
                yEnd: yEnd,
                shift: shift
            )
            if score < bestReverseScore {
                bestReverseScore = score
            }
        }
        if bestReverseScore.isFinite {
            let directionSeparation = bestReverseScore - bestScore
            guard directionSeparation >= max(0.55, bestReverseScore * 0.04) else {
                return nil
            }
        }

        // Every non-zero candidate scores as a perfect match when the stream
        // sends the same frame again (for example, after a wheel event reaches
        // the end of a page). Require the matched offset to improve on the
        // stationary comparison, otherwise the coordinator would append a
        // duplicate bottom strip for each incoming frame.
        let stationaryScore = differenceScore(
            previous: previousFrame,
            current: currentFrame,
            xStart: xStart,
            xEnd: xEnd,
            yStart: yStart,
            yEnd: yEnd,
            shift: 0
        )
        guard stationaryScore.isFinite, stationaryScore > bestScore else {
            return nil
        }

        // Repeating rows, cards, or chat messages can produce several nearly
        // identical offsets. A tiny animated patch may make one of those
        // offsets win even when the page itself did not move. Compare the
        // winner with a non-neighbouring runner-up and require a meaningful
        // advantage before treating the frame as new content.
        let runnerUpScore = shiftScores
            .filter { abs($0.shift - bestShift) > 4 }
            .map(\.score)
            .min() ?? .infinity
        let stationaryGain = stationaryScore - bestScore
        // A true scroll produces a much cleaner translation than the
        // stationary alignment. Small animated controls on an otherwise
        // static page can still make a non-zero offset win by a fraction, so
        // require both an absolute and relative improvement.
        let minimumStationaryGain = max(0.50, stationaryScore * 0.12)
        guard stationaryGain >= minimumStationaryGain else {
            return nil
        }

        if runnerUpScore.isFinite {
            let runnerUpGain = runnerUpScore - bestScore
            let minimumRunnerUpGain = max(0.55, runnerUpScore * 0.04)
            guard runnerUpGain >= minimumRunnerUpGain else {
                return nil
            }
        }

        // Mid-scroll frames, reverse motion, and unrelated live updates do
        // not form a clean overlap. Waiting for the next stable video frame is
        // safer than permanently appending a visibly corrupt strip.
        guard bestScore <= 18.0 else {
            return nil
        }

        guard hasDistributedMovementEvidence(
            previous: previousFrame,
            current: currentFrame,
            xStart: xStart,
            xEnd: xEnd,
            yStart: yStart,
            yEnd: yEnd,
            shift: bestShift
        ) else {
            return nil
        }

        let normalizedScore = bestScore / 255.0
        let separation = runnerUpScore.isFinite ? max(0, runnerUpScore - bestScore) / 255.0 : 1
        let stationarySeparation = max(0, stationaryGain) / 255.0
        let scoreComponent = max(0, min(1, 1 - normalizedScore / 0.18))
        let separationComponent = max(0, min(1, separation / 0.045))
        let stationaryComponent = max(0, min(1, stationarySeparation / 0.045))
        let confidence = (scoreComponent * 0.55)
            + (separationComponent * 0.25)
            + (stationaryComponent * 0.20)
        let sourceShift = max(
            1,
            Int(
                (CGFloat(bestShift) * CGFloat(previous.height) / CGFloat(max(1, previousFrame.height)))
                    .rounded()
            )
        )

        return ScrollMotionEstimate(
            verticalShift: sourceShift,
            confidence: confidence
        )
    }

    private func differenceScore(
        previous: GrayFrame,
        current: GrayFrame,
        xStart: Int,
        xEnd: Int,
        yStart: Int,
        yEnd: Int,
        shift: Int
    ) -> Double {
        let sampleEnd = yEnd - shift
        guard sampleEnd > yStart else {
            return .infinity
        }

        return differenceScore(
            previous: previous,
            current: current,
            xStart: xStart,
            xEnd: xEnd,
            sampleYStart: yStart,
            sampleYEnd: sampleEnd,
            shift: shift
        )
    }

    /// Real page movement changes the alignment across the capture, while a
    /// cursor, blinking control, or small animated patch changes only one
    /// local band. Requiring evidence in two independent vertical bands keeps
    /// local motion from being interpreted as a full-page scroll.
    private func hasDistributedMovementEvidence(
        previous: GrayFrame,
        current: GrayFrame,
        xStart: Int,
        xEnd: Int,
        yStart: Int,
        yEnd: Int,
        shift: Int
    ) -> Bool {
        let sampleEnd = yEnd - shift
        let sampleHeight = sampleEnd - yStart
        guard sampleHeight >= 18 else { return false }

        let bandCount = 3
        var bandsWithEvidence = 0
        for band in 0..<bandCount {
            let bandStart = yStart + (sampleHeight * band / bandCount)
            let bandEnd = yStart + (sampleHeight * (band + 1) / bandCount)
            let movedScore = differenceScore(
                previous: previous,
                current: current,
                xStart: xStart,
                xEnd: xEnd,
                sampleYStart: bandStart,
                sampleYEnd: bandEnd,
                shift: shift
            )
            let stationaryScore = differenceScore(
                previous: previous,
                current: current,
                xStart: xStart,
                xEnd: xEnd,
                sampleYStart: bandStart,
                sampleYEnd: bandEnd,
                shift: 0
            )
            guard movedScore.isFinite, stationaryScore.isFinite else { continue }

            let gain = stationaryScore - movedScore
            if gain >= max(0.45, stationaryScore * 0.08) {
                bandsWithEvidence += 1
            }
        }
        return bandsWithEvidence >= 2
    }

    private func differenceScore(
        previous: GrayFrame,
        current: GrayFrame,
        xStart: Int,
        xEnd: Int,
        sampleYStart: Int,
        sampleYEnd: Int,
        shift: Int
    ) -> Double {
        guard sampleYEnd > sampleYStart else {
            return .infinity
        }

        var totalDifference = 0
        var sampleCount = 0

        for y in stride(from: sampleYStart, to: sampleYEnd, by: rowStride) {
            let previousRow = (y + shift) * previous.width
            let currentRow = y * current.width

            for x in stride(from: xStart, to: xEnd, by: columnStride) {
                totalDifference += abs(
                    Int(previous.pixels[previousRow + x]) - Int(current.pixels[currentRow + x])
                )
                sampleCount += 1
            }
        }

        guard sampleCount > 0 else {
            return .infinity
        }

        return Double(totalDifference) / Double(sampleCount)
    }

    private func preprocess(_ image: CGImage) -> GrayFrame? {
        let targetWidth = max(1, min(workingWidth, image.width))
        let scale = CGFloat(targetWidth) / CGFloat(max(1, image.width))
        let targetHeight = max(1, Int((CGFloat(image.height) * scale).rounded()))
        let bytesPerRow = targetWidth
        let byteCount = bytesPerRow * targetHeight

        guard let data = CFDataCreateMutable(nil, byteCount) else {
            return nil
        }
        CFDataSetLength(data, byteCount)
        guard let pointer = CFDataGetMutableBytePtr(data) else {
            return nil
        }

        guard let context = CGContext(
            data: pointer,
            width: targetWidth,
            height: targetHeight,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else {
            return nil
        }

        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))

        return GrayFrame(
            width: targetWidth,
            height: targetHeight,
            pixels: Array(UnsafeBufferPointer(start: pointer, count: byteCount))
        )
    }
}

private struct GrayFrame {
    let width: Int
    let height: Int
    let pixels: [UInt8]
}
