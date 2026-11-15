# Changelog

All notable changes to VIGBT are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Semantic Versioning](https://semver.org/spec/v2.0.0.html). See `SPEC.md` §10 for the versioning rules.

Versions before 1.0.0 are development builds that have not yet been compiled or tested on a device.

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
