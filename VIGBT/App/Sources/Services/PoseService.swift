import CoreVideo
import Vision
import VIGBTCore

/// On-device body pose with Apple's Vision framework (SPEC §9.5). Nothing leaves the phone.
/// Fed about 30 frames a second from the capture camera; drops frames while the previous one is still running.
final class PoseService: @unchecked Sendable {
    /// Called on the main queue with each pose (joints with low confidence are still included; `BodyPose`
    /// filters them).
    var onPose: (@MainActor (BodyPose) -> Void)?

    private let queue = DispatchQueue(label: "vigbt.pose", qos: .userInitiated)
    private let lock = NSLock()
    private var busy = false

    private static let joints: [(VNHumanBodyPoseObservation.JointName, BodyPose.Joint)] = [
        (.nose, .nose), (.leftShoulder, .leftShoulder), (.rightShoulder, .rightShoulder),
        (.leftHip, .leftHip), (.rightHip, .rightHip), (.leftWrist, .leftWrist), (.rightWrist, .rightWrist),
        (.leftAnkle, .leftAnkle), (.rightAnkle, .rightAnkle),
    ]

    /// `time` is the frame's presentation time on the host clock, the same clock as the strike sound.
    func process(_ pixels: CVPixelBuffer, time: Double) {
        lock.lock()
        if busy { lock.unlock(); return }
        busy = true
        lock.unlock()
        queue.async {
            defer { self.lock.lock(); self.busy = false; self.lock.unlock() }
            let request = VNDetectHumanBodyPoseRequest()
            let handler = VNImageRequestHandler(cvPixelBuffer: pixels, orientation: .up)
            guard (try? handler.perform([request])) != nil,
                  let obs = request.results?.max(by: { $0.confidence < $1.confidence }),
                  let points = try? obs.recognizedPoints(.all) else {
                let empty = BodyPose(time: time, joints: [:])
                Task { @MainActor in self.onPose?(empty) }
                return
            }
            var joints: [BodyPose.Joint: BodyPose.Point] = [:]
            for (name, joint) in Self.joints {
                guard let p = points[name] else { continue }
                // Vision's origin is bottom-left; BodyPose uses y down.
                joints[joint] = BodyPose.Point(x: Double(p.location.x), y: 1 - Double(p.location.y),
                                               confidence: Double(p.confidence))
            }
            let pose = BodyPose(time: time, joints: joints)
            Task { @MainActor in self.onPose?(pose) }
        }
    }
}
