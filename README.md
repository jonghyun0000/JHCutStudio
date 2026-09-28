# JH CUT Studio 0.7

한국어 우선 macOS 로컬 영상 편집기. 연결된 영상·대사·자막 편집, 한국어·일본어·영어 자동 자막과 상호 번역, HDR→SDR 사본, H.264/HEVC/ProRes 출력과 복구 기능을 제공합니다. **0.7 장시간 영상·검증 기능은 [0.7 작업 기록](docs/UPGRADE-0.7-WORKLOG.md), 설치·문제 해결은 [INSTALL](docs/INSTALL-0.7.md), 0.6 다국어 기능은 [사용법](docs/MULTILINGUAL-0.6.md), 최신 검증과 제한은 [검증 상태](docs/STATUS.md)를 확인하세요.**

Developer ID 공증 전인 로컬 개발 빌드입니다. 34개 전체 완료 또는 상용 전문 편집기와 동등한 완성도를 주장하지 않습니다.

## 실행

`Build/JH CUT Studio.app`을 더블클릭하거나:

```bash
cd /Volumes/T7/GPT/JHCutStudio
bash Scripts/run.sh
```

- 실제 앱: `Build/JH CUT Studio.app`
- 0.7 변경·검증 기록: [UPGRADE-0.7-WORKLOG](docs/UPGRADE-0.7-WORKLOG.md) · 설치/문제 해결: [INSTALL-0.7](docs/INSTALL-0.7.md)
- 다국어 자막·번역: [0.6 사용법](docs/MULTILINGUAL-0.6.md)
- 기존 기능·사용법: [0.5 사용법과 34개 개선](docs/UPGRADE-0.5-WORKLOG.md)
- 이전 버전: [0.3 업그레이드 설명](docs/UPGRADE-0.3.md)
- 확인한 약점 41개: [AUDIT](docs/AUDIT-0.3.md)
- 검증·미구현 범위: [STATUS](docs/STATUS.md)
- 소재 출처·라이선스: [ASSET-SOURCES](docs/ASSET-SOURCES.md)
- 평가 기준과 경쟁 제품 비교: [SCORECARD](docs/SCORECARD.md)

## 0.7에서 추가·개선 (0.7.0, 빌드 8)

- 긴 영상 이어하기: 5분 구간마다 체크포인트 저장, 취소·종료 후 다시 실행하면 완료 구간을 건너뜀(원본·설정이 같을 때만).
- 대본(.srt/.txt)이 영상 옆에 있으면 CER·WER·누락/추가 문장·시간 오차 보고서. 대본이 없으면 “평가 불가”.
- 문장별 언어 감지와 직접 지정, 화자별 채널 녹음의 화자 구분(불확실하면 붙이지 않음), 선택 자막 일괄 스타일·시간 편집과 안전 영역 맞춤.
- 번역 말투(존댓말·방송체·반말)와 프로젝트 용어집(이름·브랜드 보호, 적용/실패 표시).
- 음성 구간 분석: 무음·음악·강한 소음은 인식 생략(원본 소리는 그대로), 무음·음악 위 자막 경고, Whisper 반복 루프 감지·재시도.
- 출력 후 자동 품질 검사(길이·해상도·fps·오디오, 자막 위치·중복·속도, 번인 픽셀 확인, SRT 비교)와 출력 기록 연결.
- 설치 점검, 0.6 문서 보호 사본(`.before-0.7`), 프로젝트 백업/복원, 자격 증명 없는 배포 사전 점검.

## 0.3부터 제공해 온 기능

