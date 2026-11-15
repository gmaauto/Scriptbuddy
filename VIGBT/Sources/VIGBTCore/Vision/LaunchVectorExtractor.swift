import Foundation

/// Phase 2.1: converts tracked 2D centroids from frames T0+1…T0+12 into a metric 3D launch vector.
///
/// Each centroid is back-projected through a pinhole model. Depth comes from the LiDAR-anchored
/// apparent-size ratio: Z_i = D_tee · r_ref / r_i, where r_ref is the ball's pixel radius at the tee
/// (measured at setup, or taken from the first tracked frame). This lets the extractor recover all
/// three velocity components — including motion toward/away from the lens — from a single camera,
/// regardless of whether it is placed face-on or down-the-line.
///
/// Camera-space points are then levelled using the gravity-derived pitch and roll, and a
/// least-squares line is fitted per axis to get velocity. Gravity's effect over ~0.1 s
/// (≈5 cm) is removed analytically before fitting.
public struct LaunchVectorExtractor: Sendable {
    public var frameRate: Double
    /// Inclusive frame-offset window used for the fit.
    public var window: ClosedRange<Int>
    public var minimumPoints: Int
    public var gravity: Double

    public init(frameRate: Double = 120, window: ClosedRange<Int> = 1...12,
                minimumPoints: Int = 4, gravity: Double = 9.80665) {
        self.frameRate = frameRate
        self.window = window
        self.minimumPoints = minimumPoints
        self.gravity = gravity
    }

    public enum ExtractionError: Error, Equatable {
        case insufficientPoints(found: Int, required: Int)
        case invalidRadius
    }

    /// - Parameters:
    ///   - centroids: validated centroids from `BallTracker`.
    ///   - calibration: LiDAR / pose calibration.
    ///   - referenceRadiusPixels: ball radius in pixels while sitting on the tee; if nil, the first centroid's radius is used.
    public func extract(centroids: [TrackedCentroid], calibration: TeeCalibration,
                        referenceRadiusPixels: Double? = nil) throws -> LaunchVector {
        let pts = centroids.filter { window.contains($0.frameOffset) }.sorted { $0.frameOffset < $1.frameOffset }
        guard pts.count >= minimumPoints else {
            throw ExtractionError.insufficientPoints(found: pts.count, required: minimumPoints)
        }
        let rRef = referenceRadiusPixels ?? pts[0].radiusPixels
        guard rRef > 0, pts.allSatisfy({ $0.radiusPixels > 0 }) else { throw ExtractionError.invalidRadius }

        let f = calibration.focalLengthPixels
        let cx = calibration.imageWidth / 2
        let cy = calibration.imageHeight / 2
        let dt = 1 / frameRate

        var times: [Double] = []
        var world: [Vector3] = []
        for p in pts {
            let z = calibration.distanceToTeeMeters * rRef / p.radiusPixels
            // Camera frame: +x right, +y down, +z along optical axis.
            let cam = Vector3((p.x - cx) * z / f, (p.y - cy) * z / f, z)
            let level = Self.level(cam, pitch: calibration.cameraPitchRadians, roll: calibration.cameraRollRadians)
            let t = Double(p.frameOffset) * dt
            // World: x = forward (camera heading, horizontal), y = left, z = up. Remove gravity drop.
            let w = Vector3(level.z, -level.x, -level.y + 0.5 * gravity * t * t)
            times.append(t)
            world.append(w)
        }

        let v = Vector3(Self.slope(times, world.map(\.x)),
                        Self.slope(times, world.map(\.y)),
                        Self.slope(times, world.map(\.z)))
        // Gravity was removed from positions, so the fitted vz is the velocity at t = 0 (impact).
        let horizontal = (v.x * v.x + v.y * v.y).squareRoot()
        return LaunchVector(ballSpeed: v.length,
                            launchAngleDeg: Units.degrees(atan2(v.z, horizontal)),
                            azimuthDeg: Units.degrees(atan2(-v.y, v.x)))
    }

