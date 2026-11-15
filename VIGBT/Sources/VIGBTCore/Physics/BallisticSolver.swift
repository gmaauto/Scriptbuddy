import Foundation

/// Golf ball and atmosphere constants plus the lift/drag coefficient model.
///
/// Coefficients follow the common linear-in-spin-parameter form
/// `Cd = cd0 + cdSpin·S`, `Cl = min(clMax, cl0 + clSpin·S)` with `S = r·ω / |v_rel|`.
/// The defaults were least-squares fitted against published PGA Tour launch-monitor averages
/// (driver, 3-wood, 7-iron, pitching wedge) and land within ~5% of tour carry for those clubs.
public struct AerodynamicModel: Codable, Equatable, Sendable {
    public var ballMassKg: Double = 0.04593
    public var ballRadiusMeters: Double = 0.021335
    public var airDensity: Double = 1.225
    public var gravity: Double = 9.80665
    public var cd0: Double = 0.18
    public var cdSpin: Double = 0.30
    public var cl0: Double = 0.08
    public var clSpin: Double = 0.60
    public var clMax: Double = 0.25
    /// Exponential spin-decay time constant, seconds.
    public var spinDecaySeconds: Double = 25

    public init() {}

    public var crossSectionArea: Double { .pi * ballRadiusMeters * ballRadiusMeters }

    /// Air density from temperature (°C), station pressure (hPa) and relative humidity (0...1).
    public static func airDensity(temperatureC: Double, pressureHPa: Double, relativeHumidity: Double) -> Double {
        let tK = temperatureC + 273.15
        // Tetens saturation vapour pressure, hPa
        let es = 6.1078 * pow(10, 7.5 * temperatureC / (temperatureC + 237.3))
        let pv = relativeHumidity * es * 100       // Pa
        let pd = pressureHPa * 100 - pv            // Pa
        return pd / (287.058 * tK) + pv / (461.495 * tK)
    }
}

/// Spin estimation (Phase 2.2). Spin is not measured by the camera, so it is inferred from launch angle.
public enum SpinEstimator {
    public static let minimumRPM = 2_000.0
    public static let maximumRPM = 8_500.0

    /// ω ≈ 2200 + 140·θ_deg, clamped to [2000, 8500] rpm (driver ... wedge).
    public static func estimate(launchAngleDeg: Double, axisTiltDeg: Double = 0) -> SpinEstimate {
        let rpm = min(maximumRPM, max(minimumRPM, 2_200 + 140 * launchAngleDeg))
        return SpinEstimate(rpm: rpm, axisTiltDeg: axisTiltDeg)
    }

    /// Club-aware estimate. The launch-angle formula underestimates iron spin (7-iron ≈ 4.4k vs ≈ 7k rpm
    /// measured), which makes irons read 10–15% long; a known club uses its typical spin instead.
    public static func estimate(club: Club, launchAngleDeg: Double, axisTiltDeg: Double = 0) -> SpinEstimate {
        guard let rpm = club.typicalSpinRPM else {
            return estimate(launchAngleDeg: launchAngleDeg, axisTiltDeg: axisTiltDeg)
        }
        return SpinEstimate(rpm: min(maximumRPM, max(minimumRPM, rpm)), axisTiltDeg: axisTiltDeg)
    }
}

/// Club selection for spin estimation. `.auto` falls back to the launch-angle heuristic.
public enum Club: String, Codable, CaseIterable, Identifiable, Sendable {
    case auto, driver, fairwayWood, hybrid, longIron, midIron, shortIron, wedge

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .auto: return "Automatic"
        case .driver: return "Driver"
        case .fairwayWood: return "Fairway wood"
        case .hybrid: return "Hybrid"
        case .longIron: return "Long iron (3 to 5)"
        case .midIron: return "Mid iron (6 to 7)"
        case .shortIron: return "Short iron (8 to 9)"
        case .wedge: return "Wedge"
        }
    }

    /// Typical backspin, from published PGA Tour TrackMan averages (wedge clamped by the estimator).
    public var typicalSpinRPM: Double? {
        switch self {
        case .auto: return nil
        case .driver: return 2_700
        case .fairwayWood: return 3_650
        case .hybrid: return 4_400
        case .longIron: return 5_000
        case .midIron: return 6_700
        case .shortIron: return 8_300
        case .wedge: return 9_300
        }
    }
}

/// 3D aerodynamic trajectory solver: gravity + quadratic drag + Magnus lift, integrated with
/// classical 4th-order Runge-Kutta at a fixed step (default Δt = 0.01 s).
///
/// Equations of motion (per unit mass), with v_rel = v − w (wind) and k = ½ρA|v_rel| / m:
///
///     a = −g·ẑ − k·Cd·v_rel + k·Cl·(ω̂ × v_rel)
public struct BallisticSolver: Sendable {
    public var model: AerodynamicModel
    public var timeStep: Double
    public var maxFlightSeconds: Double
    /// Keep every n-th integration step in the returned samples (for replay/plot); landing is always exact.
    public var sampleStride: Int

