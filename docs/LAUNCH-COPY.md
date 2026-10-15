# JH CUT Studio — 출시 소개·답변·미디어 자료 초안

작성일: 2026-10-15. **미게시 초안**. 자체 사이트·README·규칙이 허용하는 채널용이다. 공개 게시·연락·사이트 배포·릴리스 업로드를 실행하지 않았다. [출시 준비 현황](RELEASE-READINESS.md)과 [90일 운영 계획](LAUNCH-GROWTH-90-DAYS.md)을 먼저 확인한다.

현재 개발판은 0.7.0 build 8이며, 정식 서명·공증 다운로드와 다른 Mac 설치 검증은 아직 없다. 버전은 실제 출시 때 확정한다. 이 문서에 출시일·사용자 수·성능 우위·자막 정확도를 임의로 채우지 않는다. KO/EN 소개가 있다고 영어 앱 UI가 완성된 것은 아니다.

## 지금 쓸 수 있는 개발 현황 소개

### 한국어

JH CUT Studio를 만들고 있습니다. Mac에서 계정이나 구독 없이 영상을 편집하고, 선택적으로 설치한 Whisper 모델로 한국어·일본어·영어 음성의 자막을 생성하는 로컬 영상편집기입니다. 멀티트랙 편집, 제목·음악·전환, 자막 수정과 출력 작업을 연결하고 있습니다.

현재는 0.7.0 build 8 개발판입니다. 정식 설치 파일의 서명·공증, 다른 Mac에서의 설치 검증, 다운로드 사이트와 공개 샘플을 준비하고 있습니다. 앱 화면은 주로 한국어이며 영어 UI 작업이 남아 있습니다. 실제 자막 생성 실행은 검증했지만 사람이 검수한 정답이 없어 인식 정확도나 번역 의미 점수는 발표하지 않습니다. 기능과 남은 제한은 준비 현황 문서에 공개하겠습니다.

### English

I'm building JH CUT Studio, a local video editor for Mac. It connects multitrack editing, titles, music, transitions and editable subtitles with export. Optional Whisper models run on the Mac for Korean, Japanese and English speech workflows, without an editing account or subscription.

The current development build is 0.7.0, build 8. Signed and notarized downloads, installation checks on another Mac, a download website and public samples are still being prepared. The interface is primarily Korean; English UI work remains. Recognition runs have been verified, but there are no human-reviewed references for a real-speech accuracy score or translation meaning score. Release readiness and known limits will be documented openly.

## 출시 게이트 통과 후 사용할 소개

**아래 문안은 아직 발표하지 않는다.** 실제 버전·링크·지원 환경·라이선스 공개 상태를 확인하고 채운 뒤, 남은 제한을 최신화한다. 자리표시자가 남으면 배포하지 않는다. 확인되지 않은 문장을 삭제하는 대신 미완료 상태를 분명히 설명한다.

### 한국어 — 짧은 소개

JH CUT Studio는 Mac 개인 창작자를 위한 무료 오픈소스 영상편집기입니다. 계정·구독·제품 워터마크 없이 편집하고, Mac 안에서 음성을 인식해 자막을 만들 수 있습니다. 먼저 공개 샘플로 가져오기부터 저장·출력까지 확인해 보세요.

버전 {{VERSION}} · 지원 환경 {{VERIFIED_OS_CPU}} · {{OFFICIAL_DOWNLOAD_PAGE}}

### English — short introduction

JH CUT Studio is a free, open-source video editor for individual creators on Mac. Edit without an account, subscription or product watermark, and generate subtitles with speech recognition on your Mac. Try a public sample project to follow the workflow from import to save and export.

Version {{VERSION}} · Tested environment {{VERIFIED_OS_CPU}} · {{OFFICIAL_DOWNLOAD_PAGE}}

### 한국어 — 자세한 소개

Mac에서 짧은 영상과 인터뷰를 편집하면서, 비용과 계정 가입보다 실제 편집에 집중할 수 있는 도구를 만들고 싶었습니다. JH CUT Studio는 멀티트랙 편집, 자막 수정, 제목·음악·전환과 영상 출력을 하나의 작업 흐름으로 연결합니다.

