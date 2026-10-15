# Contributing to JH CUT Studio

Thank you for helping make local video editing reliable and accessible. Bug reports, documentation improvements, reproducible examples and focused code changes are welcome in English or Korean.

JH CUT Studio is preparing its first supported public release. The current source is licensed under the [MIT license](LICENSE). Dependencies and bundled media retain their own terms in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). Include provenance and redistribution terms when proposing new code or assets. Local release-preparation changes still need publication to the public default branch; inspect the license in the checkout you are actually using.

## Set up a development checkout

Use a Mac with Apple Silicon for the current bundled Whisper runtime. The application targets macOS 14; Apple Translation functionality requires macOS 26. A deployment target is not proof of testing on every supported OS. See the [README](README.md) for the currently verified environment and limitations.

Install a compatible Swift toolchain, Apple SDK and Python 3. The `domain` suite also needs the full Xcode application for XCTest. The main build scripts use Command Line Tools by default and support `JHCUT_DEVELOPER_DIR` and `JHCUT_SDK` overrides. Some individual probe scripts still assume the Command Line Tools layout; report a toolchain error with the exact script and versions rather than modifying the system installation.

From the repository root:

```bash
bash Scripts/build.sh
bash Scripts/run.sh
```

The app is created at `Build/JH CUT Studio.app` with a local ad-hoc signature. This is a development build, not a notarized distribution. Building does not install a speech model. Model installation and translation language packs are separate, explicit steps described in the [installation guide](docs/INSTALL-0.7.md).

`Package.swift` describes the modules, but the direct compiler scripts are the currently documented build path. Do not replace them with an unverified SwiftPM command in a bug report or release instruction.

## Find the right area

| Directory | Responsibility |
| --- | --- |
| `App/` | SwiftUI/AppKit interface, editing commands and asynchronous job application |
| `Domain/` | Project values, rational media time, edit operations and validation |
| `MediaEngine/` | AVFoundation playback/export and shared Core Image composition |
| `Persistence/` | Atomic project writes, recovery, backup, collection and compatibility |
| `Services/` | Captions, local recognition, translation, media library and output QA |
| `Tests/` and `Validation/` | Regression probes, generated media and output inspection |
| `Resources/` | App metadata, icons, attributed media and Whisper runtime notices |

The [architecture notes](docs/ARCHITECTURE.md) include historical sections. Verify current behavior in code and the README before treating an older limitation as current.

## Verify the affected behavior

Start with a focused run that generates its own media and does not require the maintainer's private videos:

```bash
python3 -B Scripts/verification-run.py --suites domain compatibility productivity
```

`domain` exercises editing and persistence using XCTest, `compatibility` generates its fixtures, and `productivity` synthesizes audio in its default mode. Do not add `--transcribe` to the latter unless you intend to use an installed voice and speech model. These suites are a starting point, not a full release acceptance test.

The runner builds the current app/Core and creates a fresh `Artifacts/Runs/<run-id>/` directory. Inspect `verification-index.json`, including the build result, each suite's exit code and the final status. Zero reported assertions, a compiler failure, a nonzero exit code or an interrupted run is not a pass. The `--core-only` option omits the full app build and cannot prove app acceptance.

Select additional suites from `Scripts/verification-run.py` for the changed behavior. Pixel, storage, timing and UI assertions cover different properties; describe what you actually checked. Use meaningful regressions for defects, including cancellation, Undo/Redo and save/reopen where relevant. Do not relax a gate to make a failing change pass.

The full suite includes private media, model, language-pack and long-running dependencies. `real-accuracy`, `production-scenarios` and other real-video probes are not ready-to-run public CI jobs. Private filenames and time ranges describe a local evaluation dataset; arbitrary replacement footage does not reproduce the same evaluation. Generated-fixture tests do not establish real speech accuracy or native UI acceptance.

Never overwrite completed run directories or compile new probes into a recorded build. Preserve original media and existing projects; use a new output folder and disposable fixtures. Do not edit sources while a verifier is building or testing that source snapshot.

See [beginner contribution briefs](docs/GOOD-FIRST-ISSUES.md) for bounded tasks and acceptance criteria. These briefs are not claims that corresponding GitHub issues have already been opened.

## Send a useful issue or pull request

Use the issue templates and include the app version or commit, macOS version, chip, steps, expected result and actual result. For media failures, report codec, dimensions, frame rate and duration. Attach only media you can redistribute, preferably a small generated reproduction. Avoid uploading personal projects, private recordings, transcripts, absolute home paths, credentials or an entire `Artifacts` directory.

For a PR, explain the user-visible problem and the final behavior, list the relevant commands and results, and identify untested conditions. Keep changes focused. Preserve rational time, source references, document compatibility, backup/Undo behavior and cancellation ownership. Mention migrations or new third-party material explicitly.

AI-assisted changes have the same review and verification requirements as any other contribution. Read the complete diff, check provenance of copied content, and report which evidence was generated or inspected. Do not present generated captions as a human-verified reference.

Security reports use the separate [security policy](SECURITY.md). Avoid discussing exploit details in a public issue.

## 한국어 안내

버그 제보와 PR은 한국어로 작성해도 됩니다. 버전·macOS·칩·재현 단계·기대 결과·실제 결과를 함께 적어 주세요. 개인 영상이나 자막 대신 재배포 가능한 짧은 샘플을 사용해 주세요.

현재 소스에는 루트 MIT 라이선스와 별도 의존성·소재 고지가 포함됩니다. 공개 기본 브랜치 반영과 정식 배포 절차는 준비 중이므로 실제 받은 체크아웃의 LICENSE를 확인하세요. 위 빌드는 개발용 ad-hoc 서명이며 공증된 설치 파일이 아닙니다. 검사 기록의 실패·중단·미검증을 그대로 보고하고, 이전 검사 폴더나 사용자 원본을 덮어쓰지 마세요.
