#!/usr/bin/env python3
"""Capture source identity, or package already-generated original public samples.

This helper does not render footage. The companion test-public-samples.sh must
compile/run Tests/PublicSamplesProbe.swift before invoking the package command.
All newly written files use exclusive creation. Never pass a frozen run as output.
"""
import argparse
import datetime
import hashlib
import json
from pathlib import Path, PurePosixPath
import plistlib
import re
import zipfile

APP_SOURCES = ["App/EditorModel.swift", "App/EditorProductivity.swift", "App/EditorWorkflow.swift",
               "App/EditorQuality.swift", "App/EditorTransitions.swift", "App/EditorSpeedTools.swift",
               "App/EditorGeneratedMedia.swift"]
INPUT_SOURCES = APP_SOURCES + ["Tests/PublicSamplesProbe.swift", "Validation/Fixtures.swift",
                             "Validation/MediaInspection.swift", "Scripts/test-public-samples.sh",
                             "Scripts/package-public-samples.py", "LICENSE", "Resources/Info.plist"]
SLUGS = ["01-vertical-story", "02-community-promo", "03-dialogue-layout"]

def digest(path):
    value = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1048576), b""):
            value.update(chunk)
    return value.hexdigest()

def write_new(path, data):
    if isinstance(data, str):
        data = data.encode("utf-8")
    with path.open("xb") as stream:
        stream.write(data)

def write_json(path, value):
    write_new(path, json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + "\n")

def require(condition, message):
    if not condition:
        raise RuntimeError(message)

def capture(repo, core, destination):
    require(repo.is_dir() and core.is_file(), "Repository/Core input is missing")
    source = {name: digest(repo / name) for name in INPUT_SOURCES}
    info = plistlib.loads((repo / "Resources/Info.plist").read_bytes())
    record = {"schemaVersion": 1, "capturedAtUTC": datetime.datetime.now(datetime.timezone.utc).isoformat(),
              "repository": str(repo), "corePath": str(core), "coreSHA256": digest(core),
              "sourceSHA256": source, "appVersion": str(info["CFBundleShortVersionString"]),
              "appBuild": str(info["CFBundleVersion"]),
              "meaning": "Source/Core identity at standalone probe compilation. Fresh verification-run index establishes full build relation; this file alone does not prove how Core was built."}
    write_json(destination, record)
    print("Captured public-sample source/Core identities")

