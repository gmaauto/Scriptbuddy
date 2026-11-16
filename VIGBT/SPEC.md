# Vision Impaired Golf Ball Tracker (VIGBT) — Master Technical & Commercial Specification

Document version: 0.13.0 · Updated 2026-11-15 · Status: draft (not yet compiled or tested on a device)

| Version | Date | Changes |
|---|---|---|
| 0.13.0 | 2026-11-16 | §12.10 trained-detector pipeline; §9.4 ballistics-engine research |
| 0.12.1 | 2026-11-16 | §12.9 search-pattern alternatives tested; none beat axis-then-lanes (no code change) |
| 0.12.0 | 2026-11-16 | §12.8 course-map surfaces (fairway, rough, green, bunker, water) for roll and readout |
| 0.11.0 | 2026-11-16 | §12.7 guided search pattern; walking guidance now ends at the near end of the search zone |
| 0.10.1 | 2026-11-16 | All 16 screens approved in design review (`design/approvals.md`); no spec changes |
| 0.10.0 | 2026-11-16 | §12.6 learning ground firmness; screen review workflow (§10, `design/`) |
| 0.9.0 | 2026-11-15 | §12.5 wind input and compass correction; tighter search ellipse |
| 0.8.0 | 2026-11-15 | §12 Monte Carlo validation (1M shots); reprojection fit with spin-axis estimation; bounce and roll; search ellipse |
| 0.7.0 | 2026-11-15 | Phase 4.5: white-ball detector and ball-colour recommendation |
| 0.6.0 | 2026-11-15 | Versioning rules (§10); visual accessibility requirements (§11); low-vision ball highlight |
| 0.5.0 | 2026-11-15 | Phase 5 built; Phase 4.4 learned search zone; §9 research |
| 0.4.0 | 2026-11-15 | Phase 5 specified; §8 open-source policy; Apache-2.0 |
| 0.3.0 | 2026-11-15 | Club selection (§6 note 3), simulated shots, shot history (§7) |
| 0.2.0 | 2026-11-15 | §7 iOS app layer |
| 0.1.0 | 2026-11-15 | Original specification; §5 data contracts and §6 engineering notes added |

## 1. Executive Summary & Product Vision

VIGBT is an accessible, on-device iOS app for visually impaired and low-vision golfers. A tripod-mounted,
LiDAR-equipped iPhone at the tee box captures the swing at high frame rate, isolates the ball's launch vector
with computer vision, predicts the landing zone with an aerodynamic ballistic physics engine, and guides the
golfer to the ball with spatial audio and haptics.

**Core architectural principles**

- **100% on-device edge processing.** No cloud servers or recurring API costs. Video processing, Vision
  tracking, physics and spatial audio run locally, so the app works offline on the course and keeps all
  App Store net revenue.
- **Launch-to-physics hand-off.** Pixel-tracking a ball 200+ yards downrange from a ground-level tripod is
  optically infeasible. The CV pipeline tracks only the first 15–25 ft off the clubface (10–20 frames at
  120 fps) to extract ball speed `v0`, vertical launch angle `θ` and horizontal azimuth `φ`, then hands them
  to a ballistic solver.
- **Accessibility first.** Every screen, alert and feedback loop is built around VoiceOver, high-contrast
  readouts and tactile feedback.
- **Open source throughout.** The app's code, every third-party dependency and every data source must be
  open source or open data. The details are in §8.

## 2. Commercial & App Store Architecture

### 2.1 Monetization (StoreKit 2)

- **Model:** paid upfront ($14.99–$19.99) *or* freemium with one non-consumable lifetime unlock
  `com.vigbt.pro.unlock`.
- **Free / trial tier:** 120 fps swing capture and slow-motion replay, 3 shots per day.
- **Pro tier:** unlimited shots, ballistic range & dispersion, GPS/spatial-audio walk-to-ball, haptic homing.
- **Receipt validation:** on-device via `Transaction.currentEntitlements` (StoreKit 2 JWS verification); no
  receipt server.
- **Open source and paid at the same time:** the source is public, so anyone can build the app themselves
  for free. The App Store price pays for the convenience of a signed, maintained build, and it is allowed
  under the licences in §8. The Pro gate is therefore a way to support the project, not copy protection.

### 2.2 App Store review & hardware compliance

- **Info.plist:** `NSCameraUsageDescription` (tee capture, ground scan), `NSMicrophoneUsageDescription`
  (impact detection), `NSLocationWhenInUseUsageDescription` (walk-to-ball navigation).
- **Thermal & battery:** release `CMSampleBuffer`s immediately after the trigger and stop the
  `AVCaptureSession` while the golfer walks.
- **Safety disclaimer:** onboarding acknowledgment that VIGBT is a navigational aid, not a hazard or collision
  avoidance system.

## 3. Target Hardware & Tech Stack

- **Hardware:** LiDAR iPhones (iPhone 12 Pro or newer).
- **OS:** iOS 17.0+, Swift 5.9+, SwiftUI.
- **Frameworks:** AVFoundation (1080p120 Ultra-Wide capture, pre-roll buffer, audio metering), ARKit (ground
  plane, `D_tee`), Vision + Accelerate (vImage HSV threshold, `VNDetectContoursRequest`, optical flow),
  CoreLocation + CoreMotion (GPS, true-north heading, pedometer), AVFAudio (`AVAudioEnvironmentNode`),
  StoreKit 2.

## 4. Phased Engineering Roadmap

### Phase 1 — MVP: capture, hybrid CV tracking, annotated replay

1. **Rolling pre-roll and acoustic trigger.** Keep 5.0 s of 1920×1080 @ 120 fps from `builtInUltraWideCamera`.
   Detect the club–ball transient (`T0`) on `AVAudioEngine` input; provide a manual **Test Strike** button.
   Save `[T0 − 1.5 s, T0 + 3.5 s]` to a temporary `.mov`, then pause capture.
2. **LiDAR tee calibration.** A short `ARWorldTrackingConfiguration` pass measures `D_tee` and camera pitch to
   the tee ground plane, giving metric scale at the tee (`m/px = D_tee / f`).
3. **Hybrid detection.** Preset HSV masks (Neon Orange, Neon Pink); tap-to-sample override (15×15 patch);
   color-agnostic motion + circularity gate (`0.7 ≤ aspect ≤ 1.3`) along a consistent kinematic vector.
   `Score = w1·Kinematics + w2·Circularity + w3·ColorMatch`.
4. **Annotated replay.** 0.25× loop, SwiftUI `Canvas` tracer spline through validated centroids, freeze on the
   exit vector with a VoiceOver launch readout.

### Phase 2 — Ballistics & landing zone

1. **Vector extraction (frames `T0+1 … T0+12`, `Δt = 1/120 s`):** `v0` (m/s, read out in mph), `θ` corrected
   for camera tilt via the `CMMotionManager` gravity vector, `φ` relative to the camera's true-north heading
   `ψ_camera`.
2. **3D trajectory solver:** RK4, `Δt = 0.01 s`, gravity + drag + Magnus lift:

   `a = −g·ẑ − k·C_d·v_rel + k·C_l·(ω̂ × v_rel)`, with `k = ρ·A·|v_rel| / (2m)` and `v_rel = v − wind`.

   - **Spin heuristic:** `ω ≈ 2200 + 140·θ_deg` rpm, clamped to [2000, 8500].
   - **Dispersion:** primary landing point `(X_carry, Y_lateral)` plus `R_search ≈ 0.08·X_carry`
     (±12 yd at 150 yd).
3. **Geospatial projection:** project carry and bearing `ψ_camera + φ` from the tee `CLLocation` to WGS84
   (`TargetCoordinate`).

### Phase 3 — Walk-to-ball navigation & spatial audio

1. **Navigation engine:** distance remaining `d_rem` and heading error `Δψ = ψ_target − ψ_user`; GPS smoothed
   with a Kalman filter fused with pedometer steps.
