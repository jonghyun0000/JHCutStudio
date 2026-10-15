# 설치·실행 문제 해결 · 0.7

JH CUT Studio 개발판0.7.0 (빌드8). **현재 정식 서명·공증된 공개 다운로드는 없습니다.** 실제 확인 환경은 Apple Silicon M4/macOS27.2이며, macOS14는 배포 타깃입니다. 모든14이상/Intel/다른Mac 지원 인수를 완료한 뜻은 아닙니다. 동봉Whisper는arm64, 자막 번역은macOS26이상과설치언어팩이필요합니다. 최신[출시 준비 현황](RELEASE-READINESS.md)을 함께 확인하세요.

## 개발판 실행과 정식 설치 준비

1. 받은 압축 파일을 풀고 **`JH CUT Studio.app`을 ‘응용 프로그램’ 폴더로 옮깁니다.** 다운로드 폴더나 디스크 이미지 안에서 바로 실행하면 macOS가 앱을 임시 격리 위치에서 실행해 설정이 저장되지 않을 수 있습니다. 앱의 ‘설치 점검’이 이 경우를 알려 줍니다.
2. 현재 개발 빌드는 ad-hoc 서명이며 Developer ID 서명·공증을 완료한 공개 배포본이 아닙니다. 개발자는 [README의 빌드 안내](../README.md#build-and-run)를 사용하세요. 정식 설치 안내와 실제 다운로드 URL·버전·크기·SHA는 서명·공증·다른Mac 인수를 마친 릴리스에 연결할 예정입니다. 개발용 로컬 실행을 일반 사용자의 Gatekeeper 배포 승인으로 계산하지 않습니다.
3. 앱이 열리면 자동으로 **설치 점검**을 합니다(읽기 전용). 기능을 막는 문제가 있을 때만 알림을 띄우고, 전체 결과는 속성 패널 → ‘설치 점검 · 프로젝트 백업’에서 볼 수 있습니다. ‘진단 정보 복사’로 문의에 붙여 넣을 수 있습니다(파일 내용은 포함하지 않음).

## 자동 자막 모델이 없을 때

- 모델은 **자동으로 내려받지 않습니다.** 자막 패널의 ‘Whisper 모델 설치…’를 누르면 출처·라이선스·용량·SHA-256을 보여 주고, 동의해야 설치합니다. 설치 후에는 음성이 이 Mac 밖으로 나가지 않습니다.
- 모델 없이도 편집·출력·SRT 가져오기는 모두 사용할 수 있습니다.
- 설치 위치: `~/Library/Application Support/JHCutStudio/Models/`. 파일이 손상되면 실행 전 SHA-256 검사에서 멈추고 다시 설치하라고 안내합니다.

## 번역 언어팩이 없을 때

- 자막 번역은 Apple의 기기 내 번역을 쓰며 **설치된 언어팩만** 사용합니다(자동 다운로드·외부 전송 없음).
- ‘설치 점검’에 설치된 언어 조합이 표시됩니다. 없으면 ‘번역 언어 설정 열기’ 버튼 → 시스템 설정 → 일반 → 언어 및 지역 → 번역 언어에서 한국어·영어·일본어를 내려받습니다.
- 언어팩이 없어도 원문 자막은 만들 수 있고, 번역을 시도하면 원문을 보존한 채 설치 방법을 알려 줍니다.

## 앱이 열리지 않거나 기능이 멈출 때

| 증상 | 원인 | 해결 |
|---|---|---|
| “앱 안의 음성 인식 실행 파일이 없거나 실행할 수 없습니다” | 압축 해제·복사 중 앱이 손상 | 받은 압축 파일에서 앱을 다시 복사 |
| “설정 폴더에 쓸 수 없습니다” | `~/Library/Application Support/JHCutStudio` 권한 문제 | 폴더 권한을 사용자 읽기/쓰기로 복구 |
| “저장 공간이 부족합니다” | 2GB 미만 | 공간 확보 후 출력·자동 자막 실행 |
| 실행 직후 종료 | macOS 14 미만, 또는 앱 번들 손상 | macOS 버전 확인 후 앱 재설치 |

## 기존 프로젝트 보호

- 저장할 때마다 직전 저장본을 `이름.jhcut.backup`으로 보관합니다(기존 기능).
- **0.6에서 만든 문서에 0.7 기능(용어집·화자·문장 언어·번역 말투 등)을 처음 저장하면, 저장 전 원본을 `이름.jhcut.before-0.7`로 한 번만 따로 보관합니다.** 0.6 앱은 0.7 전용 항목이 들어간 문서를 열지 못하므로, 0.6으로 돌아가야 할 때 이 사본을 엽니다. 이후 저장에서도 덮어쓰지 않습니다.
- ‘프로젝트 백업 만들기’: 저장된 문서와 `.backup`, 목록(manifest)을 `~/Library/Application Support/JHCutStudio/ProjectBackups/`에 시각별 폴더로 복사합니다. 영상 원본은 복사하지 않고 위치만 기록합니다.
- ‘백업에서 복원’: 해시로 손상 여부를 확인하고 **새 문서로** 엽니다. 기존 파일은 덮어쓰지 않으며, 사라진 영상 개수를 알려 줍니다. ‘다른 이름으로 저장’하세요.
- 앞으로 나올 형식(schemaVersion 2 이상)의 문서는 “지원하지 않는 프로젝트 버전”으로 거부하고 문서를 바꾸지 않습니다.

## 배포 절차 (개발자용)

자격 증명 없이 확인할 수 있는 부분과, Developer ID가 있어야 하는 부분을 나눴습니다.

```bash
bash Scripts/build.sh
bash Scripts/release-preflight.sh
```

`release-preflight.sh`는 서명 도구·공증 도구 존재, 번들 버전과 문서 버전 일치, 모델 미포함, **번들 안의 모든 Mach-O가 배포 스크립트의 서명 대상인지**, 복사본에 hardened runtime ad-hoc 서명 후 `codesign --verify --deep --strict`, 서명된 whisper-cli 실행, **빈 홈 폴더로 실행(새 Mac 첫 실행 모사)** 후 8초 유지·실제 설정 폴더 불변·모델 자동 설치 없음을 확인합니다. 실제 서명·공증은 하지 않습니다.

패키징할 앱과 검증 index는 **같은 완료 run**에서 선택합니다. 전체 앱 빌드와 선택한 검사들이 통과하고 source/input 불변이 확인된 `verification-index.json` 및 그 run의 `Build/JH CUT Studio.app`을 사용하세요. `--core-only`, 실패·중단 run, 다른 run의 앱/index 혼합은 사용할 수 없습니다. 선택한 앱을 다시 빌드하거나 수정하지 말고, 아래 세 경로를 모두 실제 절대 경로로 바꿉니다. 출력 경로는 입력 앱 밖의 새 배포 결과용 부모 폴더이며, 스크립트가 그 아래 고유한 작업 폴더를 만듭니다.

```bash
export JHCUT_RELEASE_BUNDLE="/absolute/path/to/verified-run/Build/JH CUT Studio.app"
export JHCUT_RELEASE_VERIFICATION_INDEX="/absolute/path/to/verified-run/verification-index.json"
export JHCUT_RELEASE_DIRECTORY="/absolute/path/to/new-release-output-parent"
```

자격 증명 없이 검토용 ZIP·SHA256SUMS·manifest·예비 노트를 준비하려면 다음을 사용합니다. 이 모드는 격리된 앱 사본을 만들지만 서명·앱 실행·Apple 제출은 하지 않습니다. 검토용 ZIP은 정식 배포 승인본이 아닙니다.

```bash
JHCUT_PACKAGE_PREPARE_ONLY=1 bash Scripts/package-release.sh
```

실제 배포에는 별도로 Developer ID Application 인증서와 `notarytool store-credentials`로 만든 키체인 프로필이 필요합니다. 위 절대 경로 설정을 유지하고, 다음 값은 **실제 자격 증명이 아닌 자리표시자**이므로 준비된 본인의 인증서 식별자·키체인 프로필명으로 바꾼 뒤에만 실행합니다.

```bash
JHCUT_SIGN_IDENTITY="Developer ID Application: REPLACE_WITH_YOUR_IDENTITY" \
JHCUT_NOTARY_PROFILE="REPLACE_WITH_YOUR_KEYCHAIN_PROFILE" \
  bash Scripts/package-release.sh
```

스크립트는 입력 metadata를 확인하고 내부 작업 사본을 만든 뒤 동일 입력 복사 여부를 확인합니다. 정식 모드는 검증 index·자격 증명을 요구하고 preflight를 통과해야 서명·제출합니다. 그 전에 작업 폴더나 사본이 이미 생길 수 있으며, 입력 앱은 변경하지 않습니다. 이후 내부 실행 파일부터 hardened runtime으로 서명 → 번들 서명·검증 → 공증 제출(`--wait`) → staple → Gatekeeper 평가 → 최종 ZIP·체크섬·metadata 생성 순서로 진행합니다. 공개 소스 리비전 연결과 다른 Mac 설치 인수는 별도로 확인해야 합니다. **이 저장소 작업에서는 인증서·공증 프로필이 없어 실제 공증 제출은 실행하지 않았습니다.**


## 업데이트와 제거

- 업데이트 인수는 아직 미완료입니다. 새 버전에서 열기 전에 `.jhcut` 문서와 원본 미디어를 별도 위치에 보관하세요. 문서 백업은 영상 원본을 포함하지 않습니다. 프로젝트를 옮기려면 ‘원본 모으기’ 결과를 사용하고 새 위치에서 재열기·출력을 확인하세요.
- 새 마스크/블렌드/크로마키 등 전용 필드가 추가된 문서는 이전 앱에서 열리지 않을 수 있습니다. 최초 해당기능 저장 때 보존하는 `.before-…` 사본과 `.backup`은 용도가 다릅니다. 실제 기능이 포함된 현재 버전에서 확인한 뒤 이전 버전으로 돌아갈지 결정하세요. 크로마키는 현재 통합 검증 준비 중입니다.
- 앱을 제거하는 것과 프로젝트·미디어·모델·설정을 지우는 것은 별개입니다. 앱을 휴지통으로 옮겨도 사용자가 저장한 프로젝트·원본 영상은 자동 삭제하지 않습니다. 별도 앱 데이터는 `~/Library/Application Support/JHCutStudio/`에 있으며 모델·복구본·생성 미디어가 들어갈 수 있습니다. 프로젝트가 참조하는 생성 미디어를 확인하기 전 일괄 삭제하지 마세요.
- 공개 다운로드가 준비되면 기존버전→새버전 업데이트와 최초 설치를 각각 다른Mac에서 검사하고, 확인한OS/CPU/버전·체크섬을 릴리스 노트에 기록합니다. 현재 사용자는 인증서·공증설정·검증용 다른Mac이 아직 없다고 확인했으며 해당 항목은 미완료로 남아 있습니다.

## English notes

There is no verified signed public installer yet. The deployment target is macOS14; current acceptance is bounded to the documented Apple Silicon development Mac. The bundled Whisper executable is arm64. Translation requires macOS26 or later and installed Apple language packs. See the [English README](../README.md) for the verified toolchain and build steps.

Keep a separate copy of projects and original media before updating. A document backup does not contain media; use the app's media-collection action for a portable project. Uninstalling the app and removing projects, generated media, models or recovery data are separate actions. Another-Mac first installation and update acceptance remain open.
