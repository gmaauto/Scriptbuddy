import Foundation

/// Finds an ordinary **white** golf ball lying on grass (Phase 4.5).
///
/// A colour mask alone cannot do this: sky, frost, daisies, painted lines and bunker sand are also
/// bright and unsaturated (SPEC §4 Phase 4.5 measured 100% false positives on white backgrounds and 23%
/// on sand). Each candidate must therefore pass four independent tests:
///
/// 1. **White:** saturation ≤ `maxSaturation` and value ≥ `minValue`.
/// 2. **Brighter than its neighbourhood:** value exceeds the local mean (box of `localRadius`) by
///    `minLocalContrast`, which removes large white areas (sky, cloud, frost) whose local mean is also high.
/// 3. **Round and solid:** aspect within the fusion circularity gate and fill ratio ≥ `minFillRatio`
///    (a disc fills π/4 ≈ 0.785 of its bounding box; lines and ragged clutter do not).
/// 4. **Surrounded by grass:** at least `minSurroundGrass` of the ring 1.6–2.6 radii from the centre is
///    grass-coloured, which rejects sand, cart paths, tee markers on mats and white stakes against the sky.
///
/// Pure Swift on raw BGRA bytes, so it is unit-tested off-device. A trained Core ML detector can be fused
/// with it later (SPEC §4 Phase 4.5); this heuristic stays as the always-available fallback.
public struct WhiteBallDetector: Sendable {
    public var maxSaturation: Double = 0.22
    public var minValue: Double = 0.62
    public var minLocalContrast: Double = 0.15
    public var localRadius: Int = 12
    public var minFillRatio: Double = 0.55
    public var minSurroundGrass: Double = 0.5
    /// Blob area limits in mask pixels (ball 1–10 m from a 1080p Wide camera at step 2 ≈ 3–600 px).
    public var minArea: Int = 3
    public var maxArea: Int = 600
    /// Grass hue window (degrees) and minimum saturation.
    public var grassHue: ClosedRange<Double> = 50...170
    public var grassMinSaturation: Double = 0.15

    public init() {}

    public struct Result: Sendable {
        /// Accepted balls in source pixels, best first. `colorMatchFraction` holds the detector confidence (0…1).
        public var candidates: [DetectionCandidate]
        /// Masks for the ball highlight: `color` marks only pixels that passed tests 1–2.
        public var masks: FrameMasks
    }

    public func detect(bgra: UnsafeRawBufferPointer, width: Int, height: Int, bytesPerRow: Int,
                       step: Int = 2) -> Result {
        let s = max(1, step)
        let w = width / s, h = height / s
        let n = w * h
        var value = [Double](repeating: 0, count: n)
        var luma = [UInt8](repeating: 0, count: n)
        var whiteish = [Bool](repeating: false, count: n)
        var grass = [Bool](repeating: false, count: n)

        for y in 0..<h {
            let row = y * s * bytesPerRow
            for x in 0..<w {
                let o = row + x * s * 4
                let b = Double(bgra[o]) / 255, g = Double(bgra[o + 1]) / 255, r = Double(bgra[o + 2]) / 255
                let i = y * w + x
                let maxC = max(r, g, b), minC = min(r, g, b)
                let sat = maxC > 0 ? (maxC - minC) / maxC : 0
                value[i] = maxC
                luma[i] = UInt8(min(255, (0.299 * r + 0.587 * g + 0.114 * b) * 255))
                whiteish[i] = sat <= maxSaturation && maxC >= minValue
                if sat >= grassMinSaturation, maxC > 0.08 {
                    grass[i] = grassHue.contains(HSV(r: r, g: g, b: b).h)
                }
            }
        }

        // Integral image of value for O(1) local means.
        var integral = [Double](repeating: 0, count: (w + 1) * (h + 1))
        for y in 0..<h {
            var rowSum = 0.0
            for x in 0..<w {
                rowSum += value[y * w + x]
                integral[(y + 1) * (w + 1) + x + 1] = integral[y * (w + 1) + x + 1] + rowSum
            }
        }
        func localMean(_ x: Int, _ y: Int) -> Double {
            let x0 = max(0, x - localRadius), x1 = min(w, x + localRadius + 1)
            let y0 = max(0, y - localRadius), y1 = min(h, y + localRadius + 1)
            let sum = integral[y1 * (w + 1) + x1] - integral[y0 * (w + 1) + x1]
                - integral[y1 * (w + 1) + x0] + integral[y0 * (w + 1) + x0]
            return sum / Double((x1 - x0) * (y1 - y0))
        }

        var mask = [UInt8](repeating: 0, count: n)
        for y in 0..<h {
            for x in 0..<w {
                let i = y * w + x
                if whiteish[i], value[i] - localMean(x, y) >= minLocalContrast { mask[i] = 1 }
            }
        }

        let gate = FusionScorer()
        var accepted: [(DetectionCandidate, Double)] = []
        for (c, area) in BlobDetector(minArea: minArea, maxArea: maxArea)
            .detectWithArea(mask: mask, width: w, height: h, step: s) {
            guard let circularity = gate.circularity(of: c) else { continue }
            let bw = c.width / Double(s), bh = c.height / Double(s)
            let fill = Double(area) / (Double.pi / 4 * bw * bh)
            guard fill >= minFillRatio else { continue }
            let surround = grassFraction(grass, w, h, cx: c.centerX / Double(s), cy: c.centerY / Double(s),
                                         r: max(1, c.radiusPixels / Double(s)))
            guard surround >= minSurroundGrass else { continue }
            let confidence = min(1, 0.4 * circularity + 0.3 * min(1, fill / 0.785) + 0.3 * surround)
            var out = c
            out.colorMatchFraction = confidence
            accepted.append((out, confidence))
        }
        accepted.sort { $0.1 > $1.1 }
        return Result(candidates: accepted.map { $0.0 },
                      masks: FrameMasks(width: w, height: h, step: s, luma: luma, color: mask))
    }

    /// Fraction of grass pixels in the annulus 1.6–2.6 radii around (cx, cy), in mask pixels.
    func grassFraction(_ grass: [Bool], _ w: Int, _ h: Int, cx: Double, cy: Double, r: Double) -> Double {
        let inner = 1.6 * r, outer = max(inner + 2, 2.6 * r)
        let x0 = max(0, Int(cx - outer)), x1 = min(w - 1, Int(cx + outer))
        let y0 = max(0, Int(cy - outer)), y1 = min(h - 1, Int(cy + outer))
        guard x0 <= x1, y0 <= y1 else { return 0 }
        var total = 0, green = 0
        for y in y0...y1 {
            for x in x0...x1 {
                let d = ((Double(x) + 0.5 - cx) * (Double(x) + 0.5 - cx) + (Double(y) + 0.5 - cy) * (Double(y) + 0.5 - cy)).squareRoot()
                guard d >= inner, d <= outer else { continue }
                total += 1
                if grass[y * w + x] { green += 1 }
            }
        }
        return total == 0 ? 0 : Double(green) / Double(total)
    }
}