    public init(model: AerodynamicModel = AerodynamicModel(), timeStep: Double = 0.01,
                maxFlightSeconds: Double = 20, sampleStride: Int = 5) {
        self.model = model
        self.timeStep = timeStep
        self.maxFlightSeconds = maxFlightSeconds
        self.sampleStride = max(1, sampleStride)
    }

    /// - Parameters:
    ///   - launch: initial conditions from the CV pipeline.
    ///   - spin: estimated or user-entered spin.
    ///   - wind: wind velocity in the world frame (x downrange, y left, z up), m/s.
    ///   - launchHeightMeters: tee height above the landing plane (≈0.03 m driver, 0 iron).
    public func solve(launch: LaunchVector, spin: SpinEstimate, wind: Vector3 = .zero,
                      launchHeightMeters: Double = 0) -> TrajectorySolution {
        let v0 = launch.initialVelocity
        let axis = Self.spinAxis(initialVelocity: v0, axisTiltDeg: spin.axisTiltDeg)
        let omega0 = spin.radiansPerSecond

        var t = 0.0
        var state = State(p: Vector3(0, 0, launchHeightMeters), v: v0)
        var samples = [TrajectorySample(time: 0, position: state.p, velocity: state.v)]
        var apex = state.p.z
        var step = 0

        let dt = timeStep
        while t < maxFlightSeconds {
            let next = rk4(state, t: t, dt: dt, axis: axis, omega0: omega0, wind: wind)
            step += 1
            // Ground crossing: interpolate linearly inside the last step for the exact landing point.
            if next.p.z < 0 {
                let frac = state.p.z / (state.p.z - next.p.z)
                let p = state.p + (next.p - state.p) * frac
                let v = state.v + (next.v - state.v) * frac
                let landT = t + frac * dt
                let landing = TrajectorySample(time: landT, position: Vector3(p.x, p.y, 0), velocity: v)
                samples.append(landing)
                let horiz = (v.x * v.x + v.y * v.y).squareRoot()
                return TrajectorySolution(
                    samples: samples,
                    carryMeters: p.x,
                    lateralMeters: -p.y,
                    apexMeters: apex,
                    flightTimeSeconds: landT,
                    landingSpeed: v.length,
                    landingAngleDeg: Units.degrees(atan2(-v.z, horiz)))
            }
            state = next
            t += dt
            apex = max(apex, state.p.z)
            if step % sampleStride == 0 {
                samples.append(TrajectorySample(time: t, position: state.p, velocity: state.v))
            }
        }
        // Did not land within maxFlightSeconds (degenerate input); report last state.
        return TrajectorySolution(samples: samples, carryMeters: state.p.x, lateralMeters: -state.p.y,
                                  apexMeters: apex, flightTimeSeconds: t, landingSpeed: state.v.length,
                                  landingAngleDeg: 0)
    }

    /// Spin axis unit vector. Pure backspin axis is horizontal and perpendicular to the launch
    /// direction such that ω̂ × v points up; tilting it toward −ẑ produces rightward (slice) curve.
    static func spinAxis(initialVelocity v0: Vector3, axisTiltDeg: Double) -> Vector3 {
        var horizontal = Vector3(v0.x, v0.y, 0).normalized
        if horizontal == .zero { horizontal = Vector3(1, 0, 0) }
        let backspin = horizontal.cross(.up)               // e.g. x̂ × ẑ = −ŷ
        let tilt = Units.radians(axisTiltDeg)
        return (backspin * cos(tilt) - Vector3.up * sin(tilt)).normalized
    }

    // MARK: Integration

    struct State {
        var p: Vector3
        var v: Vector3
    }

    func acceleration(v: Vector3, t: Double, axis: Vector3, omega0: Double, wind: Vector3) -> Vector3 {
        let m = model
        let vRel = v - wind
        let speed = vRel.length
        let gravity = Vector3(0, 0, -m.gravity)
        guard speed > 1e-6 else { return gravity }
        let omega = omega0 * exp(-t / m.spinDecaySeconds)
        let s = m.ballRadiusMeters * omega / speed
        let cd = m.cd0 + m.cdSpin * s
        let cl = min(m.clMax, m.cl0 + m.clSpin * s)
        let k = 0.5 * m.airDensity * m.crossSectionArea * speed / m.ballMassKg
        let drag = vRel * (-k * cd)
        let lift = axis.cross(vRel) * (k * cl)
        return gravity + drag + lift
    }

