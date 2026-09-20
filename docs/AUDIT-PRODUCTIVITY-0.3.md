# 오디오·자막 생산성 점검과 0.3 서비스 검증

2026-09-20. 0.2 코드를 기준으로 확인한 결함과 기능 공백을 아래에 구분했다. 점수 상승의 증거는 실제 동작·출력 검증이며 모델 파일·버튼·자료 수 자체는 성공한 음성 인식으로 계산하지 않는다.

| 항목 | 실제 영향 | 0.3 처리와 남은 제한 |
|---|---|---|
| 반대 위상 스테레오 파형 상쇄 | 모노로 합친 뒤 피크를 구해 소리가 있는 구간이 평평하게 표시됨 | native 채널별 절댓값 최대값으로 수정. 파형 캐시 버전 2. 반대 위상 실제 WAV 80구간 검사 |
| 파형과 레벨 측정의 혼동 | 피크 그림만으로 RMS·클리핑 상태를 알 수 없음 | 별도 streaming PCM 분석. native 채널·샘플레이트 유지 |
| 실제 RMS 측정 부재 | 음량 판단을 청취에만 의존 | 전체 채널 샘플 제곱 평균으로 RMS/dBFS 계산. LUFS가 아님 |
| 클리핑 경계 표시 부재 | full-scale 샘플을 발견하기 어려움 | 절댓값 32767/32768 이상인 채널 샘플 수. 왜곡의 확정 진단으로 표현하지 않음 |
| 피크 정규화 부재 | 클립마다 수동 볼륨 조절 | -1dBFS 원본 피크 목표, 최대 +12dB. 디지털 무음에는 gain을 제안하지 않음 |
| 최종 믹스의 클리핑 위험 | 여러 클립 합산·볼륨 키프레임에서 단일 원본보다 커질 수 있음 | 원본 분석이라고 표시. 최종 버스의 true-peak/LUFS/limiter는 여전히 없음 |
| 트림한 소스 구간 분석 부재 | 사용하지 않는 부분의 피크·무음까지 영향을 줄 수 있음 | sourceStart/sourceDuration을 AVAssetReader 범위와 샘플 타임스탬프 양쪽에서 적용 |
| 자동 무음 후보 부재 | 반복 탐색 비용이 큼 | 기본 20ms 창 RMS, -45dBFS 이하, 0.35초 이상. 삭제하지 않고 후보 시간 제공 |
| 무음 검출 정확도 제한 | 짧은 숨·자음·배경음이 무음/비무음으로 분류될 수 있음 | 오디오 임계값 방식이며 음성 VAD가 아님. 경계 오차는 최대 한 창 수준. 사람이 확인해야 함 |
| 자동 한국어 전사 경로 부재 | SRT를 외부에서 만들어야 함 | 실제 whisper.cpp CLI 어댑터 추가. 승인된 다국어 모델이 설치되어야 실행 가능 |
| 모델 설치 정보·검증 부재 | 출처·용량·영어 전용 여부를 판단하기 어려움 | 고정 revision/정확한 바이트/SHA-256/MIT/필요 공간 표시. 기본 다운로드 없음 |
| 모델/엔진 없음과 실패 구분 부재 | 성공할 수 없는 작업을 시작할 수 있음 | 읽기 전용 availability, 파일 크기·실행 파일 확인, 실행 전 전체 SHA-256. 실패 시 클라우드 대체 없음 |
| 인식 취소·임시 파일 정리 부재 | 긴 처리 중 중단 불가 또는 추출 파일 잔존 | Task 취소→CLI 종료, 필요 시 kill, UUID 임시 폴더 defer 정리. 실제 프로세스 취소 검사 |
| 인식용 모노 합성의 위상 상쇄 | 반대 위상 음성 입력이 무음으로 변할 수 있음 | 두 번의 streaming pass로 선택 구간의 에너지가 가장 큰 단일 채널을 사용. 실제 추출 PCM 피크/RMS 검사 |
| 음성 채널 선택 한계 | 음악이 큰 채널·대사가 작은 별도 채널이면 잘못된 채널 선택 가능 | 사용 채널 인덱스를 전사 결과에 기록. 사용자가 채널을 직접 지정하는 UI는 남은 과제 |
| 자막 소스/타임라인 시간 혼동 | 앞부분 트림·배속에서 자막 싱크 오류 가능 | 서비스는 절대 원본 시간 반환. 편집기는 `(sourceTime-sourceStart)/rate+clip.start`로 매핑 |
| 자동 전사 정확도 보장 부재 | 고유명사·잡음·억양에서 틀린 문구 가능 | 새 자막 트랙으로 생성하며 문구·싱크 검토 필요. 숫자 정확도·일반 음성 WER는 측정하지 않음 |
| 화자 분리·단어별 신뢰도 부재 | 인터뷰 화자별 편집·오인식 탐색이 어려움 | 이번 구현에 포함하지 않음 |
| BGM 자동 덕킹 부재 | 대사와 음악 밸런스를 일일이 조절 | 기존 볼륨·페이드·키프레임 사용. 자동 대사 기반 덕킹 미구현 |
| 자료의 편집 맥락 정보 부족 | BPM·키·악기·대사와의 적합성으로 음악 탐색 어려움 | 원본 출처·태그는 존재하나 음악 구조/비트 검출은 없음 |
| 자막 스타일 수와 언어 이해의 혼동 | 24개 스타일이 전사·타이밍 자동화를 대체하지 못함 | 스타일과 자동 인식을 별도 기능으로 분리해 설명 |
| Apple Speech 권한/지원 상태 불확실 | 기기/언어에 따라 네트워크가 필요할 수 있음 | read-only probe만 수행. 실제 앱 경로는 whisper.cpp. Apple 인식 성공을 주장하지 않음 |

