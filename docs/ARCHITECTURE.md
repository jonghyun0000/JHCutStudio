# Architecture decisions — 0.2

## One timeline, one compositor

`Project → Sequence → Track → Clip` is the editable document. `MediaAsset` represents the unchanged source; a `Clip` is a placement with independent source and timeline times. `Title` is a separate text description. The document has one active sequence, optional independent derived sequences, and main video/overlay/title/audio tracks. Optional 0.2 fields retain decoding compatibility with G0 documents: title styles, rational constant rates, visual adjustments, fades, transform/volume keyframes and asset provenance. Caption cues are independent title clips. Transition/Marker/brand-kit/AI models are not advertised as implemented capabilities.

Every accepted command produces a validated candidate document. An invalid command leaves both project and history untouched. History stores at most100 snapshots; immutable value semantics allow copy-on-write media metadata. A drag commits only at mouse-up. A locked track rejects content mutation; unlocking is a separate accepted state change. Main video cannot overlap; overlays, text and audio mix independently.

`MediaTime` stores a normalized signed integer numerator and positive timescale. Checked full-width integer arithmetic and cross-products avoid accumulated floating seconds. User-edited timeline numeric input is snapped to30fps; unchanged displayed fields preserve the original rational value, including SRT milliseconds and speed-retimed subframes. Source time input retains its distinct precision. Original time is `sourceStart + rate × (timelineTime - clip.start)`. Intervals are half-open. FrameRate retains rational numerator/denominator; 30000/1001 and24000/1001 are serialization/time-math test cases, **not enabled render profiles**.

General deletion leaves gaps. Ripple deletion shifts only items in the selected track starting at/after the removed end. Other tracks do not move. Changing constant speed preserves the source interval, remaps local keyframe/fade times and shifts later clips on the same track. Anchors and linked audio/captions are absent; other tracks stay independent. Batch commands validate the final candidate so adjacent group moves remain atomic. Animated/faded handle trims and interior ease/fade splits are explicitly rejected where a faithful split cannot be represented.

`TimelineRenderer.build` validates and re-inspects used source files; source kind/duration/color changes cannot silently reuse stale metadata. It creates AVMutableComposition media tracks, one AVMutableVideoComposition with custom `TimelineCompositor`, and AVMutableAudioMix. All image/title layers are in compositor pixels. A small16×16 black carrier emits actual timeline-rate samples through the full duration so still-only sequences and gaps retain their requested frame count. Composition tracks are pooled and the carrier is cached rather than re-encoded; see **Composition track packing** below.

`RenderPlan.makePlayerItem()` drives a single AVPlayer. `AVAssetImageGenerator` uses the same composition and videoComposition for preview evidence. `ExportJob` uses AVAssetReaderVideoCompositionOutput/AudioMixOutput and an explicit H.264/AAC AVAssetWriter; no independent FFmpeg renderer exists. Decoding the completed output proves the export path, not merely the app UI.

## Composition track packing and carrier reuse

Two allocations used to scale with the edit rather than with the timeline's shape, so every property change paid for the whole sequence.

`BlackCarrier` encodes one short all-keyframe 16×16 clip per frame rate — 300 frames, about 30KB — and caches it at `Application Support/JHCutStudio/Carrier/carrier-v<version>-<fps>fps-<frames>f.mp4`. A build repeats that clip to cover the timeline instead of encoding a full-length movie. Every frame is a keyframe, so the trailing partial repeat cuts exactly on a frame boundary. Publication uses an atomic rename, so a second process never observes a partial file and a lost race simply adopts the equivalent existing entry. A truncated entry is discarded and re-encoded once. The cached asset is retained alongside its track because `AVAssetTrack.asset` is a weak reference. `RenderPlan` no longer owns or deletes the carrier file.

