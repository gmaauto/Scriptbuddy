import Foundation

/// Launch estimation by fitting a 3D flight model to what the camera actually measures (SPEC §12).
///
/// The per-frame back-projection in `LaunchVectorExtractor` turns each apparent radius into a depth;
/// for a down-the-line camera that is where almost all the speed information lives, and a 3% radius
/// error becomes a 3% depth error on every frame. The Monte Carlo run measured ±21–30 mph (p90) speed
/// error and a slow bias from that approach. This fitter instead:
///
/// - anchors the flight at the tee, whose 3D position is known from LiDAR depth and the resting-ball pixel;
/// - models gravity, drag and Magnus lift with the same coefficients as `BallisticSolver`;
/// - minimises pixel residuals of (x, y, radius), each weighted by its own noise (centroids ≈ 0.35 px,
///   radius ≈ 0.2 px + 3%), so no frame dominates because of its depth;
/// - optionally estimates **spin-axis tilt and spin rate** from the curvature of the first frames, pulled
///   toward the club's typical spin (± `rpmPriorSigma`) and zero tilt (± `tiltPriorSigmaDeg`).
///
/// Monte Carlo result (1M shots, down-the-line): speed p90 ±3.6 mph, launch ±1.1°, azimuth ±0.7°, and
/// spin-axis tilt ±8° instead of ±27°.
public struct ReprojectionFitter: Sendable {
    public var centroidSigmaPixels: Double = 0.35
    public var radiusSigmaPixels: Double = 0.2
    public var radiusSigmaFraction: Double = 0.03
    public var estimateSpin: Bool = true
    public var rpmPriorSigma: Double = 700
    public var tiltPriorSigmaDeg: Double = 20
    public var iterations: Int = 6
    public var frameRate: Double = 120
    public var model: AerodynamicModel = AerodynamicModel()

    public init() {}

    public struct Result: Sendable {
        public var launch: LaunchVector
        public var spin: SpinEstimate
        /// RMS of the normalised residuals (≈ 1 when the noise model is right).
        public var rmsResidual: Double
    }