2. **3D audio beacon (`AVAudioEnvironmentNode`):** on-line → centred sonar pulse whose tempo rises as `d_rem`
   falls; off-line (`|Δψ| > 15°`) → beacon pans left/right with a pitch shift; VoiceOver callouts at 100, 50,
   25 yd and "Arrived at search zone" at `d_rem ≤ 10 yd`.

### Phase 4 — Close-range visual & haptic homing

1. **Search mode:** auto at `d_rem ≤ 10 yd` or via **Scan Ground**; rear Wide camera at 1080p60, continuous AF,
   torch in low light.
2. **Ground scanner:** HSV mask from the active ball profile + circular contours tuned for grass.
3. **Haptics:** double-tap when the ball enters view; Geiger ticks that speed up as the ball is centred;
   confirmation tone + `.success` when centred within 2 m.
4. **Learned search zone (implemented, from §9 research).**
   - **What is recorded:** when a ball is found, its position (the Phase 4 lock point) is stored in the
     shot as `foundLocation`. That gives a measured landing error for every found ball.
   - **What is learned:** `SearchZoneModel` learns the golfer's own **carry bias**, **lateral bias** and a
     **search radius** that covers 80% of past misses. It uses the last 20 found balls, per club category,
     falling back to all clubs. It needs at least 5 real (not simulated) balls.
   - **Limits:** both biases are capped at ±15% and the radius factor is held between 0.04 and 0.20 × carry.
   - **Effect:** the next prediction is shifted and its circle resized. A golfer who always lands 10% short
     and right is sent to the right place with a tighter circle, instead of the spec's fixed 8% radius.

### Phase 4.5 — Ball colour recommendation and white-ball detection

**Recommended ball: matte neon pink (magenta).** Matte neon orange is second choice. Avoid yellow or
lime for camera finding.

Each colour's detection mask was run against simulated pixels from typical course backgrounds (40,000
samples per cell; reproduce with `tools/ball_color_analysis.py`). The figures are false-positive rates; lower is better.

| Ball colour (mask) | Green grass | Dry grass | Autumn leaves / soil | Bunker sand | White things (sky, frost, daisies, lines) | Worst |
|---|---|---|---|---|---|---|
| **Neon pink / magenta** | 0.0% | 0.0% | 0.0% | 0.0% | 0.0% | **0.0%** |
| Neon orange | 0.0% | 0.0% | 27.3% | 0.0% | 0.0% | 27.3% |
| Optic yellow | 1.3% | 4.2% | 0.0% | 0.0% | 0.0% | 4.2% |
| Lime / green | 8.6% | 0.0% | 0.0% | 0.0% | 0.0% | 8.6% |
| White (colour only) | 0.0% | 0.0% | 0.0% | 23.3% | 100% | 100% |

- **Why pink:** magenta is about 143° of hue away from grass, the furthest of any ball colour. Almost
  nothing on a course is that colour, apart from occasional flowers.
- **Orange's weakness:** it shares its hue with autumn leaves and bare soil.
- **Yellow and lime:** too close to sunlit or dry grass.
- **Matte finish:** a matte surface avoids glossy highlights, which show up as white specks that break
  colour masks.
- **Golfers' own eyes:** human vision depends on brightness contrast, not hue. Pink is only about 1.3:1
  against grass in brightness, while optic yellow and white are about 3.9:1. A golfer who uses their own
  remaining sight *without* the app may see yellow or white better. With the app, the ball highlight
  (§11) repaints the ball in a 7:1 accent colour, so pink is the best choice overall.

**White balls (`WhiteBallDetector`, built in 0.7.0).** For golfers who play ordinary white balls, a
candidate must pass all four tests:

1. **White:** saturation at most 0.22 and brightness at least 0.62.
2. **Brighter than its surroundings:** at least 0.15 brighter than the average of a 25 × 25 area. This
   removes sky, cloud and frost.
3. **Round and solid:** aspect ratio 0.7 to 1.3, and at least 55% of its bounding circle filled. This
   removes painted lines and clutter.
4. **Grass all round:** at least half of the ring 1.6 to 2.6 radii out must be grass-coloured. This
   removes balls on sand or cart paths, and stakes against the sky.

Unit-tested scenes:

| Scene | Expected |
|---|---|
| Ball on grass | Found |
| Distant ball 3 px across | Found |
| Ball next to a painted line | Ball found, line rejected |
| Sky edge | Rejected |
| Ball on sand | Rejected |
| Ball on a cart path | Rejected |
| Grey disc | Rejected |

**Planned next step:** a small Core ML detector, combined with this heuristic. It would be trained only on
datasets whose licence has been checked (for example MIT-licensed Roboflow golf-ball sets) and on footage
we record ourselves. The heuristic stays as the fallback that needs no model.

### Phase 5 — Course & hole selection, club recommendation, course layout

**Goal:** the golfer plays a real round. They pick the course and the hole they start on (a regular,
back-nine or shotgun start), and at every shot the app says the distance to the pin and recommends a club.

1. **Course selection.**
   - **Course picker:** courses near the current GPS position, sorted by distance, with search by name. Also
     a list of recently played courses, which works offline.
   - **Course data:** each hole's tee boxes, green (front, centre and back), pin, fairway outline and
     hazards (bunkers, water, out of bounds), plus par and stroke index.
   - **Data sources (open data only, no proprietary or paid course databases):**
     - **OpenStreetMap (ODbL):** the app fetches one course's `golf=*` features once (`golf=hole` with its
       `ref`, `par` and `handicap` tags, plus `tee`, `green`, `pin`, `fairway`, `bunker`, `water_hazard`,
       `lateral_water_hazard` and `rough`) through a public Overpass API instance, following its fair-use
       policy. The result is converted to a `GolfCourse` package and cached on the device.
     - **An open-format file the user imports:** GeoJSON or GPX, for example exported from OSM editors.
     - **Marking the course in person:** stand on each tee and on each green and press "Mark tee" and
       "Mark green". This needs no data at all.
     - **Elevation for "plays-like" distance:** optional, from open elevation data (Copernicus GLO-30 DEM or
       SRTM). If it is not available, the elevation adjustment is skipped.
   - **Coverage gaps:** many courses in OSM have only some holes or no pins mapped. Missing pieces are filled
     by marking in person. Courses the golfer marks can optionally be contributed back to OpenStreetMap
     through the golfer's own OSM account. This is never automatic, because the data is the golfer's own
     GPS trace.
   - **Offline principle:** downloading a course is the only network use, and it happens once. There is no
     backend and no recurring cost, so §1's on-device principle still holds. Playing a cached course needs
     no signal.
   - **Pin position:** the green centre is the default. The golfer or a helper can set today's pin by
     standing next to the hole and pressing "Set pin here", or by choosing front, centre or back.

2. **Starting hole and hole tracking.**
   - **Choose the starting hole:** 1–18, defaulting to 1. Choosing 10 is a back-nine start; any hole works
     for a shotgun start. Play wraps from 18 to 1.
   - **Choose the tee set:** for example white, yellow or red. This sets the hole length that is read out.
   - **Moving to the next hole:** when the golfer is within 25 m of the next hole's tee box and the current
     hole's ball has been found or the hole is marked done, the app asks, "Hole 5. Are you on the tee?"
     **Next hole** and **Previous hole** buttons are always available, and every hole change is announced.
   - **Calibration:** the tee GPS fix replaces the course's stored tee position for that shot. The bearing
     from the tee to the pin gives the intended target line.

