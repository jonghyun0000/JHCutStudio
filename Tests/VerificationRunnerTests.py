import importlib.util
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path
import unittest

path = Path(__file__).resolve().parents[1] / "Scripts/verification-run.py"
spec = importlib.util.spec_from_file_location("verification_runner", path)
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)


class VerificationRunnerTests(unittest.TestCase):
    def test_domain_counts_xctest_assertions(self):
        row = runner.parse_result("domain", "DOMAIN_TEST_RESULT tests=55 failures=0", 0)
        self.assertEqual((row["passed"], row["failures"], row["status"]), (55, 0, "passed"))

    def test_compatibility_counts_custom_summary(self):
        row = runner.parse_result("compatibility", "COMPATIBILITY_RESULT 45/46 passed", 1)
        self.assertEqual((row["passed"], row["failures"], row["status"]), (45, 1, "failed"))

    def test_fail_lines_cannot_be_hidden_by_success_summary(self):
        row = runner.parse_result("speedtools", "FAIL bad frame\nSPEEDTOOLS_RESULT checks=29 failures=0", 0)
        self.assertEqual(row["status"], "failed")

    def test_nonzero_exit_cannot_report_passed(self):
        self.assertEqual(runner.parse_result("connected", "PASS cue survives", 1)["status"], "failed")

    def test_incomplete_or_empty_execution_fails(self):
        self.assertEqual(runner.parse_result("checkpoint", "Starting checkpoint test", 0)["status"], "failed")

    def test_plain_pass_format_supported(self):
        self.assertEqual(runner.parse_result("connected", "PASS first\nPASS second", 0)["passed"], 2)


class VerificationGitOwnershipTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="JHCut-Verification-Git-Fixture-")
        self.addCleanup(self.temporary.cleanup)
        self.base = Path(self.temporary.name)
        self.env = os.environ.copy()
        for key in ("GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_COMMON_DIR", "GIT_OBJECT_DIRECTORY", "GIT_ALTERNATE_OBJECT_DIRECTORIES", "GIT_CEILING_DIRECTORIES"):
            self.env.pop(key, None)
        self.env.update(GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=os.devnull)

    def git(self, directory, *arguments):
        # Artificial identity applies only to each command in our newly created temporary repos.
        return subprocess.check_output(["git", "-c", "core.hooksPath=" + os.devnull,
            "-c", "commit.gpgsign=false", "-c", "user.name=JHCut Test Fixture",
            "-c", "user.email=jhcut-test-fixture@example.invalid", *arguments],
            cwd=directory, env=self.env, stderr=subprocess.PIPE).decode().strip()

    def initialize(self, directory, commit=False):
        directory.mkdir(parents=True, exist_ok=True)
        self.git(directory, "init", "--quiet")
        if commit:
            self.git(directory, "commit", "--quiet", "--allow-empty", "-m", "Artificial verification fixture")

    def project(self, name="Source With Space"):
        directory = self.base / name
        (directory / "Scripts").mkdir(parents=True)
        shutil.copy2(path, directory / "Scripts/verification-run.py")
        for relative, text in {
            "Package.swift": "// Fixture only; never compiled.\n",
            "Resources/Info.plist": "fixture",
            "Resources/Library/manifest.json": "{}",
            "Resources/Library/compatibility.json": "{}",
            "Scripts/build-core.sh": "#!/bin/sh\nprintf 'fixture build reached' > fixture-build-reached.txt\nexit 73\n",
            "FixtureTools/usr/bin/swiftc": "#!/bin/sh\nprintf 'Fixture compiler only\\n'\n",
            "Artifacts/ExistingEvidence/sentinel.txt": "preserve exact fixture evidence\n",
        }.items():
            target = directory / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(text)
        (directory / "FixtureTools/usr/bin/swiftc").chmod(0o755)
        return directory

    def invoke(self, directory):
        env = dict(self.env, JHCUT_DEVELOPER_DIR=str(directory / "FixtureTools"))
        result = subprocess.run([sys.executable, "-B", "Scripts/verification-run.py", "--core-only", "--suites", "domain"],
            cwd=directory, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=30)
        report_root = os.environ.get("JHCUT_VERIFICATION_GIT_TEST_REPORT_DIR")
        if report_root:
            report = Path(report_root)
            report.mkdir(parents=True, exist_ok=True)
            run_paths = sorted((directory / "Artifacts/Runs").glob("*")) if (directory / "Artifacts/Runs").exists() else []
            index_heads = []
            for run in run_paths:
                index = run / "verification-index.json"
                if index.exists(): index_heads.append(json.loads(index.read_text()).get("source", {}).get("head"))
            observation = dict(exitCode=result.returncode, stdout=result.stdout, stderr=result.stderr,
                fixture=str(directory), runDirectories=[str(x) for x in run_paths],
                indexHeads=index_heads, buildStubReached=(directory / "fixture-build-reached.txt").exists(),
                sentinel=(directory / "Artifacts/ExistingEvidence/sentinel.txt").read_text())
            (report / (self._testMethodName + ".json")).write_text(json.dumps(observation, indent=2) + "\n")
        return result

    def assert_preflight_refused(self, directory, result, message):
        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertIn(message, result.stderr)
        self.assertNotIn("Traceback", result.stderr)
        self.assertFalse((directory / "Artifacts/Runs").exists(), "Preflight created a verification run")
        self.assertFalse((directory / "fixture-build-reached.txt").exists(), "Preflight invoked the fixture build")
        self.assertEqual((directory / "Artifacts/ExistingEvidence/sentinel.txt").read_text(), "preserve exact fixture evidence\n")

    def test_archive_without_git_stops_before_artifacts_or_build(self):
        directory = self.project()
        self.assert_preflight_refused(directory, self.invoke(directory), "project-owned Git checkout")

    def test_repository_without_head_stops_before_artifacts_or_build(self):
        directory = self.project()
        self.initialize(directory)
        self.assert_preflight_refused(directory, self.invoke(directory), "no valid HEAD commit")

    def test_enclosing_repository_head_is_never_used_for_source_archive(self):
        self.initialize(self.base, commit=True)
        parent_head = self.git(self.base, "rev-parse", "HEAD")
        directory = self.project()
        result = self.invoke(directory)
        self.assert_preflight_refused(directory, result, "enclosing Git repository")
        self.assertEqual(self.git(self.base, "rev-parse", "HEAD"), parent_head)

    def test_owned_dirty_repository_without_remote_retains_its_head_and_diff(self):
        directory = self.project()
        self.initialize(directory)
        (directory / "tracked.txt").write_text("original fixture\n")
        self.git(directory, "add", "tracked.txt")
        self.git(directory, "commit", "--quiet", "-m", "Artificial owned source fixture")
        head = self.git(directory, "rev-parse", "HEAD")
        (directory / "tracked.txt").write_text("dirty fixture edit\n")
        expected_patch = subprocess.check_output(["git", "diff", "HEAD", "--binary"], cwd=directory, env=self.env)
        self.assertEqual(self.git(directory, "remote"), "")
        result = self.invoke(directory)
        # Our failing stub intentionally ends the run before any real compiler or suite can run.
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertTrue((directory / "fixture-build-reached.txt").exists())
        runs = list((directory / "Artifacts/Runs").iterdir())
        self.assertEqual(len(runs), 1)
        index = json.loads((runs[0] / "verification-index.json").read_text())
        self.assertEqual(index["status"], "failed")
        self.assertEqual(index["buildExitCode"], 73)
        self.assertEqual(index["source"]["head"], head)
        self.assertTrue(index["source"]["workingTree"])
        self.assertEqual(index["source"]["trackedPatchSHA256"], hashlib.sha256(expected_patch).hexdigest())
        self.assertEqual(self.git(directory, "rev-parse", "HEAD"), head)
        self.assertEqual(self.git(directory, "remote"), "")
        self.assertEqual((directory / "tracked.txt").read_text(), "dirty fixture edit\n")
        self.assertEqual((directory / "Artifacts/ExistingEvidence/sentinel.txt").read_text(), "preserve exact fixture evidence\n")


if __name__ == "__main__":
    unittest.main()
