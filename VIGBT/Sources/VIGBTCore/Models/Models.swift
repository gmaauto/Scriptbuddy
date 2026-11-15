import Foundation

// MARK: - Geospatial

/// WGS84 coordinate. Mirrors `CLLocationCoordinate2D` without importing CoreLocation,
/// so the core stays platform-independent. The iOS layer converts at the boundary.
public struct GeoCoordinate: Codable, Equatable, Hashable, Sendable {
    public var latitude: Double
    public var longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }
}

/// The projected landing target handed from Phase 2 to Phase 3 navigation.
public struct TargetCoordinate: Codable, Equatable, Sendable {
    public var coordinate: GeoCoordinate
    /// True-north bearing from the tee to the predicted landing point, degrees [0, 360).
    public var bearingFromTeeDeg: Double
    /// Straight-line ground distance from the tee to the predicted landing point, meters.
    public var distanceFromTeeMeters: Double
    /// Radius of the search zone around `coordinate`, meters.
    public var searchRadiusMeters: Double

    public init(coordinate: GeoCoordinate, bearingFromTeeDeg: Double,
                distanceFromTeeMeters: Double, searchRadiusMeters: Double) {
        self.coordinate = coordinate
        self.bearingFromTeeDeg = bearingFromTeeDeg
        self.distanceFromTeeMeters = distanceFromTeeMeters
        self.searchRadiusMeters = searchRadiusMeters
    }
}

// MARK: - Calibration (Phase 1.2)

/// Output of the LiDAR/ARKit tee calibration pass plus device pose at setup.
public struct TeeCalibration: Codable, Equatable, Sendable {
    /// Camera-to-tee distance D_tee measured by LiDAR, meters. Stored as depth along the optical
    /// axis (the camera-space z of the ARKit raycast hit), which is what the pinhole model needs.
    public var distanceToTeeMeters: Double
    /// Camera pitch relative to the horizon, radians. Positive = tilted up.
    public var cameraPitchRadians: Double
    /// Camera roll about the optical axis, radians. Positive = rotated clockwise as seen from behind the phone.
    public var cameraRollRadians: Double
    /// True-north heading of the camera's optical axis projected onto the horizontal plane, degrees.
    public var cameraHeadingDeg: Double
    /// Horizontal field of view of the capture format, radians (Ultra-Wide ≈ 120° on Pro iPhones; read from `AVCaptureDevice.Format`).
    public var horizontalFOVRadians: Double
    /// Capture resolution in pixels.
    public var imageWidth: Double
    public var imageHeight: Double
    /// Tee box location at the time of calibration.
    public var teeLocation: GeoCoordinate

    public init(distanceToTeeMeters: Double, cameraPitchRadians: Double, cameraRollRadians: Double = 0,
                cameraHeadingDeg: Double, horizontalFOVRadians: Double,
                imageWidth: Double = 1920, imageHeight: Double = 1080,
                teeLocation: GeoCoordinate) {
        self.distanceToTeeMeters = distanceToTeeMeters
        self.cameraPitchRadians = cameraPitchRadians
        self.cameraRollRadians = cameraRollRadians
        self.cameraHeadingDeg = cameraHeadingDeg
        self.horizontalFOVRadians = horizontalFOVRadians
        self.imageWidth = imageWidth
        self.imageHeight = imageHeight
        self.teeLocation = teeLocation
    }

    /// Pinhole focal length in pixels: f = (W/2) / tan(hFOV/2).
    public var focalLengthPixels: Double {
        (imageWidth / 2) / tan(horizontalFOVRadians / 2)
    }

    /// Real-world scale at the tee plane: meters per pixel = D_tee / f.
    public var metersPerPixelAtTee: Double {
        distanceToTeeMeters / focalLengthPixels
    }
}

// MARK: - Ball detection (Phase 1.3)

