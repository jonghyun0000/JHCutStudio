# 내장 소재 출처 · 라이선스 · 검증

확인일: 2026-09-20. 앱은 아래 실제 파일을 `Resources/Library`에서 읽으며, 실행할 때 다운로드·로그인·외부 업로드를 하지 않습니다. 유료 팩이나 경쟁 편집기의 전용 소재는 포함하지 않았습니다.

총 **154개 / 미디어 파일 80,120,615바이트(약 76.4MiB)**입니다.

| 종류 | 수집 소재 | 직접 제작 | 합계 |
|---|---:|---:|---:|
| 효과음 | Kenney 100 | 합성 효과음 12 | 112 |
| 배경음악 | 작가 공개 음악 8 | 절차 생성 기악 2 | 10 |
| PNG 장식 | 0 | 16 | 16 |
| PNG 배경 | 0 | 8 | 8 |
| PNG 질감 | 0 | 8 | 8 |

`manifest.json`은 `LibraryAsset` 객체의 JSON 배열입니다. 각 항목에 한국어 이름·검색 태그, 원저자, 원본 페이지, 다운로드 URL, 라이선스 URL, 원본 파일 이름, 출처 구분(`downloaded`/`original`), SHA-256, 실제 길이·파일 크기를 기록했습니다. 변환된 파일은 원본 SHA-256과 최종 WAV SHA-256을 별도로 갖습니다.

## 수집한 효과음