`CompositionTrackPool` packs clips onto the fewest lanes whose segments stay disjoint. A lane is reused only when it is already free at the clip's start, which makes every lane's inserts strictly ascending; that ordering is what keeps `scaleTimeRange` from shifting a segment written earlier. The composition track count therefore follows the timeline's maximum overlap depth, not its clip count: 300 sequential clips use two video tracks (carrier plus one lane) instead of 301. Only the main video track forbids overlap, so genuinely overlapping overlay, title or audio clips still take separate lanes. A still image needs no composition track at all.

Audio lanes carry one `AVMutableAudioMixInputParameters` each, as `AVAudioMix` requires. Clips sharing a lane write into the same object; `ClipEnvelopes` writes every ramp in absolute composition time and the lane's segments never overlap, so the merge is exact. A flat-volume clip is pinned with a constant ramp across its own range rather than a bare `setVolume(_:at:)` point, because consecutive volume points interpolate: a point would slide the clip's level toward whatever the next clip on the lane asks for. That interpolation was harmless while every clip owned a track and is a correctness requirement once they share one.

An audio lane is reserved only after the clip is known to contribute audio, so a clip trimmed outside its source no longer leaves an empty track behind.

## Live control preview

A dragged control substitutes one clip into the rendered project without touching the document. `EditorModel.previewProject` is the committed project with the in-progress clip swapped in; `project` stays `history.project`, so saving, dirty detection and validation never see an uncommitted value. `beginLiveEdit`/`updateLiveEdit`/`commitLiveEdit` bracket the gesture and commit exactly one history entry at mouse-up, so a drag costs one undo step rather than one per tick. A rejected value leaves the document unchanged and reverts the preview.

The render loop is self-pacing rather than timer-debounced: a value arriving mid-render only sets a pending flag, and the loop repeats once with the latest value. It coalesces to whatever rate the renderer sustains. A gesture is retired by bumping a generation counter, which the loop checks instead of its own task handle, so a new gesture starting while the previous loop unwinds cannot be clobbered by it. A committed `rebuild()` retires any live gesture first and is always authoritative.

Live rendering deliberately does not set `isBuilding` and does not clear the player item, so dragging never blanks the preview or raises the compositing spinner; the previous frame stays on screen until the replacement is ready. Number fields still commit on Return or the apply button, because a partially typed value must not be applied. `RecoveryStore` is injectable into `EditorModel` so headless probes never write to the user's recovery slot.

## Color and orientation

G0 outputs SDR Rec.709 only. Import inspects video codec, track dimensions, preferredTransform, audio presence and color metadata. Missing or unsupported transfer information blocks placement/rendering. No HDR→SDR conversion is claimed. Preferred transforms are converted from AVFoundation top-left coordinates to Core Image bottom-left coordinates and normalized. Fit/fill, position, scale, rotation, alpha and PNG transparency use the same compositor in preview/export. Title coordinates are normalized and y=0 is the bottom of the canvas.

Core Image performs color-managed conversion; the compositor's pixel buffer is tagged with the AVFoundation-derived Rec.709 output space. H.264 encoding includes primaries/transfer/matrix metadata. Reference-frame comparisons normalize both images through sRGB contexts before computing differences.

## Storage, export and tasks

Project JSON has schemaVersion1, IDs, size, rational rate, color space, references and edits. Relative paths are resolved from the source document; bookmarks and absolute paths are fallbacks. Save As rebases persisted references without allowing a same-name file at the destination to become the source. The live editor retains the original reference base while its undo history is active.

Saving writes the previous valid document to a backup and replaces the primary atomically. A corrupt primary cannot overwrite the good backup. A separate 1.2-second-debounced RecoveryStore retains active/previous snapshots and per-project deferred archives. The startup/project UI explicitly chooses which valid snapshot to recover. Saving or discarding clears only the current project’s recoveries. Originals are never deleted or copied during save/export.

Export uses a UUID-named temporary directory adjacent to the destination and moves only a successfully finalized file. Cancellation propagates to reader/writer and removes that job's partial output and writer sidecars. Destination existence is checked and overwrite refused. Disk preflight accounts for ExFAT volumes that return zero for the optional important-usage capacity API by reading actual filesystem free space. Physical full-disk exhaustion was not induced.

