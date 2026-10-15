# Product requirements and acceptance roadmap

This public inventory preserves all 35 original requirements. It is a coverage checklist, not a completion score. The [neutral original specification](ORIGINAL-PRODUCT-SPEC-2026-10-11.txt) retains the complete initial scope, constraints, advanced work and initial exclusions. Personal examples and maintainer-only evidence locations remain preserved locally.

| Requirement | Implementation entry points | Required acceptance evidence |
|---|---|---|
| 01 네이티브·오프라인 핵심, 워터마크 없음 | App/JHCutStudioApp.swift, Scripts/build.sh | 새 사용자·네트워크 차단 상태 편집/저장/출력 |
| 02 한국어 UI·패널·오류/빈 상태 | App/EditorView.swift, DesignSystem.swift | 작은 화면, 패널 접기/조절, 누락/모델 없음 실제 조작 |
| 03 단축키·한국어 조합·포커스 | App/JHCutStudioApp.swift, TimelineView.swift | Space/방향키/분할/Undo/저장/삭제 및 IME 비간섭 |
| 04 합리수 시간·명령 불변식 | Domain/MediaTime.swift, Editing.swift, TimelineRange.swift | 23.976/29.97, 음수/범위/잠금 거부, 직렬화 |
| 05 멀티트랙·연결·리플·다중 선택 | Domain/ConnectedEditing.swift, App/TimelineView.swift | 이동/트림/분할/덮어쓰기/삭제별 상태 및 출력 |
| 06 Undo/Redo·드래그 한 명령 | Domain/Editing.swift, HistoryMemory.swift | 분기·메모리 예산·현재/저장 상태 보존, GUI 드래그 |
| 07 미리보기·출력 동일한 렌더 계획 | MediaEngine/TimelineRenderer.swift, TimelineCompositor.swift | 변환/색/폰트/효과 시간별 preview/output 비교 |
| 08 재생/정지/탐색 응답 | App/EditorModel.swift, Tests/TimelineSessionProbe.swift | 같은 1초 창에서 실제 clock/frame, 반복 pause/seek |
| 09 출력 1개와 동시 편집 | MediaEngine/ExportJob.swift, App/EditorModel.swift | 격리 기준선과 동일 시나리오 비교·자원/지연 |
| 10 사진·방향·알파·fit/fill | MediaEngine/MediaImporter.swift, TimelineCompositor.swift | 회전 영상/PNG/이미지 길이·crop 실제 출력 |
| 11 속도·정지·역재생·자막 재매핑 | Domain/ClipTemporalEditor.swift, SpeedTools.swift | 경계/음성 pitch/생성 파일/자막 시간 검사 |
| 12 전환·키프레임 | Domain/Transitions.swift, MediaEngine/TransitionRenderer.swift | 핸들 부족 거부, 길이 보존, 위치/불투명도/음량 시간별 비교 |
| 13 색·SDR/HDR/VFR 지원 경계 | MediaEngine/HDRVideoConverter.swift, Domain/ColorTools.swift | 실제 포맷별 decode/색/PTS, 미지원 명시 |
| 14 프록시·캐시·원본 출력 | MediaEngine/ProxyCache.swift, InspectionCache.swift | 손상/취소/시간·회전·색, 원본 없는 출력 제한 |
| 15 원자 저장·자동 복구·백업 | Persistence/ProjectStore.swift, RecoveryStore.swift, ProjectBackup.swift | 강제 종료/부족 공간/재열기, 마지막 정상 문서 |
| 16 수집·이동·재연결·생성물 보호 | Services/GeneratedMedia.swift, Persistence/ProjectCollector.swift | 현재/저장/Undo/Redo 참조 보호, 동명 다른 파일 거부 |
| 17 수동 자막·SRT·폰트·스타일 | Domain/SRTCodec.swift, CaptionEditing.swift, App/CaptionsPanel.swift | 한글/조합문자, 분할/합치기, 누락 폰트 표시, 번들 라이선스 |
| 18 로컬 STT·언어 인식 | Services/LocalTranscription.swift, SourceLanguageEvidence.swift | ko/ja/en 실제 음성, 모델 identity, 원본 시간/구간 경계 |
| 19 번역·수정·원문 보존 | Services/CaptionTranslation.swift, Domain/CaptionTranslationTracking.swift | 언어별 사람 검수, 늦은 결과/변경 원문 적용 거부 |
| 20 VAD·전사 편집·검토 | Services/VoiceActivity.swift, App/EditorWorkflow.swift | 후보/맥락 확인·승인 후 삭제·한 번 Undo, 문구 수정 분리 |
| 21 파형·볼륨·페이드·ducking·EQ | Domain/AudioAutomation.swift, MediaEngine/WaveformAnalyzer.swift | 실제 PCM/피크·라우드니스 구분, 청취, 내보내기 일치 |
| 22 BGM·효과음·소재·앱 로고 | Services/AssetLibrary.swift, Resources/Library, Scripts/build-icon.sh | 모든 파일 decode/hash/출처/번들 재배포 조건, 2~3분 BGM |
| 23 AI 클립 보드·후보 교체 | Domain/ContentModels.swift, App/ProductivityPanel.swift | 사용자 메타데이터, 길이/crop/audio 교체 정책 |
| 24 브랜드·공모전·엔드카드 | Domain/ContentModels.swift, EditTemplate.swift | 4종 사용자 키트, 조건/문구, 임의 연락처 없음 |
| 25 비율/도입부 파생·출력 큐 | App/EditorProductivity.swift, Services | 독립 수정, 원본 재사용, 취소/재시도/출력 identity |
| 26 제출 전 검사 | Services/OutputQuality.swift, App/EditorQuality.swift | 길이/코덱/오디오/빈 공간/동적 자막 검사, 후보와 확정 구분 |
| 27 고급 효과·추적·색·오디오 | 원본 명세 9절, Domain/MediaEngine | 마스크/키/블렌드/모자이크/추적/배경제거/리프레임/LUT/커브/스코프/색매칭/비트/장면/속도곡선/복합클립/조정레이어별 근거 |
| 28 선택형 검색·FCPXML·외부 AI | 원본 명세 9·11절 | 지원 subset/손실 보고, 선택형 모델/API 조건/비용/동의 |
| 29 기본 예제 15초 및 추가 18초 | 원본 명세 12절 + 이전 목표의 추가 예제 | 15초 450frame: 5초 입력 3개→각4초+3초 이미지. 별도18초: 3×5초+3초 |
| 30 30~60초 세로 광고 | 실제 EditorModel/GUI + ExportJob | 자막/로고/BGM/엔드카드→저장/재열기/출력 |
| 31 3~5분 홍보 | 같은 실제 앱 | 대사/BGM·전환·제목·색 보정, 재편집/출력 |
| 32 10~20분 대화 | 자막/번역/저장/출력 | 언어 인식·사람 수정·저장 후 편집·출력 |
| 33 장시간·4K 성능·취소 | TimelineSession/RealTimeline/ProxyIntegrity | 기기/OS/형식/부하별 지연·메모리·전체 decode |
| 34 배포·회귀·새 사용자 | Scripts/verification-run.py, package-release.sh | 새 폴더 사본 패키지, 지원 환경, 회귀/설치/업데이트/복구 자료 |
| 35 서명·공증·Gatekeeper·다른 Mac | Scripts/release-preflight.sh | Developer ID·공증 ticket·최종 SHA·다른Mac 전체 인수 |

## Advanced follow-on scope remains required

Each item requires its own implementation and evidence. Partial masks, selected-color chroma and blend modes do not imply tracking, segmentation or all advanced tools are complete.

- 수동 도형 마스크
- 크로마키
- 블렌드 모드
- 키프레임 모자이크
- 객체 추적
- 인물 배경 제거
- 자동 리프레임
- 노출·대비·채도·화이트밸런스
- LUT
- 커브·스코프·색상 매칭
- 비트 검출·장면 검출
- 전사 검색·선택형 시각 검색
- 속도 곡선
- 고급 오디오
- 복합 클립·조정 레이어
- 제한된 FCPXML

The original initial exclusions remain separate: multicam, RAW development, HDR mastering, 360/spatial video, 3D, plugin marketplace, live collaboration and mobile are not silently added to the initial release. Conditional search/FCPXML/external AI work retains explicit subset, loss-reporting, cost, consent and availability gates.

See [release readiness](RELEASE-READINESS.md) and [the roadmap](../ROADMAP.md). A source copy does not establish native UI acceptance, real speech accuracy, all-suite success, signing or installation support.
