# JH CUT Studio 0.7

> Development source candidate: publication, successful builds and supported installation are separate gates. Check the actual source revision and Release assets. See [source/evaluation boundaries](docs/PUBLIC-PRIVATE-VALIDATION.md).

A local video editor for Mac, built for individual creators working with iPhone footage, short videos, interviews and promotional projects.

Edit a multitrack timeline, create Korean, Japanese and English subtitle workflows, and export without an account, subscription or product watermark. Speech recognition runs on your Mac with an optional Whisper model.

[한국어 안내](README.ko.md) · [Release readiness](docs/RELEASE-READINESS.md) · [Contributing](CONTRIBUTING.md)

**Development build: 0.7.0, build 8.** Signed public downloads are still being prepared. The interface is primarily Korean. An App Language menu now offers partial English coverage for the main editing flow and model-installation consent; advanced tools and some diagnostics remain Korean. This project does not claim feature or performance parity with a commercial editor.

## What you can do

- Arrange, split, trim and ripple-edit video, image, title and audio tracks. Use connected clips, snapping, multiselection, undo/redo and independent aspect-ratio versions.
- Preview and export through a shared compositor, with transform/opacity/volume keyframes, color adjustments, limited 3D LUT support, six transitions and six blend modes.
- Generate local subtitles, review language uncertainty, edit text and timing, import/export SRT, and keep original subtitles linked to separate translations. Models are installed with explicit consent.
- Use proxy previews while exporting from original media, reconnect missing files, collect project media, and recover saved projects from backups.
- Add library assets: 112 sound effects, 21 music tracks and 225 image assets. Twelve music tracks are 2–3 minutes long. See [media credits](Resources/Library/CREDITS.md) for sources and terms.
- Export SDR Rec.709 H.264 or HEVC MP4 and ProRes 422 MOV. Audio is AAC, including the current ProRes path.

Adjustable ellipse/rectangle masks now have core/editor regression evidence and a native rectangle drag, Undo/Redo and save/reopen check. Full native control/real-footage acceptance remains open. Tracking, foreground segmentation, automatic reframing, free-form curves/scopes, continuous speed curves, compound clips and other advanced tools remain on the [original requirements roadmap](docs/GOAL-REQUIREMENTS-2026-10-11.md).

## Build and run

The verified local toolchain is **Apple Silicon, Command Line Tools Swift 6.3.3, macOS SDK 26.5, Swift 5 language mode**. The recent test Mac runs macOS 27.2. The deployment target is macOS 14, but that is not a claim that all macOS 14+ configurations have passed acceptance. Intel and other Macs remain unverified; the bundled Whisper executable is arm64.

Install the required Apple developer tools, then run from the repository root:

```bash
bash Scripts/build.sh
bash Scripts/run.sh
```

The app is created at `Build/JH CUT Studio.app`. The build uses local ad-hoc signing. It is not a Developer ID signed or notarized release. Run `build.sh` again after changing source; `run.sh` builds only when the app is absent.

To select another installed toolchain without changing the system selection:

```bash
export JHCUT_DEVELOPER_DIR="/Library/Developer/CommandLineTools"
export JHCUT_SDK="$(DEVELOPER_DIR="$JHCUT_DEVELOPER_DIR" xcrun --sdk macosx --show-sdk-path)"
bash Scripts/build.sh
```

The full app needs a macOS 26+ SDK. The documented local CLT path is verified; some individual probes still assume CLT paths. The public generated-fixture CI lane selects full Xcode explicitly. SwiftPM is not the verified build route on the current development machine. See [installation details](docs/INSTALL-0.7.md).

## First edit

Follow the bilingual [first edit guide](docs/QUICKSTART.md).

1. Import supported media and add it to a timeline. Space toggles play/pause; arrow keys step frames; Cmd+B splits; Cmd+Z undoes; Cmd+S saves.
2. Open the subtitle panel if you want automatic captions. Ordinary editing and export remain available when the optional model is missing.
3. Review the model's source, license, size and SHA-256 before approving installation. The base multilingual model is approximately 148 MB and is downloaded separately.
4. Review generated words, timing and language flags. Translation additionally requires **macOS 26+ and installed Apple translation language packs**.
5. Add music/titles, save the `.jhcut` project, reopen it and export to a new file. Existing output files are not overwritten.

