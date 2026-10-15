# Bundled local speech runtime

The app bundles an arm64 whisper.cpp executable, its pinned source/model metadata and complete third-party notices. The speech model is **not bundled**. Ordinary editing and export work without the model; model installation remains a separate explicit user choice.

`runtime-and-model.json` records the source archive, actual executable digest, compiler and CPU policy. `unsignedBinarySHA256` is a compatibility field name: it describes the executable **before app-bundle signing**, including its compiler/linker ad-hoc signature. The app build signs its bundled copy again, so that copy has a separate byte digest.

Recipe version 3 uses a fixed `armv8.2-a+fp16` ISA target with `GGML_NATIVE=OFF` and `GGML_CPU_ALL_VARIANTS=OFF`, applied globally to C/C++ and to the ggml CPU backend. CPU and Apple Accelerate remain enabled; Metal and curl remain disabled. `cpuTarget` records the actual target flags rather than claiming host-native tuning. This ISA target has been tested only on the current Mac. Other Macs and OS versions remain unverified; arm64 architecture and the macOS 14 deployment target do not establish compatibility.

A first generic `armv8-a` candidate passed all eight actual output-contract calls but matched only one of four retained speech windows exactly against the native runtime. That failed equivalence result is preserved. Source and binary review identified a distinct FP16 arithmetic-path difference: disabling vector FP16 changes accumulation/reduction to FP32. The subsequent `armv8.2-a+fp16` candidate restored that path and passed eight of eight actual production output-contract calls and four of four exact language/text/rational-timing comparisons, without retries or checkpoint reuse. This is a bounded runtime regression comparison on the current Mac, not a human recognition-accuracy score, a guarantee for unseen recordings, or validation of another Mac. Deployment still requires fresh app integration and the remaining release gates.

## Rebuild from the pinned source

From the repository root on the verified Apple Silicon / Command Line Tools setup:

```bash
bash Scripts/build-whisper-runtime.sh
bash Scripts/build.sh
```

The optional runtime rebuild verifies the pinned archive SHA and source commit, extracts a clean owned source tree and builds with pinned CMake 4.1.3. It uses the cached archive/tools when present; otherwise it downloads those source/build dependencies. It never downloads a speech model.

Source file, macro and debug prefixes map to `/jhcut-build`. Build receipts and logs remain under `Build/whisper-work.*/`. The recipe retains a checksum for each archived source file and refuses a compiled executable containing the checked private build prefixes. This path check is not a universal privacy or license audit.

The recipe preserves the model specification and complete existing notices. It records the new executable size/digest and verifies the copied output. Building and `--help` alone do not prove speech-recognition accuracy or runtime compatibility. App integration, real recognition and error/cancellation regressions must be checked for a changed runtime.

For a separate review output:

```bash
mkdir -p Build
JHCUT_WHISPER_OUTPUT_DIR="$(mktemp -d "$PWD/Build/WhisperReview.XXXXXX")" \
  bash Scripts/build-whisper-runtime.sh
```

`JHCUT_BUILD_JOBS` defaults to 2. `JHCUT_CMAKE` can select an existing CMake 4.1.3 executable. `JHCUT_DEVELOPER_DIR` selects tools for this process; `xcrun` resolves clang for CLT or full Xcode. Set `JHCUT_SDK` to the matching installed SDK when it is not at the documented CLT SDK 26.5 path. The recorded rebuild and speech checks used CLT/SDK 26.5; resolving another installed toolchain is not proof of the same binary or acceptance.

Runtime publication copies five runtime/metadata/notice files after a successful build. This source-resource update is not a multi-file atomic transaction; keep project evidence and previous runtime bytes when changing a release candidate. It does not write user projects or source media.

Read `LICENSE-whisper.cpp.txt`, `LICENSE-whisper-model.txt` and `THIRD-PARTY-NOTICES.txt` for the original terms. Rebuilding does not replace or relicense those components.
