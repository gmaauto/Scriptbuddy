# VIGBT: Vision Impaired Golf Ball Tracker

This folder holds the core engine for an on-device iOS assistive app for blind and low-vision golfers.
See [SPEC.md](SPEC.md) for the full technical and commercial specification.

`VIGBTCore` is a Foundation-only Swift package. It contains every algorithm in the pipeline:

| Stage | Types |
|---|---|
| Impact trigger and pre-roll | `ImpactDetector`, `RingBuffer`, `ClipWindow` |
| Ball detection and tracking | `BallColorProfile`, `FusionScorer`, `BallTracker` |
| Launch vector (v0, θ, φ) | `LaunchVectorExtractor` |
| Ballistics and landing zone | `SpinEstimator`, `BallisticSolver` (3D RK4 with drag and Magnus lift), `LandingZoneEstimator` |
| Geospatial | `GeoMath` |
| Walk-to-ball | `PositionKalmanFilter`, `NavigationEngine` |
| Close-range homing | `HomingController` |
| Monetization gating | `EntitlementGate`, `ShotQuota` |

```bash
cd VIGBT
swift test
```

To use the package in the iOS app target, add it in Xcode with **File → Add Package Dependencies → Add Local…**.
The AVFoundation, ARKit, Vision, StoreKit and CoreHaptics adapters belong in the app target; they are listed
in SPEC.md §7.