# README/notice templates are embedded below; the command is self-contained.
README_EN = '# JH CUT Studio: three editable starter projects\n\n[한국어](README.ko.md)\n\nThese are three separate projects rendered by JH CUT Studio @VERSION@ (local build @BUILD@), using original procedural graphics, editable Korean headings/captions, transitions and mathematical test audio. They are working starter examples, not filmed advertisements or an automatic-caption accuracy demo.\n\n| Folder | Format | Duration | Editable workflow |\n| --- | --- | --- | --- |\n| `01-vertical-story` | 1080 × 1920, 30 fps | 14 seconds | Three graphic scenes, motion, two dissolves, heading and captions |\n| `02-community-promo` | 1920 × 1080, 30 fps | 20 seconds | Fictional event design, motion, two dissolves, heading and captions |\n| `03-dialogue-layout` | 1920 × 1080, 30 fps | 18 seconds | Two schematic speakers and three manually authored dialogue cues |\n\n## Open, edit and export\n\n1. Extract the complete pack to a writable local folder. Keep each `Media` folder next to its `Project.jhcut`.\n2. In JH CUT Studio choose File → Open (⌘O) and select a `Project.jhcut`.\n3. Select an image, title or caption on the timeline and change its timing, text or inspector settings. The audio is a low-level synthetic test chord, not speech or a background-music recording.\n4. Export a new H.264 movie. `Result.mp4` is the already-rendered reference; choose another destination to preserve it.\n\nEach folder contains source media, an editable project, a SHA-256 collection manifest, the actual rendered MP4, four exported reference frames and a bounded `Verification.json`. All project references are relative; no security bookmark or developer home/disk path is included. Saving your own copy may add your local paths/bookmarks as normal app behavior.\n\n## Generation and verification\n\nThe candidate generator is `Tests/PublicSamplesProbe.swift`, used with `Validation/Fixtures.swift` and `Validation/MediaInspection.swift`. The proposed entry point is `Scripts/test-public-samples.sh`. After those reviewed files are installed in a source checkout, build the app, then run `JHCUT_BUILD_DIR=/path/to/that/build bash Scripts/test-public-samples.sh /path/to/new-output-parent`. The parent may exist; its `Generation` directory and provenance/package files must be new. The wrapper compiles the standalone probe against that Core, generates the pack and invokes `Scripts/package-public-samples.py` to create documentation, identities, checksums and an archive, then independently extracts and verifies it. Use the README of the source checkout for build prerequisites. The generator does not download media or use a speech model.\n\nAuthoring exercised the real EditorModel import/edit/split/Undo/Redo/transition/save commands. Each project was collected, stripped of absolute fallbacks, copied to another folder, loaded in a distinct EditorModel and exported by the actual app export queue. Every output video frame and audio sample was decoded. Frames 30, 150, 270 and 390 were compared against the shared preview compositor. See `MANIFEST.json` for the frozen local source/Core identity, file sizes and hashes.\n\nThe editable structure is reproducible. UUIDs, encoder metadata, operating-system fonts and hardware encoding can change bytes across runs; bit-for-bit identical regeneration is not promised. These checks do not establish native pointer-based GUI acceptance, live playback performance, audible speaker quality, real footage quality, ASR/translation quality, signed installation or another Mac’s compatibility. No claim of Final Cut Pro parity follows from these examples.\n\nSee [ASSET-NOTICE.md](ASSET-NOTICE.md) and [LICENSE](LICENSE) for permissions.\n'

