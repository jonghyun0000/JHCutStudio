# Third-party notices

JH CUT Studio includes components and media that retain their own licenses.
The root source license does not replace the notices below.

- **Whisper runtime:** `Resources/Whisper/THIRD-PARTY-NOTICES.txt` contains the
  pinned whisper.cpp/ggml MIT grant and embedded miniaudio, stb_vorbis and YaRN
  notices. `LICENSE-whisper.cpp.txt` also preserves the upstream top-level grant.
- **Optional Whisper base model:** installed separately, not bundled in the app.
  `Resources/Whisper/LICENSE-whisper-model.txt` preserves OpenAI's MIT grant.
  `runtime-and-model.json` records the model URL, byte count and SHA-256.
- **Media library:** `Resources/Library/CREDITS.md`, `manifest.json` and
  `Licenses/` preserve CC0 terms, source/author records, requested credits and
  installed/source checksums for all 358 library items.
- **Apple platform resources:** macOS frameworks and fonts are supplied by the
  operating system. No external font file or FFmpeg executable is included in
  the inspected Resources tree. This statement must be checked against the final
  release package if packaging changes.

The app icon was generated with an AI image tool; its provenance is recorded in
`Resources/Brand/generation.json`. See `Resources/Brand/README.md` for the grant
and brand-use scope of the original graphics distributed with this project.