3. **Distance to the pin and club recommendation.**
   - **Distance:** the distance to the pin comes from the current position: the tee for a tee shot, or the
     found ball position after Phase 4. Front, centre and back distances to the green are also available.
   - **Club distances:** each golfer has a personal carry distance per club, learned from their own tracked
     shots. It uses a rolling median of the last 10 shots per club and starts from age- and
     handicap-based defaults that the golfer can edit.
   - **Picking the club:** the recommended club has the smallest median carry that is at least the plays-like
     distance minus a short-side margin of 5 yards.
   - **Plays-like distance:** the distance adjusted for elevation (1 yard per metre of rise, when the
     course package has elevation) and for wind, if the golfer enters it.
   - **Tee shots on long holes:** when the distance to the pin is longer than the longest club, the app
     recommends the longest club that keeps the median landing point at least 10 yards short of any hazard
     crossing the centre line.
   - **Readout:** spoken and shown on screen, for example: "152 yards to the pin. Plays 158. Recommended:
     7-iron. Your 7-iron carries 155." Alternatives one club either side are listed below.
   - **Feeding into the shot:** the recommended club becomes the selected club for spin estimation (§6
     note 3). The golfer can override it before the shot, and the override is what gets recorded.
   - **Finer club list:** this needs a more detailed list than today's spin categories: Driver, 3W, 5W, 7W,
     hybrids (2–5), irons (3–9), PW, GW, SW and LW. Each maps to a spin category in `Club`.
   - **Alignment aid:** at address, the spatial-audio beacon (Phase 3.2) can be placed on the pin's bearing
     to help the golfer aim, then switched off before the swing so it does not set off the impact trigger.

4. **Course layout screen.**
   - **Opening it:** a **Course layout** button is on the Ready, Replay, Walk and Homing screens. It opens a
     full-screen view of the current hole. Opening it does not stop any running guidance: the beacon,
     milestone callouts and homing haptics keep going.
   - **Visual view:** drawn by the app itself with SwiftUI `Canvas` from the course's open vector data. There
     are no map tiles and no satellite imagery, both of which are proprietary. This also keeps the view
     fully offline and lets it use high contrast. The hole is rotated so the tee is at the bottom and the
     green at the top, and shows "© OpenStreetMap contributors" as the ODbL requires. Overlays in thick,
     high-contrast colours show:
     - the tee;
     - the fairway outline;
     - hazards, in a distinct colour and pattern;
     - the green and pin;
     - the golfer's position;
     - the predicted landing point with its search circle (Phase 2);
     - the tracked ball path.
   - **Non-visual view:** VoiceOver reads an ordered description of the hole, from the tee to the green, for
     example: "Hole 4, par 4, 380 yards, stroke index 7. Fairway bends right at 230 yards. Bunker on the
     right from 215 to 240 yards. Water short left of the green at 340 yards. Green 28 yards deep." Each
     feature is its own accessibility element, with its distance from the golfer's current position.
   - **Return button:** a **Return** button, at least 64 pt high and fixed at the bottom, closes the layout.
     It brings back exactly the screen and state the golfer left, and reads that screen's title. The VoiceOver
     escape gesture (two-finger Z) does the same.

5. **Round flow and scoring (optional).** Each recorded shot is attached to its hole. A hole summary is
   spoken when the golfer moves to the next hole, for example: "Hole 4: 3 shots tracked, last ball found 12
   yards short of the green." Full scorecard entry is out of scope for this phase.

6. **Proposed tiers (open product decision).**
   - **Free:** course and hole selection, the layout screen, and distance to the pin.
   - **Pro:** club recommendation and learned club distances, which depend on Phase 2 carry tracking.

## 5. Data Models (Core Swift Contracts)

All contracts live in the `VIGBTCore` Swift package (`VIGBT/Sources/VIGBTCore`). The package is
Foundation-only (no AVFoundation, ARKit, Vision or CoreLocation imports), so every algorithm is unit-testable
on macOS, the iOS Simulator and Linux CI. The iOS app layer adapts framework types at the boundary, for example
`CLLocationCoordinate2D ↔ GeoCoordinate` and `VNContoursObservation → DetectionCandidate`.

### 5.1 Coordinate conventions

| Space | Axes | Notes |
|---|---|---|
| Image | +x right, +y down, origin top-left, pixels | Vision normalized coords must be flipped (`1 − y`) and scaled. |
| Camera | +x right, +y down, +z along optical axis | Pinhole, `f = (W/2) / tan(hFOV/2)`. |
| Physics world | +x downrange (camera heading), +y **left**, +z up | Right-handed. Public APIs report lateral offsets as **positive = right**. |
| Geo | WGS84 lat/lon, true-north bearings in [0, 360) | Spherical earth (error is centimetres at golf distances). |

### 5.2 Contracts

| Type | Purpose | Key fields |
|---|---|---|
| `TeeCalibration` | Phase 1.2 output | `distanceToTeeMeters` (optical-axis depth), `cameraPitchRadians`, `cameraRollRadians`, `cameraHeadingDeg`, `horizontalFOVRadians`, `imageWidth/Height`, `teeLocation`; derived `focalLengthPixels`, `metersPerPixelAtTee` |
| `HSV`, `HSVRange` | Color masks | Hue in degrees; ranges may wrap through 0° |
| `BallColorProfile` | Active ball color (Phases 1 and 4) | `.neonOrange`, `.neonPink`, `.sampled(from:)` (circular-mean hue ± tolerance) |
| `DetectionCandidate` | One contour blob per frame | centre, bbox, `colorMatchFraction`; derived `aspectRatio`, `radiusPixels` |
| `TrackedCentroid` | Validated ball position | `frameOffset` (T0+n), `x`, `y`, `radiusPixels`, `score` |
| `LaunchVector` | Phase 2.1 output | `ballSpeed` (m/s), `launchAngleDeg`, `azimuthDeg` (+ = right); `ballSpeedMph`, `initialVelocity` |
| `SpinEstimate` | Spin input | `rpm`, `axisTiltDeg` (+ = fade/slice) |
| `TrajectorySolution` | Solver output | `samples`, `carryMeters`, `lateralMeters`, `apexMeters`, `flightTimeSeconds`, `landingSpeed`, `landingAngleDeg` |
| `LandingEstimate` | Phase 2 result | carry, lateral, `searchRadiusMeters`, `target` |
| `TargetCoordinate` | Phase 2 → 3 hand-off | `coordinate`, `bearingFromTeeDeg`, `distanceFromTeeMeters`, `searchRadiusMeters` |
| `ShotRecord` | Persisted shot (Codable) | id, timestamp, profile, calibration, centroids, launch, spin, trajectory, landing, `clipFileName` |
| `ShotPhase` | App state machine | `setup → armed → processing → replay → navigating → homing → found` |
| `NavigationGuidance` | Phase 3 tick | `distanceRemainingMeters`, `headingErrorDeg`, `alignment`, `pulseIntervalSeconds`, `beaconRight/Forward`, `pitchShiftCents`, `milestones`, `hasArrived` |
| `GroundDetection`, `HomingEvent` | Phase 4 I/O | normalized centre offset + depth → `.peripheralDetected`, `.tick`, `.lost`, `.locked` |
| `EntitlementTier`, `Feature`, `ShotQuota` | Section 2.1 gating | free-tier daily counter (3/day), feature matrix |
| `GolfCourse` | Phase 5.1 course package (Codable, cached offline) | `id`, `name`, `location`, `holes`, `source` (`.download`, `.imported`, `.marked`), `updatedAt` |
| `Hole` | One hole | `number`, `par`, `strokeIndex`, `tees: [TeeBox]`, `green: GreenGeometry`, `pin: GeoCoordinate?`, `centerline: [GeoCoordinate]`, `fairway: [GeoCoordinate]`, `hazards: [Hazard]` |
| `TeeBox` | Tee set position | `name` (e.g. "White"), `coordinate`, `lengthMeters` |
| `GreenGeometry` | Green targets | `front`, `center`, `back` coordinates, `outline`, optional `elevationMeters` |
| `Hazard` | Layout feature | `kind` (`.bunker`, `.water`, `.outOfBounds`, `.trees`), `outline: [GeoCoordinate]`, derived carry-in / carry-out distances along the centre line |
| `RoundState` | Current round (persisted) | `course`, `teeSetName`, `startingHole`, `currentHole`, `holesPlayed`, `shotIDs` per hole |
| `ClubBag` / `ClubStats` | Phase 5.3 learned distances | specific club (Driver … LW) → `spinCategory: Club`, `medianCarryMeters`, `sampleCount`, `isUserEdited` |
| `ClubRecommendation` | Phase 5.3 output | `distanceToPinMeters`, `playsLikeMeters`, `recommended`, `alternatives`, `reason`, spoken `readout` |
| `HoleDescription` | Phase 5.4 non-visual layout | ordered `[LayoutFeature]` (kind, side, from/to distance) → spoken text |

