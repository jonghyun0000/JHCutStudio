# Release readiness

This is the public development source for **JH CUT Studio 0.7.0, build 8**. As of 2026-10-15 UTC (2026-10-16 KST), the reviewed source is published at main commit `8405f225534f6ede1e62c72d2a2bb3e9e1e5bce4`; its tree passed the hosted full-app/generated-fixture lane described below. This establishes that bounded compilation/regression result, not supported installation or full release acceptance. Maintainer-only media, transcripts, evaluation references and raw evidence remain outside this source tree.

## Implemented work and limits

Local timeline editing, linked captions, translations, proxy preview/original export, project backups, shape masks, selected-color chroma key, six blend modes, attributed assets and partial Korean/English UI are present in source. Local development runs include focused generated-fixture and real-media evidence. They do not establish all default suites, all effects, complete English/VoiceOver, human recognition accuracy or all supported environments.

The deployment target is macOS 14. Tested OS/CPU conditions must be stated for each actual verification; a deployment target is not support acceptance. The bundled Whisper executable uses a fixed `armv8.2-a+fp16` arm64 ISA target with `GGML_NATIVE=OFF` and no all-variant dispatch. It has been tested only on the current Mac; other CPUs, Macs and OS versions remain unverified. Translation needs macOS 26 and installed Apple language packs. There are no human-reviewed real-speech reference scores in this candidate.

## Hosted CI evidence

The [PR run](https://github.com/jonghyun0000/JHCutStudio/actions/runs/38769007139) completed successfully on 2026-10-15 UTC (2026-10-16 KST), using macOS 26.6.2/arm64, Xcode 26.5, Swift 6.3.2, macOS SDK 26.5 and Python 3.14.7. Its full-app build and generated probes passed: domain 55, compatibility 46, productivity 37, totaling **138 checks / 0 failures**. The Python runner regression passed **10 / 0 separately**. The workspace safety gate, 36 bundled legal files, absent speech model and empty-input/unchanged-source/terminal-index guard also passed; no separate workspace assertion count is claimed.

The actual PR checkout was GitHub test-merge commit `6e0cf13e54e44faa15fecd9ebfd17f254cd359a0`. Its Git tree `522325dd007ff1b1228cf30c0a4513432f810537` matches the published main revision above. The [automatic main run](https://github.com/jonghyun0000/JHCutStudio/actions/runs/38770467886) also reports success; [Actions](https://github.com/jonghyun0000/JHCutStudio/actions/workflows/public-generated.yml) is the current status source. Later source changes require their own results.

The workflow retained the job log and summary, but did not upload the full verification index, generated outputs or compiled binaries. No independent hosted per-file/binary rehash is claimed. These generated-only results do not verify private footage, human ASR/translation accuracy, complete UI/accessibility, signing/notarization or installation on another Mac.

## Gates still open

| Gate | Required work |
|---|---|
| Current public source | Preserve the reviewed transformations/exclusions and legal/runtime/library material. Hosted compilation passed for the dated tree above; future changes require fresh checks. Some private probes retain fixed logical filenames and require a separate consented dataset. |
| Binary provenance/privacy | Recipe3 uses a fixed FP16 ISA target and maps source/macro/debug prefixes to `/jhcut-build`; checked private compiler-prefix matches are zero in the runtime. Its exact bytes passed eight production-output-contract calls and four exact language/ordered-cue-text/rational-time comparisons against the retained baseline. The first generic ARMv8-A candidate passed eight contracts but only one exact pair; that failure is preserved. The checkpoint identity now includes `cpu-armv8.2-fp16-r3` while retaining postprocessing `pipeline9`, so the changed numerical runtime policy has its own cache identity; the hosted build does not independently establish full-app ASR cache behavior (this lane has no installed model). Neither result is human accuracy or another-Mac acceptance. Older reachable repository and preserved local verification history still contain old runtimes/path metadata; this snapshot has no `.git` and no history was rewritten. Full source/history/semantic privacy and redistribution review remains separate. See [runtime provenance](../Resources/Whisper/README.md). |
| Distribution debug metadata | The build recipe strips debug symbol entries only from the copied bundle main/Core before signing, retaining standalone binaries and local dSYMs. A separate copy-only diagnosis retained all 34 file-backed sections per binary and matching original/stripped/dSYM UUIDs, with checked private prefixes absent afterward. That diagnosis is preserved separately; hosted full-app compilation and the legal-file gate now passed, while final distribution-bundle privacy/behavior acceptance remains open. It is not a full privacy or behavior certification. |
| Public CI | The dated hosted lane above passed. Retain future verification indices and logs for independent inspection; current runs did not retain full build/output artifacts. This is a generated-only lane. |
| Product acceptance | Finish broader first-use/recovery/missing-media/accessibility/English and real-footage/physical audio checks. Retain unresolved raw preAAC tail evidence and distinguish generated playback gates from every changed-speed/device condition. |
| Language quality | Obtain consented human references and reviewed translations before claiming CER/WER or meaning scores. Local ASR completion is a different property. |
| Source identity | The reviewed source is published at the revision/tree above. Bind any future release package to its exact verified source revision. Dirty HEAD is only a base commit. |
| Official installation | Developer ID signing, notarization, stapling, Gatekeeper, final archive SHA/size, and actual install/update/edit/export on another Mac remain incomplete. |
| Downloads/materials | A private bilingual Site preparation exists. Public Release assets, a public download site, three verified downloadable sample projects, actual usage recording and tutorial remain to be connected and accepted. |
| Growth | The 90-day plan and bilingual launch drafts are plans. Stars, downloads, first exports and external contributions are measured outcomes, not promised results. |

## Source and evaluation boundaries

[The 35-requirement inventory](GOAL-REQUIREMENTS-2026-10-11.md) and [neutral original specification](ORIGINAL-PRODUCT-SPEC-2026-10-11.txt) retain original requirements, advanced follow-on work and initial exclusions. Neutralization changes personal examples only; it does not remove required capabilities.

The current default runner also lists private-media/model-dependent probes. This snapshot excludes `References/`, local handoffs, built apps, raw results and private footage. Use the generated-fixture lane first. `Scripts/real-copies.sh` requires an explicit `JHCUT_IPHONE_DIR` for separately authorized local inputs; it does not guess a maintainer's disk path. Public example projects must use the separately reviewed procedural sample ZIPs, not entire run directories.

See [installation](INSTALL-0.7.md), [contributing](../CONTRIBUTING.md), [roadmap](../ROADMAP.md), [90-day plan](LAUNCH-GROWTH-90-DAYS.md) and [launch drafts](LAUNCH-COPY.md). No public posting, message, source-history rewrite or upload is performed by preparing these files.