[Kenney — Interface Sounds 1.0](https://kenney.nl/assets/interface-sounds)의 **100개 전부**를 공식 ZIP에서 받았습니다. 공식 페이지의 CC0 표시와 ZIP 안의 `License.txt`를 함께 확인했습니다. 클릭, 확인, 오류, 열기·닫기, 선택, 스크롤, 전환, 유리음 등 20개 계열입니다.

- 저자: Kenney
- 라이선스: [CC0 1.0](https://creativecommons.org/publicdomain/zero/1.0/)
- 원문: `Resources/Library/Licenses/Kenney-Interface-Sounds.txt`
- 원본: OGG. 현재 Mac의 내장 `/usr/bin/afconvert`로 16비트 PCM WAV 변환을 실제 수행했습니다.
- 앱 파일: `Audio/SFX/Kenney/*.wav`
- 저자 표시는 CC0 의무와 별개로 출처를 투명하게 남기기 위해 유지했습니다.

## 수집한 배경음악

모음집의 일괄 표시에 의존하지 않고 다음 **개별 작품 페이지의 저자·CC0 표시·다운로드 파일**을 확인했습니다. 원본 음악의 길이를 늘리거나 반복해서 새 파일로 만들지 않았습니다. 한국어 표시명은 탐색을 위한 이름이며 원제와 원본 파일명도 보존했습니다.

| 앱 표시명 / 원제 | 저자 | 실제 길이 | 포함 형식 | 작품·라이선스 출처 |
|---|---|---:|---|---|
| 카페 보사노바 · 8비트 / Bossa Nova | Joth | 59.611초 | MP3 | [개별 작품](https://opengameart.org/content/bossa-nova) |
| 새로운 하루 · 밝은 모험 / A New Day | SpiderDave | 88.613초 | PCM WAV | [개별 작품](https://opengameart.org/content/a-new-day) |
| 전자 리듬 · Techno 5 / Electronic | Alex McCulloch (Pro Sensory) | 98.870초 | MP3 | [개별 작품](https://opengameart.org/content/electronic) |
| 희망의 끝 · 잔잔한 피아노 / At the end of hope | Emma_MA | 183.040초 | MP3 | [개별 작품](https://opengameart.org/content/at-the-end-of-hope) |
| 꿈의 공간 · 앰비언스 / Dream 2 Ambience | TokyoGeisha | 129.463초 | MP3 | [개별 작품](https://opengameart.org/content/dream-2-ambience) |
| 빛의 흐름 · 일렉트로 하우스 / Liquid Flame | Of Far Different Nature | 220.803초 | MP3 | [개별 작품](https://opengameart.org/content/liquid-flame) |
| 질주 · 밝은 신스 / Pure Raceway | MintoDog | 96.000초 | MP3 | [개별 작품](https://opengameart.org/content/pure-raceway) |
| 댄스 필드 · 레트로 리듬 / Dance field | Centurion_of_war | 54.909초 | MP3 | [개별 작품](https://opengameart.org/content/dance-field) |

모두 위 개별 페이지에서 CC0가 표시된 실제 오디오 첨부 파일입니다. `A New Day`만 OGG 원본을 PCM WAV로 변환했고, 나머지 MP3는 다운로드한 바이트 그대로 보존했습니다. 사이트의 미리보기 이미지·댓글·다른 작가의 파일은 포함하지 않았습니다. 각 작품의 출처 기록은 `Licenses/OGA-*.txt`에 있습니다. CC0 법률문서는 [Creative Commons 원문](https://creativecommons.org/publicdomain/zero/1.0/legalcode.en)과 로컬 `Licenses/CC0-1.0.html`에서 볼 수 있습니다.

## 직접 제작한 소재

외부 수집 항목과 명확히 구분한 **46개**입니다. 저자는 `JH CUT Studio · 로컬 절차 생성`, `origin`은 `original`입니다.

- 효과음 12개: 전환 바람, 상승음, 임팩트, 물결풍 전환, 종이 넘김풍 합성음, 알림, 엔딩 강조 등. 외부 샘플·음성 복제 없이 수학적 발진·노이즈·엔벌로프로 생성했습니다. 실물 녹음 효과음이라고 표시하지 않습니다.
- 기악 배경 2개: 96 BPM의 30초 「잔잔한 펄스」, 120 BPM의 32초 「가벼운 아침」. 직접 정한 코드·패턴·발진음으로 생성했으며 외부 음악을 잘라 쓰지 않았습니다.
- PNG 32개: 화살표·원형 강조·프레임·밑줄·자막 바·리본·말풍선 등 오버레이 16개, 그라데이션 배경 8개, 입자·격자·줄무늬·비네트·필름 가장자리 등 질감 8개. 모두 1080×1920이며 장식·질감에는 알파 채널이 있습니다. 이미지에 상표·주소·가격 같은 정보를 임의로 넣지 않았습니다.

생성 소스는 `Scripts/generate-assets.py`와 `Scripts/generate-assets.swift`입니다. 원본 제작 항목도 CC0로 제공하며 설명은 `Licenses/Originals.txt`에 있습니다. 폰트 파일이나 타사의 로고는 포함하지 않았습니다. 편집 가능한 자막 스타일은 이미지 소재가 아닌 별도의 `TitlePreset` 모델로 관리합니다.

## 실제 검증

현재 Apple M4 / macOS 27.0 / SDK 26.5 환경에서 수행했습니다.

- **오디오 122개:** AVAssetReader로 처음부터 끝까지 PCM 샘플을 디코딩하고 완료 상태·샘플 수·길이를 확인했습니다.
- **PNG 32개:** ImageIO로 실제 이미지를 디코딩하고 해상도를 확인했습니다.
- **154개 전체:** `AssetLibrary.verify()`의 CryptoKit SHA-256 검사 통과.
- 변조 바이트, `../` 경로 이탈, 라이브러리 밖으로 연결되는 심볼릭 링크, 중복 ID를 각각 만들어 거부됨을 확인했습니다. 테스트 임시 폴더는 정리했습니다.
- 32개 그래픽의 컨택트 시트를 이미지 도구로 직접 확인했습니다. 도형·알파·배경·프레임 구분이 정상입니다. 자동 오디오 디코딩은 개별 음악의 청취 평가나 특정 광고와의 음악적 적합성 평가를 대신하지 않습니다.

결과는 `Resources/Library/validation.json`에 있습니다. 수집 원본의 고정 SHA-256 목록은 `Scripts/collect-assets.lock.json`입니다. 네트워크가 필요 없는 앱에서는 PCM WAV/MP3/PNG만 읽습니다. OGG 변환 도구는 앱에 포함하지 않습니다.

## 재현

저장소 루트에서 실행합니다. Python 표준 라이브러리, macOS 내장 `afconvert`, 설치된 Swift/Apple SDK만 사용하며 pip·FFmpeg·유료 API가 필요하지 않습니다.

```sh
python3 Scripts/collect-assets.py
python3 Scripts/generate-assets.py
```

수집 스크립트는 검토된 URL과 잠금 파일의 원본 SHA-256을 비교합니다. 상위 원본이 변경되어 해시가 달라지면 중단합니다. 출처와 라이선스를 다시 검토한 뒤 의도적으로 갱신할 때만 `--refresh-lock`을 사용합니다. 현재 포함된 완성 파일은 다시 다운로드하지 않고도 앱에서 사용할 수 있습니다. 다른 OS 버전에서 소재 재생이나 재생성을 실행했다고 주장하지 않습니다.