README_KO = '# JH CUT Studio 편집 가능한 시작 예제 3개\n\n[English](README.md)\n\nJH CUT Studio @VERSION@ 로컬 빌드 @BUILD@에서 실제로 편집·저장·다시 열기·출력한 서로 다른 프로젝트 3개입니다. 코드로 그린 그래픽, 수정 가능한 한국어 제목·자막, 전환, 수학적으로 합성한 테스트 화음만 사용했습니다. 실사 광고나 자동 자막 정확도 데모가 아닙니다.\n\n| 폴더 | 출력 형식 | 길이 | 편집 요소 |\n| --- | --- | --- | --- |\n| `01-vertical-story` | 1080 × 1920 / 30fps | 14초 | 그래픽 3장, 움직임, 디졸브 2개, 제목·예문 자막 |\n| `02-community-promo` | 1920 × 1080 / 30fps | 20초 | 가상 행사 소개, 움직임, 디졸브 2개, 제목·예문 자막 |\n| `03-dialogue-layout` | 1920 × 1080 / 30fps | 18초 | 도형으로 표현한 대화자 2명, 수동 작성한 대화 예문 3개 |\n\n## 열고 수정하기\n\n1. 압축을 쓰기 가능한 로컬 폴더에 풉니다. 각 `Project.jhcut` 옆의 `Media` 폴더를 함께 보관합니다.\n2. 앱에서 파일 → 열기(⌘O)로 원하는 `Project.jhcut`을 엽니다.\n3. 타임라인에서 이미지·제목·자막을 선택하고 시간·문구·속성을 변경합니다. 오디오는 작은 합성 테스트 화음이며 사람 목소리나 녹음된 배경음악이 아닙니다.\n4. 새 H.264 영상으로 출력합니다. 함께 있는 `Result.mp4`를 보존하려면 다른 이름을 사용합니다.\n\n각 폴더에는 원본 이미지·PCM, 프로젝트, 미디어 SHA-256 목록, 실제 출력 MP4, 출력 프레임 4장과 범위를 명시한 `Verification.json`이 있습니다. 프로젝트 참조는 모두 상대 경로이며 개발자의 개인 디스크 경로나 보안 북마크가 없습니다. 직접 저장하는 사본에는 앱의 일반 동작에 따라 자신의 로컬 경로·북마크가 생길 수 있습니다.\n\n## 생성 및 검증 범위\n\n검토 후 저장소에 적용할 생성 코드는 `Tests/PublicSamplesProbe.swift`이며 기존 `Fixtures.swift`, `MediaInspection.swift`를 사용합니다. 제안 진입점은 `Scripts/test-public-samples.sh`입니다. 검토된 파일을 소스에 적용한 후 앱을 빌드하고 `JHCUT_BUILD_DIR=/빌드/경로 bash Scripts/test-public-samples.sh /새로운/출력/상위폴더`로 실행합니다. 상위 폴더는 존재해도 되지만 그 아래 `Generation` 디렉터리와 생성할 출처·패키지 파일은 새 이름이어야 합니다. 래퍼는 해당 Core로 독립 probe를 빌드·실행하고 `Scripts/package-public-samples.py`로 한영 설명·권리·식별값·체크섬·ZIP을 생성한 뒤 별도 폴더에 풀어 검증합니다. 빌드 환경은 소스 저장소 README를 따릅니다. 외부 다운로드나 음성 모델은 필요 없습니다.\n\n실제 EditorModel 가져오기·편집·분할·Undo·Redo·전환·저장을 실행했습니다. 수집 기능으로 미디어를 복사하고 절대 경로를 제거한 뒤 다른 상위 폴더로 옮겼으며, 별도 EditorModel에서 다시 열고 실제 출력 대기열로 영상을 만들었습니다. 모든 출력 영상 프레임·오디오 샘플을 해독하고 프레임 30·150·270·390을 공유 미리보기 합성과 비교했습니다. `MANIFEST.json`에서 소스·Core의 고정 식별값과 파일별 크기·SHA-256을 확인할 수 있습니다.\n\n편집 구조의 재현이 목적이며 UUID·인코더 메타데이터·운영체제 폰트·하드웨어에 따른 바이트 차이는 가능합니다. 네이티브 마우스 조작 전 과정, 실시간 재생 성능, 실제 스피커 청음, 실사 품질, ASR·번역 정확도, 정식 서명 설치나 다른 Mac 호환성을 검증한 것은 아닙니다. 이 예제로 파이널컷과 동등한 수준을 주장하지 않습니다.\n\n이용 허락은 [ASSET-NOTICE.md](ASSET-NOTICE.md)와 [LICENSE](LICENSE)를 참고하세요.\n'

ASSET_NOTICE = '# Sample media provenance and permissions\n\nCopyright (c) 2026 JongHyun and JHCutStudio contributors.\n\nThe procedural sample generator and the original sample text, geometry, PNG images, mathematical PCM test chords, project documents, rendered movies and frame images are offered under the included MIT license to the extent copyright is held by the contributors. You may modify, redistribute and use these samples commercially subject to that license. This is an original generated sample pack, separate from the app’s third-party asset library. It contains no downloaded music, stock footage, private camera video, recorded people, synthesized speech or bundled font files.\n\nImages are drawn by the included generator with Core Graphics/Core Text. AppleSDGothicNeo-Bold is requested from the local macOS installation for rendering; the font software itself is not distributed. Audio is an explicitly mathematical three-note test chord at 48 kHz, not a recording, a music-performance demonstration or speech. The captions and dialogue are fictional manually authored Korean examples; no ASR or translation accuracy is demonstrated. The event is fictional and makes no real-world venue, price or schedule claim.\n\nSource code is supplied with the repository under its root MIT license. Third-party app dependencies keep their own notices. This sample notice does not grant rights in third-party marks or imply an exclusive right in simple geometric forms or generated audio.\n'

def public_files(pack):
    items = []
    for path in sorted(pack.rglob("*")):
        require(not path.is_symlink(), "Symlink in public pack: " + str(path.relative_to(pack)))
        if path.is_file():
            require(not path.name.startswith("._"), "Filesystem metadata must not be distributed")
            items.append(path)
    return items

