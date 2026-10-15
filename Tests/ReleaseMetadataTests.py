#!/usr/bin/env python3
"""Credential-free package identity/binding/collision/privacy regressions."""
import copy
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest
import zipfile

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location('release_metadata', ROOT / 'Scripts/release_metadata.py')
metadata = importlib.util.module_from_spec(spec)
spec.loader.exec_module(metadata)
OUTPUT = Path(sys.argv[1]) if len(sys.argv) == 2 else ROOT / 'Artifacts/ReleaseMetadataTests'
FIXTURE = OUTPUT / 'FixtureExecutable'


class ReleaseMetadataTests(unittest.TestCase):
    def setUp(self):
        self.workspace = Path(tempfile.mkdtemp(prefix='case-', dir=OUTPUT))
        self.run = self.workspace / '20261015-123456-12345678'
        self.bundle = self.run / 'Build/JH CUT Studio.app'
        self.output = self.workspace / 'package'; self.output.mkdir()
        self.sources = self.workspace / 'notices'; self.sources.mkdir()
        self.info = dict(CFBundleShortVersionString='0.7.0', CFBundleVersion='8', CFBundleIdentifier='studio.jhcut.studio',
                         CFBundleExecutable='JHCutStudio', LSMinimumSystemVersion='14.0')
        for relative in ['Contents/MacOS/JHCutStudio', 'Contents/Frameworks/libJHCutCore.dylib', 'Contents/Resources/Whisper/whisper-cli']:
            target = self.bundle / relative; target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(FIXTURE, target)
        self.write_info()
        mapping = {'LICENSE': 'Legal/LICENSE.txt', 'THIRD_PARTY_NOTICES.md': 'Legal/THIRD_PARTY_NOTICES.md',
                   'Resources/Brand/README.md': 'Legal/BRAND.md', 'Resources/Whisper/THIRD-PARTY-NOTICES.txt': 'Whisper/THIRD-PARTY-NOTICES.txt',
                   'Resources/Library/CREDITS.md': 'Library/CREDITS.md'}
        for source, relative in mapping.items():
            for target in [self.sources / source, self.bundle / 'Contents/Resources' / relative]:
                target.parent.mkdir(parents=True, exist_ok=True); target.write_text('Complete fixture notice: ' + source + '\n')
        files = {'Resources/Info.plist': metadata.sha(self.bundle / 'Contents/Info.plist'),
                 'Resources/Whisper/whisper-cli': metadata.sha(self.bundle / 'Contents/Resources/Whisper/whisper-cli')}
        snapshot = dict(head='a' * 40, trackedPatchSHA256='b' * 64,
                        workingTree=[' M /Users/private-secret/caption.srt'], files=files)
        self.index = dict(schemaVersion=1, runID=self.run.name, status='passed', appBuildRequested=True, buildExitCode=0,
                          sourceUnchanged=True, inputUnchanged=True, finishedAt='2026-10-15T00:00:00Z',
                          infrastructure=dict(status='passed', exitCode=0, passed=10, failures=0),
                          suites=[dict(suite='domain', status='passed', exitCode=0, passed=55, failures=0)],
                          source=snapshot, sourceAfter=copy.deepcopy(snapshot), binaries={
                              'Build/JH CUT Studio.app/Contents/MacOS/JHCutStudio': metadata.sha(self.bundle / 'Contents/MacOS/JHCutStudio'),
                              'Build/JH CUT Studio.app/Contents/Frameworks/libJHCutCore.dylib': metadata.sha(self.bundle / 'Contents/Frameworks/libJHCutCore.dylib'),
                              'Build/JH CUT Studio.app/Contents/Resources/Whisper/whisper-cli': metadata.sha(self.bundle / 'Contents/Resources/Whisper/whisper-cli')})
        self.index_path = self.run / 'verification-index.json'; self.write_index()

    def write_index(self):
        self.index_path.write_text(json.dumps(self.index))

    def write_info(self):
        with (self.bundle / 'Contents/Info.plist').open('wb') as stream:
            plistlib.dump(self.info, stream)

    def binding(self):
        return metadata.verification_binding(self.bundle, self.index_path)

    def package(self):
        return metadata.package(self.bundle, self.output, self.binding(), 'review-only', self.sources)

    def test_review_archive_actual_bytes_and_privacy(self):
        before = metadata.bundle_tree(self.bundle)
        result = self.package()
        archive = self.output / result['archive']['file']
        self.assertIn('0.7.0-build-8-macOS-', archive.name)
        self.assertTrue(archive.name.endswith('-REVIEW-ONLY.zip'))
        self.assertEqual(metadata.sha(archive), result['archive']['sha256'])
        self.assertEqual(archive.stat().st_size, result['archive']['bytes'])
        self.assertEqual((self.output / 'SHA256SUMS').read_text(), f'{metadata.sha(archive)}  {archive.name}\n')
        with zipfile.ZipFile(archive) as contents:
            self.assertEqual(contents.read('JH CUT Studio.app/Contents/Info.plist'), (self.bundle / 'Contents/Info.plist').read_bytes())
        self.assertEqual(before, metadata.bundle_tree(self.bundle))
        public = (self.output / 'release-manifest.json').read_text() + (self.output / 'RELEASE-NOTES-DRAFT.md').read_text()
        self.assertNotIn('private-secret', public)
        self.assertNotIn(str(self.workspace), public)
        self.assertFalse(result['publicReleaseReady'])
        self.assertEqual(result['verification']['selectedSuites'][0]['passed'], 55)
        self.assertEqual(result['legalNotices']['status'], 'five-complete-notices-match-current-sources')
        self.assertEqual(result['packagedSourceEquivalence']['status'], 'exact-content-copy-of-input')
        self.assertIn('this target is not support acceptance', (self.output / 'RELEASE-NOTES-DRAFT.md').read_text())

    def test_dirty_base_head_never_claims_source_tag(self):
        binding = self.binding()
        self.assertTrue(binding['source']['workingTreeWasDirty'])
        self.assertFalse(binding['source']['cleanCommitBuildProven'])
        self.assertIsNone(binding['source']['publishedSourceTag'])
        self.assertEqual(binding['source']['baseCommit'], 'a' * 40)
        self.assertIn('Does not cover all Library bytes', binding['source']['snapshotScope'])

    def test_version_rejects_injection_and_noncanonical_numbers(self):
        for version in ['../1.0.0', '1.0.0\nfoo', '01.0.0', '1.0', 'v1.0.0', '1.0.0-beta']:
            self.info['CFBundleShortVersionString'] = version; self.write_info()
            with self.assertRaises(metadata.InvalidRelease): metadata.identity(self.bundle)
        self.assertEqual(list(self.output.iterdir()), [])

    def test_build_rejects_invalid_values(self):
        for build in ['0', '08', '-1', '8/other', 8, '8\n']:
            self.info['CFBundleVersion'] = build; self.write_info()
            with self.assertRaises(metadata.InvalidRelease): metadata.identity(self.bundle)

    def test_collision_preserves_existing_bytes(self):
        sentinel = self.output / 'release-manifest.json'; sentinel.write_text('retain original')
        with self.assertRaises(metadata.InvalidRelease): self.package()
        self.assertEqual(sentinel.read_text(), 'retain original')
        self.assertEqual(list(self.output.iterdir()), [sentinel])

    def test_archive_name_collision_preserves_existing_bytes(self):
        name = metadata.identity(self.bundle)['stem'] + '-REVIEW-ONLY.zip'
        sentinel = self.output / name; sentinel.write_bytes(b'old ZIP')
        with self.assertRaises(metadata.InvalidRelease): self.package()
        self.assertEqual(sentinel.read_bytes(), b'old ZIP')

    def test_failed_running_or_unstable_index_rejected(self):
        for key, value in [('status', 'running'), ('status', 'failed'), ('sourceUnchanged', False), ('inputUnchanged', False),
                           ('buildExitCode', 1), ('appBuildRequested', False)]:
            original = self.index[key]; self.index[key] = value; self.write_index()
            with self.assertRaises(metadata.InvalidRelease): self.binding()
            self.index[key] = original

    def test_failing_suite_rejected(self):
        self.index['suites'][0]['failures'] = 1; self.write_index()
        with self.assertRaises(metadata.InvalidRelease): self.binding()

    def test_malformed_index_objects_rejected(self):
        self.index_path.write_text('[]')
        with self.assertRaises(metadata.InvalidRelease): self.binding()
        self.index['suites'] = [None]; self.write_index()
        with self.assertRaises(metadata.InvalidRelease): self.binding()

    def test_source_snapshot_disagreement_rejected(self):
        self.index['sourceAfter']['files']['Resources/Info.plist'] = 'e' * 64; self.write_index()
        with self.assertRaises(metadata.InvalidRelease): self.binding()

    def test_tampered_binary_rejected(self):
        with (self.bundle / 'Contents/MacOS/JHCutStudio').open('ab') as stream: stream.write(b'tamper')
        with self.assertRaises(metadata.InvalidRelease): self.binding()

    def test_unrecorded_or_tampered_bundled_runtime_rejected(self):
        key = 'Build/JH CUT Studio.app/Contents/Resources/Whisper/whisper-cli'
        value = self.index['binaries'].pop(key); self.write_index()
        with self.assertRaises(metadata.InvalidRelease): self.binding()
        self.index['binaries'][key] = value; self.write_index()
        with (self.bundle / 'Contents/Resources/Whisper/whisper-cli').open('ab') as stream: stream.write(b'tamper')
        with self.assertRaises(metadata.InvalidRelease): self.binding()

    def test_index_from_another_app_rejected(self):
        other = self.workspace / 'Other.app'; shutil.copytree(self.bundle, other)
        with self.assertRaises(metadata.InvalidRelease): metadata.verification_binding(other, self.index_path)

    def test_same_identity_tampered_owned_copy_rejected_before_zip(self):
        other = self.workspace / 'Owned/JH CUT Studio.app'; shutil.copytree(self.bundle, other)
        self.assertEqual(metadata.identity(other), metadata.identity(self.bundle))
        with (other / 'Contents/MacOS/JHCutStudio').open('ab') as stream: stream.write(b'different executable')
        self.assertEqual(metadata.identity(other), metadata.identity(self.bundle))
        with self.assertRaises(metadata.InvalidRelease):
            metadata.package(other, self.output, self.binding(), 'review-only', self.sources, original_bundle=self.bundle)
        self.assertEqual(list(self.output.iterdir()), [])
        process = subprocess.run([sys.executable, '-B', str(ROOT / 'Scripts/release_metadata.py'), '--bundle', str(self.bundle),
                                  '--packaged-bundle', str(other), '--output', str(self.output), '--notice-root', str(self.sources),
                                  '--verification-index', str(self.index_path)], capture_output=True, text=True)
        self.assertNotEqual(process.returncode, 0)
        self.assertNotIn(str(self.workspace), process.stderr)
        self.assertEqual(list(self.output.iterdir()), [])

    def test_incomplete_copy_and_extra_payload_rejected(self):
        other = self.workspace / 'Owned/JH CUT Studio.app'; shutil.copytree(self.bundle, other)
        original = metadata.validate_owned_copy(self.bundle, other)
        self.assertEqual(original, metadata.bundle_tree(self.bundle))
        extra = other / 'Contents/Resources/unexpected-payload'; extra.write_text('extra')
        with self.assertRaises(metadata.InvalidRelease): metadata.validate_owned_copy(self.bundle, other)
        extra.unlink()
        (other / 'Contents/Resources/Whisper/whisper-cli').unlink()
        with self.assertRaises(metadata.InvalidRelease): metadata.validate_owned_copy(self.bundle, other)

    def test_stale_legal_notice_rejected_before_output(self):
        (self.sources / 'LICENSE').write_text('new complete notice')
        with self.assertRaises(metadata.InvalidRelease): self.package()
        self.assertEqual(list(self.output.iterdir()), [])

    def test_unbound_prepare_is_explicit_and_notarized_mode_refuses_it(self):
        unbound = metadata.verification_binding(self.bundle, None)
        result = metadata.package(self.bundle, self.output, unbound, 'review-only', self.sources)
        self.assertEqual(result['verification']['status'], 'not-provided')
        self.assertEqual(result['distributionChecks']['notarization'], 'not-performed')
        self.assertFalse(result['publicReleaseReady'])
        with self.assertRaises(metadata.InvalidRelease):
            metadata.package(self.bundle, self.workspace, unbound, 'notarized', self.sources)

    def test_nested_output_rejected_without_mutating_app(self):
        # Existing output directory inside the bundle is rejected before ZIP creation.
        nested = self.bundle / 'Contents/Output'; nested.mkdir()
        before = metadata.bundle_tree(self.bundle)
        with self.assertRaises(metadata.InvalidRelease):
            metadata.package(self.bundle, nested, self.binding(), 'review-only', self.sources)
        self.assertEqual(before, metadata.bundle_tree(self.bundle))


if __name__ == '__main__':
    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    OUTPUT.mkdir(exist_ok=False)
    subprocess.run(['/usr/bin/xcrun', '--sdk', 'macosx', 'clang', '-x', 'c', '-', '-o', str(FIXTURE)],
                   input='int main(void) { return 0; }\n', text=True, check=True)
    suite = unittest.defaultTestLoader.loadTestsFromTestCase(ReleaseMetadataTests)
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    failures = len(result.failures) + len(result.errors)
    report = dict(schemaVersion=1, tests=result.testsRun, failures=failures,
                  scope='Generated minimal bundles with real Mach-O bytes; credential-free metadata, ZIP, binding and immutable-input checks. No Apple submission or UI launch.')
    with (OUTPUT / 'checks.json').open('x') as stream: json.dump(report, stream, indent=2); stream.write('\n')
    print(f'RELEASE_METADATA_RESULT checks={result.testsRun} failures={failures}')
    sys.exit(0 if result.wasSuccessful() else 1)