- SDR HEVC/ProRes, JPEG/HEIC·EXIF 방향, 프록시 생성·재사용·취소, 원본 기반 출력.
- 삽입·덮어쓰기·오디오 분리·트랙 관리, 키프레임/페이드를 보존하는 분할·트림.
- 실제 PCM 피크/RMS·무음 후보·피크 정규화, 프로젝트 원본 수집·검증.
- 자막 병합·일괄 시간 이동, UTF-16/CP949 추가, 한국어 Whisper 설치/인식 UI. base 모델은 설치되어 실제 자막 생성과 출력 검사를 통과했습니다. small 설치와 실사 정답 대본 기반 정확도 평가는 별도 대기입니다.
- **4K UHD·DCI 4K 출력과 23.976~60fps 지원.** 캔버스·프레임레이트·품질을 속성에서 고릅니다. 비트레이트는 해상도에 맞춰 자동 제안합니다.
- **macOS 26 Liquid Glass 디자인.** 창 툴바 통합, 영상 위 떠 있는 재생 컨트롤, 투명도 줄이기 설정 존중, 아이콘 버튼 전체에 VoiceOver 레이블.
- H.264 출력 4~64Mbps, 검색·속성 접기·안전 영역·타임라인 자동 스크롤.
- 속성 슬라이더를 드래그하는 동안 미리보기가 바로 바뀝니다. 드래그 한 번은 실행취소 1단계입니다. 숫자 입력은 Return 또는 `입력한 숫자 적용`을 씁니다.
- 편집마다 타임라인 전체를 다시 조합하던 비용을 없앴습니다. 10분·300컷 타임라인의 조합 재구축이 11.510초에서 0.070초입니다. 합성 소재 기준이며 실사 장시간 편집을 검증한 값은 아닙니다.

기존 0.2 기능도 포함합니다.

- **효과음 112개, 배경음 10곡, PNG 소스 32개**를 앱에 포함했습니다. 외부 CC0 108개와 직접 제작 46개를 출처·저작자·라이선스·SHA-256과 함께 구분합니다.
- **자막 스타일 24종**, 테두리·배경·정렬·줄 간격·최대 줄 수, 내 스타일 저장, 자막 목록·검색, UTF-8 SRT 입출력.
- 라이브러리 검색·종류 필터·즐겨찾기·음원 미리듣기·현재 위치에 삽입.
- 일정 속도 0.25–4배, 위치·크기·회전·불투명도·볼륨 키프레임, 노출·대비·채도·크롭, 화면/소리 페이드.
- 실제 샘플 파형, Cmd 다중 선택, 그룹 이동·삭제 한 번 실행취소, 클립 경계·플레이헤드 스냅, 겹친 클립 선택 메뉴.
- 독립된 9:16/16:9/1:1/4:5 버전, 누락 미디어 재연결, 자동 복구본·프로젝트별 복구 선택.

기본 설정에서는 음성이 있는 지원 영상을 가져오면 메인 트랙 배치 → 언어 감지 → 원문 자막 생성 → 한국어 번역까지 실행합니다. 한국어 영상은 원문을 표시합니다. 자막 탭에서 자동 생성을 끄거나 번역 언어를 바꿀 수 있습니다. 사운드/소스 탭의 `+`는 플레이헤드에 삽입하며 자막 탭의 스타일은 선택 자막에 적용합니다. 자막을 선택하지 않았으면 새 제목을 만듭니다. 속성의 슬라이더는 드래그하는 동안 반영되고, 숫자는 Return 또는 `입력한 숫자 적용`으로 반영합니다. 키프레임은 별도의 `현재 위치에 키프레임 저장` 버튼을 사용합니다.

Space 재생/정지, ←/→ 프레임 이동, Cmd+B 분할, Cmd+D 복제, Delete 삭제, Cmd+Z/Shift+Cmd+Z 실행취소/재실행, Cmd+S 저장입니다. 편집 단축키는 텍스트 입력 중에는 본문 편집을 방해하지 않습니다. 리플 삭제·배속 변경은 같은 트랙의 뒤 클립만 이동하며 다른 트랙을 자동 연결하지 않습니다.

## 지원과 안전성

