import Foundation

/// Per-frame binary masks built from a BGRA pixel buffer (the iOS layer passes the locked
/// `CVPixelBuffer` base address). Kept in pure Swift so it is testable off-device.
public struct FrameMasks: Sendable {
    /// Mask dimensions (source dimensions / step).
    public let width: Int
    public let height: Int
    /// Sub-sampling step: mask pixel (x, y) ↔ source pixel (x·step, y·step).
    public let step: Int
    /// 8-bit luma, used for frame differencing.
    public let luma: [UInt8]
    /// 1 where the pixel passes the HSV colour mask, else 0. All zeros when no profile is active.
    public let color: [UInt8]

    public init(width: Int, height: Int, step: Int, luma: [UInt8], color: [UInt8]) {
        self.width = width
        self.height = height
        self.step = step
        self.luma = luma
        self.color = color
    }

    /// - Parameters:
    ///   - bgra: raw BGRA8888 bytes (`kCVPixelFormatType_32BGRA`).
    ///   - roi: optional source-pixel region to process; everything outside is left 0.
    public static func build(bgra: UnsafeRawBufferPointer, width: Int, height: Int, bytesPerRow: Int,
                             step: Int = 1, range: HSVRange?) -> FrameMasks {
        let s = max(1, step)
        let mw = width / s
        let mh = height / s
        var luma = [UInt8](repeating: 0, count: mw * mh)
        var color = [UInt8](repeating: 0, count: mw * mh)
        let satMin = range?.saturation.lowerBound ?? 0
        let satMax = range?.saturation.upperBound ?? 1
        let valMin = range?.value.lowerBound ?? 0
        let valMax = range?.value.upperBound ?? 1
        for my in 0..<mh {
            let row = my * s * bytesPerRow
            for mx in 0..<mw {
                let o = row + mx * s * 4
                let b = Int(bgra[o])
                let g = Int(bgra[o + 1])
                let r = Int(bgra[o + 2])
                let i = my * mw + mx
                // Rec. 601 integer luma.
                luma[i] = UInt8((77 * r + 150 * g + 29 * b) >> 8)
                guard let range else { continue }
                // Cheap rejects on value and saturation before computing hue.
                let maxC = max(r, g, b)
                let v = Double(maxC) / 255
                guard v >= valMin, v <= valMax, maxC > 0 else { continue }
                let minC = min(r, g, b)
                let sat = Double(maxC - minC) / Double(maxC)
                guard sat >= satMin, sat <= satMax else { continue }
                if range.contains(HSV(r: Double(r) / 255, g: Double(g) / 255, b: Double(b) / 255)) {
                    color[i] = 1
                }
            }
        }
        return FrameMasks(width: mw, height: mh, step: s, luma: luma, color: color)
    }

    /// 1 where |luma − previous.luma| > threshold (colour-agnostic motion mask).
    public func motion(since previous: FrameMasks, threshold: UInt8 = 25) -> [UInt8] {
        precondition(previous.width == width && previous.height == height, "mask size mismatch")
        var out = [UInt8](repeating: 0, count: luma.count)
        let t = Int(threshold)
        for i in luma.indices where abs(Int(luma[i]) - Int(previous.luma[i])) > t {
            out[i] = 1
        }
        return out
    }
}

/// 8-connected component labelling on a binary mask. Replaces running `VNDetectContoursRequest`
/// on a synthesised mask image: same output (blob centroid, extent) without the CGImage round trip.
public struct BlobDetector: Sendable {
    /// Area limits in *mask* pixels.
    public var minArea: Int
    public var maxArea: Int

    public init(minArea: Int = 2, maxArea: Int = 5_000) {
        self.minArea = minArea
        self.maxArea = maxArea
    }

    /// - Parameters:
    ///   - mask: nonzero = foreground.
    ///   - color: optional colour mask; sets each candidate's `colorMatchFraction`.
    ///   - step: mask-to-source scale, so candidates come back in source pixel coordinates.
    public func detect(mask: [UInt8], width: Int, height: Int, color: [UInt8]? = nil,
                       step: Int = 1) -> [DetectionCandidate] {
        precondition(mask.count == width * height, "mask size mismatch")
        var visited = [Bool](repeating: false, count: mask.count)
        var stack: [Int] = []
        var out: [DetectionCandidate] = []
        let s = Double(max(1, step))
        for start in mask.indices where mask[start] != 0 && !visited[start] {
            visited[start] = true
            stack.append(start)
            var area = 0, colorCount = 0
            var sumX = 0.0, sumY = 0.0
            var minX = Int.max, minY = Int.max, maxX = Int.min, maxY = Int.min
            while let i = stack.popLast() {
                let x = i % width
                let y = i / width
                area += 1
                sumX += Double(x)
                sumY += Double(y)
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
                if let color, color[i] != 0 { colorCount += 1 }
                for dy in -1...1 {
                    let ny = y + dy
                    guard ny >= 0, ny < height else { continue }
                    for dx in -1...1 where dx != 0 || dy != 0 {
                        let nx = x + dx
                        guard nx >= 0, nx < width else { continue }
                        let j = ny * width + nx
                        if mask[j] != 0, !visited[j] {
                            visited[j] = true
                            stack.append(j)
                        }
                    }
                }
            }
            guard area >= minArea, area <= maxArea else { continue }
            let n = Double(area)
            out.append(DetectionCandidate(
                centerX: (sumX / n + 0.5) * s,
                centerY: (sumY / n + 0.5) * s,
                width: Double(maxX - minX + 1) * s,
                height: Double(maxY - minY + 1) * s,
                colorMatchFraction: color == nil ? 0 : Double(colorCount) / n))
        }
        return out
    }
}