자동 자막은 별도로 설치하는 Whisper 모델을 사용해 Mac에서 처리합니다. 한국어·일본어·영어 작업을 지원하며, 결과의 단어와 타이밍은 직접 검수해야 합니다. 번역에는 macOS 26 이상과 해당 Apple 번역 언어팩이 필요합니다. 모델·언어팩 설치에는 네트워크가 필요할 수 있습니다.

{{VERSION}}의 설치 파일, 체크섬, 공개 샘플과 실제 사용 데모를 {{OFFICIAL_DOWNLOAD_PAGE}}에 정리했습니다. 소스와 각 구성요소의 라이선스, 지원 조건과 알려진 제한도 함께 확인할 수 있습니다. 상용 전문 편집기와 모든 기능·성능이 같다고 주장하지 않습니다.

처음 가져오기·저장·출력 중 막힌 단계가 있다면 개인 영상이나 자막을 올리지 않고도 재현 조건을 알려 주세요. 개발에 참여하고 싶다면 {{CONTRIBUTING_URL}}을 확인해 주세요. 사용해 보고 도움이 됐다면 GitHub Star는 자발적으로 선택할 수 있습니다. 다운로드에 Star는 필요하지 않습니다.

### English — longer introduction

I wanted a Mac editing tool that lets individual creators focus on making a video without an editing account or subscription. JH CUT Studio brings multitrack editing, subtitle correction, titles, music, transitions and export into one workflow.

Automatic subtitles use a separately installed Whisper model on the Mac. Korean, Japanese and English workflows are supported, and generated words and timing need review. Translation requires macOS 26 or later and the relevant Apple translation language packs. Installing models or language packs may require a network connection.

Downloads for {{VERSION}}, checksums, public sample projects and a real usage demo are at {{OFFICIAL_DOWNLOAD_PAGE}}. Source, component licenses, tested environments and known limits are included. This is not a claim of complete feature or performance parity with a commercial professional editor.

If import, save or export gets in your way, a reproducible report helps; please keep private footage and transcripts out of public issues. To contribute, start at {{CONTRIBUTING_URL}}. A GitHub star is optional if the project is useful to you and is never required to download it.

## 기능·주장 확인표 / claims checklist

| 표현 | 사용 조건과 지금의 경계 |
|---|---|
| 무료 / free | 프로젝트의 핵심 편집에 계정·구독·제품 워터마크 없음. 모델/언어팩·장비·네트워크 조건은 별도 안내 |
| 오픈소스 / open source | 로컬 MIT 파일은 준비됨. 공개 링크에서 해당 커밋의 LICENSE와 전체 의존성 고지를 실제 확인한 뒤 공개 문안 확정 |
| 로컬 / local | 핵심 편집·Whisper 인식·앱 번역 경로는 미디어를 클라우드 처리 API에 업로드하지 않음. 다운로드·언어팩·웹사이트 로그와 구분. 모든 기능이 네트워크 없이 최초 실행된다고 주장하지 않음 |
| 다국어 / multilingual | 한국어·일본어·영어 인식과 자막 작업, 번역의 OS/언어팩 조건 설명. 언어별 동등 정확도·모든 언어 지원 주장 없음 |
| 실제 출력 / real export | 공개 데모의 실제 앱·출력 파일과 버전 연결. API 테스트만을 전체 UI 수용 검증이라고 표시하지 않음 |
| 안정성·성능 / stability and speed | 테스트 환경·소스 버전·영상 조건과 범위를 함께 제시. 상세 오디오 탭 600ms 실패 등 열린 제한을 숨기지 않음 |
| 상용 편집기 비교 | 같은 자료/작업/장비로 검증하지 않은 “Final Cut 동급”, “가장 빠름”, “100점”, “완벽 자막” 사용 금지 |
| 사용자·스타 | 실제 관측일과 출처가 있을 때만. 다운로드를 고유 사용자 수로 표현하지 않음. 10,000스타는 목표이며 현재 실적/보장 아님 |