HDR input requires a supported explicit SDR conversion copy. Unsupported or unknown color profiles are not silently relabeled as SDR. See [format boundaries](README.ko.md#지원-형식과-데이터-보호).

## Privacy and licenses

Core editing, speech recognition and the application's translation path do not upload footage, audio or subtitle text to a cloud processing API. Model installation and explicitly invoked asset-collection scripts download files. Apple translation language packs are a separate system requirement.

Source code is available under the [MIT license](LICENSE). Dependencies and media retain their own licenses; see [third-party notices](THIRD_PARTY_NOTICES.md), [runtime notices](Resources/Whisper/THIRD-PARTY-NOTICES.txt), [media credits](Resources/Library/CREDITS.md) and [artwork provenance](Resources/Brand/README.md). Complete notices are included in new app builds and can be read from the app's **라이선스 및 소재 출처…** menu.

No external font binaries or FFmpeg executable are included in the inspected resources. Installed macOS fonts and frameworks are platform resources.

## Verification and known limits

One completed integration run built the full app and passed the following scopes (subsequent mask runs are recorded separately):

| Scope | Result |
|---|---|
| Playback observation graph protection | 34 checks, 0 failures |
| Actual editor command: subtitle failure, preservation and retry | 40 checks, 0 failures |
| Distribution diagnostics, backups and bundled legal files | 34 checks, 0 failures |
| Real iPhone recognition: 3 videos, 4 windows, 24 trials | 101 checks, 0 failures |

A separate current native-app check opened a generated project, paused at 7 seconds 6 frames, verified diagnostic-menu protection and exported a 15-second movie. Independent decoding found 450 frames, monotonic timestamps and 720,000 AAC samples per channel. These bounded checks do not establish all-device support, human listening quality or recognition accuracy.

**Human-reviewed references are 0/4**, so no real-speech CER/WER or translation meaning score is claimed. The latest full app playback run passes the original strict 600 ms generated 1080/4K fixture cases after an exact-unity audio-lane algorithm fix. Historical failures are preserved; changed-speed audio startup and physical speaker acceptance remain unverified. A supplemental audio-quality probe retains one raw preAAC buffer-duration failure under investigation. The earlier full regression was interrupted; its completed checks do not prove all current suites pass. Full mask/first-use acceptance, complete English coverage, official signing/notarization and installation on another Mac remain open.

Read [release readiness](docs/RELEASE-READINESS.md) for the current evidence, limits and next gates.

## Tests

The source-bound runner requires a standalone Git checkout with a valid HEAD (for example, a clone containing the reviewed revision). The source-review ZIP can be built with `Scripts/build.sh`, but has no Git history and cannot run this verification command directly. Check out the branch or commit you intend to verify; do not use an unrelated parent repository as its Git identity. Source availability on GitHub does not establish signed public-download acceptance.

For a fresh app build and generated-fixture checks:

```bash
python3 -B Scripts/verification-run.py --suites domain compatibility productivity
```

The domain lane additionally requires an installed Xcode XCTest framework; set `JHCUT_XCODE` to that Xcode's developer directory if needed. [Public CI](.github/workflows/public-generated.yml) separates these generated probes from private-footage and installed-model checks. On 2026-10-15 UTC (2026-10-16 KST), the [PR hosted run](https://github.com/jonghyun0000/JHCutStudio/actions/runs/38769007139) built the full app and passed 138 generated checks (55 domain, 46 compatibility, 37 productivity), with 10 Python runner tests passed separately. See [the dated scope and limits](docs/RELEASE-READINESS.md#hosted-ci-evidence); [Actions](https://github.com/jonghyun0000/JHCutStudio/actions/workflows/public-generated.yml) shows subsequent results. This result does not establish signed installation or recognition accuracy.

Each run writes a unique directory under `Artifacts/Runs/`, with a source-bound index, build, logs and output evidence. Check the terminal status, suite exit codes and file hashes. Do not reuse or overwrite old run directories. The current default list has **73 suites**; running a subset does not prove all 73 pass. Full local validation additionally needs the documented private dataset, an installed model and other feature-specific inputs.

To generate a reproducible 15-second example after building:

```bash
mkdir -p Artifacts
JHCUT_DEMO_OUTPUT="$(mktemp -d "$PWD/Artifacts/Demo-XXXXXX")"
Build/JHCutValidate "$JHCUT_DEMO_OUTPUT"
```

## Help build JH CUT

See [CONTRIBUTING](CONTRIBUTING.md) for changes and evidence expectations, [SECURITY](SECURITY.md) for vulnerability reporting, and the [architecture](docs/ARCHITECTURE.md) for code locations. Bug, feature and pull request templates are included. See the [changelog](CHANGELOG.md), [roadmap](ROADMAP.md) and [beginner contribution briefs](docs/GOOD-FIRST-ISSUES.md).

A tested release package, public download site, redistributable sample projects, a real usage demo and contributor issues are still being prepared. Stars are optional and will never be a download requirement. The long-term goal is 10,000 GitHub stars; downloads, successful first exports, returning users and useful contributions will also be tracked.

A [90-day growth plan](docs/LAUNCH-GROWTH-90-DAYS.md) and [KO/EN launch drafts](docs/LAUNCH-COPY.md) are prepared. A separate owner-private bilingual Site preview is deployed; a verified public download, actual usage recording and three public sample projects remain open.