/// A colour in HSV space. `h` in degrees [0, 360), `s` and `v` in [0, 1].
public struct HSV: Codable, Equatable, Sendable {
    public var h: Double
    public var s: Double
    public var v: Double

    public init(h: Double, s: Double, v: Double) {
        self.h = h
        self.s = s
        self.v = v
    }

    /// Converts 8-bit-normalised RGB (each 0...1) to HSV.
    public init(r: Double, g: Double, b: Double) {
        let maxC = max(r, g, b)
        let minC = min(r, g, b)
        let delta = maxC - minC
        var hue: Double = 0
        if delta > 0 {
            if maxC == r {
                hue = 60 * ((g - b) / delta).truncatingRemainder(dividingBy: 6)
            } else if maxC == g {
                hue = 60 * ((b - r) / delta + 2)
            } else {
                hue = 60 * ((r - g) / delta + 4)
            }
        }
        self.h = Units.normalizeBearing(hue)
        self.s = maxC == 0 ? 0 : delta / maxC
        self.v = maxC
    }
}

/// Inclusive HSV threshold window. Hue windows may wrap through 0° (e.g. 340°...10° for pink/red).
public struct HSVRange: Codable, Equatable, Sendable {
    public var hueMin: Double
    public var hueMax: Double
    public var saturation: ClosedRange<Double>
    public var value: ClosedRange<Double>

    public init(hueMin: Double, hueMax: Double, saturation: ClosedRange<Double>, value: ClosedRange<Double>) {
        self.hueMin = Units.normalizeBearing(hueMin)
        self.hueMax = Units.normalizeBearing(hueMax)
        self.saturation = saturation
        self.value = value
    }

    public func contains(_ c: HSV) -> Bool {
        guard saturation.contains(c.s), value.contains(c.v) else { return false }
        let h = Units.normalizeBearing(c.h)
        if hueMin <= hueMax {
            return h >= hueMin && h <= hueMax
        }
        return h >= hueMin || h <= hueMax // wraps through 0°
    }
}

public enum BallColorPreset: String, Codable, CaseIterable, Sendable {
    case neonOrange
    case neonPink
    case sampled
}

/// The active ball colour profile shared by Phase 1 launch tracking and Phase 4 ground scanning.
public struct BallColorProfile: Codable, Equatable, Sendable {
    public var preset: BallColorPreset
    public var range: HSVRange

    public init(preset: BallColorPreset, range: HSVRange) {
        self.preset = preset
        self.range = range
    }

    public static let neonOrange = BallColorProfile(
        preset: .neonOrange,
        range: HSVRange(hueMin: 10, hueMax: 40, saturation: 0.55...1.0, value: 0.45...1.0))

    public static let neonPink = BallColorProfile(
        preset: .neonPink,
        range: HSVRange(hueMin: 315, hueMax: 350, saturation: 0.40...1.0, value: 0.45...1.0))

    /// Tap-to-sample override: builds a profile from a 15×15 patch sampled at setup.
    /// Uses the circular mean of hue and widens each channel by a tolerance band to absorb lighting changes.
    public static func sampled(from patch: [HSV],
                               hueTolerance: Double = 12,
                               saturationTolerance: Double = 0.20,
                               valueTolerance: Double = 0.25) -> BallColorProfile? {
        guard !patch.isEmpty else { return nil }
        let n = Double(patch.count)
        let sinSum = patch.reduce(0) { $0 + sin(Units.radians($1.h)) }
        let cosSum = patch.reduce(0) { $0 + cos(Units.radians($1.h)) }
        let meanHue = Units.normalizeBearing(Units.degrees(atan2(sinSum / n, cosSum / n)))
        let meanS = patch.reduce(0) { $0 + $1.s } / n
        let meanV = patch.reduce(0) { $0 + $1.v } / n
        let range = HSVRange(
            hueMin: meanHue - hueTolerance,
            hueMax: meanHue + hueTolerance,
            saturation: max(0, meanS - saturationTolerance)...min(1, meanS + saturationTolerance),
            value: max(0, meanV - valueTolerance)...min(1, meanV + valueTolerance))
        return BallColorProfile(preset: .sampled, range: range)
    }
}

