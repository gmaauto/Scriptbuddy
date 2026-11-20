# Assist projects: handoff

Written 2026-11-20 for a new Claude project. Upload this file to the project's knowledge so any new chat can
pick up the work. It covers two apps built in two earlier Claude Code sessions:

1. **VIGBT** (Vision Impaired Golf Ball Tracker), in the session "golf assist".
2. **Bowling Coach**, in the session "Push git tags".

Both are accessible iPhone apps for blind and low-vision players. They follow the same approach: Swift on
device, everything open source, and simulation before field testing.

---

## Working preferences (apply to both)

- **Accessibility first.** Everything that matters is spoken, VoiceOver-labelled and haptic. Never colour
  alone. Dynamic Type up to the largest sizes. WCAG AAA (7:1) contrast. Screens are reviewed and approved
  one by one.
- **Open source only.** Apache-2.0 for our code and open data only (for example OpenStreetMap, ODbL). No
  decompiling or reverse engineering of proprietary apps. Other projects contribute ideas only, unless
  their licence allows reuse; record which in the spec.
- **On device and private.** No cloud services for player data. AI cloud coaching (for example OpenAI) was
  rejected for that reason.
- **Simulate, then fix, then field test.** Validate features with large Monte Carlo runs before claiming
  accuracy, and say plainly when results are synthetic.
- **Versioning (VIGBT rule, worth keeping for bowling too).**
  - Each implemented recommendation is a **minor** bump.
  - Each batch of screen decisions or each fix is a **patch** bump.
  - `VERSION`, code, CHANGELOG, SPEC and the Xcode project must agree; `tools/check_version.sh` enforces this.
  - Screen decisions are logged in `design/approvals.md`.
- **The developer uses Windows and has no Mac.**
  - iPhone builds run on GitHub Actions macOS runners.
  - The app is installed with AltStore (or Sideloadly) from a field-test `.ipa`.
  - Option B (TestFlight, $99 a year) was offered as the alternative and not chosen yet.
- **Commits** end with the Claude co-author line. No model names in commits or code.

---

## 1. VIGBT: Vision Impaired Golf Ball Tracker

**Code:** GitHub `gmaauto/Scriptbuddy`, branch **`claude/vigbt-specification-ie7w0j`**, folder `VIGBT/`.
**Version:** **0.17.0** (build 25). All commits are pushed. Tags exist locally but GitHub refuses tag pushes
from cloud sessions; push them from a PC with `git push origin --tags` if wanted.
**Screen review page:** https://claude.ai/artifact/Rr6a9yfCtbh5gDYpj3a7qN (private to the owner). All 16
screens are approved. The Ready screen changed in 0.15.0 (swing-check line) and needs re-review.

### What it does
A tripod-mounted LiDAR iPhone (12 Pro or later Pro) at the tee:
1. Calibrates with LiDAR and the compass.
2. Hears the strike and films 120 fps.
3. Tracks the ball until the camera loses it.
4. Fits a 3D flight (RK4 drag + Magnus) and predicts where the ball **stops**, including bounce and roll.
5. Speaks the readout.
6. Guides the golfer walking to a **search ellipse** with spatial audio.
7. Runs a guided close-range ground scan with haptic homing to find the ball.

Other features:
- **Course play:** course and hole choice (OpenStreetMap), club advice from distance to the pin, course
  layout view, wind input, compass correction (flag sighting and learned from found balls), and learned
  ground firmness.
- **Water:** the warning is spoken first, and **Drop a ball** replaces walking.
- **Swing check (0.15.0), on-device Apple Vision pose:**
  - ignores strike sounds that aren't the golfer's swing;
  - announces practice swings;
  - gives tempo relative to the golfer's own swings ("steady / quicker / slower than your usual").
- **Ball colour:** white is supported with a dedicated detector; a coloured ball is recommended for tracking.

