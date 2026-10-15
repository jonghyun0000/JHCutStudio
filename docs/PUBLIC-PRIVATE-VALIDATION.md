# Public and private validation lanes

The [public workflow](../.github/workflows/public-generated.yml) builds the full app and executes generated domain, compatibility and productivity probes. It does not need private recordings, an installed Whisper model, human reference transcripts or Apple translation packs. Hosted execution remains to be verified on the published checkout.

The default runner additionally registers feature-specific and private real-video suites. Those tests are kept as source to preserve acceptance requirements. References, camera videos, transcripts, provenance directories and result artifacts are deliberately absent from public source. Fixed filenames in private probes are a local evaluation contract; they are not public sample media and arbitrary substitute footage cannot reproduce the same accuracy or performance claim.

For a separately authorized private evaluation, prepare a reviewed dataset/reference manifest, set explicit local paths and use immutable copies. `Scripts/real-copies.sh` requires `JHCUT_IPHONE_DIR` instead of guessing a maintainer's disk. Never upload private media or entire run directories to an issue or CI artifact. To add a shareable regression, create a small generated or explicitly redistributable fixture and state what it proves.

The runner expects a genuine Git checkout and creates fresh evidence under Artifacts. This preparation directory has no Git history and has not been compiled or tested; do not run the verifier inside a nested artifact directory where it can accidentally discover an unrelated ancestor .git.

A development build, code existence, matching copied SHA, selected suite success and human/native/other-Mac acceptance are separate properties. The [35 requirements](GOAL-REQUIREMENTS-2026-10-11.md) and [original neutral specification](ORIGINAL-PRODUCT-SPEC-2026-10-11.txt) remain the coverage checklist.