## 자주 받을 질문에 대한 답변 초안

아래 답변 역시 해당 채널의 AI 텍스트 규칙을 먼저 확인한다. **HN·r/opensource 게시용이 아니다.**

| 질문 | 한국어 답변 | English reply |
|---|---|---|
| 지금 다운로드 가능한가요? | 현재는 개발판이며 정식 서명·공증 다운로드를 준비 중입니다. 검증된 공개 설치 링크가 생기면 버전·체크섬·알려진 문제와 함께 안내하겠습니다. | Signed and notarized public downloads are still being prepared. A verified release will include its version, checksum and known issues. |
| 정말 무료인가요? | 핵심 편집에 계정·구독·제품 워터마크를 요구하지 않습니다. 코드와 외부 자료는 각 라이선스 조건을 확인해 주세요. | Core editing does not require an account or subscription and adds no product watermark. Source and third-party materials have their respective license terms. |
| 영상이 서버로 올라가나요? | 핵심 편집과 Whisper 인식은 Mac에서 처리합니다. 모델 다운로드와 Apple 언어팩 설치는 별도입니다. 민감한 영상·자막은 공개 이슈에 올리지 말아 주세요. | Core editing and Whisper recognition run on your Mac. Model downloads and Apple language-pack installation are separate. Please keep private footage and transcripts out of public issues. |
| 자막은 얼마나 정확한가요? | 실제 생성 실행과 정확도는 구분합니다. 사람이 검수한 정답이 아직 없어 정확도 점수를 발표하지 않습니다. 생성 자막은 단어와 타이밍을 검수해 주세요. | Successful recognition runs do not establish accuracy. We do not yet have human-reviewed references for an accuracy score. Please review generated words and timing. |
| 어떤 Mac에서 되나요? | 배포 타깃과 실제 검증 환경을 구분해 안내합니다. 현재 다른 Mac·Intel 수용 검증은 남아 있고 bundled Whisper 실행 파일은 arm64입니다. 최신 지원표를 확인해 주세요. | The deployment target is separate from verified support. Another-Mac and Intel acceptance remain open; the bundled Whisper executable is arm64. Check the current tested-environment list. |
| 영어 UI도 있나요? | 지금은 한국어 중심이며 영어 UI는 아직 출시 작업입니다. 영어 README가 영어 앱 UI의 완료를 뜻하지 않습니다. | The interface is currently primarily Korean. English UI localization remains a release task; an English README does not mean that work is complete. |
| 번역이 안 됩니다. | 앱 버전, macOS 26 이상 여부, 해당 Apple 번역 언어팩 상태를 먼저 확인해 주세요. 원문을 보존하고 오류 단계만 알려 주시면 재현에 도움이 됩니다. | First check the app version, macOS 26-or-later requirement and relevant Apple translation language packs. Preserve the original text and report the failing step without sharing private content. |
| Final Cut을 대체하나요? | 개인 창작자의 편집 흐름을 목표로 합니다. 전문 편집기의 모든 기능과 성능이 같다고 주장하지 않습니다. 필요한 기능과 알려진 제한을 먼저 확인해 주세요. | It targets individual creators' workflows. We do not claim every feature or performance characteristic of a professional commercial editor. Check the features and known limits for your task. |
| 버그가 나면요? | 버전·OS/CPU 종류·실패 단계·재현 절차를 알려 주세요. 원본 영상·전체 경로·자막·인증정보를 공개하지 않아도 됩니다. 저장/출력 손실은 우선 분류합니다. | Report the version, OS/CPU type, failing step and reproduction steps. You do not need to publish original footage, full paths, transcripts or credentials. Save/export data-loss reports receive priority triage. |
| Star를 해야 쓰나요? | 아닙니다. 로그인이나 Star 없이 다운로드하고 사용할 수 있도록 준비하고 있습니다. Star는 사용 후 선택 사항입니다. | No. Downloads and use are being prepared without a login or star requirement. A star is optional after trying the project. |

