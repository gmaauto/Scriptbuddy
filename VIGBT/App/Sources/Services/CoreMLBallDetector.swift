import CoreML
import CoreVideo
import Vision
import VIGBTCore

/// Optional trained golf-ball detector (SPEC §12.10), produced by `tools/train_ball_detector.py`.
///
/// Loaded only when the app bundle contains `VIGBTBallDetector.mlmodelc` **and** its
/// `VIGBTBallDetector.json`, and the JSON declares only open training-data licences (SPEC §8). Without
/// it the ground scanner works exactly as before. The model outputs a ball-centre heatmap and a radius
/// map at stride 4 for a 512 × 288 input; peaks above the threshold become `ModelDetection`s.
final class CoreMLBallDetector: @unchecked Sendable {
    let info: BallDetectorInfo
    private let request: VNCoreMLRequest
    private let inputWidth = 512.0, inputHeight = 288.0, stride = 4.0

    init?(bundle: Bundle = .main) {
        guard let modelURL = bundle.url(forResource: "VIGBTBallDetector", withExtension: "mlmodelc"),
              let infoURL = bundle.url(forResource: "VIGBTBallDetector", withExtension: "json"),
              let data = try? Data(contentsOf: infoURL),
              let info = try? JSONDecoder().decode(BallDetectorInfo.self, from: data),
              info.isOpenData,
              let model = try? MLModel(contentsOf: modelURL),
              let vision = try? VNCoreMLModel(for: model) else { return nil }
        self.info = info
        request = VNCoreMLRequest(model: vision)
        request.imageCropAndScaleOption = .scaleFill
    }

    /// Detections in the source buffer's pixel coordinates.
    func detect(_ pixels: CVPixelBuffer, threshold: Double = 0.5) -> [ModelDetection] {
        let handler = VNImageRequestHandler(cvPixelBuffer: pixels, orientation: .up)
        guard (try? handler.perform([request])) != nil,
              let results = request.results as? [VNCoreMLFeatureValueObservation],
              let heat = results.first(where: { $0.featureName == "heatmap" })?.featureValue.multiArrayValue,
              let radius = results.first(where: { $0.featureName == "radius" })?.featureValue.multiArrayValue,
              heat.shape.count == 4 else { return [] }
        let h = heat.shape[2].intValue, w = heat.shape[3].intValue
        let sx = Double(CVPixelBufferGetWidth(pixels)) / inputWidth
        let sy = Double(CVPixelBufferGetHeight(pixels)) / inputHeight
        func value(_ a: MLMultiArray, _ y: Int, _ x: Int) -> Double {
            a[[0, 0, NSNumber(value: y), NSNumber(value: x)]].doubleValue
        }
        var out: [ModelDetection] = []
        for y in 0..<h {
            for x in 0..<w {
                let c = value(heat, y, x)
                guard c >= threshold else { continue }
                var isPeak = true
                for dy in -1...1 {
                    for dx in -1...1 where dx != 0 || dy != 0 {
                        let yy = y + dy, xx = x + dx
                        if yy >= 0, yy < h, xx >= 0, xx < w, value(heat, yy, xx) > c { isPeak = false }
                    }
                }
                guard isPeak else { continue }
                out.append(ModelDetection(centerX: (Double(x) + 0.5) * stride * sx, centerY: (Double(y) + 0.5) * stride * sy,
                                          radiusPixels: value(radius, y, x) * stride * (sx + sy) / 2, confidence: c))
            }
        }
        return out
    }
}