## 구현 계약

- `AudioAnalysis.analyze(url:sourceStart:duration:options:) async throws`는 원본 파일을 변경하지 않는다. 첫 오디오 트랙을 streaming float PCM으로 디코딩한다. 여러 오디오 트랙 전체의 믹스 분석이 아니다.
- `AudioAnalysisResult`의 `peakDBFS`/`rmsDBFS`가 nil이면 디지털 무음(-∞)이다. 유한한 가짜 바닥값을 만들지 않는다. `silenceRegions.start`는 절대 원본 시간이다. `normalizationBoostLimited`는 목표 피크에 도달하지 못하는 증폭 제한을 뜻한다.
- 분석은 미디어의 원래 소리이다. 클립 배속·볼륨·페이드·다른 트랙과 합친 뒤의 출력 레벨을 측정한 것이 아니다. 샘플 피크이며 inter-sample true peak, LUFS, 청감 음량을 의미하지 않는다.
- `LocalTranscription.transcribe(url:sourceStart:duration:configuration:progress:)`는 선택 범위를 16kHz mono PCM16 WAV로 추출한 뒤 `whisper-cli -l ko -osrt`를 실행한다. 임시 파일은 종료·실패·취소 시 정리한다. 결과 cue는 절대 원본 시간이다. `sourceChannelIndex`는 선택된 원본 채널의 0부터 시작하는 번호이다.
- `WhisperModelInstaller.installBaseModel(approvedByUser:destination:)`는 명시적 설치 동의가 있어야 실행된다. 기존 모델을 덮어쓰지 않으며 크기/전체 SHA-256을 확인한 staging 파일만 이동한다. 앱 실행·availability 조회·전사 시작은 모델을 다운로드하지 않는다.
- 마이크를 사용하지 않는다. whisper.cpp 경로에 Apple Speech 권한은 필요 없다. 시스템 권한을 자동 승인하거나 TCC를 바꾸지 않았다.

## 고정 배포 정보