배포 후에는 “준비 중” 답변을 실제 링크와 검증 환경으로 갱신한다. 해결 일정을 모르면 약속하지 말고 알려진 우회·원문 보존 방법·다음 확인 항목을 안내한다. 댓글 작성자가 아닌 다른 사용자의 개인정보를 재인용하지 않는다.

## 채널별 적용

2026-10-15 확인. [90일 계획의 공식 규칙 표](LAUNCH-GROWTH-90-DAYS.md#공식-채널-규칙과-실행-조건)를 함께 사용한다.

- **자체 사이트/README:** 위 KO/EN 문안의 대상이다. 실제 앱 화면과 데모를 연결하고 미완료 다운로드 버튼을 “다운로드 가능”으로 표시하지 않는다.
- **Hacker News:** [공식 지침](https://news.ycombinator.com/newsguidelines.html)은 생성·AI 편집 글과 자동 게시를 금지한다. **이 문안·답변을 복사하거나 AI로 고쳐서 게시하지 않는다.** [Show HN](https://news.ycombinator.com/showhn.html)은 직접 시도 가능한 작업을 요구한다. 제작자가 직접 쓰는 데 필요한 사실만 아래 확인 목록으로 제공한다: 왜 만들었는지 본인의 경험, 직접 만든 범위, 실제 실행 방법, 현재 한계, 기술적 선택과 타협, 직접 토론할 수 있는 시간. 제목/본문/댓글을 대신 생성하지 않는다. 투표·댓글 요청 금지.
- **r/opensource:** [공식 규칙](https://www.reddit.com/r/opensource/about/rules.json)에 AI 생성 콘텐츠 금지가 있다. 이 문안을 게시하지 않는다. 실제 공개 라이선스와 제작자의 직접 작성, 규칙·flair 재확인이 전제다.
- **r/macapps:** [공식 규칙](https://www.reddit.com/r/macapps/about/rules.json)의 자격·승인·템플릿·홍보 빈도·공식 배포 링크 조건을 확인해야 한다. 아직 계정 자격/개별 승인 미확인이다. 이 문안을 그대로 게시할 수 있다는 뜻이 아니다.
- **다른 커뮤니티·언론·개인 연락:** 대상과 규칙·사용자 승인 범위를 먼저 정한다. 이 문서에는 수신자나 전송 예약을 만들지 않는다.

## 미디어 키트 초안

제작자나 기자가 실제 자료를 찾도록 하는 목록이다. 아래 “준비/미완료”를 완료로 바꾸려면 파일·권리·버전·공개 URL을 확인한다. 연락처는 제작자가 공개를 승인한 공식 경로만 넣는다. 개인 이메일·전화번호를 추측하지 않는다.

| 항목 | 초안 내용 / 현재 상태 | 공개 전에 확인할 것 |
|---|---|---|
| 제품명 | JH CUT Studio | 앱·사이트·Release·아이콘 표기 일치 |
| 한 줄 KO | Mac에서 편집하고, 로컬 자막을 만들고, 직접 출력하는 무료 오픈소스 영상편집기 | 실제 공개 라이선스·다운로드 게이트 |
| One line EN | A free, open-source Mac video editor with local subtitles and a complete editing-to-export workflow. | Current release scope and working public links |
| 제작 배경 | 개인 창작자가 계정·구독 부담 없이 편집하도록 만들고 있음 | 본인이 말한 경험만 인용. 타 개발자와 제휴·보증 암시 금지 |
| 소스·라이선스 | MIT 로컬 적용, 구성요소별 별도 고지 | 공개 커밋의 LICENSE·notices 확인. 외부 자료를 MIT라고 일괄 표시하지 않음 |
| 버전·지원표 | 개발판 0.7.0 build 8. 실제 배포 버전 미확정 | 태그·커밋·설치 파일·OS/CPU 검증표·SHA |
| 앱 아이콘 | 저장소 Brand 자료와 provenance 준비 | 실제 사용할 파일, 크기별 내보내기, 출처 고지. 독점/상표 보장 표현 없음 |
| 스크린샷 3장 | 첫 편집, 자막 검수, 출력 완료 **공개용 선정 미완료** | 실제 앱 화면. 개인 경로/영상/자막/메타데이터 제거. 버전·캡션 |
| 실제 데모 30–60초 | **제작 미완료** | 원본 소유/재배포 권리, 실제 조작과 출력, 편집된 시간 압축 표시 |
| 튜토리얼 | 설치 → 샘플 → 편집 → 저장 → 출력 **미완료** | 새 Mac 설치 조건, 모델 선택, 취소/실패, 결과 재생 |
| 샘플 3종 | 세로 숏폼/홍보/대화의 공개 프로젝트와 결과 **미완료** | 권리·파일 수집·상대 경로·외부 모델 조건·버전·재현 절차. 개인 아이폰 영상은 자동 전환 금지 |
| 기능별 짧은 영상 | 트림/자막 수정/음악/저장·복구/출력 **미완료** | 녹화한 실제 동작만. 클릭 없는 가짜 UI 연출 없음 |
| 개발 회고 | 재생 중 진단 변경 보호, 자막 결과 파일 계약과 실패 복구, 공개 권리 고지 개선 | 공개 가능한 원리·근거만. private 진단/자막/경로·실제 정확도 추측 제외 |
| 공식 연락 | **미지정** | 공개 이슈 또는 승인된 보안/미디어 연락 경로, 담당·응답 여력 |

공개 파일명을 정하면 `제품명 / 버전 / 제작일 / 권리·출처 / 원본 또는 실제 조작 여부 / 공개 URL / SHA-256`을 자산별로 기록한다. 이 표는 스크린샷·동영상 파일 자체를 제작한 증거가 아니다.

## 실제 데모·회고 제작 메모

30–60초 데모의 제안 흐름은 다음과 같다. 각 구간의 길이는 편집 목표이며 측정된 앱 성능이 아니다. 녹화에서 기다리는 구간을 줄이면 “시간 단축” 표시를 한다.

1. 0–5초: 실제 앱과 재배포 가능한 소스, 계정 없이 시작하는 화면.
2. 5–15초: 가져오기·트림·분할·중간 일시정지.
3. 15–30초: 설치된 모델의 실제 자막 생성 결과, 단어/타이밍 수정. 초기 모델 설치 조건은 별도 자막으로 안내.
4. 30–42초: 제목·음악과 실제 출력 설정. 번역은 현재 OS/언어팩에서 검증한 경우에만 포함.
5. 42–55초: 저장·재열기, 실제 출력 완료와 플레이어 재생.
6. 55–60초: 검증한 지원 환경, 알려진 제한, 실제 다운로드·소스 주소. Star는 선택 사항.

개발 회고는 제작자가 검토해 자신의 경험으로 작성한다. 제안 구조는 “어떤 편집 작업이 막혔는가 → 재현 조건 → 바뀐 실제 동작 → 확인한 범위 → 아직 모르는 것 → 다음 작업”이다. 생성 실행 24회 완료를 자막 정확도 100%로 바꾸거나 독립 검사 수를 제품 점수로 환산하지 않는다.

## 공개 직전 체크

- 공식 Release의 버전·태그·커밋·자산 URL·파일 크기·SHA, 사이트 내용이 일치한다.
- `{{...}}` 자리표시자가 없고 앱·사이트 지원표와 알려진 문제가 최신이다.
- 로컬 license 적용과 원격 공개 상태, 테스트 완료와 미검증을 구분한다.
- 실제 화면·소리·프로젝트의 공개 권리와 민감 정보 점검을 마쳤다.
- 제목·설명·FAQ의 “무료/로컬/다국어”에 필요한 조건과 제한이 연결된다.
- 해당 채널의 당일 규칙, AI 텍스트 허용 여부, 계정 자격, 제작자 공개, 게시 대상·범위 승인을 확인했다.
- 제작자가 응답할 수 있고, 과장·가짜 후기·가짜 수치·Star 조건·투표 요청이 없다.

초안·계획의 작성 완료, 게시 완료, 출시 완료와 10,000스타 달성은 각각 별개로 기록한다.
