# Roadmap

JH CUT Studio aims to make local Mac editing dependable for individual creators. A feature appearing in this roadmap is not a shipping claim. The [original 35-requirement inventory and advanced roadmap](docs/GOAL-REQUIREMENTS-2026-10-11.md) remain the authoritative coverage checklist; nothing below removes their unfinished requirements.

## First supported release

| Work | Acceptance |
|---|---|
| Playback and editing reliability | Resolve release-blocking failures, preserve project data, retain strict timing evidence with hardware/media conditions, and verify actual import/edit/save/reopen/recover/export flows. |
| Recognition and translation | Preserve truthful output/failure handling. Keep execution success separate from human CER/WER and translation review. Human-reviewed references are currently unavailable. |
| Masks and selected-color chroma key | Complete source-compatible implementation and preview/export/editor regression; inspect real UI and distinguish synthetic pixels from real hair/transparency/spill quality. |
| First use and languages | Verify model-missing, permission, missing-media, cancellation and output failures; complete English interface coverage alongside Korean. |
| Public source | Publish the reviewed license/notices/docs, finish source/history privacy checks, run hosted generated-fixture CI and open bounded contributor issues. |
| Installation | Bind source/version/checksum to an installer; Developer ID sign, notarize and staple; verify Gatekeeper, first install and update on another Mac. External signing setup and a second Mac are not yet available. |
| Downloads and examples | Ship a bilingual responsive site linked to verified GitHub Release assets, three redistributable samples, a 30–60-second real usage demo and a first-export tutorial. |
| Launch operations | Complete the 90-day growth plan and honest measurement; publish only to authorized destinations under their current rules. |

## Follow-on advanced work

Preserve these original directions in the detailed inventory: viewer/pen masks and tracking; foreground segmentation and automatic reframing; richer color curves/scopes; continuous speed control; compound/nested editing and further professional workflow needs. Their design, implementation and acceptance must be tracked separately. Adjustable shape masks do not satisfy free-form mask or tracking requirements; the existing simple green-screen path does not satisfy full selected-color/spill control.

## How priorities change

Data loss, repeated crashes, corrupted output and failures that prevent ordinary editing take priority over new effects. Reuse valid evidence; rerun the portions affected by an actual change. Do not weaken thresholds to close a milestone. Supported environments expand only after actual acceptance.

The growth milestones are 100, 1,000, 3,000 and 10,000 GitHub stars. They are measured outcomes, not promised release dates or substitutes for successful editing. Installation and first-export failures, useful bug fixes and external contributions also shape priorities.
