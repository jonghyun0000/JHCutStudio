# Changelog

## Unreleased — release preparation for 0.7.0, build 8

This is a working-tree change log. It does not announce a published tag or a downloadable signed release. Read [release readiness](docs/RELEASE-READINESS.md) for verified scopes and remaining gates.

### Reliability

- Finalize audio-lane pitch policy after packing: use Varispeed only for exact-unity mappings and retain Spectral for changed-speed lanes. The original strict startup fixture gate passes in the bounded current playback run; changed-speed startup and physical audio acceptance remain open.

- Treat missing, malformed or inconsistent Whisper SRT/JSON output as a failure even when the child process exits successfully. Preserve existing captions and editing history on failed recognition; allow a successful retry on the same editor.
- Keep raw process output and private paths out of public recognition errors. Save optional redacted diagnostic metadata only when restrictive file/directory permissions are confirmed on the actual filesystem.
- Refuse replacement of an active audio-diagnostic graph during playback. Disable the matching menu commands while the protected graph is active, and pause before clearing observation during bundled-media restoration.

### Editing

- Add an app-specific Korean/English language menu with partial first-use UI, menus, transport labels, save/open/import prompts and model consent. Language changes preserve the current native edit/Undo/paused state in the tested workflow. Advanced tools and some details remain Korean. Clarify that a speech model is needed for automatic captions; editing and export work without it.

- Add crop-relative ellipse and rectangle mask parameters with center, dimensions, rotation and inward feather. Preserve existing saved ellipse behavior and protect the first save with a retained pre-mask copy. Integration acceptance is tracked separately while editor/UI validation proceeds.
- Retain the existing multitrack, subtitle/translation, media library, proxy, recovery, transition, blend and generated-media features. This entry does not independently revalidate all existing behavior.

### Open source and packaging

- Add the root MIT grant, complete pinned Whisper component notices, requested media credits and artwork provenance. Bundle the legal files and expose them through an offline app viewer.
- Add English and Korean entry documentation and a generated-fixture GitHub Actions workflow. Hosted CI and final public publication are pending.
- Retain historical strict startup failures and the remaining raw preAAC buffer-tail finding, absent human speech references, incomplete English UI and unavailable signing/notary/other-Mac acceptance.

Earlier development reports are kept under `docs/`; their dates and results are historical evidence, not release tags. A source commit/tag and package checksum will be recorded with an actual release.
