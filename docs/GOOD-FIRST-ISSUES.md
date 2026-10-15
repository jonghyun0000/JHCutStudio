# Beginner contribution briefs

These are reviewable issue drafts for the public maintainer queue. They have not been posted as GitHub issues. Check the current code before claiming a task; avoid duplicate work. The interface is primarily Korean and the current release preparation is not a signed public release.

## 1. Verify shape-mask controls with VoiceOver

- Area: `App/ClipInspector.swift`, shape-mask controls and shared slider presentation.
- Observed on2026-10-15: the earlier native build lacked individual purpose labels. The shared slider has since received labels and units; verify the current shape controls and VoiceOver experience before filing any remaining defect.
- Work: inspect the native accessibility tree, add labels/value/help only for a remaining observed gap, preserve all visual geometry ranges and live-edit ownership.
- Acceptance: report before/after native accessibility observations for center X/Y, width/height, rotation and feather. A complete drag still creates one Undo step; locked/busy controls stay disabled. Do not change kernel math.

## 2. Translate the license-viewer navigation into English

- Area: `App/LicenseInformationView.swift` and the app menu entry.
- Work: introduce reviewed Korean/English user-facing strings using the project's chosen localization mechanism. Preserve legal document bytes and selectable text.
- Acceptance: both languages display all five tabs, missing-file guidance is understandable, and bundled legal files remain byte-identical to their sources. This task does not claim full English UI coverage.

## 3. Improve missing-model first-use instructions

- Area: caption-panel model guidance; documentation in `docs/INSTALL-0.7.md`.
- Work: show a clear next step without blocking ordinary import/edit/export. Keep source, MIT terms, approximate size and actual SHA visible before download consent.
- Acceptance: inspect a separate disposable app home with no model, cancel the install prompt, and complete a generated clip export. Do not delete a maintainer's installed model or make a network request without the explicit installation action.

## 4. Document a clean full-Xcode generated-fixture build

- Area: `CONTRIBUTING.md`, `.github/workflows/public-generated.yml` and supported compiler-selection helpers.
- Work: follow the existing public subset in a clean checkout without private recordings or a model; record actual toolchain selection and fix only observed portability gaps.
- Acceptance: full app build plus `domain compatibility productivity` passes with a terminal source-bound index; document OS, CPU, Xcode and SDK. No hard-coded home/external-disk paths, secrets or uploaded private logs. Local CLT support must remain intact.

## 5. Add a redistributable missing-media recovery walkthrough

- Area: installation/tutorial documentation and a tiny generated project fixture.
- Work: demonstrate moving one generated source, recognizing the missing-media message, relinking it, saving and reopening.
- Acceptance: source and recovered exports match the intended generated scene; keep fixtures relative and include their provenance/license. Never attach personal recordings or transcripts.

## 6. Check public documentation links and tool versions

- Area: English/Korean README, contribution, security, installation, architecture and roadmap documentation.
- Work: report and fix broken relative links, inconsistent versions or commands verified to fail. Separate historical audit files from current developer instructions.
- Acceptance: a new developer can reach each current entry document and understands which commands need full Xcode, private media, models or language packs. Do not replace evidence with guessed compatibility claims or rewrite retained historical reports.

## Filing these drafts

Before opening an issue, the maintainer checks that the problem still exists and adds the exact observed result. An unconfirmed accessibility or toolchain question should be labeled as investigation, not a proven defect. Use the existing issue template. New contributors should not need private maintainer artifacts to reproduce a public issue.