    func rk4(_ s: State, t: Double, dt: Double, axis: Vector3, omega0: Double, wind: Vector3) -> State {
        func deriv(_ st: State, _ tt: Double) -> State {
            State(p: st.v, v: acceleration(v: st.v, t: tt, axis: axis, omega0: omega0, wind: wind))
        }
        func add(_ a: State, _ b: State, _ h: Double) -> State {
            State(p: a.p + b.p * h, v: a.v + b.v * h)
        }
        let k1 = deriv(s, t)
        let k2 = deriv(add(s, k1, dt / 2), t + dt / 2)
        let k3 = deriv(add(s, k2, dt / 2), t + dt / 2)
        let k4 = deriv(add(s, k3, dt), t + dt)
        return State(
            p: s.p + (k1.p + k2.p * 2 + k3.p * 2 + k4.p) * (dt / 6),
            v: s.v + (k1.v + k2.v * 2 + k3.v * 2 + k4.v) * (dt / 6))
    }
}

/// Phase 2 orchestration: launch vector → spin → trajectory → bounce & roll → search zone → WGS84 target.
public struct LandingZoneEstimator: Sendable {
    public var solver: BallisticSolver
    /// Circle fallback: R_search = dispersionFactor × carry. The spec's original 0.08 covered only 9–33% of
    /// balls in the Monte Carlo run (§12); 0.18 is the measured 80% coverage radius.
    public var dispersionFactor: Double
    /// Ellipse semi-axes as fractions of carry (80% coverage in §12). Errors along the line are larger
    /// than across it because roll, wind and spin rate mostly change distance.
    public var alongFactor: Double
    public var lateralFactor: Double
    /// Low launches (thin, skulled, topped) are mostly roll, which depends on ground firmness the app cannot
    /// see. Below `lowLaunchDeg` the ellipse is sized from the predicted *rest distance* instead of carry:
    /// ±45% along, ±12% across covers 87% of them (vs 19% with the normal ellipse, §12).
    public var lowLaunchDeg: Double = 8
    public var lowLaunchAlongFactor: Double = 0.45
    public var lowLaunchLateralFactor: Double = 0.12
    /// Floor on the search radius so very short shots still get a usable zone.
    public var minimumSearchRadiusMeters: Double
    /// Predict bounce and roll and target the rest position (recommended).
    public var predictRoll: Bool
    public var ground: GroundModel

    public init(solver: BallisticSolver = BallisticSolver(), dispersionFactor: Double = 0.18,
                alongFactor: Double = 0.22, lateralFactor: Double = 0.14,
                minimumSearchRadiusMeters: Double = 5, predictRoll: Bool = true, ground: GroundModel = GroundModel()) {
        self.solver = solver
        self.dispersionFactor = dispersionFactor
        self.alongFactor = alongFactor
        self.lateralFactor = lateralFactor
        self.minimumSearchRadiusMeters = minimumSearchRadiusMeters
        self.predictRoll = predictRoll
        self.ground = ground
    }

    /// - Parameter zone: learned correction (`SearchZoneModel`), applied to the rest position; nil uses the defaults.
    public func estimate(launch: LaunchVector, calibration: TeeCalibration,
                         spin: SpinEstimate? = nil, wind: Vector3 = .zero, zone: SearchZoneCalibration? = nil)
        -> (spin: SpinEstimate, trajectory: TrajectorySolution, landing: LandingEstimate) {
        let spin = spin ?? SpinEstimator.estimate(launchAngleDeg: launch.launchAngleDeg)
        let traj = solver.solve(launch: launch, spin: spin, wind: wind)
        let carry = traj.carryMeters
        let lateral = traj.lateralMeters

        var restCarry = carry
        var restLateral = lateral
        if predictRoll, let last = traj.samples.last {
            // Physics frame has +y = left; LandingEstimate reports lateral as + = right.
            let rest = RollModel.rest(landing: Vector3(carry, -lateral, 0), velocity: last.velocity, ground: ground)
            restCarry = rest.x
            restLateral = -rest.y
        }

        var along = alongFactor * carry
        var across = lateralFactor * carry
        if launch.launchAngleDeg < lowLaunchDeg {
            let restDistance = (restCarry * restCarry + restLateral * restLateral).squareRoot()
            along = lowLaunchAlongFactor * restDistance
            across = lowLaunchLateralFactor * restDistance
        }
        if let zone, zone.sampleCount > 0 {
            let c = zone.corrected(carry: restCarry, lateral: restLateral)
            restCarry = c.carry
            restLateral = c.lateral
            along = c.radius
            across = c.radius
        }
        along = max(minimumSearchRadiusMeters, along)
        across = max(minimumSearchRadiusMeters, across)
        let radius = (along * across).squareRoot()
        let target = GeoMath.project(teeLocation: calibration.teeLocation,
                                     cameraHeadingDeg: calibration.cameraHeadingDeg,
                                     carryMeters: restCarry,
                                     lateralMeters: restLateral,
                                     searchRadiusMeters: radius)
        let landing = LandingEstimate(carryMeters: carry, lateralMeters: lateral, searchRadiusMeters: radius,
                                      target: target, restCarryMeters: restCarry, restLateralMeters: restLateral,
                                      searchAlongMeters: along, searchLateralMeters: across)
        return (spin, traj, landing)
    }
}
