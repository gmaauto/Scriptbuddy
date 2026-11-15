import CoreLocation
import CoreMotion
import Observation
import VIGBTCore

/// Phase 3.1 inputs: GPS fixes, true-north heading and pedometer distance, fused by
/// `PositionKalmanFilter` into a smoothed walking position.
@MainActor
@Observable
final class LocationService: NSObject {
    private(set) var authorization: CLAuthorizationStatus = .notDetermined
    private(set) var lastFix: CLLocation?
    /// True-north heading of the top of the phone (portrait), degrees.
    private(set) var heading: Double?
    /// Kalman-smoothed position while walking (nil until `beginWalk`).
    private(set) var smoothedPosition: GeoCoordinate?

    @ObservationIgnored private let manager = CLLocationManager()
    @ObservationIgnored private let pedometer = CMPedometer()
    @ObservationIgnored private var filter: PositionKalmanFilter?
    @ObservationIgnored private var lastPedometerDistance: Double = 0
    @ObservationIgnored private var lastPredict = Date()
    @ObservationIgnored var onUpdate: (() -> Void)?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.activityType = .fitness
        manager.headingFilter = 2
        manager.headingOrientation = .portrait
        authorization = manager.authorizationStatus
    }

    func requestPermission() {
        manager.requestWhenInUseAuthorization()
    }

    func start() {
        manager.startUpdatingLocation()
        if CLLocationManager.headingAvailable() { manager.startUpdatingHeading() }
    }

    func stop() {
        manager.stopUpdatingLocation()
        manager.stopUpdatingHeading()
        pedometer.stopUpdates()
        filter = nil
        smoothedPosition = nil
    }

    /// Best recent fix for the tee position (horizontal accuracy ≤ 15 m and < 10 s old).
    var teeFix: GeoCoordinate? {
        guard let f = lastFix, f.horizontalAccuracy >= 0, f.horizontalAccuracy <= 15,
              -f.timestamp.timeIntervalSinceNow < 10 else { return nil }
        return GeoCoordinate(latitude: f.coordinate.latitude, longitude: f.coordinate.longitude)
    }

    /// Starts dead-reckoning fusion from the tee.
    func beginWalk(from origin: GeoCoordinate) {
        filter = PositionKalmanFilter(origin: origin, initialVariance: 25)
        smoothedPosition = origin
        lastPedometerDistance = 0
        lastPredict = Date()
        // Walking in the background (screen locked, phone in pocket) keeps guidance running.
        manager.allowsBackgroundLocationUpdates = true
        manager.showsBackgroundLocationIndicator = true
        start()
        if CMPedometer.isDistanceAvailable() {
            pedometer.startUpdates(from: Date()) { [weak self] data, _ in
                guard let meters = data?.distance?.doubleValue else { return }
                Task { @MainActor in self?.pedometerUpdate(totalMeters: meters) }
            }
        }
    }

    func endWalk() {
        manager.allowsBackgroundLocationUpdates = false
        pedometer.stopUpdates()
        filter = nil
    }

    private func pedometerUpdate(totalMeters: Double) {
        guard var f = filter, let h = heading else { return }
        let delta = max(0, totalMeters - lastPedometerDistance)
        lastPedometerDistance = totalMeters
        let now = Date()
        f.predict(distanceWalkedMeters: delta, headingDeg: h, elapsedSeconds: now.timeIntervalSince(lastPredict))
        lastPredict = now
        filter = f
        smoothedPosition = f.coordinate
        onUpdate?()
    }

    fileprivate func received(location: CLLocation) {
        lastFix = location
        guard var f = filter, location.horizontalAccuracy > 0 else { return }
        f.update(gps: GeoCoordinate(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude),
                 horizontalAccuracy: location.horizontalAccuracy)
        filter = f
        smoothedPosition = f.coordinate
        onUpdate?()
    }

    fileprivate func received(heading h: CLHeading) {
        let value = h.trueHeading >= 0 ? h.trueHeading : h.magneticHeading
        heading = value
        onUpdate?()
    }

    fileprivate func received(authorization status: CLAuthorizationStatus) {
        authorization = status
    }
}

extension LocationService: CLLocationManagerDelegate {
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let last = locations.last else { return }
        Task { @MainActor in self.received(location: last) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        Task { @MainActor in self.received(heading: newHeading) }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in self.received(authorization: status) }
    }

    nonisolated func locationManagerShouldDisplayHeadingCalibration(_ manager: CLLocationManager) -> Bool {
        true
    }
}