/// A candidate blob produced by the Vision contour stage for a single frame.
public struct DetectionCandidate: Codable, Equatable, Sendable {
    /// Centroid in image pixels (origin top-left, +y down).
    public var centerX: Double
    public var centerY: Double
    /// Bounding-box size in pixels.
    public var width: Double
    public var height: Double
    /// Fraction [0, 1] of the blob's pixels that pass the active HSV mask.
    public var colorMatchFraction: Double

    public init(centerX: Double, centerY: Double, width: Double, height: Double, colorMatchFraction: Double) {
        self.centerX = centerX
        self.centerY = centerY
        self.width = width
        self.height = height
        self.colorMatchFraction = colorMatchFraction
    }

    public var aspectRatio: Double { height > 0 ? width / height : .infinity }
    /// Apparent radius in pixels (mean of half-width and half-height).
    public var radiusPixels: Double { (width + height) / 4 }
}

/// A validated ball centroid on a specific frame, after fusion scoring.
public struct TrackedCentroid: Codable, Equatable, Sendable {
    /// Frame offset from the impact frame T0 (T0 + 1 = 1).
    public var frameOffset: Int
    public var x: Double
    public var y: Double
    public var radiusPixels: Double
    public var score: Double

    public init(frameOffset: Int, x: Double, y: Double, radiusPixels: Double, score: Double) {
        self.frameOffset = frameOffset
        self.x = x
        self.y = y
        self.radiusPixels = radiusPixels
        self.score = score
    }
}

// MARK: - Launch & flight (Phase 2)

/// Initial launch conditions extracted from the first ~12 frames after impact.
public struct LaunchVector: Codable, Equatable, Sendable {
    /// Ball speed v0, m/s.
    public var ballSpeed: Double
    /// Vertical launch angle θ above horizontal, degrees.
    public var launchAngleDeg: Double
    /// Horizontal azimuth φ relative to the camera heading, degrees. Positive = right.
    public var azimuthDeg: Double

    public init(ballSpeed: Double, launchAngleDeg: Double, azimuthDeg: Double) {
        self.ballSpeed = ballSpeed
        self.launchAngleDeg = launchAngleDeg
        self.azimuthDeg = azimuthDeg
    }

    public var ballSpeedMph: Double { Units.mph(fromMetersPerSecond: ballSpeed) }

    /// Initial velocity in the physics world frame (x downrange, y left, z up).
    public var initialVelocity: Vector3 {
        let th = Units.radians(launchAngleDeg)
        let ph = Units.radians(azimuthDeg)
        return Vector3(ballSpeed * cos(th) * cos(ph),
                       -ballSpeed * cos(th) * sin(ph),
                       ballSpeed * sin(th))
    }
}

public struct SpinEstimate: Codable, Equatable, Sendable {
    /// Total spin rate, revolutions per minute.
    public var rpm: Double
    /// Spin-axis tilt, degrees. 0 = pure backspin; positive = fade/slice (curves right); negative = draw/hook.
    public var axisTiltDeg: Double

    public init(rpm: Double, axisTiltDeg: Double = 0) {
        self.rpm = rpm
        self.axisTiltDeg = axisTiltDeg
    }

    public var radiansPerSecond: Double { rpm * 2 * .pi / 60 }
}

public struct TrajectorySample: Codable, Equatable, Sendable {
    public var time: Double
    public var position: Vector3
    public var velocity: Vector3

    public init(time: Double, position: Vector3, velocity: Vector3) {
        self.time = time
        self.position = position
        self.velocity = velocity
    }
}

