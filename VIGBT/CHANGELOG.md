# Changelog

All notable changes to VIGBT are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Semantic Versioning](https://semver.org/spec/v2.0.0.html). See `SPEC.md` §10 for the versioning rules.

Versions before 1.0.0 are development builds that have not yet been compiled or tested on a device.

## [0.14.1] - 2026-11-19

### Design
- Homing screen (guided search) approved on re-review. All 16 screens are approved (`design/approvals.md`).

## [0.14.0] - 2026-11-19

### Added
- Water handling, decided in the replay-screen review (options a and c; SPEC §12.8):
  - when the ball is predicted in water, the readout starts with a water warning before the numbers, with a warning haptic (`Readout.shotSummary`, `Readout.waterWarning`);
  - "Drop a ball" replaces "Walk to ball": it records `ShotRecord.droppedFromWater`, speaks drop instructions and starts setup at the drop spot. Walking guidance is never offered towards water.
- `vigbt-montecarlo`: `--ground-per-round` and `--roll-learning` options.

### Fixed
- The Swift package did not compile:
  - `HoleGeometry` read `.e`/`.n` from `enuOffset`, which returns `east`/`north`;
  - a lift expression in `BallisticSolver` failed type-checking;
  - `MonteCarloTests` called a helper named `run()`, which clashed with `XCTestCase.run()`.
  - All 114 tests now pass on Linux (Swift 6.0.3). The iOS app target still needs a macOS build.
- The roll-learning test used 300 shots (10 rounds), and p90 noise of about 1 yd hid the gain. It now uses 1,200 shots. At 3,000 shots, learning lowers p90 by 1–2 yd on each of three seeds.

### Design
- Replay screen approved with changes: keep the surface sentence; announce water first; replace walking with "Drop a ball" (`design/approvals.md`).

## [0.13.3] - 2026-11-17

### Design
- Walk screen approved on re-review (`design/approvals.md`). "Yards to the search zone" and "Turn left 20 degrees" are kept.
- Replay mockup on the review page now shows the full spoken readout, including the search-zone sentence the app already speaks.

## [0.13.2] - 2026-11-17

### Fixed
- Walk screen: the distance label read only "yards", and VoiceOver and speech said "yards to go", although since 0.11.0 the distance is to the near end of the search zone, not to the ball. The screen, VoiceOver and spoken guidance now all say "yards to the search zone", matching the reviewed design (`Readout.distanceToSearchZone`).

## [0.13.1] - 2026-11-17

### Documented
- Wind-shear study (SPEC §12.11). A log-law wind profile in the predictor makes predictions worse whenever the golfer enters the wind: p90 error to rest rises from 29.3 to 31.7 yd and ellipse coverage falls from 90.2% to 85.6%. It helps only when the wind is known exactly. The predictor therefore keeps uniform wind; no app code change.
- `tools/monte_carlo.py`: `--shear-truth` and `--shear-predict` take a profile strength from 0 (uniform) to 1 (full log law). Report: `docs/validation/wind-shear-sweep-30k.txt`.

## [0.13.0] - 2026-11-16

### Added
- Trained ball-detector pipeline (SPEC §12.10):
  - `tools/train_ball_detector.py`: a tiny centre-heatmap network that refuses datasets without an open licence and exports to Core ML.
  - `CoreMLBallDetector`: used only when a model trained on open data is bundled.
  - `DetectionFusion` (combines the model with the hand-built detectors).
  - `DetectionRange`: search lanes widen only for a field-validated range.
  - The smoke test on synthetic images reached precision 0.97 and recall 0.76.
- SPEC §9.4: review of ballistics-engine (MIT/Apache-2.0). Wind shear, station atmosphere, uncertainty-aware learning and an error-budget hint are taken as ideas; no code is copied.

### Notes
- Core ML export did not run in the Linux/Python 3.13 build environment. It is expected to work on macOS, which is untested.

## [0.12.1] - 2026-11-16

### Documented
- Search-pattern alternatives (SPEC §12.9): widening, lanes clipped to the ellipse, and an ellipse-shaped spiral did not beat the shipped axis-then-lanes pattern. Missed balls mostly run out of walking budget rather than lying outside the pattern. The study is in `tools/search_sim.py` and the report in `docs/validation/search-alternatives-100k.txt`. No code change.

## [0.12.0] - 2026-11-16

### Added
- `SurfaceMap` and `Surface`:
  - The hole's mapped fairways, green, bunkers and water decide the roll physics for the predicted landing point (rough, green, bunker and water each have their own).
  - The readout and stats say what the ball lands on ("It should land in the rough.", "It may have gone in the water.").
  - In a million-shot test, the p90 error drops from 31.1 to 28.5 yd and search coverage rises from 87.9% to 89.4% (SPEC §12.8).
- Monte Carlo `--surface-model fairway` (rough by landing outside a fairway) and `--map-surface`.

### Changed
- `LandingEstimate.landingSurface`; `LandingZoneEstimator.estimate`, `ShotAnalyzer.analyze` and `ClipAnalysisService.analyze` take a `surfaceMap`.
- The "Your shot" screen gains a "Lands" row and a surface sentence, so it is marked for review again.

## [0.11.0] - 2026-11-16

### Added
- Guided search pattern (SPEC §12.7):
  - `SearchPattern` and `SearchGuide` lead the golfer down the long axis of the search ellipse, then along lanes, with a spoken instruction at each turn.
  - The beacon leads along the path while the camera scans, and pauses when the ball comes into view.
  - In a 100,000-shot study with a pink ball, the median walk in the zone drops from 43 m to 30 m and 89.8% of balls are found within 250 m, up from 87.9%.
- `tools/search_sim.py` (search strategy study) and `docs/validation/search-pattern-100k.txt`.

### Changed
- Walking guidance now ends at the near end of the search zone (5 m arrival radius) instead of its centre. The ground scanner starts there.

## [0.10.1] - 2026-11-16

### Approved
- All 16 iOS screens approved in design review, with no changes requested: Welcome and safety, Set up at the tee, Ready, Measuring, Your shot, Walking to your ball, Finding your ball, Ball found, Course layout, Choose course, Round setup, Wind, My bag, Settings, VIGBT Pro, Shot history. Logged in `design/approvals.md`.

## [0.10.0] - 2026-11-16

### Added
- `RollLearner`: learns how far balls roll on this course today from the balls the golfer finds, and scales later roll predictions. It resets for each new round or day. In a million-shot test with one ground firmness per round, the p90 error drops from 34.9 to 30.8 yd and search coverage rises from 86.2% to 88.2% (SPEC §12.6).
- `ShotFrame` (converts between GPS coordinates and the shot's local frame); `LandingEstimate.rollMultiplier` and `nominalRest`.
- Monte Carlo ground model with one firmness per round, per-shot variation and rough (`--ground-model round`, `--ground-learning`; Swift `groundPerRound`, `rollLearning`).
- Screen review: `design/screen-review.html` (16 iOS screens in both themes and three text sizes, with Approve / Request changes), `design/README.md` (workflow) and `design/approvals.md` (decision log).

### Changed
- Versioning rule (SPEC §10): every implemented recommendation is a minor release, and every batch of screen-review decisions is a patch release. The review page's version is now part of the version check.

## [0.9.0] - 2026-11-15

### Added
- Wind input (SPEC §12.5):
  - `WindInput`, with strength presets (calm to very strong) and 8 directions relative to the target ("into you", "from the left", …), stored as a compass bearing. Wind older than 2 hours is ignored.
  - The wind feeds the flight prediction and the plays-like distance used for club advice.
  - A Wind picker with large buttons, on the Setup and Ready screens.
- Compass correction:
  - `CompassCorrection` averages heading readings and checks how steady they are. An unsteady compass usually means metal nearby, and the golfer is warned.
  - Optional **Sight the flag** step at setup, used when the flag position is known.
  - `SessionCompassLearner` learns each tripod setup's compass error from the balls the golfer finds.
- Tighter search ellipse once the compass is corrected and wind is entered: ±20% / ±10% of carry, 35% less area to search.
- Monte Carlo modes `--wind-input` and `--heading-mode raw|sighted|session` (Python and Swift), and the million-shot report `docs/validation/monte-carlo-1M-seed2026-wind-compass.txt`.

### Changed
- The calibration stores the averaged raw heading. `TeeCalibration.compassCorrectionDeg` records the correction applied to each shot; it is optional, so older shots still load.
- In the simulator, the ball now flies through wind that gusts ±20% around the base wind.

## [0.8.0] - 2026-11-15

### Added
- Monte Carlo validation (SPEC §12):
  - `tools/monte_carlo.py` (1,000,000 shots in about 8 minutes) and the Swift `MonteCarlo` harness, which runs the real `VIGBTCore` pipeline;
  - a `vigbt-montecarlo` command-line runner, a CI test, and a 200,000-shot CI run;
  - the full million-shot report in `docs/validation/`.
- `ReprojectionFitter`: a tee-anchored 3D flight fit on raw pixel measurements that also estimates the spin-axis tilt from early curvature. Ball speed error at p90 drops from ±21–30 mph to ±2.9 mph, and spin-axis error from ±27° to ±8°.
- `RollModel` and `GroundModel`: bounce and roll. The navigation target is now the predicted rest position.
- Search ellipse (±22% of carry along the line, ±14% across) with a separate low-launch rule (±45% / ±12% of the predicted rest distance). Coverage of the true rest position is 84.6%, against 13.2% for the old 8% circle.
- `SeededRandom` (reproducible SplitMix64 random numbers).

### Changed
- `LandingEstimate` gains rest and ellipse fields. They are optional, so shots saved before 0.8.0 still load.
- `SearchZoneModel` now measures found balls against the predicted rest position. Its default radius is 0.18 × carry.
- Ball tracking follows up to 40 frames, until the camera loses the ball.
- Readouts state where the ball should stop and the size of the search zone.

## [0.7.0] - 2026-11-15

### Added
- White-ball detector (`WhiteBallDetector`, Phase 4.5). A candidate must be white, brighter than its neighbourhood, round and solid, and surrounded by grass, so sky, frost, painted lines, sand and cart paths are rejected. It is used for ground scanning, the ball highlight, and the ball on the tee before impact.
- "White" ball colour option.
- Ball-colour recommendation (SPEC Phase 4.5): matte neon pink/magenta, backed by measured false-positive rates. It is now the default colour.

### Changed
- `BlobDetector.detectWithArea` reports each blob's pixel count.
- `shots.json` is now format 3, because shots can record the new white preset. Version 0.6.0 will keep the file untouched instead of misreading it.

## [0.6.0] - 2026-11-15

### Added
- Project versioning:
  - `VERSION` file, this changelog, and a document version and revision history in `SPEC.md`.
  - `VIGBTVersion` in code; `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in the app project are kept in sync with it.
  - `tools/check_version.sh` and `VersioningTests` fail the build if any of these disagree.
- Versioned data files: every saved JSON file now carries `formatVersion` and `appVersion`. Older files (format 1) still load. A file written by a newer app version is refused instead of being overwritten.
- Visual accessibility (WCAG 2.2):
  - Text meets AAA contrast (at least 7:1) and graphics meet at least 3:1, in both a high-contrast dark theme and a high-contrast light theme. Unit tests enforce this.
  - A theme setting: dark, light, or match the system.
  - Dynamic Type on every screen, including the largest accessibility sizes. Rows switch to vertical layouts and all content scrolls.
  - Hazards on the course map have patterns and text labels, so nothing relies on colour alone.
  - Reduce Motion shows a still replay tracer. Smart Invert leaves the camera, video and map alone.
- Low-vision ball highlight on the Homing screen: the scene is dimmed, ball-coloured pixels are painted in the accent colour, and the detected ball is ringed. It can be magnified.

### Changed
- All colours now come from one tested palette. Secondary buttons always have an outline.

## [0.5.0] - 2026-11-15

### Added
- Phase 5:
  - Courses from OpenStreetMap or GeoJSON, or marked on site.
  - Choice of starting hole and tee set, with prompts when the golfer reaches the next tee.
  - Club recommendation from the distance to the pin, including plays-like distance and a lay-up rule for hazards.
  - Club bag with carries learned from the golfer's own shots.
  - Course layout screen with a spoken hole description and a Return button.
- Learned search zone: carry bias, lateral bias and search radius are learned from balls that were actually found.
- `SPEC.md` §9: research on features from other golf apps and from open-source projects.

## [0.4.0] - 2026-11-15

### Added
- `SPEC.md` Phase 5 specification.
- Open-source policy (§8).
- Apache-2.0 `LICENSE` and `NOTICE`.

## [0.3.0] - 2026-11-15

### Added
- Club-aware spin estimation.
- Simulated shots, which run in the iOS Simulator.
- Shot history.

## [0.2.0] - 2026-11-15

### Added
- iOS app layer:
  - high-speed capture with a 5-second pre-roll and an acoustic trigger;
  - LiDAR calibration;
  - clip analysis;
  - walk-to-ball with a spatial audio beacon;
  - haptic homing;
  - StoreKit 2 purchase.

## [0.1.0] - 2026-11-15

### Added
- `VIGBTCore` Swift package:
  - ball detection and tracking;
  - launch vector extraction;
  - RK4 drag-and-Magnus ballistics;
  - WGS84 projection;
  - navigation and homing logic;
  - entitlement gating.
- `SPEC.md` with Section 5 data contracts and engineering notes.
