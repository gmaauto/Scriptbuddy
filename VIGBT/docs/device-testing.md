# Testing VIGBT on an iPhone

VIGBT version 0.16.0. This is the first time the app runs on real hardware, so expect rough edges. Note
anything that fails or feels wrong; the results table at the end says what to send back.

## What you need

- **An iPhone with LiDAR.** That is an iPhone 12 Pro / Pro Max or any later **Pro** model, on iOS 17 or
  later. Phones without LiDAR stop at setup with "VIGBT needs an iPhone with a LiDAR scanner".
- **A Mac** with Xcode 16 or later. The first time, also run `brew install xcodegen`.
- **A free Apple ID** is enough to run the app on your own phone. Apps signed this way stop opening after
  7 days; run them again from Xcode to renew.
- **A USB cable**. Wi-Fi works after the first run.
- **Safety:** for the outdoor tests, use a driving range or an empty field, with a sighted helper.

## One-time setup

1. **Get the code:**
   ```
   git clone https://github.com/gmaauto/Scriptbuddy
   cd Scriptbuddy && git checkout claude/vigbt-specification-ie7w0j
   ```
2. **Your signing details** (these stay on your Mac and are never committed):
   ```
   cd VIGBT/App/Config
   cp Local.xcconfig.example Local.xcconfig
   ```
   Then edit `Local.xcconfig`:
   - `DEVELOPMENT_TEAM`: your 10-character team ID. In Xcode, go to **Settings → Accounts**, add your
     Apple ID, select it, and the team ID is shown for your "Personal Team". You can also find it at
     developer.apple.com → Account → Membership.
   - `PRODUCT_BUNDLE_IDENTIFIER`: anything unique, for example `com.yourname.vigbt`. Free accounts can't
     use `com.vigbt.app`.
3. **Generate and open the project:**
   ```
   cd .. && xcodegen && open VIGBT.xcodeproj
   ```
   Run `xcodegen` again whenever you pull new code.
4. **On the iPhone:**
   - Turn on **Settings → Privacy & Security → Developer Mode**. The phone restarts.
   - Plug the phone into the Mac and tap **Trust**.

## Running it

1. At the top of Xcode, choose the **VIGBT Device** scheme and your iPhone.
   - That scheme is a Release build, so ball tracking runs at full speed.
   - The plain **VIGBT** scheme is for the Simulator and SwiftUI previews. Its unoptimised build is about
     20 times slower at image processing.
2. Press **Run** (⌘R).
3. The first time, iOS may block the app as coming from an "untrusted developer". On the iPhone, go to
   **Settings → General → VPN & Device Management → your Apple ID → Trust**, then run it again.
4. Allow Camera, Microphone, Location and Motion when asked. VIGBT needs all four.
5. To see what the app logs, keep the phone connected and watch Xcode's console (**View → Debug Area**).

**Purchases:** the device scheme uses the local StoreKit test file. "VIGBT Pro" can be bought for free in
testing, and nothing is charged. Reset purchases in **Debug → StoreKit → Manage Transactions**.

## Test plan

Work through the stages in order. Each stage needs the one before it.

### Stage 1: indoors, no ball flight (about 15 minutes)

| # | Test | Pass when |
|---|---|---|
| 1.1 | Launch and complete **Welcome to VIGBT** ("I understand") | The safety notice is read aloud with VoiceOver on, and the setup screen follows |
| 1.2 | VoiceOver on: swipe through every screen you reach | Every control is spoken with a clear name, and nothing is announced only as "button" |
| 1.3 | Largest text (Settings → Accessibility → Larger Text, maximum) | No clipped or overlapping text, and rows stack vertically |
| 1.4 | **Set up at the tee**: phone on a tripod, about 3 m from a ball on the floor, pointed at the ball | LiDAR measures the distance (check it against a tape measure, within ±10 cm), and setup completes |
| 1.5 | **Sample ball colour** on a coloured ball, then a white one | The ball is found; for white, the app uses the white-ball detector |
| 1.6 | **Ready** screen: **Test Strike** | "Shot captured. Measuring…", then the replay or a "could not be measured" message, with no crash |
| 1.7 | Knock two clubs together, or clap sharply, about 1 m from the phone, out of the camera's view | Note whether it triggers. Detection is tuned for a club hitting a ball, so a clap may not trigger; knocking clubs is closer. Use whichever triggers for 1.11 and 1.12 (**Test Strike** always counts, so it can't test the swing check) |
| 1.8 | **Simulated shot** | The replay, readout and stats appear, and **Walk to ball** works |
| 1.9 | Swing check: stand fully in view at about 3 m and hold still for 2 seconds | The Ready screen says "Swing check: I can see you." |
| 1.10 | A full practice swing without a ball (with room to swing!) | "Practice swing." After 3 or more, you hear "Tempo steady" or "quicker/slower than your usual" |
| 1.11 | Stand still at address, fully in view, while someone makes the sound from 1.7 | "That strike was not your swing. Still ready." (the shot is not recorded) |
| 1.12 | Step out of view; make the sound again | It triggers normally (a shot is never discarded when VIGBT can't see you) |
| 1.13 | **Settings**: change themes and ball highlight | The colours change and stay readable |

### Stage 2: range or field, real shots (about 45 minutes, sighted helper)

Use 10 shots per club with a short iron, a mid iron and a driver if possible. For each shot, the helper
notes where the ball actually stopped.

| # | Test | Pass when |
|---|---|---|
| 2.1 | Real strike detection | Every real shot triggers within a second. Count any missed and any false triggers |
| 2.2 | Launch readout (ball speed, launch angle, direction) | It sounds plausible for the club. With a launch monitor available, note both readings |
| 2.3 | Neighbour's strike while you stand still and in view | Ignored ("not your swing") |
| 2.4 | Search-zone accuracy | The helper paces how far, and which way, the ball stopped from the predicted spot: along the line and sideways |
| 2.5 | **Walk to ball**: follow the beacon | It leads to the near end of the search zone; note the distance and direction left when you arrive |
| 2.6 | **Finding your ball**: guided search | Note how far into the search the ball is found, or not found |
| 2.7 | Ground scan range | The distance at which the scanner first locks onto the ball: white ball, then coloured ball |
| 2.8 | Wind entered vs not entered | Compare search-zone accuracy for a few shots each |
| 2.9 | **Sight the flag to correct the compass** | Later predictions are more on line |

### Stage 3: on the course (a few holes, sighted helper)

- Choose the course and hole, check that the club recommendation sounds right, and open the layout with **Return**.
- A shot into water, if one happens: the water warning comes first, and **Drop a ball** is offered instead of walking.
- Battery and heat: battery used per hole, and whether "thermal" warnings appear.

## What to send back

The easiest way: copy this table into a message, or attach Xcode console output for any crash.

| Item | Your result |
|---|---|
| iPhone model and iOS version | |
| Stage 1 tests that failed (number and what happened) | |
| LiDAR distance vs tape measure (1.4) | |
| Strikes detected / missed / false triggers (2.1) | |
| Swing-check "not your swing": correct / wrong (1.11, 2.3) | |
| For each shot: predicted vs actual stop (along, sideways) (2.4) | |
| Ground-scan lock distance, white / coloured ball (2.7) | |
| Anything confusing when listened to with VoiceOver | |
| Crashes (with Xcode console text) | |

These numbers replace the assumptions in SPEC §12. In particular, the search ellipse, the detection range
in §12.7 and §12.10, and the swing-check thresholds in §9.5 were all set from simulation, and field data
will retune them.