Runtime은 [공식 whisper.cpp v1.9.4](https://github.com/ggml-org/whisper.cpp/releases/tag/v1.9.4), commit `927cfce34f31707e17f2bff35c349632fb9e2c3a`이다. 소스·빌드 도구는 프로젝트의 `Build/`에만 저장했다. `Scripts/build-whisper-runtime.sh`로 재현하며 모델은 다운로드하지 않는다. arm64/macOS 14 대상 Release, CPU + Accelerate, static ggml/whisper, Metal/curl 비활성. 실제 실행 파일은 2,518,344바이트이다. 앱 서명 전 SHA-256은 `Resources/Whisper/runtime-and-model.json`에 저장했다. 시스템 dylib만 참조하며 Homebrew 라이브러리나 개발 폴더에 의존하지 않는다. Intel/macOS 14 실제 기기는 미검증이다.

모델은 [공식 whisper.cpp 모델 안내](https://github.com/ggml-org/whisper.cpp/blob/v1.9.4/models/README.md)가 연결하는 ggerganov 저장소의 다국어 `ggml-base.bin`이다. [.en이 아닌 한국어 지원 모델의 고정 파일](https://huggingface.co/ggerganov/whisper.cpp/blob/5359861c739e955e79d9a303bcbc70fb988958b1/ggml-base.bin), 147,951,465바이트, SHA-256 `60ed5bc3dd14eea856493d334349b405782ddcaf0028d4b5df4088345fba2efe`, [MIT 라이선스](https://github.com/openai/whisper/blob/main/LICENSE). 설치 임시 공간까지 포함해 400MB 이상 여유를 확인한다. upstream의 base RAM 표시는 약388MB이며 이 앱의 실측 메모리 결과가 아니다. 모델은 앱에 번들하지 않으며 Application Support/JHCutStudio/Models에 별도 저장한다.

## 실제 실행한 검증

`bash Scripts/test-productivity.sh Artifacts/Productivity-0.3` 결과는 `checks.json`, `audio-measurements.json`, `apple-speech-availability.json`에 기록한다. 실제 WAV/AAC 파일, 동일 위상/반대 위상, 디지털 무음, -60dB 저음량, full-scale PCM, 트림 구간, 소스 보존, 오류·취소·설치 거부를 검사한다. 모든 소스가 원본 샘플에서 계산되며 파형이나 전사 결과를 꾸미지 않는다.

Apple read-only 상태는 이 Mac에서 `ko-KR / supportsOnDeviceRecognition=true / isAvailable=true / authorization=notDetermined`였다. 권한 요청 및 Apple 음성 인식은 수행하지 않았다. Apple 문서는 [온디바이스 지원이 false일 때 네트워크가 필요하다](https://developer.apple.com/documentation/speech/sfspeechrecognizer/supportsondevicerecognition)고 명시한다.

현재 모델 설치 승인을 기다리는 동안 자동 전사 성공은 미검증으로 남긴다. 설치가 승인되면 `--transcribe` 옵션으로 설치된 Yuna 음성이 읽은 한국어 fixture를 실제 전사하고 SRT/JSON 및 트림한 구간의 타임스탬프를 저장한다. 합성된 짧은 한국어 한 예문의 성공을 자연 발화·잡음 환경 전체 정확도로 일반화하지 않는다.

최종 실행 결과(모델 설치 전): 서비스 검사 **37/37 통과**, `Artifacts/Productivity-0.3/checks.json`. 정확한 모델 크기로 만든 변조 파일도 SHA-256 단계에서 거부했고, NaN PCM 샘플도 거부했다. 합성 파일은 검사 후 삭제했으며 정상 모델 다운로드와 혼동하지 않는다.

`bash Scripts/test-app-productivity.sh Artifacts/Productivity-App-0.3`로 실제 `EditorModel`의 UI 연결을 화면 없이 실행하여 **9/9 통과**했다. 2배속 클립의 sourceStart/sourceDuration 전달, 소스 무음 시간을 타임라인 프레임으로 매핑, 클립 변경·재연결·프로젝트 전환 시 오래된 분석 무효화, 취소 후 상태 해제, 모델 미설치 시 문서 비변경을 확인했다. 저장/편집 명령은 호출하지 않아 사용자의 복구본을 건드리지 않았다. 이 검사는 네이티브 GUI를 직접 클릭한 검사를 대체하지 않는다.

UI 코드 검토에서 정규화 증폭 제한에도 목표 -1dBFS 달성을 표시하던 문제와 프록시 생성 중 재연결한 원본에 이전 프록시를 연결할 수 있는 경쟁 조건을 발견했다. 담당자가 실제 달성 피크·상한 표시와 원본 스냅샷 재검증으로 수정했다.