public struct TrajectorySolution: Codable, Equatable, Sendable {
    public var samples: [TrajectorySample]
    /// Downrange carry X_carry along the camera heading, meters.
    public var carryMeters: Double
    /// Lateral offset Y_lateral at landing, meters. Positive = right of the camera heading.
    public var lateralMeters: Double
    public var apexMeters: Double
    public var flightTimeSeconds: Double
    public var landingSpeed: Double
    /// Descent angle at landing, degrees below horizontal.
    public var landingAngleDeg: Double

    public init(samples: [TrajectorySample], carryMeters: Double, lateralMeters: Double, apexMeters: Double,
                flightTimeSeconds: Double, landingSpeed: Double, landingAngleDeg: Double) {
        self.samples = samples
        self.carryMeters = carryMeters
        self.lateralMeters = lateralMeters
        self.apexMeters = apexMeters
        self.flightTimeSeconds = flightTimeSeconds
        self.landingSpeed = landingSpeed
        self.landingAngleDeg = landingAngleDeg
    }

    public var carryYards: Double { Units.yards(fromMeters: carryMeters) }
    public var lateralYards: Double { Units.yards(fromMeters: lateralMeters) }
}

public struct LandingEstimate: Codable, Equatable, Sendable {
    public var carryMeters: Double
    public var lateralMeters: Double
    /// R_search ≈ 0.08 × X_carry.
    public var searchRadiusMeters: Double
    public var target: TargetCoordinate

    public init(carryMeters: Double, lateralMeters: Double, searchRadiusMeters: Double, target: TargetCoordinate) {
        self.carryMeters = carryMeters
        self.lateralMeters = lateralMeters
        self.searchRadiusMeters = searchRadiusMeters
        self.target = target
    }
}

/// A full shot, persisted for history and replay.
public struct ShotRecord: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var capturedAt: Date
    public var ballProfile: BallColorProfile
    public var calibration: TeeCalibration
    public var centroids: [TrackedCentroid]
    public var launch: LaunchVector?
    public var spin: SpinEstimate?
    public var trajectory: TrajectorySolution?
    public var landing: LandingEstimate?
    /// File name of the trimmed .mov clip inside the app's clips directory (nil for simulated shots).
    public var clipFileName: String?
    public var club: Club?
    /// Impact time T0 on the clip's timeline, and the clip frame rate, for the replay tracer.
    public var clipImpactTime: Double?
    public var clipFrameRate: Double?
    public var isSimulated: Bool?

    public init(id: UUID = UUID(), capturedAt: Date = Date(), ballProfile: BallColorProfile,
                calibration: TeeCalibration, centroids: [TrackedCentroid] = [],
                launch: LaunchVector? = nil, spin: SpinEstimate? = nil,
                trajectory: TrajectorySolution? = nil, landing: LandingEstimate? = nil,
                clipFileName: String? = nil, club: Club? = nil, clipImpactTime: Double? = nil,
                clipFrameRate: Double? = nil, isSimulated: Bool? = nil) {
        self.id = id
        self.capturedAt = capturedAt
        self.ballProfile = ballProfile
        self.calibration = calibration
        self.centroids = centroids
        self.launch = launch
        self.spin = spin
        self.trajectory = trajectory
        self.landing = landing
        self.clipFileName = clipFileName
        self.club = club
        self.clipImpactTime = clipImpactTime
        self.clipFrameRate = clipFrameRate
        self.isSimulated = isSimulated
    }
}

// MARK: - App flow

/// Top-level state machine for one shot, driving which subsystems are powered.
public enum ShotPhase: String, Codable, Sendable {
    case setup            // onboarding, disclaimer, calibration
    case armed            // ring buffer + acoustic trigger live
    case processing       // clip saved, capture paused, CV + physics running
    case replay           // annotated slow-motion replay + VoiceOver readout
    case navigating       // GPS / spatial-audio walk to the target (camera OFF)
    case homing           // close-range scan with Wide camera + haptics
    case found
}
