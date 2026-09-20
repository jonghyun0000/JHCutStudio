# 네이티브 GUI 검증 — 2026-09-20

최종 `Scripts/build.sh`로 만든 `Build/JH CUT Studio.app`을 실제 macOS에서 실행했습니다. SwiftUI/AppKit 화면을 CUA로 조작하고, 결과 MP4는 별도 AVFoundation 디코더로 검사했습니다. CLI 보고서의 GUI-lifecycle `not_run`은 이 문서의 별도 실행 증거로 보완됩니다.

환경: Apple M4 / 16GB / macOS 27.0 (26A428), CLT Swift 6.3.3, SDK 26.5. 로컬 ad-hoc 서명 검사는 `codesign --verify --deep --strict` 종료 코드 0입니다.

## 실행한 흐름

| 동작 | 확인 결과 |
|---|---|
| 앱 실행·네이티브 열기 창 | 한국어 경로의 프로젝트를 열어 미디어 6개와 총 15초, 4트랙 복원 |
| 영상 선택·숫자 트림 | 첫 장면 길이 4→3초 적용, 더티 표시, 실행취소 버튼으로 4초 복원 |
| Cmd+B 분할 | 플레이헤드 2초 2프레임에서 실제 클립 길이 2.0667초로 분할 |
| Cmd+Z | 분할 전 4초 클립과 저장 상태로 복원 |
| PNG 앞트림 드래그 | 엔드카드 시작 12→12.9667초, 길이 3→2.0333초, 원본 시작 0 유지. 한 번의 undo로 복원 |
| Shift+Cmd+Z | 트림 12.9667초/2.0333초 재실행. 다시 undo하여 최종 출력은 원래 15초 내용 유지 |
| 제목 입력 중 Space | 한국어 제목 끝에 공백 입력, 재생 시각 2:02 유지 |
| 제목 입력 중 Backspace/Cmd+B | 공백만 삭제, 제목 클립 삭제·분할 없음 |
| Cmd+S 저장 | 프로젝트와 이전 버전 백업 수정 시각 08:49:29 KST 확인 |
| Cmd+Q 완전 종료 | 앱 프로세스가 종료된 것을 pgrep으로 확인 |
| 앱 재실행·재열기 | 새 프로세스의 네이티브 Open 창에서 같은 문서 복원, 총 15초 표시 |
| 재생·정지 | 재생 버튼으로 시각 0:07 진행, Space로 4:06에서 정지. 합성된 두 번째 장면·제목·PNG 표시 |
| MP4 출력 | 네이티브 Save 창에서 GUI-final.mp4 지정, 실제 14% 진행 표시, 완료 메시지 확인 |

검증 중 발견된 한국어 입력 소스의 Cmd+Z 처리 문제는 키 문자 대신 물리 키코드를 사용하도록 수정하고 위 최종 검증을 수행했습니다. 파일 열기/저장 모달에서는 타임라인 단축키를 처리하지 않습니다.

가져오기 중 문서 교체, 외부 문서 열기의 미저장 변경 보호, Save As 상대 경로 기준도 코드 검토 후 보완했습니다. 이 세 상황의 GUI 오류 재현은 미실행이고 저장 계층에는 관련 회귀 테스트가 포함되어 있습니다.

## GUI로 만든 출력 재검사

출력: `/Volumes/T7/GPT/JHCutStudio/Artifacts/G0/GUI-final.mp4`

```bash
Build/JHCutValidate --inspect \
  '/Volumes/T7/GPT/JHCutStudio/Artifacts/G0/GUI-final.mp4' \
  '/Volumes/T7/GPT/JHCutStudio/Artifacts/G0/gui-proof'
```

결과 파일: `Artifacts/G0/gui-output-inspection.json`.

- 1080×1920, 30fps, H.264 (`avc1`), AAC (`aac `).
- 실제 디코딩 450프레임, 단조 증가 타임스탬프, 영상 끝 15초, 컨테이너 15초.
- 채널당 오디오 720,000샘플, 15초, 정규화 RMS 0.0707035962, 피크 0.1018227041.
- 프레임 30의 로컬 OCR: `종현의 첫 영상 | SCENE 1 | FRAME 045 | JH | SDR H.264 • 30 fps`.
- 별도 투명 PNG에서 온 시안색 16,724픽셀.
- GUI 출력의 대표 프레임 30/150/270/390 PNG가 `Artifacts/G0-Final/proof/export-frame-*.png`와 각각 SHA-256 일치. GUI와 최종 자동 검증 출력의 네 장면이 같은 픽셀임을 확인했습니다.
- GUI 디코딩 프레임 30과 390을 직접 열어 한국어 제목·원본 프레임 번호·PNG 알파·엔드카드를 육안 확인했습니다.

프레임 30 SHA-256: `7b700e2dad322ea45511723bfedf4e8a9ccfc6be254d65ee08f7c495fc66a963`

프레임 390 SHA-256: `7ac5d72b564a83fb472ad2a893301d65d8b867fdb1197e3f71c2707cdafdb37e`

## 미실행

실시간 재생 드롭 수, 화면 표시 첫 프레임 지연, 실제 디스크 고갈, 외장 장치 강제 분리, 물리 키보드 한글 IME 조합, 장시간 편집/10분 출력, macOS 14/Intel, 공개 서명·공증. 이 항목은 통과로 계산하지 않습니다.
