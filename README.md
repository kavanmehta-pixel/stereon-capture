# Stereon Capture

In-house AR capture app for the Stereon pipeline. Measures a freight item's
envelope, and exports a GLB that drops straight into the Item Library
(`sourceType: scan`).

Deliberately NOT a Polycam clone: no textures, no photogrammetry, no cloud.
Rough shape + honest metric dims + GLB out. That's the whole job.

## Two capture modes (picked automatically)

| Mode | Devices | What you get |
|---|---|---|
| **LiDAR mesh** | iPhone/iPad **Pro** (12 Pro or later) | Real reconstructed geometry, cropped to the box. Dims measured from the mesh. |
| **Box fit** | Any ARKit iPhone (incl. iPhone 16 non-Pro) | You fit a box to the item; the box IS the measurement. Envelope only, no shape. |

Both modes export the **same coordinate frame** — metres, floor at y=0,
footprint centred — so the Item Library and load planner treat them
identically. The load planner already runs AABB collision over primitive
proxies, so a box-fit envelope is directly usable.

The app shows which mode is active as a badge under the status pill.

## Requirements

- Any ARKit iPhone (iOS 17+). LiDAR unlocks mesh mode but is not required.
- Xcode on the Mac.

## Build & run

1. `xcodegen generate` in this directory (only needed after editing
   `project.yml`).
2. Open `StereonCapture.xcodeproj` → select the **StereonCapture** target →
   **Signing & Capabilities** → tick *Automatically manage signing* → pick your
   Team (a free Apple ID / "Personal Team" works).
   - If *"Failed to register bundle identifier"*, change the Bundle Identifier
     to something globally unique, e.g. `com.kavanmehta.stereoncapture`.
3. Plug in the iPhone, choose it as the run destination, hit Run.
4. First run only: on the phone, Settings → General → VPN & Device Management →
   trust the developer certificate.

Free Apple IDs expire the build after 7 days — just re-run from Xcode.

Headless build check (no signing needed):

```sh
xcodebuild -project StereonCapture.xcodeproj -scheme StereonCapture \
  -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
```

## Scan workflow

A single AR screen: an ARKit coaching overlay establishes tracking, a pulsing
reticle marks the aim point, a frosted control panel sits at the bottom, and a
status pill up top tells you the next step.

1. Move the phone until tracking locks (the coaching overlay guides you).
2. Aim the reticle at the floor next to the item, tap **Set scan box**. A blue
   wireframe box drops onto the floor (light haptic confirms).
3. Fit the box with the **Width / Depth / Height** sliders, and **rotate** it
   with the yaw slider so it lines up with the item. Rotation matters: an
   unaligned box inflates the envelope. Live box size shows above the sliders.
   **Reposition** moves the box somewhere else.
4. *LiDAR mode only:* walk around the item slowly (2–3 m away) until it is
   fully meshed.
5. Tap **Capture** → result sheet with Width / Depth / Height tiles, footprint
   area, and (LiDAR mode) a PCA cross-check of the footprint. If the PCA
   numbers disagree badly with the box dims, the box wasn't aligned — redo it.
6. **Share GLB** → AirDrop to the Mac → attach in the Item Library.
   **New scan** clears everything and restarts a fresh session.

Clipping and export happen in **box-local space** (the box's yaw removed), so
the reported dims are a true oriented bounding box, not a world-axis one.

## Accuracy protocol (Phase-0)

Every scan that enters the library gets tape-verified: record scan dims vs tape
dims per axis in the Capture Lab variance tracker.

- **Box fit** is a manual envelope, not measured geometry — its accuracy is
  your box-fitting accuracy plus ARKit's visual-inertial scale drift. Tape-verify
  every item; treat as `estimate`-grade confidence until it is.
- **LiDAR mesh**: thin features (masts, poles) are the weak spot — expect
  underscan there; the body envelope should land within a few cm.

## Verification status

Verified by compiling and running the real source with `swiftc` on macOS, and
parsing the output with an independent GLB reader:

- `GLBWriter` — round-trips to exact millimetre dimensions.
- `BoxMesh` + `GLBWriter` — a 1.34 × 1.94 × 4.21 m box exports as exactly that,
  floor at y=0, footprint centred.
- `orientedFootprint` (PCA) — recovers a 30°-rotated rectangle exactly.
- Mesh clip/remap — keeps only fully-inside triangles with valid re-indexing.

The whole app compiles clean for arm64 iOS (`** BUILD SUCCEEDED **`, no
warnings). Not yet exercised on-device — the AR capture loop itself still needs
a real run.

## Not built (on purpose, for now)

- Photogrammetry / Object Capture — Apple's on-device Object Capture *also*
  requires LiDAR, and Mac-side photogrammetry loses metric scale without a
  reference object. Box fit is the better non-LiDAR answer.
- Direct upload to the Stereon server — needs item picker + auth UX;
  AirDrop covers Phase-0.
- Texturing, mesh cleanup, hole filling — cosmetic; dims don't need them.
