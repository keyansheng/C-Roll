# Gate

An original iPhone camera prototype inspired by [Log Cam's RAW-to-video approach](https://apps.apple.com/us/app/log-cam-open-gate-by-raw-cam/id6766185881). Built in SwiftUI, AVFoundation, Core Image, and Metal, with no third-party dependencies. The initial hardware target is **iPhone 16 Pro, iOS 18 or newer**.

For an independent critique, start with the [Gemini code review handoff](docs/GEMINI_REVIEW.md).

This is a working first implementation, not feature parity with Log Cam. The recording path requests **Bayer RAW photos**, develops their buffers, and encodes movies. The hardware recording monitor uses Apple's standard video feed when available to avoid a second RAW render. Version 0.1.2 uses the earlier sensor settings and two-frame bound, and defers the video-preview connection until idle RAW captures finish at take start. User-reported throughput on iPhone 16 Pro is approximately **25 fps at full HD and 22 fps at 4K**; the 30 fps target is not yet achieved. The simulator generates clearly labelled synthetic frames.

## Run on your iPhone

1. Open `Gate.xcodeproj` in Xcode 16 or later (built here using Xcode 27).
2. Select the **Gate** target → **Signing & Capabilities** → your development team. Change the bundle identifier if needed.
3. Connect your iPhone 16 Pro, select it as the run destination, and enable Developer Mode if Xcode asks.
4. Run the **Gate** scheme and allow camera access.
5. Start with **HD, HEVC, 12 fps**, then try 24 and 30 fps while watching the measured frame rate. Try 4K after checking HD stability.

If Xcode reports a missing Metal Toolchain, install its official component with `xcodebuild -downloadComponent MetalToolchain`. The color kernels are compiled during the build rather than compiled from legacy shader strings at launch.

Clips and capture metadata are stored in **Files → On My iPhone → Gate → Clips**. The in-app library plays and shares finalized movies. No account, analytics, network service, or Photos-library access is required.

## Implemented

| Area | Behavior |
| --- | --- |
| Capture | Physical rear wide camera at 1×, Bayer RAW only; Apple ProRAW disabled |
| Cadence | 12 / 24 / 25 / 30 fps targets; actual achieved rate and skipped work displayed |
| Framing | Full 4:3 sensor framing or center-cropped 16:9, fixed portrait orientation |
| Resolution | 1920, 3840, or 4032 pixel long edge; 4032 open gate outputs 3024 × 4032 in portrait |
| Recording | HEVC with adjustable target bitrate, or ProRes 422, subject to runtime encoder support |
| Color | Linear Rec.709 primaries → custom Gate Log or Rec.709 display encoding |
| Exposure | Auto with EV compensation, or manual ISO and shutter within hardware limits |
| White balance | Manual Kelvin, applied during RAW development |
| Focus | Continuous AF before a take or manual lens position; locked during recording |
| Monitor | Developed RAW while idle; standard system video preview during hardware recording; thirds grid; RAW gamma/zebra/false-color assists before a take |
| Development | Default tone curve, sharpening, local contrast, and detail disabled; optional noise reduction and lens correction |
| Library | Movie review and share, metadata share, Files access |
| Grading | Included 33³ `.cube` conversion LUT, exportable from recording settings |
| Lifecycle | Bounded capture/render work; drains in-flight frames before finalization; handles interruptions, camera errors, backgrounding, encoder failure, critical heat, and missing frames |

The current movie pipeline supplies **8-bit BGRA** to both codecs. A ProRes container does not recover precision discarded by that input. This build records **silent video**. It does not yet implement 10-bit HEVC, HEVC 4:4:4, imported LUTs, landscape capture, lens switching, audio, external-drive capture, anamorphic desqueeze, stabilization controls, or gyro export.

## Pipeline

```
Physical wide camera
  → AVCapturePhotoOutput (Bayer RAW, speed priority, no processed companion)
  → retained AVCapturePhoto.pixelBuffer + metadata
  → CIRAWFilter (linear development, explicit processing settings)
  → framing and scaling
  → Gate Log / Rec.709 → AVAssetWriter → MOV + JSON

Idle only: developed RAW → monitor gamma / exposure assist → camera screen
Recording: same capture session → AVCaptureVideoPreviewLayer → camera screen
```

`CameraController` owns capture state on a serial capture queue. `RawProcessor` and `MovieRecorder` run on a separate serial processing queue. Two bounded slots cover both AVFoundation callbacks and downstream GPU/encoder work. RAW monitoring runs at a six-fps target while idle to reduce heat.

Hardware recording can skip the second RAW render used to create a monitor `CGImage`. An `AVCaptureVideoPreviewLayer` displays Apple's processed camera feed while the RAW branch only develops and encodes the movie. In version 0.1.2, the layer starts disconnected, so launch uses the earlier RAW-only camera setup. Starting a take pauses new idle requests, waits for pending RAW captures to finish, then explicitly connects the layer within a session transaction on the capture queue. SwiftUI only hosts and sizes the layer; it cannot attach, detach, or rotate capture connections. During a take with a native preview, the monitor is labelled **SYSTEM PREVIEW**, and RAW gamma/zebra/false-color controls are disabled. If the preview connection cannot be added, recording falls back to RAW monitoring. Simulator recording keeps its synthetic preview.

Version 0.1.2 leaves sensor frame durations under AVFoundation control, reverting the video-cadence override introduced in 0.1.1. Recording-clock publications remain limited to four per second, and monitor-only control changes do not reapply device exposure and white-balance settings. Capture errors include the failing stage, error domain/code, and underlying error. Retry rebuilds a failed session after outstanding work drains. If the optional preview connection was present when capture failed, Retry disables that connection for the session and restores RAW-only monitoring.

Every photo has fresh capture settings and a retained delegate. The photo is held until rendering finishes because its pixel buffer is an inner pointer. A slot is released only after both capture completion and processing complete. Encoder back pressure drops work instead of growing a queue.

Movie timestamps come from **the sensor's photo timestamps**, relative to the first accepted frame. Slow capture produces timestamp gaps rather than sped-up playback. This yields variable cadence when the device cannot sustain the requested rate. Achieved average rate and output pixel dimensions are recorded in each JSON sidecar. Its `performance` section records mean RAW callback latency, processing-queue wait, and RAW render/encoder-append time for successfully written frames, plus skipped capture/encoder opportunities. These timings help distinguish camera delivery from application processing; append time does not measure the encoder's asynchronous completion time.

## Gate Log

Gate Log is a custom transfer curve, not Apple Log, S-Log3, or a camera matching profile. For each nonnegative, scene-linear RGB channel `x` in Rec.709 primaries:

```
encoded = log2(1 + 15 * x) / 4
linear  = (2^(4 * encoded) - 1) / 15
```

Black maps to 0; linear 1 maps to 1. Values beyond that are clipped by the current 8-bit output, so this is not a calibrated extended-highlight format. No sensor dynamic-range gain is claimed. The `.cube` applies the inverse curve followed by the Rec.709 OETF; use it in a grading timeline whose input is interpreted as the encoded values in Rec.709 primaries, with no extra automatic input transform. Regenerate it with `python3 Scripts/generate_lut.py`.

Monitor assists never enter the movie path. While idle, zebras and false color evaluate the RAW-derived Rec.709 display signal regardless of whether gamma assist is enabled. During hardware recording they are disabled and the monitor shows the system camera feed. Thresholds are documented in the app. Custom Gate Log has no standardized QuickTime transfer-function tag; the movie description and JSON explicitly identify its curve.

Apple documents Bayer RAW as minimally processed sensor data, while Apple ProRAW incorporates computational photography. This implementation follows [Apple's RAW capture guide](https://developer.apple.com/documentation/avfoundation/capturing-photos-in-raw-and-apple-proraw-formats) and the [linear development settings shown in WWDC21](https://developer.apple.com/videos/play/wwdc2021/10160/). It uses Apple's RAW decoder and color calibration; a completely independent sensor decoder would be a separate project.

## Verification

Core tests:

```sh
swift test
```

Simulator build and GPU/movie integration tests (use an installed simulator destination):

```sh
xcodebuild -project Gate.xcodeproj -scheme Gate \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath build CODE_SIGNING_ALLOWED=NO build

xcodebuild -project Gate.xcodeproj -scheme Gate \
  -destination 'platform=iOS Simulator,name=Gate iPhone 16 Pro' \
  -derivedDataPath build CODE_SIGNING_ALLOWED=NO test
```

Core tests cover curve round trips, duplicate/out-of-order timestamps, preserving real-time gaps, and slot pressure. Integration tests render the GPU curve, verify crop dimensions, encode and read back both codec formats, inspect movie timestamps and sidecars, and reject empty takes.

Version 0.1.0 verification: simulator build, unsigned physical-iPhone release build, three core tests, and five simulator integration tests passed. The integration checks covered consecutive takes and background finalization. One additional ProRes test was explicitly skipped because the simulator lacked the encoder.

Version 0.1.1 verification: five core tests pass, including hardware-preview routing through recording/draining states and performance aggregation. The physical-iPhone release archive builds, and the integration-test target is compiled without booting a simulator. This version has not yet been benchmarked on a physical phone. When retesting, compare measured recording FPS in HD, 3840, and 4032 open gate, then share each clip's JSON if the rate remains low.

Version 0.1.2 verification: six core tests pass, including nested camera-error reporting. The release archive and integration-test target build without booting a simulator. The user subsequently confirmed recording on iPhone 16 Pro, reporting approximately 25 fps at full HD and 22 fps at 4K. These are user-reported measurements; the resulting clips and timing metadata have not been independently inspected. Further profiling is needed to sustain 30 fps.

The lifecycle integration run completed with `TEST SUCCEEDED`. A subsequent run adding decoded HEVC color-value assertions reported all test suites passing, but Xcode stalled while finalizing the result bundle; that runner was interrupted after preserving its console log. The decoded color assertions themselves passed.

Before relying on the hardware capture path:

- Check that the phone reports **BAYER RAW**, and that manual ISO, shutter, Kelvin, and focus change the developed picture.
- Record a clock or moving subject for ten seconds at each cadence. Compare clip duration with elapsed wall time and inspect the JSON average frame rate.
- Try HD and 4K in daylight and low light, plus a longer take to measure heat and dropped work.
- Check bright patches, color, framing, and orientation against a single Bayer RAW reference. Compare the monitor to the movie after applying the Gate Log conversion LUT.
- Verify interruption/background recovery, denied camera permission, limited disk space, and sharing a finalized file.

## Source layout

- `Gate/Capture/CameraController.swift`: permissions, RAW session, scheduling, controls, take lifecycle.
- `Gate/Capture/RawProcessor.swift`: RAW development, color transforms, framing, exposure assists.
- `Gate/Capture/GateKernels.metal`: Metal color curves and monitor-assist shaders.
- `Gate/Capture/MovieRecorder.swift`: bounded movie buffers, sensor timing, metadata, finalization.
- `Gate/Core/CaptureMath.swift`: platform-independent curve, timeline, and capture budget.
- `Gate/Views/CameraView.swift`: original camera interface, settings, clip library.
- `Gate/Views/SystemCameraPreview.swift`: native recording preview with a persistent session connection.
- `GateTests/`: GPU and movie integration tests.
- `Tests/GateCoreTests/`: portable timing/math tests.

The app has its own name and interface and does not include Log Cam's assets or source code.
