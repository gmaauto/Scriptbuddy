import Foundation

/// Spherical-earth geodesy helpers (Phase 2.3). Over golf-hole distances (< 600 m) the spherical
/// approximation of WGS84 is accurate to centimetres, far below consumer GPS error.
public enum GeoMath {
    /// IUGG mean Earth radius, meters.
    public static let earthRadiusMeters = 6_371_008.8

    /// Great-circle destination from `origin` after travelling `distanceMeters` on `bearingDeg` (true north).
    public static func destination(from origin: GeoCoordinate, distanceMeters: Double, bearingDeg: Double) -> GeoCoordinate {
        let delta = distanceMeters / earthRadiusMeters
        let theta = Units.radians(bearingDeg)
        let phi1 = Units.radians(origin.latitude)
        let lambda1 = Units.radians(origin.longitude)
        let phi2 = asin(sin(phi1) * cos(delta) + cos(phi1) * sin(delta) * cos(theta))
        let lambda2 = lambda1 + atan2(sin(theta) * sin(delta) * cos(phi1),
                                      cos(delta) - sin(phi1) * sin(phi2))
        return GeoCoordinate(latitude: Units.degrees(phi2),
                             longitude: Units.signedAngle(Units.degrees(lambda2)))
    }

    /// Haversine great-circle distance, meters.
    public static func distance(from a: GeoCoordinate, to b: GeoCoordinate) -> Double {
        let phi1 = Units.radians(a.latitude)
        let phi2 = Units.radians(b.latitude)
        let dPhi = phi2 - phi1
        let dLambda = Units.radians(b.longitude - a.longitude)
        let h = sin(dPhi / 2) * sin(dPhi / 2) + cos(phi1) * cos(phi2) * sin(dLambda / 2) * sin(dLambda / 2)
        return 2 * earthRadiusMeters * atan2(h.squareRoot(), (1 - h).squareRoot())
    }

    /// Initial true-north bearing from `a` to `b`, degrees [0, 360).
    public static func bearing(from a: GeoCoordinate, to b: GeoCoordinate) -> Double {
        let phi1 = Units.radians(a.latitude)
        let phi2 = Units.radians(b.latitude)
        let dLambda = Units.radians(b.longitude - a.longitude)
        let y = sin(dLambda) * cos(phi2)
        let x = cos(phi1) * sin(phi2) - sin(phi1) * cos(phi2) * cos(dLambda)
        return Units.normalizeBearing(Units.degrees(atan2(y, x)))
    }

    /// Local East/North offset (meters) of `point` relative to `origin` (equirectangular; valid < ~10 km).
    public static func enuOffset(of point: GeoCoordinate, from origin: GeoCoordinate) -> (east: Double, north: Double) {
        let latMid = Units.radians((point.latitude + origin.latitude) / 2)
        let east = Units.radians(point.longitude - origin.longitude) * cos(latMid) * earthRadiusMeters
        let north = Units.radians(point.latitude - origin.latitude) * earthRadiusMeters
        return (east, north)
    }

    /// Inverse of `enuOffset`.
    public static func coordinate(east: Double, north: Double, from origin: GeoCoordinate) -> GeoCoordinate {
        let lat = origin.latitude + Units.degrees(north / earthRadiusMeters)
        let latMid = Units.radians((lat + origin.latitude) / 2)
        let lon = origin.longitude + Units.degrees(east / (earthRadiusMeters * cos(latMid)))
        return GeoCoordinate(latitude: lat, longitude: lon)
    }

    /// Projects a carry/lateral landing point (relative to the camera heading) onto WGS84.
    /// Bearing = ψ_camera + atan2(Y_lateral, X_carry); for a straight ball this is ψ_camera + φ.
    public static func project(teeLocation: GeoCoordinate, cameraHeadingDeg: Double,
                               carryMeters: Double, lateralMeters: Double,
                               searchRadiusMeters: Double) -> TargetCoordinate {
        let distance = (carryMeters * carryMeters + lateralMeters * lateralMeters).squareRoot()
        let bearing = Units.normalizeBearing(cameraHeadingDeg + Units.degrees(atan2(lateralMeters, carryMeters)))
        let coord = destination(from: teeLocation, distanceMeters: distance, bearingDeg: bearing)
        return TargetCoordinate(coordinate: coord, bearingFromTeeDeg: bearing,
                                distanceFromTeeMeters: distance, searchRadiusMeters: searchRadiusMeters)
    }
}
