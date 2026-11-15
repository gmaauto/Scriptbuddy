# Vision Impaired Golf Ball Tracker (VIGBT) — Master Technical & Commercial Specification

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

**Phase 5 UI (specified, not yet built).**
- **New screens:** Course picker, Round setup (tee set and starting hole), and a Hole header on the
  Ready / Walk / Homing screens showing the hole number, par, distance to the pin and recommended club.
  The club picker defaults to the recommendation.
- **Course layout:** a full-screen sheet with the **Return** button. While it is open, `AppModel.phase` does
  not change, so closing it restores the previous screen and all guidance keeps running underneath.
- **New services:** `CourseService` (download and import), with the cache stored next to `ShotStore`.

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
| **VIGBT source code** (core, app, tests, tools) | Published under an OSI-approved licence. Recommended: **Apache-2.0**, which is compatible with App Store distribution and grants patent rights. MIT would also work. Avoid GPL/AGPL: the App Store terms conflict with them, and the FSF has had GPL apps removed for this reason. | **Licence not chosen yet. A `LICENSE` file is still needed.** |
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

