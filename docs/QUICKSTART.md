# 첫 편집부터 MP4 출력까지 · First edit to MP4

JH CUT Studio 0.7.0 (build 8). [English](#english) · [설치·문제 해결](INSTALL-0.7.md) · [현재 출시 상태](RELEASE-READINESS.md)

**현재 정식 서명·공증된 공개 다운로드는 없습니다.** 아래는 로컬 개발 빌드를 사용하는 안내이며, 다른 Mac의 설치 검증이나 30–60초 사용 녹화를 대신하지 않습니다. 개발자는 [빌드 안내](../README.md#build-and-run)에 따라 앱을 만드세요. 추후 공개 릴리스의 설치 파일·체크섬·지원 환경을 확인한 뒤 사용하는 설치 안내와 구분합니다.

## 1. 편집할 자료 열기

처음에는 원본을 보존하고 작업할 폴더를 따로 만드세요. 앱의 **파일 → 미디어 가져오기… (⌘I)**로 지원되는 SDR 영상·이미지·오디오를 선택합니다. 미디어 목록의 항목을 두 번 클릭하면 타임라인에 추가할 수 있습니다. HDR·Log 등 변환이 필요한 자료는 안내를 확인하고, 지원되는 경우 명시적인 SDR 사본 변환을 사용하세요.

별도 제공되는 `JHCutStudio-0.7.0-Three-Samples.zip`을 가지고 있다면 **전체를** 압축 해제하고, **파일 → 프로젝트 열기… (⌘O)**에서 `01-vertical-story/Project.jhcut`을 여세요. 각 프로젝트의 `Media` 폴더를 함께 보관하세요. 샘플 팩은 소스 ZIP과 별도로 [샘플 전용 prerelease](https://github.com/jonghyun0000/JHCutStudio/releases/tag/samples-0.7.0-v2)에서 [ZIP](https://github.com/jonghyun0000/JHCutStudio/releases/download/samples-0.7.0-v2/JHCutStudio-0.7.0-Three-Samples.zip)과 [SHA-256 파일](https://github.com/jonghyun0000/JHCutStudio/releases/download/samples-0.7.0-v2/JHCutStudio-0.7.0-Three-Samples.zip.sha256)을 받을 수 있습니다. 앱 설치 파일이 아니며 정식 서명·공증 배포본을 포함하지 않습니다. 동봉 `LICENSE`와 `ASSET-NOTICE.md`의 MIT 고지를 유지하세요. 샘플에는 생성 그래픽·수동 예문 자막·수학적 테스트 화음이 들어 있습니다. 실제 사람 영상·자동 자막 정확도·음악 감상 데모가 아닙니다. 수동 자막이므로 샘플을 열 때 Whisper 모델은 필요하지 않습니다. [공개 사이트](https://jhcut-studio.jonghyun04.chatgpt.site)에서 실제 앱 스크린샷을 볼 수 있지만, 사용 녹화는 아직 없습니다.

ZIP과 SHA-256 파일을 같은 폴더에 받은 뒤 터미널에서 다음 명령으로 확인하세요. 실제 공개 ZIP은 37,109,550바이트이며 SHA-256은 `0fac840b2f8b489ff3f248feeae55e19cd99eec358da889ab65fb4be66a389ff`입니다.

```bash
shasum -a 256 -c JHCutStudio-0.7.0-Three-Samples.zip.sha256
```

## 2. 재생하고 한 번 잘라 보기

타임라인의 클립을 선택합니다. 겹쳐서 선택하기 어렵다면 **전체 클립 목록** 버튼에서 원하는 클립을 고릅니다. 선택할 때 재생 위치가 클립 시작으로 이동할 수 있으므로, 선택한 다음 **Space**로 재생하고 클립 중간에서 다시 Space로 정지하세요.

**← / →**로 프레임을 이동한 뒤 **⌘B**를 누르면 선택한 클립을 현재 위치에서 분할합니다. 클립의 시작·끝 경계에서는 분할하지 않습니다. **⌘Z**로 되돌리고 **⇧⌘Z**로 다시 적용해 보세요. 텍스트를 편집 중이면 먼저 입력을 마치고 타임라인에 초점을 돌린 뒤 편집 단축키를 사용합니다.

## 3. 제목·음악과 선택형 자막

**제목 추가**로 문구를 넣거나 기존 제목·자막을 선택해 수정합니다. 숫자 입력과 프로젝트 이름처럼 Return으로 적용하는 항목은 입력 후 **Return**을 누르세요. 화면에 입력 중인 글자가 보이는 것과 편집 명령이 적용된 것은 다를 수 있습니다.

**사운드** 탭에서 음악·효과음을 찾아 미리듣고 정지한 뒤 `+`로 넣습니다. 선택한 오디오의 음량·페이드와 재생 위치를 확인하세요. 샘플의 테스트 화음은 완성된 배경음악이 아닙니다.

자동 자막은 선택 사항입니다. **자막** 패널의 **Whisper 모델 설치…**에서 출처·MIT 라이선스·용량·SHA-256과 필요한 공간을 확인하고 동의하면 별도로 설치합니다. 모델이 없어도 일반 편집·수동 자막·SRT·출력을 사용할 수 있습니다. 인식한 문구·시간·언어는 직접 검토하세요. 번역은 macOS 26 이상과 설치된 Apple 번역 언어팩이 필요하며, 원문과 연결된 별도 자막으로 관리됩니다. 인식 실행 성공이 정확도를 보장하지는 않습니다.

## 4. 프로젝트를 저장하고 다시 열기

**파일 → 다른 이름으로 저장… (⇧⌘S)**으로 자신의 `.jhcut` 사본을 새 이름으로 저장합니다. 미디어를 수집하는 명령은 아니므로 원본 파일은 그대로 보관하세요. **⌘S**로 저장한 뒤 앱을 종료하고, 저장한 문서를 다시 열어 편집 내용과 재생을 확인합니다.

다른 폴더·디스크·Mac으로 옮기려면 **원본 모으기…**로 문서와 참조 미디어를 함께 수집하세요. 문서 `.backup`이나 프로젝트 백업만으로는 영상 원본까지 복사되지 않습니다. 누락 경고가 나면 원본을 재연결하고, 확인 전에 같은 이름의 다른 파일로 대체하지 마세요.

## 5. 새 MP4로 출력하고 확인하기

프로젝트 속성에서 원하는 캔버스·프레임레이트와 **H.264 · 호환성**을 확인합니다. **영상 출력 (⌘E)**에서 존재하지 않는 새 `.mp4` 파일 이름을 고릅니다. 앱은 기존 출력 파일을 덮어쓰지 않습니다. 출력이 끝나면 길이·오디오·자막 검사와 경고를 읽으세요.

출력 파일을 영상 플레이어로 열어 처음·중간·끝, 장면 순서, 자막과 소리를 확인합니다. 표본 검사 통과가 모든 프레임·음질·문구의 사람 검수를 대신하지 않습니다. 현재 개발 빌드의 알려진 제한과 미완료 인수는 [출시 상태](RELEASE-READINESS.md)를 따릅니다.

## English

There is **no verified signed/notarized public download yet**. Build the local development app using the [README](../README.md#build-and-run). These instructions are a written guide, not a usage recording, a signed-installation test or another-Mac acceptance.

1. **Open media or a starter project.** Use **File → Import Media… (⌘I)** and double-click a media item to add it to the timeline. Use supported SDR media; follow the explicit conversion guidance for supported HDR inputs. If you already have the separately supplied three-sample pack, extract it completely, keep each `Media` folder beside its document, and open `01-vertical-story/Project.jhcut` with **⌘O**. The pack is separate from the source ZIP: download the [sample ZIP](https://github.com/jonghyun0000/JHCutStudio/releases/download/samples-0.7.0-v2/JHCutStudio-0.7.0-Three-Samples.zip) and [SHA-256 sidecar](https://github.com/jonghyun0000/JHCutStudio/releases/download/samples-0.7.0-v2/JHCutStudio-0.7.0-Three-Samples.zip.sha256) from the [sample-only prerelease](https://github.com/jonghyun0000/JHCutStudio/releases/tag/samples-0.7.0-v2). It is not an app installer. Verify the sidecar with the command above before extracting. Keep the included MIT `LICENSE` and `ASSET-NOTICE.md`. Its graphics, manually authored captions and mathematical test chords are generated examples, not real speech, finished music or an ASR accuracy demonstration. Opening these manual-caption projects does not require a Whisper model. The [public site](https://jhcut-studio.jonghyun04.chatgpt.site) includes actual app screenshots; a usage recording is still unfinished.
2. **Play, pause and split.** Select the clip first, using **All Clips** if it is obscured. Selection can seek to its start. Press **Space** to play and again to pause inside the clip. Step with **← / →**, split with **⌘B**, undo with **⌘Z**, and redo with **⇧⌘Z**. Finish text entry and return focus to the timeline before using editing shortcuts.
3. **Add a title and sound.** Add or select a title/caption and edit its text. Commit fields that use submission, such as the project name, with **Return**. In **Sound**, audition a library item, stop it and use `+` to insert it; review its level and fades. Automatic captions require a separately approved Whisper model. Review its source, license, size and checksum before installation. Editing, manual captions, SRT and export work without that model. Translation additionally requires macOS 26+ and installed Apple language packs. Review all generated words, timing and language; successful execution does not establish accuracy.
4. **Save your copy and reopen it.** Use **File → Save As… (⇧⌘S)** for a new `.jhcut` document, then **⌘S**. Quit and reopen that saved document to check your edits. Save As and document backups do not collect original media. Use the app's **Collect Originals…** action before moving the project to another location or Mac, and verify the collected copy before removing anything.
5. **Export a new MP4.** Check canvas, frame rate and **H.264 · Compatibility**, then choose **Export Video (⌘E)** and a new filename. Existing outputs are not overwritten. Read the post-export checks and warnings; open the movie in a player and inspect its beginning, middle, end, captions and sound. Sampled automated checks do not replace human review of the complete result.

The interface currently has partial English coverage; advanced controls may retain Korean labels. See [installation help](INSTALL-0.7.md), [format boundaries](../README.ko.md#지원-형식과-데이터-보호) and [release readiness](RELEASE-READINESS.md) for current requirements and limits.
