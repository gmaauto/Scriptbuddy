import Foundation

/// Low-vision "ball highlight" (spec §9.3 item 1, from colour-filter ball-finder apps).
/// Renders the ground-scan colour mask as an RGBA image: the scene is dimmed to a faint grey,
/// ball-coloured pixels are painted in the theme's accent colour, and the detected ball gets a thick
/// ring, so a golfer with some vision can see the ball pop out of the grass. Pure Swift so the
/// pixel logic is unit-tested; the app wraps the bytes in a `CGImage`.
public enum BallHighlight {
    public struct Image: Sendable {
        public let width: Int
        public let height: Int
        /// RGBA8888, premultiplied alpha = 255 everywhere.
        public let rgba: [UInt8]
    }

    /// - Parameters:
    ///   - masks: frame masks from the scanner (mask resolution).
    ///   - ball: detected ball in *source* pixels (as returned by `BlobDetector` with `step`), if any.
    ///   - dim: background luma multiplier (0 = black, 1 = original).
    public static func render(masks: FrameMasks, ball: DetectionCandidate?, highlight: RGB, ring: RGB,
                              background: RGB, dim: Double = 0.25) -> Image {
        let w = masks.width, h = masks.height
        var out = [UInt8](repeating: 255, count: w * h * 4)
        let bgLum = Double(background.relativeLuminance > 0.5 ? 255 : 0)
        for i in 0..<(w * h) {
            let o = i * 4
            if masks.color[i] != 0 {
                out[o] = highlight.r; out[o + 1] = highlight.g; out[o + 2] = highlight.b
            } else {
                // Faint grey scene so the golfer keeps orientation, pushed toward the theme background.
                let l = Double(masks.luma[i])
                let v = UInt8(max(0, min(255, bgLum + (l - bgLum) * dim)))
                out[o] = v; out[o + 1] = v; out[o + 2] = v
            }
        }
        if let ball {
            let s = Double(masks.step)
            let cx = ball.centerX / s, cy = ball.centerY / s
            let r = max(6, ball.radiusPixels / s * 2.2)
            let thickness = max(2, r * 0.25)
            let x0 = max(0, Int(cx - r - thickness)), x1 = min(w - 1, Int(cx + r + thickness))
            let y0 = max(0, Int(cy - r - thickness)), y1 = min(h - 1, Int(cy + r + thickness))
            if x0 <= x1, y0 <= y1 {
                for y in y0...y1 {
                    for x in x0...x1 {
                        let d = ((Double(x) + 0.5 - cx) * (Double(x) + 0.5 - cx) + (Double(y) + 0.5 - cy) * (Double(y) + 0.5 - cy)).squareRoot()
                        if abs(d - r) <= thickness / 2 {
                            let o = (y * w + x) * 4
                            out[o] = ring.r; out[o + 1] = ring.g; out[o + 2] = ring.b
                        }
                    }
                }
            }
        }
        return Image(width: w, height: h, rgba: out)
    }
}