- 입력: SDR 메타데이터가 확인되는 H.264·HEVC·ProRes 422 계열, PNG·JPEG·HEIC, 실제 디코딩에 성공한 오디오. **HDR/Log·색 정보가 불명확한 파일은 차단**합니다. 지원 세부 프로필과 실제 시험 범위는 엔진 감사 문서를 참조하세요.
- 출력: SDR Rec.709 H.264 MP4. **최대 4096×2160(9.4메가픽셀), 23.976/24/25/29.97/30/50/59.94/60fps**, 4–64Mbps. 오디오가 있으면 AAC/48kHz 스테레오. 기존 출력 파일은 덮어쓰지 않습니다.
- 미리보기와 출력이 같은 Core Image/Core Text 합성기를 사용합니다. 출력 계획은 항상 원본을 참조하며 프록시를 출력하지 않습니다.
- 원본은 읽기 참조입니다. 프로젝트는 유리수 시간·상대 경로·bookmark와 함께 원자적으로 저장하며 이전 정상 문서는 `.backup`에 보존합니다.
- 변경 후 1.2초에 별도 복구본을 저장합니다. 복구를 미룬 다른 프로젝트의 복구본도 프로젝트별로 보존합니다. 원본 문서를 자동으로 덮어쓰지 않습니다.
- 가져온 자료는 파일 참조입니다. ‘프로젝트와 원본 모으기’로 새 폴더에 원본·문서·SHA-256 목록을 수집할 수 있습니다.
- 계정·서버·외부 API·유료 소재·제품 워터마크가 없습니다. 영상·음성·번역 문구를 클라우드 처리로 보내지 않습니다. Apple 번역은 기기 안에서 처리하며 API 사용·성능 메타데이터 수집 가능성은 [Apple 안내](https://developer.apple.com/documentation/translation/translationsession)를 따릅니다. 수집 스크립트는 명시적으로 실행할 때 공개 자료를 다운로드합니다.
- HDR→SDR 사본·연결 클립·타원 마스크·기본 믹스는 0.5에서 추가했습니다. 추적·속도 곡선·멀티캠·협업·공개 배포 공증은 미완료입니다. 4K는 소프트웨어 합성이라 미리보기가 느릴 수 있으니 프록시를 함께 쓰세요.

## 재현

```bash
bash Scripts/build.sh
bash Scripts/test-domain.sh
bash Scripts/test-productivity.sh
bash Scripts/test-app-productivity.sh Artifacts/Editor-NewRun
bash Scripts/test-scale.sh Artifacts/Scale-NewRun 300
bash Scripts/test-live-preview.sh Artifacts/Live-NewRun
bash Scripts/test-format.sh Artifacts/Format-NewRun
JHCUT_COMPAT_BUILD="$PWD/Build" JHCUT_COMPAT_USE_EXISTING_CORE=1 bash Scripts/test-compatibility.sh Artifacts/Compatibility-NewRun
bash Scripts/test-engine.sh Artifacts/EngineUpgrade
Build/JHCutValidate Artifacts/G0-NewRun
Build/JHCutValidate --upgrade Artifacts/Upgrade-NewRun
```

자동 검사 228개가 통과합니다. `test-scale.sh`는 트랙 패킹과 carrier 재사용을, `test-live-preview.sh`는 라이브 미리보기와 실행취소 1단계를 확인하며 사용자의 복구본을 건드리지 않습니다. 검증은 실제 영상을 생성·출력·재디코딩합니다. 기존 출력 보호를 위해 새 결과 폴더를 지정하세요. `--inspect movie.mp4 [proof-folder]`로 기존 MP4의 코덱·프레임·오디오·샘플 이미지를 검사할 수 있습니다. 완성된 60초/10분 영상과 보고서는 `Artifacts/Upgrade`에 있습니다.

## 빌드 환경

실제 장비: Apple M4 / Mac16,1 / 16GB / macOS27.0(26A428). CLT Swift6.3.3, SDK26.5, Swift5 언어 모드, arm64, 최소 macOS14 타깃으로 빌드했습니다. macOS14 실기기와 Intel은 미검증입니다.

설치된 Xcode27은 약관 동의가 되어 있지 않아 기본 `swift`/`git` 경로가 차단되어 있습니다. 스크립트는 해당 프로세스의 `DEVELOPER_DIR`만 CLT로 지정합니다. 시스템 설정이나 약관 동의를 대신 변경하지 않습니다. 이 장비의 SwiftPM은 PackageDescription 인터페이스/라이브러리 버전 불일치가 있어 **검증된 빌드 경로는 Scripts/build.sh**입니다. XCTest는 CLT 컴파일러와 설치된 XCTest 프레임워크를 사용합니다.

Apple 시스템 프레임워크와 공식 whisper.cpp v1.9.4 로컬 실행 파일을 사용합니다. Whisper MIT 라이선스를 앱에 포함하며 모델은 승인 후 별도로 다운로드합니다. FFmpeg·폰트 파일은 포함하지 않습니다. 앱은 로컬 ad-hoc 서명이고 Developer ID 서명·공증 제품은 아닙니다. 코드 구조는 [ARCHITECTURE](docs/ARCHITECTURE.md)에 기록했습니다.