def validate_public(pack):
    require(sorted(path.parent.name for path in pack.glob("*/Project.jhcut")) == SLUGS,
            "Exactly three expected projects are required")
    for slug in SLUGS:
        document = pack / slug / "Project.jhcut"
        project = json.loads(document.read_text())
        require(len(project["assets"]) == 4, "Expected three original graphics and one test chord")
        for asset in project["assets"]:
            name = asset["path"]
            path = PurePosixPath(name)
            require(name == asset.get("relativePath") and name.startswith("Media/") and
                    not path.is_absolute() and ".." not in path.parts and "\\" not in name and
                    not asset.get("bookmark"), "Project must have relative media paths without bookmarks")
            require((document.parent / name).is_file(), "Missing public media")
        collection = json.loads((document.parent / "Collection.json").read_text())
        for item in collection["media"]:
            path = PurePosixPath(item["relativePath"])
            require(not path.is_absolute() and ".." not in path.parts and str(path).startswith("Media/"),
                    "Invalid collection media path")
            media = document.parent / str(path)
            require(digest(media) == item["sha256"] and media.stat().st_size == item["byteCount"],
                    "Collection hash/size mismatch")
    forbidden = ["/Users/", "/Volumes/", "/var/folders/", "IMG_0047", "IMG_0140", "IMG_9211"]
    for path in public_files(pack):
        if path.suffix in [".jhcut", ".json", ".md", ".txt"] or path.name in ["LICENSE", "SHA256SUMS"]:
            text = path.read_text()
            require(not any(token in text for token in forbidden),
                    "Private path/name marker in public text: " + str(path.relative_to(pack)))