### 5.3 Services (pure logic, in `VIGBTCore`)

| Service | Spec section |
|---|---|
| `ImpactDetector`: adaptive noise floor, +24 dB threshold, −20 dBFS absolute floor, 2 s refractory, `forceTrigger` for Test Strike | 4 / Phase 1.1 |
| `RingBuffer<T>`, `ClipWindow`, `RingBufferBudget` | Phase 1.1 |
| `FusionScorer`, `BallTracker` (constant-velocity gated association) | Phase 1.3 |
| `LaunchVectorExtractor` (pinhole back-projection, gravity levelling, per-axis least squares) | Phase 2.1 |
| `SpinEstimator`, `AerodynamicModel`, `BallisticSolver` (3D RK4), `LandingZoneEstimator` | Phase 2.2 |
| `GeoMath` (destination, haversine, bearing, ENU) | Phase 2.3 |
| `PositionKalmanFilter`, `NavigationEngine` | Phase 3 |
| `HomingController` | Phase 4 |
| `EntitlementGate` | Section 2.1 |
| `CourseLocator`: nearest courses to a GPS fix; matches a GPS fix to a tee box to detect the next hole | Phase 5.1–5.2 |
| `HoleGeometry`: distances to the pin and front/centre/back of the green, hazard carry distances along the centre line, layout rotation angle | Phase 5.2–5.4 |
| `ClubAdvisor`: plays-like distance, smallest-club-that-reaches rule, hazard lay-up rule, rolling median learned from `ShotRecord`s | Phase 5.3 |
| `HoleDescriber`: hole geometry → ordered spoken description with distances relative to the golfer | Phase 5.4 |

## 6. Engineering Review Notes (decisions and corrections to the original draft)

1. **The pre-roll cannot hold raw frames.** 5 s × 120 fps = 600 frames. At ~3.1 MB per 1080p NV12 frame,
   that is ~1.9 GB, which iOS will terminate for memory. Encode the pre-roll continuously to HEVC instead
   (`AVAssetWriter` writing ~1 s rolling segments, or `VTCompressionSession` packets in the `RingBuffer`),
   which is about 37 MB at 60 Mbps. Decode only the 12–20 frames after `T0` for CV. `RingBufferBudget`
   encodes this check.
2. **3D launch from one camera.** A single 2D view cannot measure motion toward or away from the lens. The
   extractor recovers depth per frame from the ball's apparent size, anchored to LiDAR:
   `Z_i = D_tee · r_tee / r_i`. All three velocity components are therefore measured whether the tripod is
   face-on or down-the-line, and `φ` is reported relative to `ψ_camera` as specified. For the noise budget,
   prefer down-the-line placement (behind the golfer), where `φ` comes mostly from the image x-axis and size
   only affects speed. The ball is only about 6–12 px wide at 3 m on the Ultra-Wide, so sub-pixel ellipse
   fitting on the contour is required.
3. **Spin heuristic accuracy.** `2200 + 140·θ` matches drivers (about 3.7k rpm at 11°) but underestimates
   irons. A tour 7-iron at 16° gives about 4.4k rpm against a real ~7k. Low spin flies longer, so iron carry
   reads long by about 10–15%. The 8% search radius partly absorbs this. **Implemented:** a `Club` picker on
   the Ready screen uses typical tour spin per club (driver 2.7k … wedge 8.5k rpm, clamped to the spec's
   bounds). `.auto` keeps the formula. With the mid-iron setting, a tour 7-iron carries 174 yd, against
   187 yd from the formula and 172 yd measured on tour.
4. **Aerodynamic coefficients.** `C_d = 0.18 + 0.30·S`, `C_l = min(0.25, 0.08 + 0.60·S)`, `S = rω/|v|`,
   with spin decay time constant τ = 25 s. Fitted against PGA Tour TrackMan averages, the model gives driver
   272 yd (tour 275), 7-iron 173 (172), PW 130 (136) and 3-wood 253 (243).
   `AerodynamicModel.airDensity(...)` supports temperature, pressure and humidity correction.
5. **Camera tilt.** Pitch and roll come from the gravity vector at calibration time. The extractor removes
   both before computing `θ`, and subtracts the ½gt² drop over the fit window, so the fitted `v_z` is the
   launch value at `T0`.
6. **Milestone hygiene.** `NavigationEngine.begin(from:)` suppresses callouts the golfer is already inside
   (no "100 yards" on a 40-yard chip). If one GPS jump crosses several milestones, only the nearest is
   spoken.
7. **Homing lock debounce.** `.locked` requires 6 consecutive centred frames within 2 m (LiDAR depth at the
   centroid), which rejects single-frame false positives such as divots and leaves.

## 7. iOS app layer (`VIGBT/App`)

The app target is defined in `App/project.yml`. Generate it with XcodeGen
(`brew install xcodegen && cd VIGBT/App && xcodegen`). It depends on `VIGBTCore` as a local package.

| File | Role |
|---|---|
| `Services/CaptureService.swift` | Ultra-Wide 1080p120 (falls back to Wide), stabilization off, distortion correction on, 1/2000 s shutter locked after auto-exposure settles. Rolling 1 s HEVC segments in a `RingBuffer`. `AVAudioEngine` tap → `ImpactDetector` in 5 ms blocks, minus the acoustic delay `D_tee/343`. After T0 + 3.5 s: stop the session, stitch the overlapping segments and export the clip. |
| `Services/ClipAnalysisService.swift` | `AVAssetReader` decodes T0 − 8 … T0 + 20 frames as BGRA → `FrameMasks` → resting-ball radius from colour blobs before impact, motion blobs after it → `ShotAnalyzer`. |
| `Services/CalibrationService.swift` | ARKit `.gravityAndHeading` + `.sceneDepth`. Centre raycast gives optical-axis depth; pitch, roll and true-north heading come from the camera transform. Locks when 10 readings agree within 3 cm. Tap-to-sample reads a 15×15 YCbCr patch. |
| `Services/LocationService.swift` | GPS, true heading and `CMPedometer` → `PositionKalmanFilter`. Keeps working in the background with the screen locked. |
| `Services/FeedbackServices.swift` | Speech (VoiceOver announcements when VoiceOver is running), audio session modes, `AVAudioEnvironmentNode` HRTF beacon (mono ping, pitch-shifted when off-line), CoreHaptics Geiger ticks. |
| `Services/GroundScanService.swift` | Wide camera at 1080p60, continuous AF, auto torch. Colour mask at half resolution → round blob → `GroundDetection`, with distance from apparent size. |
| `Services/StoreService.swift` | StoreKit 2: product, purchase, restore, `Transaction.updates` / `currentEntitlements` → `EntitlementTier`. |
| `Services/ShotStore.swift` | On-device JSON persistence of shots (last 30, with clips), free-tier quota, disclaimer and colour profile. |
| `App/AppModel.swift` | The state machine. Powers only the current phase's hardware and pauses recording when the phone gets too hot. |
| `Views/*` | High-contrast SwiftUI screens with 64 pt buttons, headers and spoken status. Replay draws a Catmull–Rom tracer and the exit arrow over a 0.25× looping player. |