### Layout
- `VIGBT/Sources/VIGBTCore`: Swift package, Foundation only, testable on Linux.
  - **Physics:** BallisticSolver, RollModel, Wind, SearchZoneModel.
  - **Vision:** ReprojectionFitter, WhiteBallDetector, DetectionFusion, SwingTracker.
  - **Course:** SurfaceMap, ClubAdvisor.
  - **Navigation:** SearchPattern.
  - **Validation:** MonteCarlo.
- `VIGBT/App`: SwiftUI app, generated with XcodeGen (`project.yml`).
  - **Schemes:** `VIGBT` (Debug, Simulator, SwiftUI previews) and `VIGBT Device` (Release, for the phone).
  - **Signing:** `App/Config/Local.xcconfig`, git-ignored, from `Local.xcconfig.example`.
- `VIGBT/tools`:
  - `monte_carlo.py`: NumPy, millions of shots;
  - `search_sim.py`, `train_ball_detector.py`, `check_version.sh`.
- **Docs:**
  - `SPEC.md` (sections 1–12, the source of truth);
  - `CHANGELOG.md`;
  - `docs/device-testing.md` (Mac and Windows install, staged test plan, results table);
  - `docs/validation/` (simulation reports).
- **CI:** `.github/workflows/vigbt.yml` ("VIGBT CI").
  - **Jobs:** version check; Linux tests plus a 200k-shot Monte Carlo; macOS tests; iPhone app build for
    the Simulator and Release device.
  - **Artifact:** each run uploads **`VIGBT-x.y.z-fieldtest`**, the sideloadable `.ipa`. Its
    `VIGBT_FIELD_TEST` flag unlocks Pro, and Settings labels it.
  - **Mac capacity:** GitHub's macOS arm64 runners are sometimes short of capacity. If they are, use
    "Re-run failed jobs".

### Status
- **Core tests:** 122 Swift tests pass (Linux, Swift 6.0.3 and CI).
- **App build:** builds in CI with Xcode 16.4.
- **Never run on a real iPhone.** That is the next step. The `.ipa` from run 44582355317 is ready, and the
  developer is installing it via AltStore.

### Key simulation results
- **Rest-point accuracy:** with the realistic configuration (1M shots), the median error to the final rest
  point is about 9.6 yd and p90 about 28.5 yd. The shipped search ellipse covers about 90% of shots.
- **Wind shear (0.13.1):** a log-law profile in the predictor makes things worse with golfer-entered wind,
  so it isn't shipped.
- **Swing check:** 2,000 synthetic swings, all detected, no real strike rejected. A 20% tempo change is
  flagged 86% of the time.
- **Synthetic detector pipeline:** precision 0.97, recall 0.76. Not validated on real images.

### Next steps
1. **First install:** install the `.ipa` and run test-plan Stage 1 indoors. Fix any crash or install errors.
2. **Field test:** Stage 2 at a range. Real numbers then retune the search ellipse, detection range and
   swing-check thresholds.
3. **Backlog:**
   - re-review of the Ready screen;
   - penalty strokes on the scorecard for water drops;
   - air density from the barometer;
   - an in-app hint naming which input would help most;
   - training the detector on real, licence-checked images.

---

## 2. Bowling Coach

**⚠️ Not saved anywhere permanent.** The code is version **v0.1.0**, committed with a tag, but only inside
the temporary cloud machine of the session "Push git tags". That session has no GitHub repository, so
**nothing is pushed**. Before that machine is reclaimed, either:
- give that session a GitHub `owner/repo` and ask it to push `main` with the tag; or
- have this session create a folder or repository for it.

Until then, everything below comes from that session's own summary and README, not from code anyone can
reach.

### What it does
Two iPhones, iOS 17+:
- **Lane phone:** on a tripod behind the approach, at head height, centred, at 120 fps. Tracks the ball.
- **Side phone:** about 4–5 m beside the approach, at hip height. Tracks the bowler's body with Apple Vision
  and streams it to the lane phone over Multipeer, with clock sync and a video clip per shot.

