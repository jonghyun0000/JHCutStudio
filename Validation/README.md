# Media validation — G0 and 0.2

From the repository root:

```sh
./Scripts/build.sh
./Build/JHCutValidate "$PWD/Artifacts/G0"
```

The CLI creates its own media inside the selected output folder. Repeating the command replaces its named fixture files, project, report, and reference export. Use a dedicated folder. It never reads personal media, downloads content, or invokes FFmpeg.

The fixture sources are three 150-frame SDR Rec.709 H.264 videos at 540×960/30 fps, a PNG end card, a separate PNG with transparency, a 440 Hz PCM WAV at 48 kHz, and a one-second landscape source with 90° preferred-transform metadata. The three main videos have identical filenames in distinct Korean folders containing spaces.

The test imports sources, adds full five-second clips, trims each to four seconds with a 0.5-second source offset, exercises split/reorder/undo/redo, adds the end card/title/PNG/BGM, saves, reloads, builds the shared render plan, generates a first preview frame, and exports real 1080×1920/30 fps H.264/AAC MP4. Every output video and audio sample is decoded again.

`report.json` and `report.md` contain the exact machine, timing, memory, output format, sample counts, and pass/fail/not-run status. `proof/` contains full-size preview and decoded frames and side-by-side images at 1, 5, 9, and 13 seconds. The expected output is exactly 450 video frames and a 15-second video presentation range; container and audio sample durations are reported separately.

Preview/output comparison converts both images into sRGB and measures RGB absolute error. The limits are mean error < 0.035 and 99th-percentile error < 0.20 on a 0–1 scale, allowing H.264 and chroma subsampling loss. Scene colors, source frame number 045, Korean title and end-card OCR, distinct PNG color pixels, and audio RMS provide independent content checks. Review the comparison PNGs visually as well.

Cancellation, missing media, corrupt input, existing output preservation, invalid output paths and temporary read-only APFS output directories are exercised. The low-space test raises the required-capacity threshold to `Int64.max`; it queries real capacity but is explicitly a simulated threshold failure. It does not fill storage. Actual mid-write disk exhaustion is untested.

To inspect a separate MP4, including one exported through the GUI:

```sh
./Build/JHCutValidate --inspect "/absolute/path/to/output.mp4" "/absolute/path/to/proof-folder"
```

The optional proof folder receives representative decoded PNGs. This mode prints observed metadata, sample counts, audio RMS, and Korean OCR as JSON. It does not make a blanket pass claim about arbitrary inputs.

The CLI's first-frame and seek times measure `AVAssetImageGenerator` using the same composition/compositor as the player and exporter. They do not measure interactive AVPlayer latency or dropped frames. Peak RSS includes fixture creation, rendering, decoding and OCR. The separate native GUI smoke test is responsible for application quit/relaunch and interactive playback verification.

## 0.2 regression

```sh
bash Scripts/test-engine.sh Artifacts/EngineProbe-NewRun
Build/JHCutValidate --upgrade Artifacts/Upgrade-NewRun
```

EngineProbe checks16 advanced model/pixel/PCM/waveform behaviors and records the actual core dylib SHA-256. The upgrade CLI verifies the bundled154 files and24 title presets, creates a60-second portrait edit and600-second low-complexity landscape timeline, saves/reopens each, exports, decodes every sample, and compares selected shared-preview frames against encoded pixels. Library audio is real collected/generated media; scene videos are deterministic generated fixtures. No external service is called. The10-minute case is a bounded regression, not an interactive dropped-frame or broad camera-format benchmark.

Historical run at Artifacts/Upgrade used a separate unoptimized core, and its timings are labeled accordingly in docs/STATUS.md. Final release-core advanced probe lives at Artifacts/EngineUpgrade-Final. The CLI incorporates a sibling EngineUpgrade proof only if the recorded hash matches its current core, otherwise reports it not_run.
