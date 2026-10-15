# Changelog

## Unreleased — release preparation for 0.7.0, build 8

This development changelog does not announce a signed app release. The separate `samples-0.7.0-v2` prerelease contains project/media examples, not the application. Read [release readiness](docs/RELEASE-READINESS.md) for verified scopes and remaining gates.

### Reliability

- Finalize audio-lane pitch policy after packing: use Varispeed only for exact-unity mappings and retain Spectral for changed-speed lanes. The original strict startup fixture gate passes in the bounded current playback run; changed-speed startup and physical audio acceptance remain open.

- Treat missing, malformed or inconsistent Whisper SRT/JSON output as a failure even when the child process exits successfully. Preserve existing captions and editing history on failed recognition; allow a successful retry on the same editor.
- Keep raw process output and private paths out of public recognition errors. Save optional redacted diagnostic metadata only when restrictive file/directory permissions are confirmed on the actual filesystem.
- Refuse replacement of an active audio-diagnostic graph during playback. Disable the matching menu commands while the protected graph is active, and pause before clearing observation during bundled-media restoration.

### Editing

- Add an app-specific Korean/English language menu with partial first-use UI, menus, transport labels, save/open/import prompts and model consent. Language changes preserve the current native edit/Undo/paused state in the tested workflow. Advanced tools and some details remain Korean. Clarify that a speech model is needed for automatic captions; editing and export work without it.

- Add crop-relative ellipse and rectangle mask parameters with center, dimensions, rotation and inward feather. Preserve existing saved ellipse behavior and protect the first save with a retained pre-mask copy. Integration acceptance is tracked separately while editor/UI validation proceeds.
- Retain the existing multitrack, subtitle/translation, media library, proxy, recovery, transition, blend and generated-media features. This entry does not independently revalidate all existing behavior.

### Caption tools

- Extend the partial-English Auto Captions UI with 65 catalog entries per language: region-policy explanations, evaluation caveats, speaker/channel controls and batch fields. Local full-app compilation, 43 localization checks and a native EN→KO→EN input-state check passed; this changes presentation, not speech recognition accuracy. Public CI now also selects the existing localization suite.

### Open source and packaging

- Add the root MIT grant, complete pinned Whisper component notices, requested media credits and artwork provenance. Bundle the legal files and expose them through an offline app viewer.
- Publish the reviewed source and English/Korean entry documentation. The [main generated-fixture CI](https://github.com/jonghyun0000/JHCutStudio/actions/runs/38773524663) built the full app and passed 138 checks; Python 10/0 and workspace 16/0 passed separately. Current diagnostics retain the verification index and logs, not generated outputs or binaries.
- Connect the [public bilingual site](https://jhcut-studio.jonghyun04.chatgpt.site), three actual app screenshots and [three MIT starter projects](https://github.com/jonghyun0000/JHCutStudio/releases/tag/samples-0.7.0-v2) with manual captions/generated graphics/test chords. The sample-only prerelease is not an app installer; the install button stays disabled and the usage recording remains unfinished.
- Retain historical strict startup failures and the remaining raw preAAC buffer-tail finding, absent human speech references, incomplete English UI and unavailable signing/notary/other-Mac acceptance.

Earlier development reports are kept under `docs/`; their dates and results are historical evidence, not release tags. An app release will bind its exact source revision and package checksum separately from the already published sample-data tag.