Info.plist additions beyond §2.2: `NSMotionUsageDescription` (the pedometer needs it) and
`UIBackgroundModes` `audio` + `location` (guidance keeps running with the screen locked; App Review will
ask for this justification). `VIGBT.storekit` lets the purchase be tested in the simulator and on a device
without App Store Connect.

**Phase 5 UI (built).**
- **New screens:** Course picker, Round setup (tee set and starting hole), and a Hole header on the
  Ready / Walk / Homing screens showing the hole number, par, distance to the pin and recommended club.
  The club picker defaults to the recommendation.
- **Course layout:** a full-screen sheet with the **Return** button. While it is open, `AppModel.phase` does
  not change, so closing it restores the previous screen and all guidance keeps running underneath.
- **New services:** `CourseService` (download and import), with the cache stored next to `ShotStore`.
- **Files:** `Services/CourseService.swift`, `App/RoundModel.swift` and `Views/CourseViews.swift`.
  - `HoleHeader` appears at the top of every screen during a round.
  - Arriving on the next tee shows a "Yes, start hole N" prompt.
  - The club picker is pre-selected from the recommendation until the golfer picks by hand.
  - **My bag** edits which clubs are carried and their carry distances.
  - The layout screen has **Read hole**, **Mark tee**, **Mark green**, **Set pin here** and **Return**.
- **Not built yet:** importing GPX files (GeoJSON import works), and elevation for plays-like distance
  (the hook is in place but no open elevation data is bundled yet).

**Simulated shot.** `ShotSimulator` (core) generates a physically consistent calibration and per-frame
detections, including the vacated tee spot and club-head distractors, from a random launch. The whole
pipeline then runs: tracking, extraction, ballistics, replay tracer, walk-to-ball and paywall. This works
in the iOS Simulator with no camera, LiDAR or ball. Simulated shots do not count toward the free-tier
limit. In the Simulator, walking guidance falls back to GPS course, or to "on line", when there is no
compass. Drive the walk with an Xcode GPX route.

**Shot history** lists the last 30 shots, each with its club, carry and date. Each one reopens in replay
and supports walk-to-ball.

**Not yet verified on hardware:**
- 1080p120 availability on the Ultra-Wide of each supported model.
- That the sensor-native buffer orientation matches ARKit's camera axes (both are landscape-right; the
  pitch/roll derivation relies on this).
- The motion/colour thresholds on real grass and in real light.
- `CLHeading` behaviour when the phone is held upright rather than flat.

## 8. Open-source policy and licensing

Everything that makes up VIGBT must be open source or open data.

| Part | Requirement | Current status |
|---|---|---|
| **VIGBT source code** (core, app, tests, tools) | Published under an OSI-approved licence. Recommended: **Apache-2.0**, which is compatible with App Store distribution and grants patent rights. MIT would also work. Avoid GPL/AGPL: the App Store terms conflict with them, and the FSF has had GPL apps removed for this reason. | **Done:** Apache-2.0. See `VIGBT/LICENSE` and `VIGBT/NOTICE`. |
| **Third-party code dependencies** | Only OSI-licensed packages, pinned to exact versions, with their licences listed in an in-app "Acknowledgements" screen. | None so far. `VIGBTCore` and the app use only the Swift standard library and the iOS SDK. |
| **Build tools** | Open source. | XcodeGen (MIT), Swift toolchain (Apache-2.0). The coefficient-fitting script is in this repo. |
| **Course data** | Open data only: OpenStreetMap (ODbL 1.0), user imports in open formats (GeoJSON or GPX), or the golfer's own marking. ODbL needs "© OpenStreetMap contributors" shown wherever course data appears, and share-alike for any course *database* the project publishes. | Specified in Phase 5.1. |
| **Elevation data** | Open data only: Copernicus GLO-30 or SRTM, with attribution. | Optional. |
| **Maps and imagery** | No proprietary map tiles or satellite imagery. The course layout is drawn from vector data (Phase 5.4). | Specified. |
| **Physics and aero coefficients** | Derived only from published averages and documented in this spec (§6 note 4), so others can reproduce and change them. | Done. |

**Exception: the platform itself.** iOS frameworks such as AVFoundation, ARKit, CoreLocation, CoreHaptics
and StoreKit are closed source, and any iOS app has to use them. The project keeps them as thin adapters
in `VIGBT/App`. All algorithms stay in the open, Foundation-only `VIGBTCore` package, which also builds on
Linux. That makes a future port to another platform (for example Android, or an open-hardware launch
monitor) a matter of rewriting the adapters only.

**Bundled assets** such as sounds, icons and voice prompts must be created by the project or carry an open
licence (CC0 or CC-BY). The beacon ping is synthesized in code, so it needs no asset.

## 9. Research: features from other golf apps and open-source projects

**Method.** Features were taken only from public sources: App Store listings, reviews, project READMEs and
news coverage. No app was decompiled or reverse-engineered. That would break those apps' terms and
copyright, and code obtained that way could not ship under Apache-2.0 (§8). Open-source code is reused only
when its licence is compatible with Apache-2.0. Otherwise only the idea is used.

### 9.1 What exists

- **Commercial GPS and caddie apps** (Golf Pad, Golfshot, SwingU, Shot Pattern, Arccos, 18Birdies, Tangent):
  - **Typical paid features:** plays-like distance (elevation and wind), club recommendations from the
    golfer's own shot history, strokes gained, and per-club **dispersion patterns**.
  - **Pricing:** the paid tiers cost about $25–$200 a year. Most are subscriptions, and Arccos needs
    sensors.
  - None of them is built for blind golfers.
- **Blind and low-vision golf:**
  - Toptracer ranges run sight-loss clinics where each shot's distance, direction and accuracy are spoken.
  - GolfBuddy Voice devices speak GPS distances.
  - A Johns Hopkins student project ("Green Reader") targets green reading for visually impaired putters.
  - The MeepMeep disc-golf tracker shows that screen-reader-first design works for finding a thrown object.
  - There is no mainstream golf ball finder for blind players. VIGBT's walk-to-ball and homing appear to be
    unique.
- **Sighted ball-finder apps,** for example Golf Ball Finder, put a coloured (blue) filter over the camera so a
  ball stands out from grass.
- **Open-source launch monitors:**
  - **PiTrac** uses Raspberry Pi cameras to measure 3D speed, launch angles and spin. Its components carry
    several licence files, so treat it as **ideas only** until those are checked.
  - **OpenFlight** uses Doppler radar plus a sound trigger to measure ball and club speed, smash factor and
    launch angle. It is **AGPL-3.0, so its code is not compatible** with this Apache-2.0 project and only
    ideas are used.

### 9.2 Adopted

| Feature (seen in) | VIGBT version | Status |
|---|---|---|
| Plays-like distance (Golf Pad, SwingU) | `ClubAdvisor.playsLike`: elevation and wind | Done (elevation data pending) |
| Club recommendation from personal history (SwingU, Golfshot, Arccos) | `ClubBag.learn` rolling median + `ClubAdvisor` | Done |
| Alternatives when between clubs (Tangent "Smart Caddie") | One club either side is offered | Done |
| Per-club dispersion (Shot Pattern, Arccos) | **Learned search zone** from *found* balls (Phase 4.4), which is ground truth no GPS app has | Done |
| Hazard-aware lay-up (caddie apps) | Lay-up rule for hazards crossing the line | Done |
| Spoken shot feedback (Toptracer blind clinics, GolfBuddy Voice) | Launch, carry and search-zone readouts | Done |
| Sound-triggered capture window (OpenFlight, as an idea) | `ImpactDetector` | Already in place |

### 9.4 ballistics-engine (ballistics.rs), reviewed 0.13.0

[ballistics-engine](https://github.com/ajokela/ballistics-engine) (crate 0.50.1, **MIT OR Apache-2.0**, so
compatible with this project, with attribution if code is copied) is a large rifle-ballistics engine
(about 146,000 lines of Rust). VIGBT copies no code from it. Ideas worth taking:

| Idea | Module | Value for VIGBT |
|---|---|---|
| **Wind shear (log-law profile)** | `wind/field.rs` `LogProfile` | High. The golfer feels wind at about 1.7 m, but a drive peaks at 25–30 m where wind is about 1.7× stronger. A 10 mph headwind costs a further 5–6 yd of carry (driver 229 → 223 yd). Planned for 0.14.0. |
| Station atmosphere (ICAO plus humidity) | `atmosphere.rs` | Medium. The iPhone barometer (`CMAltimeter`) gives station pressure, which gives air density. A course at altitude flies noticeably further. |
| Uncertainty-aware truing (MAP fit with priors and Laplace intervals) | `truing_uncertainty.rs` | Medium. A principled version of our learners (compass, roll, search zone), which could also report *how sure* they are. |
| Per-input error budget ("which single input is worth improving") | `error_budget.rs` | Medium. Our ablations (§12.3) as an in-app hint, e.g. "Entering the wind would help most now." |
| Spin decay from roll-damping physics | `spin_decay.rs` | Low. Built for bullets; golf needs its own data. We keep τ = 25 s. |
| Adaptive RK45 integration | `trajectory_integration.rs` | Low. Speed only; our fixed-step RK4 is fast enough. |

Not relevant: Coriolis (about 1 cm at golf distances), reticles and optics, recoil, gyroscopic stability,
bullet ballistic-coefficient tables, transonic drag.

### 9.3 Backlog (prioritised)

1. **Low-vision ball highlight** (from colour-filter finder apps). **Done in 0.6.0:** `BallHighlight` and
   `HomingView`, with zoom up to 4×. On the Homing screen, draw the live
   colour mask as a bright, magnifiable overlay so low-vision golfers can see the ball as well as hear it.
2. **External launch monitor input** (from PiTrac and OpenFlight). An optional input that takes launch data
   (`LaunchVector`, and spin when available) from a DIY or commercial launch monitor through an open, local
   protocol. A radar's speed and spin then replace the camera estimate, while walk-to-ball and homing stay
   unchanged. Check the licence and terms of whichever protocol is chosen first.
3. **Club speed and smash factor** (from OpenFlight). Track the club-head blob in the frames before impact
   (it is already in the motion mask) to estimate club speed and smash factor. Useful for coaching and as a
   check on bad ball-speed readings.
4. **Strokes gained, spoken** (from Golf Pad, Shot Pattern and 18Birdies). Use the round's shot positions
   to produce a short spoken summary after each hole.
5. **Green reading with LiDAR** (from Green Reader). Scan the green with the ARKit mesh, fit a plane, then
   speak the slope and fall line relative to the line to the hole, for example "Putt breaks left, slightly
   uphill."
6. **Apple Watch** (from Golfshot and Arccos). Directional taps on the wrist for walk-to-ball, and homing
   ticks on the wrist so the phone can stay pointed at the ground.
7. **Practice-range mode** (from Toptracer clinics). Capture and readouts only, with no walk or homing, for
   lessons and warm-ups.

## 10. Versioning

- **One version number for everything.** It follows Semantic Versioning (`MAJOR.MINOR.PATCH`). While the
  major number is 0 the project is in development, and 1.0.0 will be the first release tested on real
  devices.
  - **MINOR** goes up for new features or spec sections.
  - **PATCH** goes up for fixes and wording changes.
  - **MAJOR** (from 1.0) goes up for changes that break saved data or the app's settings.
- **Where the version must appear.** All of these are updated in the same commit:
  - the `VIGBT/VERSION` file;
  - `VIGBTVersion.string` in code;
  - a new top entry in `CHANGELOG.md`;
  - this document's "Document version" line, with a new row in the revision table;
  - `MARKETING_VERSION` in `App/project.yml`.
- **Build number.** `CURRENT_PROJECT_VERSION` in `App/project.yml` and `VIGBTVersion.build` go up by 1 for
  every release. The App Store requires the build number to increase with each upload.
- **Enforcement.** `tools/check_version.sh` (run in CI) and `VersioningTests` fail if any of these places
  disagree.
- **Saved data files.**
  - Every JSON file the app writes (`shots.json`, `quota.json`, the course files, the club bag and the round
    state) is wrapped as `{formatVersion, appVersion, savedAt, payload}`. The current format numbers are in
    `DataFormat`.
  - **Changing a file's shape:** bump that file's number and add a migration in `DataFormat.decode`.
  - **Old files:** files from before this scheme (format 1, without the wrapper) are still read.
  - **Newer files:** a file written by a newer app version is never overwritten. The app keeps it and asks
    the golfer to update.
- **A new version for every decision.** Each implemented recommendation or new feature is a **minor**
  release. Each batch of screen-review decisions from the review page is a **patch** release, whether
  approvals or requested changes, and is logged in `design/approvals.md`, so every approved state of the
  app can be named by its version. The review page (`design/screen-review.html`) shows the version and is
  covered by the version check. The workflow is in `design/README.md`.
- **Tags.** Each release is tagged `vX.Y.Z` on the commit that sets the version.
- **Source files.** Individual source files do not carry version headers. Git history already records the
  version of every file, and per-file headers tend to go out of date.

## 11. Visual accessibility requirements

These are the targets for every screen. The standard is WCAG 2.2: AAA for contrast and text size, and AA
for everything else. Apple's accessibility guidelines also apply.

| Requirement | Implementation |
|---|---|
| **Text contrast at least 7:1** (WCAG 1.4.6 AAA) | All colours come from `ThemePalette`. `AccessibilityTests` checks every text and background pair in both themes; the lowest ratio is 7.6:1. |
| **Graphics contrast at least 3:1** (1.4.11) | Map features, the tracer, the pin and the outlines are tested against the background. A secondary button's fill can be below 3:1, so it always has a text-colour outline. |
| **Not colour alone** (1.4.1) | Hazards are filled *and* patterned *and* labelled (water has wavy lines, bunkers are dotted, out of bounds is dashed). On-line or off-line guidance is spoken and shown as text, not only as arrow colour. |
| **Themes** | High-contrast dark (yellow and white on black, the default), high-contrast light (black and blue on white), or "Match system". Set under Settings → Display. |
| **Text size and reflow** (1.4.4, 1.4.10) | Only Dynamic Type text styles are used. Large numbers use `@ScaledMetric`. Every screen scrolls, and button rows switch to vertical layouts at accessibility text sizes (`AdaptiveStack`). |
| **Bold Text and Increase Contrast** | Text styles pick up Bold Text automatically. With Increase Contrast, outlines get thicker. |
| **Touch targets** (2.5.8) | Main buttons are at least 64 pt high and every other control at least 44 pt. |
| **Reduce Motion** (2.3.3) | The replay tracer is shown complete and still instead of animating. |
| **Smart Invert** | The camera preview, video, map and ball highlight are excluded from inversion. |
| **Screen reader** | Headings, combined elements, hints, and announcements for status changes. Decorative images are hidden. |
| **Low vision** | Ball highlight: a magnifiable view of the mask with a ring around the ball. Very large distance numbers on the Walk screen. |

## 12. Monte Carlo validation (1,000,000 simulated shots)

**Question.** Starting only from what the tee camera sees in the first few frames, how reliably can VIGBT
predict where the ball ends up? This covers every kind of strike, including skulls, slices, hooks and
shanks.

### 12.1 Method

- **Harness.** `tools/monte_carlo.py` (vectorised NumPy, about 8 minutes per million shots) and the Swift
  `MonteCarlo` (the real `VIGBTCore` code; `swift run -c release vigbt-montecarlo --shots N`, plus a
  400-shot CI test). Both share the same models and seeds.