    /// - Parameters:
    ///   - centroids: tracked ball positions (frame offsets from impact).
    ///   - tee: resting ball on the tee (pixel centre); its depth is `calibration.distanceToTeeMeters`.
    ///   - initial: starting guess, e.g. from `LaunchVectorExtractor`.
    ///   - spinPrior: club-based spin (rpm) used as the prior and, if `estimateSpin` is off, as the value.
    public func fit(centroids: [TrackedCentroid], tee: (x: Double, y: Double), calibration: TeeCalibration,
                    initial: LaunchVector, spinPrior: Double) -> Result? {
        let obs = centroids.filter { $0.frameOffset >= 1 && $0.radiusPixels > 0 }
        guard obs.count >= 6 else { return nil }
        let teeWorld = LaunchVectorExtractor.backProject(x: tee.x, y: tee.y, depth: calibration.distanceToTeeMeters,
                                                         calibration: calibration)
        let solver = BallisticSolver(model: model)
        let n = estimateSpin ? 5 : 3

        // Parameters: vx, vy, vz (m/s), rpm / 1000, tilt / 10° — scaled to similar magnitudes.
        func residuals(_ x: [Double]) -> [Double] {
            let v = Vector3(x[0], x[1], x[2])
            let rpm = n == 5 ? x[3] * 1000 : spinPrior
            let tilt = n == 5 ? x[4] * 10 : 0
            let axis = BallisticSolver.spinAxis(initialVelocity: v, axisTiltDeg: tilt)
            let a = solver.acceleration(v: v, t: 0, axis: axis, omega0: max(0, rpm) * 2 * .pi / 60, wind: .zero)
            var out: [Double] = []
            out.reserveCapacity(obs.count * 3 + 2)
            for c in obs {
                let t = Double(c.frameOffset) / frameRate
                let p = teeWorld + v * t + a * (0.5 * t * t)
                let q = LaunchVectorExtractor.project(p, calibration: calibration)
                let z = max(0.05, q.z)
                let r = calibration.focalLengthPixels * model.ballRadiusMeters / z
                let sr = radiusSigmaPixels + radiusSigmaFraction * r
                out.append((c.x - (calibration.imageWidth / 2 + (q.x - calibration.imageWidth / 2) * q.z / z)) / centroidSigmaPixels)
                out.append((c.y - (calibration.imageHeight / 2 + (q.y - calibration.imageHeight / 2) * q.z / z)) / centroidSigmaPixels)
                out.append((c.radiusPixels - r) / sr)
            }
            if n == 5 {
                out.append((x[3] * 1000 - spinPrior) / rpmPriorSigma)
                out.append((x[4] * 10) / tiltPriorSigmaDeg)
            }
            return out
        }

        let v0 = initial.initialVelocity
        var x = [v0.x, v0.y, v0.z, spinPrior / 1000, 0].prefix(n).map { $0 }
        var r0 = residuals(x)
        for _ in 0..<iterations {
            // Numeric Jacobian, normal equations, damped Gauss-Newton step.
            var jt = [[Double]](repeating: [], count: n)
            for j in 0..<n {
                var xp = x
                xp[j] += 0.01
                let rp = residuals(xp)
                jt[j] = zip(rp, r0).map { ($0 - $1) / 0.01 }
            }
            var jtj = [[Double]](repeating: [Double](repeating: 0, count: n), count: n)
            var jtr = [Double](repeating: 0, count: n)
            for a in 0..<n {
                for b in 0..<n { jtj[a][b] = zip(jt[a], jt[b]).reduce(0) { $0 + $1.0 * $1.1 } }
                jtj[a][a] += 1e-6
                jtr[a] = zip(jt[a], r0).reduce(0) { $0 + $1.0 * $1.1 }
            }
            guard let step = Self.solve(jtj, jtr.map { -$0 }) else { break }
            let candidate = zip(x, step).map { $0 + $1 }
            let rc = residuals(candidate)
            // Accept only steps that reduce the cost (keeps the fit stable on bad tracks).
            if rc.reduce(0, { $0 + $1 * $1 }) <= r0.reduce(0, { $0 + $1 * $1 }) {
                x = candidate
                r0 = rc
            } else {
                break
            }
        }

        let v = Vector3(x[0], x[1], x[2])
        let speed = v.length
        guard speed.isFinite, speed > 1 else { return nil }
        let horizontal = (v.x * v.x + v.y * v.y).squareRoot()
        let launch = LaunchVector(ballSpeed: speed, launchAngleDeg: Units.degrees(atan2(v.z, horizontal)),
                                  azimuthDeg: Units.degrees(atan2(-v.y, v.x)))
        let rpm = n == 5 ? min(11_000, max(500, x[3] * 1000)) : spinPrior
        let tilt = n == 5 ? min(45, max(-45, x[4] * 10)) : 0
        let measured = obs.count * 3
        let rms = (r0.prefix(measured).reduce(0) { $0 + $1 * $1 } / Double(measured)).squareRoot()
        return Result(launch: launch, spin: SpinEstimate(rpm: rpm, axisTiltDeg: tilt), rmsResidual: rms)
    }

    /// Gaussian elimination with partial pivoting for the small normal-equation systems.
    static func solve(_ a: [[Double]], _ b: [Double]) -> [Double]? {
        let n = b.count
        var m = a
        var y = b
        for col in 0..<n {
            guard let pivot = (col..<n).max(by: { abs(m[$0][col]) < abs(m[$1][col]) }), abs(m[pivot][col]) > 1e-12 else {
                return nil
            }
            m.swapAt(col, pivot)
            y.swapAt(col, pivot)
            for row in (col + 1)..<n {
                let f = m[row][col] / m[col][col]
                for k in col..<n { m[row][k] -= f * m[col][k] }
                y[row] -= f * y[col]
            }
        }
        var x = [Double](repeating: 0, count: n)
        for row in stride(from: n - 1, through: 0, by: -1) {
            var s = y[row]
            for k in (row + 1)..<n { s -= m[row][k] * x[k] }
            x[row] = s / m[row][row]
        }
        return x
    }
}