Editor UI allows one import batch and one export at a time; document replacement is blocked during either. Export pauses playback and locks edit actions. Heavy processing happens off the main thread where required; preview builds are generation-guarded and cancelled when obsolete. Source video is streamed; full video assets are never loaded into RAM. Timeline thumbnails are small, limited to40 used assets, and computed at most two at a time. Waveforms are streamed from 24kHz mono PCM into bounded peak bins, cached with source path/size/modification time/version. The engine cache is capped at16MB; UI waveform and thumbnail queues each have at most two jobs. No persistent disk analysis cache or proxy workflow is claimed.

## Toolchain audit

Workspace had unrelated projects but no Swift video editor, root Git repository, or applicable AGENTS.md. Existing folders were not modified. No repository was force-initialized. New code lives entirely in JHCutStudio.

Default `git`, `swift` and Xcode developer commands reported: `You have not agreed to the Xcode license agreements…`. `DEVELOPER_DIR=/Library/Developer/CommandLineTools swift --version` succeeded. SwiftPM exposed a separate stale private PackageDescription interface and runtime mismatch (`extra argument swiftLanguageModes`; using legacy spelling then gave undefined PackageDescription symbols). System developer files were left intact. Direct compiler scripts are the verified local build method; Package.swift remains for a coherent Swift6 installation.

Minimum target14.0 was checked by compilation. Running macOS14/Intel and public signed distribution remain separate verification tasks.

## Shared 0.2 effects and library

Core Text rasterizes style presets, editor thumbnails and exported title pixels through the same path. Styled titles support alignment anchors, stroke then fill, background padding/alpha, shadow, line spacing and explicit line-limit ellipsis; nil style keeps the G0 rendering path. Crop occurs before fit/fill, then exposure/contrast/saturation and evaluated transforms/alpha fades.

Composition ranges use exact rational constant-speed mapping. AVAudioMix uses spectral pitch preservation and piecewise linear approximations of combined volume-keyframe/fade envelopes (maximum scalar-volume error0.0005). A final encoded PCM probe checks440Hz preservation at2× and fade/volume shape. UI waveforms map sourceStart and source duration at the current playback rate; they are not synthetic decorative waves.

AssetLibrary reads a bundled JSON manifest and resolves only contained files. Source/author/license/original and converted-file hashes remain available. Collection is an explicit build-time script, not an app network dependency. Relinking library media retains attribution only when the replacement SHA-256 matches; a different file loses the old provenance. Original media and title presets are identified separately from third-party CC0 downloads.


## 0.3 추가 구조

- `ClipTemporalEditor`: 소스/타임라인 유리수 매핑, 출력 프레임 기반 애니메이션·페이드 보존 구간 편집. `CaptionEditing`과 `SubtitleTextDecoder`: 자막 편집·검증된 문자 인코딩.
- `ProjectCollector`: 원본 복사·SHA-256 중복 제거·취소 정리·독점 확정. `DocumentCompatibility`: 알 수 없는 편집 필드의 조용한 손실 방지.
- `MediaImporter.loadImage`: ImageIO 방향·미러·색 정보 점검. `ProxyCache`: 원본 파일 식별·PTS 보존·용량 제한·현재 재생 파일 보호. `RenderPlan.usesProxyMedia`는 출력기의 원본 사용 검증에 연결된다.
- `AudioAnalysis`: 네이티브 채널 PCM 분석. `LocalTranscription`: 승인 기반 모델 설치, CPU/Accelerate whisper.cpp 프로세스, 선택 범위 추출·취소·SRT 시간 복원. 원본 수정이나 음성 업로드 없음.
- `EditorProductivity` / `ProductivityPanel`: 분석 결과의 클립·프로젝트 일치 검사, 배속 시간 매핑, 프록시 원본 변경 검사, 독립 출력 계획, 작업 취소와 UI 연결.

과거 섹션의0.2 제약 목록은 당시 기록이다. 현재 지원/제한은 `UPGRADE-0.3.md`를 우선한다.