- **Shot mix.**
  - Clubs: driver (35%), 7-iron (40%) and wedge (25%), at amateur speeds, launch angles and spins.
  - Strikes: pure 40%, slice 15%, hook 8%, thin/skull 8%, push 6%, pull 6%, fat 6%, toe/heel 6%,
    topped 3%, shank 1%, pop-up 1%.
  - Each strike changes speed, launch angle, spin, spin-axis tilt and direction.
- **Truth (unknown to the app).**
  - The 3D flight with the true spin and spin axis.
  - Random wind (0–6 m/s from any direction) and air density.
  - **Bounce and roll** on ground of random firmness.
- **Camera.**
  - Down-the-line tripod, 2.5–4 m behind the tee and 0.8–1.4 m high, Ultra-Wide lens, 120 fps.
  - The ball is followed **until the camera loses it**: it leaves the frame or appears smaller than
    1 px in radius. The median is 36 frames (0.3 s); 1 shot in 10 gets fewer than 25.
- **Measurement errors.**
  - Ball centre ±0.35 px.
  - Ball radius ±(0.2 px + 3%).
  - 5% of frames missed.
  - LiDAR tee distance ±2 cm.
  - Camera tilt and roll ±0.5°.
  - **Compass heading ±3°.**
- **Score.** The distance from the predicted target to the **true rest position**, and whether the ball
  lies inside the search zone.

### 12.2 Findings and the changes they drove

| Finding | Change (0.8.0) |
|---|---|
| Turning each frame's apparent size into a distance gave speed errors of ±21–30 mph (p90) with a slow bias. For a down-the-line camera, almost all speed information comes from the ball shrinking. | **`ReprojectionFitter`**: anchors the flight at the tee and fits the 3D flight (gravity, drag, lift) to the raw pixel position and radius, each weighted by its own noise. Result: speed ±2.9 mph, launch ±1.0°, direction ±0.5° (p90). |
| Spin axis (slice/hook) was the largest single unknown. | The same fit estimates **spin-axis tilt from the curve of the first 0.3 s** (a slice moves about 20 px sideways). Tilt error drops from ±27° to **±8°** and lateral error p90 from 33 to 18.5 yd. Spin *rate* is not observable that early, so it stays with the club table (prior ±700 rpm). |
| The golfer looks for the ball where it **stopped**, not where it landed. A driver typically rolls 15–25 yd. | **`RollModel`** (impulse bounces, then rolling friction). The navigation target is now the predicted rest position. |
| The spec's 8%-of-carry circle around the landing point contained only **13%** of balls. | **Search ellipse** around the predicted rest point: ±22% of carry along the line and ±14% across (80% coverage; the ellipse is about 6% smaller than the equivalent circle). |
| Thin, skulled and topped shots are mostly roll, and the roll depends on ground firmness. | Below 8° launch the ellipse is sized from the predicted rest distance: ±45% along and ±12% across. Coverage for those shots rises from 19% to **87%**. |
| Placing the tripod face-on gives the best speed (±1.1 mph) but only about 11 frames and worse direction. | Keep down-the-line as the recommended placement. 45° behind is an acceptable alternative. |

### 12.3 Results (1,000,000 shots, seed 2026, full report in `docs/validation/`)

| Measure | Value |
|---|---|
| Launch measured (at least 4 frames, valid fit) | 100.0% |
| Error to final rest | median **14.3 yd**, p80 27.0, p90 37.5, p95 50.4 |
| Search-zone coverage, shipped policy | **84.6%** (normal 84.5%, low launch 87.2%) |
| Same, old policy (8% circle at landing) | 13.2% |
| Median error by club (pure strikes) | driver 21 yd, 7-iron 12.5 yd, wedge 8.5 yd |
| Worst strike types (p90) | driver thin/skull 100 yd, topped 120 yd (now inside their wider zones 87% of the time) |

**What still limits accuracy** (each figure is the p90 error with that unknown removed; baseline 48.7 yd
before spin-axis estimation):

| Unknown removed | p90 error |
|---|---|
| Spin axis | 39.2 yd (now largely recovered by the fit) |
| Wind | 43.4 yd |
| Ground firmness | 44.0 yd |
| Compass | 46.4 yd |
| Spin rate | 48.2 yd |

With everything known, the median error is 3 yd. Measurement is not the bottleneck. Wind, ground firmness
and the compass are.

### 12.4 Next steps suggested by the data

1. **Done in 0.9.0 (§12.5).** **Ask the user for wind**, or use the phone's barometer and weather data where available offline. This
   is worth about 5 yd at p90.
2. **Done in 0.10.0 (§12.6).** **Learn ground firmness per course** from found balls, extending `SearchZoneModel` to the roll
   distance.
3. **Done in 0.9.0 (§12.5), plus self-correction from found balls.** **Correct the compass** by sighting the target line at setup (point the phone at the green or pin):
   ±3° is about 10 yd at 200 yd.
4. **Done in 0.11.0 (§12.7).** **Guided search pattern** inside the ellipse: walk the long axis first, because along-line errors are
   about twice the lateral ones.

### 12.5 Wind input and compass correction (0.9.0)

**Wind.** The golfer picks a strength (calm, light 5 mph, moderate 10, strong 15, very strong 20) and where
they feel it coming from: one of 8 directions relative to the target, such as "into you" or "from the
left, behind". It is stored as a true bearing so it stays right on every hole, and is ignored after 2 hours.
It feeds the flight prediction and the plays-like distance in the club advice.

The simulation assumes the golfer judges strength with ±40% error and direction with ±30°, before snapping
to the presets. The real wind gusts ±20% around what the golfer feels.

**Compass.**
- **Steadiness check:** heading readings are averaged over the calibration (12 readings). If they are
  unsteady (spread over 4°, usually from metal nearby), the golfer is warned.
- **Sight the flag (optional, when the flag position is known):** turn the tripod camera to the flag,
  press, then turn it back to the ball. ARKit tracks the rotation precisely, so only the GPS bearing of the
  tee→flag line is left: about 1–2° at 100–220 m.
- **Self-correction (always on):** each ball found from the same tripod setup reveals that setup's
  compass error (bearing to the predicted rest versus bearing to the found ball).
  `SessionCompassLearner` averages these with a 1-shot shrinkage prior and a 12° outlier clamp. A sighting
  counts as 3 found balls.

**Tighter zone.** Once the compass is corrected and wind is entered, the ellipse narrows to ±20% of carry
along the line and ±10% across (±8% across for low launches). That is 35% less ground to search.

Results (100,000 shots each; the last row is 1,000,000 shots, report in `docs/validation/`):

| Mode | Median error | p90 | Search-zone coverage |
|---|---|---|---|
| 0.8.0 baseline | 14.3 yd | 37.7 yd | 84.3% |
| Wind entered | 13.5 | 36.0 | 84.7% |
| Flag sighted | 12.1 | 35.2 | 90.1% |
| Self-correcting compass (8 shots per setup) | 11.4 | 34.7 | 90.4% |
| Wind + self-correction, tighter zone (1M) | **11.0** | **32.7** | **87.1%** (tight zone on 87% of shots) |
| Limit: wind and compass known exactly | 9.1 | 30.2 | 94.1% |

- **Sideways error at p90** fell from 18.5 yd to 12.4 yd.
- **Median error on pure strikes:** driver 16 yd (was 21), 7-iron 9.6 yd (was 12.5), wedge 6.2 yd (was 8.5).
- **What's left:** the main remaining error is roll, from ground firmness the app cannot see (§12.4 item
  2), plus spin rate.

### 12.6 Learning ground firmness (0.10.0)

**Model change.** Real firmness is shared by a course on a day: weather, mowing and season. In this
simulation each round of 30 shots therefore gets one firmness, with ±25% variation per shot and 30% of balls
in rough, which rolls 1.8× less freely. Before 0.10.0 each shot drew its own firmness.

**Learner.** `RollLearner` learns from each found ball:
- **What it measures:** the roll that actually happened, measured from the predicted landing point along
  the predicted roll direction, as a ratio of the roll the nominal ground model predicted.