**Ball metrics:**
- launch speed and speed at the pins;
- board at the foul line and at the arrows;
- **hit or miss on your mark** (± boards);
- breakpoint board and distance;
- entry board and angle, and a pocket call.

**Body metrics:**
- balance (head over the slide knee) and timing (ball at the bottom vs. slide stop);
- backswing height and elbow bend;
- slide knee and forward tilt;
- finish hold and step count;
- from behind: swing straightness, start and slide board, and drift.

**After each shot:**
- a spoken report (brief, standard or full), through VoiceOver when it's on;
- a lane diagram with an audio graph;
- drills matched to the bowler's faults;
- pin count, session stats and CSV export.

**Accessibility:**
- spoken framing help on the side phone ("I can't see your feet…");
- haptics, and icons with words (not colour alone);
- Dynamic Type;
- calibration needs a sighted helper once per tripod setup: six taps on lane landmarks with a magnifier
  loupe.

### Layout (in that session's machine, at `/home/user/bowling-coach`)
- `bowling_coach/`: Python reference implementation (lane geometry, ball tracking, metrics, MediaPipe form
  analysis, CLI). **10 pytest tests pass.**
- `ios/BowlingCore`: a Swift port of the same algorithms, plus the link protocol and clock sync, with XCTest.
- `ios/App`: SwiftUI app; `ios/project.yml` for XcodeGen.
- `sim/`: `simulate.py` and `analyze.py`, with results in `sim/RESULTS.md`.
- `reference/`: cloned open-source repos and `fetch.sh`.
- **Licences of the references:**
  - **may be reused:** only TrueLine (MIT) and CorraPiano. TrueLine inspired the six-landmark
    least-squares calibration. The others gave ideas only, and no code was copied;
  - **video link:** AVCaptureMultipeerVideoDataOutput (MIT) showed the iPhone-to-iPhone video link.

### Status
**The Swift code has never been compiled.** It was written without a Swift toolchain, so expect build fixes.
The same GitHub Actions approach as VIGBT would solve that for a Windows developer: macOS CI build plus a
field-test `.ipa`. Note that this app needs **two** iPhones.

### Simulation (100,000 throws, through the real tracker and metrics code)

| Measure | Result |
|---|---|
| Throws tracked | 99.75% |
| Launch speed, typical error | 0.38 mph |
| Board at the arrows, typical error | 0.25 board |
| Entry angle, typical error | 0.8° |
| Entry board, typical error | 1.4 boards |
| Hit/miss call correct | 87% |

**Calibration care matters most.** Careful taps (under 1.5 px) give 92% correct hit/miss calls and a 0.74
board entry error; sloppy taps give 84% and 2.1 boards.

**Bugs the simulation found, now fixed:**
- noise gates rejected the ball at high fps;
- flying pins were counted as the ball (+2 mph bias);
- entry board was guessed from tracks ending too early, so it's now reported only for tracks of 56 ft or more.

**Weak spots:**
- breakpoints are missed on 31% of hooks, and a false breakpoint is reported on 12% of straight balls;
- throws are simulated detections, not real alley video.

### Next steps
1. **Save the code:** push it to GitHub. This is urgent.
2. **CI:** add macOS builds, fix compile errors and produce a field-test `.ipa`, as for VIGBT.
3. **Real footage:** check against real alley video with known boards.
4. **Breakpoint detection:** improve it for small hooks.

---

## Shared ideas worth porting between the two

- **From VIGBT to bowling:**
  - the `check_version.sh` and CHANGELOG discipline;
  - the GitHub Actions iPhone build and field-test `.ipa`;
  - the screen-review page with approvals;
  - AAA contrast themes.
- **From bowling to VIGBT:**
  - a second phone for body tracking from the side;
  - a magnifier loupe for any sighted-helper taps;
  - spoken framing guidance ("I can't see your feet").