def package(repo, provenance_path, generation, binary, destination):
    require(destination.is_dir(), "Output parent must already exist")
    provenance = json.loads(provenance_path.read_text())
    require(str(repo) == provenance["repository"], "Repository differs from compile capture")
    require(all(digest(repo / name) == value for name, value in provenance["sourceSHA256"].items()),
            "Source changed after compile capture")
    require(digest(Path(provenance["corePath"])) == provenance["coreSHA256"],
            "Core changed after compile capture")
    require(binary.is_file(), "Compiled probe binary is missing")
    checks = json.loads((generation / "checks.json").read_text())
    require(len(checks["results"]) == 3 and [r["slug"] for r in checks["results"]] == SLUGS,
            "Generation must finish all three samples")
    require(len(checks["checks"]) == 77 and all(row.get("passed") is True for row in checks["checks"]),
            "Generation requires all 77 actual checks to pass")
    for result, seconds, frames in zip(checks["results"], [14, 20, 18], [420, 600, 540]):
        require(result["durationSeconds"] == seconds and result["frames"] == frames,
                "Unexpected decoded duration/frame count")
    pack = generation / "PublicSamples"
    validate_public(pack)
    version = provenance["appVersion"]
    require(re.fullmatch(r"[0-9A-Za-z._-]+", version) is not None, "Unsafe version string")
    for filename, content in [("README.md", README_EN), ("README.ko.md", README_KO),
                              ("ASSET-NOTICE.md", ASSET_NOTICE)]:
        write_new(pack / filename, content.replace("@VERSION@", version).replace("@BUILD@", provenance["appBuild"]))
    write_new(pack / "LICENSE", (repo / "LICENSE").read_bytes())
    manifest = {"schemaVersion": 1, "samplePackVersion": version + "-three-samples-v2",
                "appVersion": version, "appBuild": provenance["appBuild"],
                "generatedAtUTC": datetime.datetime.now(datetime.timezone.utc).isoformat(),
                "coreSHA256": provenance["coreSHA256"], "generatorBinarySHA256": digest(binary),
                "sourceSHA256": provenance["sourceSHA256"],
                "verification": {"checks": 77, "failures": 0, "allFramesDecoded": True,
                                 "allAudioSamplesDecoded": True, "decodedVideoFrameTotal": 1560,
                                 "sampleCount": 3, "nativePointerAcceptance": False,
                                 "ASRAccuracyEvaluated": False},
                "scope": "Actual EditorModel API commands and full decode of procedural original graphics, synthetic test chords and manual captions. The verification-run index relates these identities to its fresh product build. No native GUI pointer, speech quality, signed distribution or another Mac acceptance is established.",
                "files": [{"path": str(path.relative_to(pack)), "bytes": path.stat().st_size,
                           "sha256": digest(path)} for path in public_files(pack)]}
    manifest["listedFileBytes"] = sum(row["bytes"] for row in manifest["files"])
    write_json(pack / "MANIFEST.json", manifest)
    write_new(pack / "SHA256SUMS", "".join(digest(path) + "  " + str(path.relative_to(pack)) + "\n"
                                          for path in public_files(pack)))
    validate_public(pack)
    archive = destination / ("JHCutStudio-" + version + "-Three-Samples.zip")
    with zipfile.ZipFile(archive, "x", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as handle:
        for path in public_files(pack):
            handle.write(path, Path("JHCutStudio-Samples") / path.relative_to(pack))
    extracted = destination / "ArchiveVerification"
    extracted.mkdir()  # Exclusive: never replace another verification folder.
    with zipfile.ZipFile(archive) as handle:
        require(handle.testzip() is None, "ZIP CRC verification failed")
        for name in handle.namelist():
            path = PurePosixPath(name)
            require(not path.is_absolute() and ".." not in path.parts and
                    path.parts[0] == "JHCutStudio-Samples", "Unsafe ZIP member")
        handle.extractall(extracted)
    unpacked = extracted / "JHCutStudio-Samples"
    validate_public(unpacked)
    extracted_manifest = json.loads((unpacked / "MANIFEST.json").read_text())
    for row in extracted_manifest["files"]:
        path = unpacked / row["path"]
        require(path.stat().st_size == row["bytes"] and digest(path) == row["sha256"],
                "Extracted manifest file identity mismatch")
    checksum_count = 0
    for line in (unpacked / "SHA256SUMS").read_text().splitlines():
        expected, name = line.split("  ", 1)
        require(digest(unpacked / name) == expected, "Extracted SHA256SUMS mismatch")
        checksum_count += 1
    audit = {"schemaVersion": 1, "archive": archive.name, "archiveBytes": archive.stat().st_size,
             "archiveSHA256": digest(archive), "archiveCRCValid": True,
             "manifestFilesVerified": len(extracted_manifest["files"]),
             "checksumFilesVerified": checksum_count, "projectCount": 3,
             "projectReferencesRelativeNoBookmarks": True, "sourceAndCoreUnchanged": True,
             "generatorChecks": 77, "generatorFailures": 0,
             "sourceCapture": provenance_path.name,
             "verificationScope": manifest["scope"]}
    write_json(destination / "package-audit.json", audit)
    print("PACKAGED_PUBLIC_SAMPLES archive=" + archive.name + " bytes=" + str(audit["archiveBytes"]) +
          " sha256=" + audit["archiveSHA256"])

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    first = sub.add_parser("capture")
    first.add_argument("--repo", required=True, type=Path)
    first.add_argument("--core", required=True, type=Path)
    first.add_argument("--output", required=True, type=Path)
    second = sub.add_parser("package")
    second.add_argument("--repo", required=True, type=Path)
    second.add_argument("--provenance", required=True, type=Path)
    second.add_argument("--generation", required=True, type=Path)
    second.add_argument("--binary", required=True, type=Path)
    second.add_argument("--output-parent", required=True, type=Path)
    args = parser.parse_args()
    if args.command == "capture":
        capture(args.repo.resolve(), args.core.resolve(), args.output.resolve())
    else:
        package(args.repo.resolve(), args.provenance.resolve(), args.generation.resolve(),
                args.binary.resolve(), args.output_parent.resolve())

if __name__ == "__main__":
    main()