- **How it averages:** a geometric mean of these ratios, with a 2-shot prior at 1.0 and each ratio clamped
  to 0.2–3.
- **How it's used:** later predictions scale the roll by the learned multiplier.
- **When it resets:** at each new round, or on a new day.

Results, 1,000,000 shots each, with wind entered and the self-correcting compass (reports in
`docs/validation/`):

| | Without roll learning | With roll learning |
|---|---|---|
| Median error to rest | 11.1 yd | **9.9 yd** |
| p90 | 34.9 yd | **30.8 yd** |
| Along-line p90 | 33.1 yd | **28.5 yd** |
| Search coverage | 86.2% | **88.2%** |
| Pure strikes, median | — | driver 14.1, 7-iron 8.7, wedge 5.7 yd |

Low launches (thin and topped shots) remain the weakest group at about 82% coverage, because their roll
varies most between fairway and rough.

### 12.7 Guided search pattern (0.11.0)

**Problem.** Walking guidance used to lead to the centre of the search zone, with the ground scanner
switched on only within 10 yd of it. Since 48% of balls stop *short* of the predicted point and the golfer
approaches from the tee, many were walked past unseen.

**Change.**
- **Where walking ends:** walking guidance now ends at the zone's near end (5 m arrival radius), where
  scanning starts.
- **The search path:** `SearchPattern` / `SearchGuide` lead the golfer down the long axis to the far end,
  then along lanes 2 × 0.7 × the detection range apart, alternating right and left, out to 1.25× the zone
  half-width.
- **Guidance on the path:** the spatial-audio beacon points to each waypoint and each turn is spoken.
- **When the ball comes into view:** the beacon pauses so the haptic ticks lead. It resumes if the ball is
  lost.
- **Detection range used:** 6 m for a coloured ball and 4 m for a white one.

**Study** (`tools/search_sim.py`: real prediction errors from the shipped pipeline, 100,000 shots, golfer
always approaching from the tee; report in `docs/validation/search-pattern-100k.txt`):

| Ball (detection range) | Strategy | Found within 250 m of searching | Median walk in the zone |
|---|---|---|---|
| Pink (6 m) | Centre, then spiral (before 0.11.0) | 87.9% | 43 m |
| Pink (6 m) | **Axis, then lanes** | **89.8%** | **30 m** |
| White (4 m) | Centre, then spiral | 82.8% | 56 m |
| White (4 m) | **Axis, then lanes** | 82.6% | **50 m** |

- **Less walking:** axis-then-lanes needs less walking on 70% of shots with a pink ball and 61% with a
  white one.
- **Variations that lost:** extending the axis walk 1.3× or 1.6× past the zone ends made results worse
  (more walking for few extra finds). Axis-then-spiral also did worse.
- **White balls:** finding rates are no better, because detection range is the limit there, which is one
  more reason to recommend a pink ball (§4.5).

### 12.8 Course-map surfaces (0.12.0)

**Problem.** After roll learning, the remaining roll error comes mostly from *where* the ball lands: rough
stops a ball far sooner than fairway. In the earlier simulation, rough was assigned at random to 30% of
balls; in reality it depends on the landing point.

**Model.** Each round gets a fairway 13–22 m half-width along the target line, and a ball landing outside
it is in rough. Rough has 1.8× the rolling friction and 0.8× the bounce.

**Change.** `SurfaceMap` takes the hole's mapped fairways, green, bunkers and water (OpenStreetMap or marked
on site) and classifies the predicted landing point. Each surface has its own roll physics, layered on top
of the learned firmness:

| Surface | Roll physics |
|---|---|
| Fairway | The learned fairway model |
| Rough | 1.8× rolling friction, 0.8× bounce |
| Green | 0.5× rolling friction |
| Bunker | Almost no bounce or roll |
| Water | No roll |

The readout and stats name the surface, for example "It should land in the rough." or "It may have gone
in the water." On an unmapped hole, behaviour is unchanged.

Results, 1,000,000 shots each (wind entered, self-correcting compass, roll learning, fairway-width rough;
reports in `docs/validation/`):

| | No map | Map surfaces |
|---|---|---|
| Median error to rest | 10.1 yd | **9.6 yd** |
| p90 | 31.1 yd | **28.5 yd** |
| Along-line p90 | 29.0 yd | **26.0 yd** |
| Search coverage | 87.9% | **89.4%** |
| Pure strikes, median | — | driver 13.7, 7-iron 8.8, wedge 5.8 yd |

### 12.9 Search-pattern alternatives (0.12.1, no code change)

**Question.** About 9.5% of pink balls are still not found within 250 m of searching. Would widening the
search, or a pattern shaped like the ellipse, help?

**Result.** No. With 100,000 shots in the shipped configuration (map surfaces on), the report is
`docs/validation/search-alternatives-100k.txt`:

| Strategy | Found within 250 m | Median walk |
|---|---|---|
| Centre, then spiral (before 0.11) | 89.1% | 42 m |
| **Axis, then lanes (shipped)** | **90.5%** | **31 m** |
| Axis, then lanes, then widen to 2.5× width and 1.5× length | 90.5% | 31 m |
| Axis, then lanes clipped to the ellipse's chord | 90.3% | 31 m |
| Axis, then isotropic spiral | 88.6% | 31 m |
| Axis, then ellipse-shaped spiral | 88.2% | 31 m |

**Why.** 76% of the missed balls lie inside the area the shipped pattern already covers (median 29 m from
the predicted rest). They are missed because long driver searches run out of walking budget, not because
the pattern stops too soon: with a 500 m budget the same pattern finds 94.6%. The remaining levers are
therefore a longer detection range (a pink ball, §4.5; a trained detector) and a smaller zone (better
prediction), not a different path. The shipped pattern is unchanged.

### 12.10 Trained ball detector pipeline (0.13.0)

**Why.** The search study (§12.9) showed detection range is the main remaining lever:

| Detection range | Found within 250 m | Median walk |
|---|---|---|
| 4 m (white ball today) | 83.9% | 48 m |
| 6 m (pink ball today) | 90.6% | 31 m |
| 8 m | 93.6% | 25 m |
| 10 m | 95.2% | 22 m |

**What is built.**
- **`tools/train_ball_detector.py`**, our own code:
  - A tiny network, about 224,000 parameters, that outputs a heat map of ball centres plus each ball's
    radius, at a quarter of the 288 × 512 input resolution.
  - Tools: PyTorch (BSD) to train and coremltools (BSD) to export to Core ML.
  - It **refuses any dataset whose `dataset.json` lacks an approved open licence** (§8).
  - It also writes `VIGBTBallDetector.json` with the training-data licences.
- **`CoreMLBallDetector`** (app): used only if the model and its JSON are bundled and the training data is
  open. Otherwise the scanner works as before.
- **`DetectionFusion`** (core): combines the trained detector with the hand-built checks:
  - when both see the ball, their confidences combine;
  - the trained detector alone counts from 0.6 confidence;
  - the hand-built checks alone behave exactly as before.
- **`DetectionRange`:** the search lanes widen only once a model's range has been **measured in a field
  test** (`validatedRangeMeters`). An untested model can add finds but never widen the search.

**Status.**
- **Pipeline smoke test** on 2,000 *synthetic* images (6 epochs, CPU): precision 0.97, recall 0.76, still
  improving (`docs/validation/detector-smoke-synthetic-metrics.json`). That shows the pipeline works; it
  says nothing about real-world accuracy.
- **Core ML export** did not run in the Linux/Python 3.13 build environment (coremltools' native writer
  is missing there). It is expected to work on macOS, but that is unverified.
- **Next:** train on licence-checked real images, then a field test that fills in `validatedRangeMeters`.

These are model results: the physics, camera and noise figures are assumptions until they are checked
against real recorded shots. Treat real-world capture as the next validation step.

