#!/usr/bin/env python3
"""Fresh build/output directory and source-bound verification evidence per run."""
import argparse, datetime, hashlib, json, os, re, signal, subprocess, sys, uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SUITES = "domain playback playback-observation-guard live-preview history-memory compatibility connected productivity app-productivity auto-captions app-transcription-failure multilingual checkpoint evaluation language language-repair translation-freshness speaker speaker-safety caption-workflow batch glossary vad quality quality-safety export-delivery storage-safety storage-faults distribution stabilization stabilize-editor transitions transition-editor speedtools speed-editor generated-media format engine media-timing transcription-output transcription-boundary real-iphone07 vad-safety cache-safety evaluation-safety accuracy-dataset accuracy-completion caption-scope human-evaluation accuracy-failure real-accuracy scale real-timeline proxy-integrity timeline-session app-export-preview library-decode library-workflow library-migration production-scenarios audio-ducking prefetch translation-fit dynamic-pixel blend-modes blend-editor shape-mask shape-mask-editor chroma-key chroma-key-editor public-samples release-metadata ui-localization".split()

def digest(path):
    h = hashlib.sha256()
    with path.open("rb") as f:
        for block in iter(lambda: f.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()

def now():
    return datetime.datetime.now(datetime.timezone.utc).isoformat()

def git(*args):
    return subprocess.check_output(["git", *args], cwd=ROOT)

def project_git_head():
    """Reject archives and enclosing repositories before creating verification artifacts."""
    guidance = "Clone JHCutStudio and run verification from that checkout, or initialize and commit this source directory as its own repository. Source ZIPs can still use the documented build script."
    try:
        top = subprocess.check_output(["git", "rev-parse", "--show-toplevel"], cwd=ROOT, stderr=subprocess.DEVNULL).decode().strip()
    except (OSError, subprocess.CalledProcessError) as error:
        raise RuntimeError("Verification requires a project-owned Git checkout. " + guidance) from error
    if Path(top).resolve() != ROOT.resolve():
        raise RuntimeError("Verification refused an enclosing Git repository: its HEAD does not identify this source directory. " + guidance)
    try:
        head = subprocess.check_output(["git", "rev-parse", "--verify", "HEAD^{commit}"], cwd=ROOT, stderr=subprocess.DEVNULL).decode().strip()
    except (OSError, subprocess.CalledProcessError) as error:
        raise RuntimeError("The project repository has no valid HEAD commit. Commit the source before verification. " + guidance) from error
    if not re.fullmatch(r"(?:[0-9a-fA-F]{40}|[0-9a-fA-F]{64})", head):
        raise RuntimeError("The project repository returned an invalid HEAD identity. " + guidance)
    return head

def snapshot():
    head = project_git_head()
    files = {}
    for name in ("App", "Domain", "Services", "Persistence", "MediaEngine", "Validation", "Tests", "Scripts", "References", "Resources/Whisper", "Resources/Localization"):
        for p in sorted((ROOT / name).rglob("*")):
            if p.is_file() and (p.suffix in (".swift", ".sh", ".py", ".json", ".js", ".html", ".strings") or name == "Resources/Whisper"):
                files[str(p.relative_to(ROOT))] = digest(p)
    for name in ("Package.swift", "Resources/Info.plist", "Resources/Library/manifest.json", "Resources/Library/compatibility.json"):
        files[name] = digest(ROOT / name)
    return dict(head=head,
                trackedPatchSHA256=hashlib.sha256(git("diff", "HEAD", "--binary")).hexdigest(),
                workingTree=git("status", "--porcelain=v1").decode().splitlines(), files=files)

def parse_result(suite, text, code):
    passed = len(re.findall(r"^PASS\b", text, re.M))
    failures = len(re.findall(r"^FAIL\b", text, re.M))
    pattern = r"DOMAIN_TEST_RESULT tests=(\d+) failures=(\d+)" if suite == "domain" else r"[A-Z_]+_RESULT checks=(\d+) failures=(\d+)"
    result = re.search(pattern, text)
    compatibility = re.search(r"COMPATIBILITY_RESULT (\d+)/(\d+) passed", text)
    if suite == "compatibility" and compatibility:
        passed, total = map(int, compatibility.groups()); failures = total - passed
    elif result:
        total, explicit = map(int, result.groups())
        failures = max(failures, explicit); passed = total - failures
    return dict(suite=suite, exitCode=code, passed=passed, failures=failures,
                status="passed" if code == 0 and passed > 0 and failures == 0 else "failed")

def write(run, index):
    temp = run / "verification-index.json.tmp"
    temp.write_text(json.dumps(index, ensure_ascii=False, indent=2) + "\n")
    temp.replace(run / "verification-index.json")

def execute(command, log, env):
    print("RUN " + " ".join(command) + " → " + str(log), flush=True)
    with log.open("w") as f:
        child = subprocess.Popen(command, cwd=ROOT, env=env, stdout=f, stderr=subprocess.STDOUT, start_new_session=True)
        try:
            return child.wait()
        except KeyboardInterrupt:
            os.killpg(child.pid, signal.SIGTERM)
            try:
                child.wait(timeout=5)
            except subprocess.TimeoutExpired:
                os.killpg(child.pid, signal.SIGKILL)
                child.wait()
            raise

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--suites", nargs="+", choices=SUITES)
    parser.add_argument("--core-only", action="store_true")
    parser.add_argument("--request-id", help="Optional UUID binding this run to its requesting attempt")
    args = parser.parse_args()
    if args.request_id:
        try: args.request_id = uuid.UUID(args.request_id).hex
        except ValueError: parser.error("request-id must be a UUID")
    suites = args.suites or os.environ.get("JHCUT_SUITES", " ".join(SUITES)).split()
    if not suites or any(s not in SUITES for s in suites) or len(set(suites)) != len(suites):
        parser.error("Suite names must be supported, nonempty and unique.")
    try:
        before = snapshot()
    except RuntimeError as error:
        parser.error(str(error))
    run = ROOT / "Artifacts/Runs" / (datetime.datetime.now().strftime("%Y%m%d-%H%M%S") + "-" + uuid.uuid4().hex[:8])
    run.mkdir(parents=True, exist_ok=False)
    build, outputs, logs = (run / n for n in ("Build", "Outputs", "Logs"))
    for p in (build, outputs, logs): p.mkdir()
    env = os.environ.copy()
    env.update(JHCUT_BUILD_DIR=str(build), JHCUT_COMPAT_BUILD=str(build),
               JHCUT_USE_EXISTING_CORE="1", JHCUT_COMPAT_USE_EXISTING_CORE="1",
               JHCUT_EVALUATION_OUTPUT=str(outputs / "evaluation"), JHCUT_REAL_COPY_REUSE="1")
    index = dict(schemaVersion=1, runID=run.name, startedAt=now(), status="running",
                 requestID=args.request_id,
                 source=before, appBuildRequested=not args.core_only, suites=[], binaries={}, inputs={},
                 countMeaning="Reported assertions include measurements; not an accuracy or coverage guarantee.")
    developer = env.get("JHCUT_DEVELOPER_DIR", "/Library/Developer/CommandLineTools")
    compiler = Path(developer) / "usr/bin/swiftc"
    if not compiler.exists(): compiler = Path(developer) / "Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc"
    index["environment"] = dict(os=subprocess.check_output(["sw_vers"], text=True).strip(),
                                arch=subprocess.check_output(["uname", "-m"], text=True).strip(),
                                compiler=subprocess.check_output([str(compiler), "--version"], text=True).strip(),
                                developerDir=developer, sdk=env.get("JHCUT_SDK", developer + "/SDKs/MacOSX26.5.sdk"))
    write(run, index)
    print("VERIFICATION_RUN=" + str(run), flush=True)
    try:
        copies = ROOT / "Artifacts/Upgrade-0.7/RealCopies"
        for p in sorted(copies.glob("*.mov")): index["inputs"][str(p.relative_to(ROOT))] = digest(p)
        for p in sorted((ROOT / "Artifacts/Stage15Copies").glob("*")):
            if p.is_file(): index["inputs"][str(p.relative_to(ROOT))] = digest(p)
        for p in sorted((ROOT / "Artifacts/Stage5Copies").glob("*")):
            if p.is_file(): index["inputs"][str(p.relative_to(ROOT))] = digest(p)
        model = Path.home() / "Library/Application Support/JHCutStudio/Models/ggml-base.bin"
        if model.exists(): index["inputs"]["localModels/ggml-base.bin"] = digest(model)
        code = execute(["bash", "Scripts/build-core.sh" if args.core_only else "Scripts/build.sh"], logs / "build.log", env)
        index["buildExitCode"] = code
        if code: raise RuntimeError("Current build failed; old binaries were not used.")
        for p in sorted(build.rglob("*")):
            if p.is_file() and (p.suffix in (".dylib", ".swiftmodule") or p.name in ("JHCutStudio", "JHCutValidate", "whisper-cli")):
                index["binaries"][str(p.relative_to(run))] = digest(p)
        code = execute(["bash", "Scripts/test-probe-workspace.sh"], logs / "workspace.log", env)
        index["infrastructure"] = parse_result("workspace", (logs / "workspace.log").read_text(), code)
        if index["infrastructure"]["status"] != "passed": raise RuntimeError("Workspace safety regression failed.")
        for suite in suites:
            env["JHCUT_REAL_COPY_REPORT_DIR"] = str(run / "DatasetVerification" / suite)
            log = logs / (suite + ".log"); start = now()
            code = execute(["bash", "Scripts/test-" + suite + ".sh", str(outputs / suite)], log, env)
            row = parse_result(suite, log.read_text(errors="replace"), code)
            row.update(startedAt=start, finishedAt=now(), log=str(log.relative_to(run)),
                       logSHA256=digest(log), coreSHA256=digest(build / "libJHCutCore.dylib"))
            index["suites"].append(row); write(run, index)
            print(f"{suite}: {row['status']} passed={row['passed']} failures={row['failures']} exit={code}", flush=True)
        after = snapshot()
        index["sourceAfter"] = after
        index["sourceUnchanged"] = before["head"] == after["head"] and before["files"] == after["files"]
        index["status"] = "passed" if index["sourceUnchanged"] and all(r["status"] == "passed" for r in index["suites"]) else "failed"
        index["reportedCheckTotal"] = sum(r["passed"] + r["failures"] for r in index["suites"])
        index["artifactHashes"] = {str(p.relative_to(run)): digest(p) for p in sorted(outputs.rglob("*")) if p.is_file()}
        for p in sorted(build.rglob("*")):
            if p.is_file() and (p.name.endswith("Probe") or p.name == "JHCutDomainTests"):
                index["binaries"][str(p.relative_to(run))] = digest(p)
        index["inputUnchanged"] = all(digest(ROOT / name) == value for name, value in index["inputs"].items() if not name.startswith("localModels/"))
        if not index["inputUnchanged"]: index["status"] = "failed"
    except (Exception, KeyboardInterrupt) as error:
        index.update(status="interrupted" if isinstance(error, KeyboardInterrupt) else "failed", error=str(error))
    finally:
        index["finishedAt"] = now(); write(run, index)
    failed = sum(r["status"] != "passed" for r in index["suites"])
    print(f"UPGRADE07_SUITES suites={len(index['suites'])} failed={failed} status={index['status']}", flush=True)
    return 0 if index["status"] == "passed" else 1

if __name__ == "__main__":
    sys.exit(main())
