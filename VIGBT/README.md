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

## iOS app

```bash
brew install xcodegen
cd VIGBT/App && xcodegen && open VIGBT.xcodeproj
```

- **Simulator and SwiftUI previews:** use the **VIGBT** scheme (Debug). The Simulator has no camera or
  LiDAR, so use **Simulated shot**.
- **iPhone:** you need a LiDAR iPhone (12 Pro or a newer Pro model). Use the **VIGBT Device** scheme
  (Release, so image processing runs at full speed). Put your team ID and a unique bundle ID in
  `App/Config/Local.xcconfig`, starting from `Local.xcconfig.example`; that file is git-ignored.
  `docs/device-testing.md` has the full setup and the test plan.
- **Purchases:** `VIGBT.storekit` is wired into both schemes, so the Pro purchase can be tested locally.

See SPEC.md §7 for what each file does.

## Versioning

The current version is in [`VERSION`](VERSION), and changes are listed in [CHANGELOG.md](CHANGELOG.md).
SPEC.md §10 has the rules. Run `tools/check_version.sh` before committing a release.

## Accessibility

Every screen meets WCAG 2.2 AAA text contrast (at least 7:1) in both the high-contrast dark and light
themes, supports Dynamic Type up to the largest accessibility sizes, and never relies on colour alone.
SPEC.md §11 has the details, and `AccessibilityTests` checks the palette.

## Licence

VIGBT is open source under the [Apache License 2.0](LICENSE). Its dependencies and data sources must be
open source or open data too. Course data is © OpenStreetMap contributors (ODbL). See SPEC.md §8 for the
full policy.