    /// Rotates a camera-frame vector into a level frame (+x right, +y down, +z horizontal forward).
    /// Undo roll about the optical axis first, then pitch about the camera's x-axis.
    static func level(_ c: Vector3, pitch: Double, roll: Double) -> Vector3 {
        let x1 = c.x * cos(roll) - c.y * sin(roll)
        let y1 = c.x * sin(roll) + c.y * cos(roll)
        let z1 = c.z
        let y2 = y1 * cos(pitch) - z1 * sin(pitch)
        let z2 = y1 * sin(pitch) + z1 * cos(pitch)
        return Vector3(x1, y2, z2)
    }

    /// Ordinary least-squares slope of y on x.
    static func slope(_ x: [Double], _ y: [Double]) -> Double {
        let n = Double(x.count)
        let mx = x.reduce(0, +) / n
        let my = y.reduce(0, +) / n
        var num = 0.0
        var den = 0.0
        for i in x.indices {
            num += (x[i] - mx) * (y[i] - my)
            den += (x[i] - mx) * (x[i] - mx)
        }
        return den > 0 ? num / den : 0
    }

    /// Forward-projects a known world-space ball path into synthetic centroids. Used by tests and the
    /// "Test Strike" dry-run mode to exercise the full pipeline without a real swing.
    public static func synthesizeCentroids(launch: LaunchVector, calibration: TeeCalibration,
                                           teeWorldPosition: Vector3, ballRadiusMeters: Double = 0.021335,
                                           frameRate: Double = 120, frames: ClosedRange<Int> = 1...12,
                                           gravity: Double = 9.80665) -> (centroids: [TrackedCentroid], referenceRadius: Double) {
        let f = calibration.focalLengthPixels
        let v = launch.initialVelocity
        func project(_ w: Vector3) -> (x: Double, y: Double, z: Double) { Self.project(w, calibration: calibration) }
        let tee = project(teeWorldPosition)
        let refR = f * ballRadiusMeters / tee.z
        var out: [TrackedCentroid] = []
        for i in frames {
            let t = Double(i) / frameRate
            let w = teeWorldPosition + v * t + Vector3(0, 0, -0.5 * gravity * t * t)
            let p = project(w)
            out.append(TrackedCentroid(frameOffset: i, x: p.x, y: p.y, radiusPixels: f * ballRadiusMeters / p.z, score: 1))
        }
        return (out, refR)
    }

    /// Pinhole projection of a camera-relative world point (x forward, y left, z up) to pixels and depth.
    public static func project(_ w: Vector3, calibration: TeeCalibration) -> (x: Double, y: Double, z: Double) {
        let f = calibration.focalLengthPixels
        // world (fwd, left, up) → level (right, down, fwd)
        let lx = -w.y, ly = -w.z, lz = w.x
        // inverse pitch, then inverse roll
        let p = calibration.cameraPitchRadians
        let r = calibration.cameraRollRadians
        let y1 = ly * cos(p) + lz * sin(p)
        let z1 = -ly * sin(p) + lz * cos(p)
        let x0 = lx * cos(r) + y1 * sin(r)
        let y0 = -lx * sin(r) + y1 * cos(r)
        return (calibration.imageWidth / 2 + f * x0 / z1, calibration.imageHeight / 2 + f * y0 / z1, z1)
    }

    /// Inverse of `project` for a pixel at a known optical-axis depth (used for the resting ball on the tee).
    public static func backProject(x: Double, y: Double, depth: Double, calibration: TeeCalibration) -> Vector3 {
        let f = calibration.focalLengthPixels
        let cam = Vector3((x - calibration.imageWidth / 2) * depth / f, (y - calibration.imageHeight / 2) * depth / f, depth)
        let l = level(cam, pitch: calibration.cameraPitchRadians, roll: calibration.cameraRollRadians)
        return Vector3(l.z, -l.x, -l.y)
    }
}
