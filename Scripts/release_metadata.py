#!/usr/bin/env python3
"""Local package identity/checksums. No signing, credentials, launch or upload.

The verification binding covers the indexed app/core/runtime/Info.plist bytes;
it is not a source tag, reproducible-build attestation, or complete coverage claim.
"""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import stat
import subprocess
import sys


class InvalidRelease(ValueError):
    pass


def require(condition, message):
    if not condition:
        raise InvalidRelease(message)


def sha(path):
    def stamp(value):
        return value.st_dev, value.st_ino, value.st_mode, value.st_size, value.st_mtime_ns, value.st_ctime_ns
    before = path.lstat()
    require(stat.S_ISREG(before.st_mode), "Expected regular, nonsymlink release input")
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    try:
        require(stamp(os.fstat(descriptor)) == stamp(before), 'Release input changed before hashing')
        result = hashlib.sha256()
        for block in iter(lambda: os.read(descriptor, 1024 * 1024), b''):
            result.update(block)
        require(stamp(os.fstat(descriptor)) == stamp(before) == stamp(path.lstat()), 'Release input changed while hashing')
        return result.hexdigest()
    finally:
        os.close(descriptor)


def canonical_hash(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(',', ':'), ensure_ascii=False).encode()).hexdigest()


def identity(bundle):
    with (bundle / 'Contents/Info.plist').open('rb') as stream:
        info = plistlib.load(stream)
    require(isinstance(info, dict), 'Invalid bundle metadata')
    version, build = info.get('CFBundleShortVersionString'), info.get('CFBundleVersion')
    require(isinstance(version, str) and re.fullmatch(r'(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)', version),
            "Version must be a numeric major.minor.patch")
    require(isinstance(build, str) and re.fullmatch(r'[1-9][0-9]*', build), "Build must be a positive decimal integer")
    require(info.get('CFBundleExecutable') == 'JHCutStudio', "Unexpected app executable")
    identifier = info.get('CFBundleIdentifier')
    require(isinstance(identifier, str) and re.fullmatch(r'[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+', identifier),
            "Invalid bundle identifier")
    minimum = info.get('LSMinimumSystemVersion')
    require(isinstance(minimum, str) and re.fullmatch(r'[0-9]+(?:\.[0-9]+){1,2}', minimum), "Invalid minimum macOS version")
    executable = bundle / 'Contents/MacOS/JHCutStudio'
    architectures = subprocess.check_output(['/usr/bin/lipo', '-archs', str(executable)], text=True).strip().split()
    require(architectures and len(architectures) == len(set(architectures)) and set(architectures) <= {'arm64', 'x86_64'},
            "Only arm64/x86_64 package architecture names are supported")
    architectures.sort()
    arch = 'universal' if len(architectures) == 2 else architectures[0]
    return dict(version=version, build=build, bundleIdentifier=identifier, minimumMacOS=minimum,
                architectures=architectures, stem=f'JH-CUT-Studio-{version}-build-{build}-macOS-{arch}')


def verification_binding(bundle, index_path):
    if index_path is None:
        return dict(status='not-provided', source=None)
    require(not index_path.is_symlink(), "Verification index must not be a symlink")
    index_digest = sha(index_path)
    with index_path.open() as stream:
        index = json.load(stream)
    require(isinstance(index, dict), 'Invalid verification index object')
    run = index_path.parent.resolve()
    require(index_path.name == 'verification-index.json' and bundle.resolve() == run / 'Build/JH CUT Studio.app',
            "Verification index does not own this exact input app")
    require(index.get('schemaVersion') == 1 and index.get('runID') == run.name and
            re.fullmatch(r'[0-9]{8}-[0-9]{6}-[0-9a-f]{8}', run.name), "Invalid verification run identity")
    require(index.get('status') == 'passed' and index.get('appBuildRequested') is True and
            index.get('buildExitCode') == 0 and index.get('sourceUnchanged') is True and index.get('inputUnchanged') is True and
            isinstance(index.get('finishedAt'), str), "Verification must be terminal, passing and unchanged")
    infrastructure = index.get('infrastructure', {})
    require(isinstance(infrastructure, dict), 'Invalid workspace result')
    require(infrastructure.get('status') == 'passed' and infrastructure.get('exitCode') == 0 and
            infrastructure.get('failures') == 0 and infrastructure.get('passed', 0) > 0, "Workspace infrastructure did not pass")
    suites = index.get('suites')
    require(isinstance(suites, list) and bool(suites), "Verification contains no suites")
    selected = []
    for row in suites:
        require(isinstance(row, dict), 'Invalid selected suite object')
        name = row.get('suite')
        require(isinstance(name, str) and re.fullmatch(r'[a-z][a-z0-9-]{0,63}', name) and name not in selected and
                row.get('status') == 'passed' and row.get('exitCode') == 0 and row.get('failures') == 0 and
                isinstance(row.get('passed'), int) and row['passed'] > 0, "Invalid or failing selected suite")
        selected.append(name)
    source, after = index.get('source', {}), index.get('sourceAfter', {})
    require(isinstance(source, dict) and isinstance(after, dict) and isinstance(index.get('binaries'), dict), 'Invalid source or binary map')
    files, after_files = source.get('files'), after.get('files')
    require(isinstance(files, dict) and bool(files) and files == after_files and source.get('head') == after.get('head'),
            "Verification source snapshots disagree")
    require(all(isinstance(k, str) and isinstance(v, str) and re.fullmatch(r'[0-9a-f]{64}', v) for k, v in files.items()),
            "Invalid source hash map")
    head, patch = source.get('head'), source.get('trackedPatchSHA256')
    require(isinstance(head, str) and re.fullmatch(r'[0-9a-f]{40,64}', head) and
            isinstance(patch, str) and re.fullmatch(r'[0-9a-f]{64}', patch) and isinstance(source.get('workingTree'), list),
            "Invalid source snapshot identity")
    expected = {
        'Contents/MacOS/JHCutStudio': index.get('binaries', {}).get('Build/JH CUT Studio.app/Contents/MacOS/JHCutStudio'),
        'Contents/Frameworks/libJHCutCore.dylib': index.get('binaries', {}).get('Build/JH CUT Studio.app/Contents/Frameworks/libJHCutCore.dylib'),
        # build.sh re-signs the bundled recogniser. Its signed bytes must be
        # recorded by the run; the unmodified source runtime hash is different.
        'Contents/Resources/Whisper/whisper-cli': index.get('binaries', {}).get('Build/JH CUT Studio.app/Contents/Resources/Whisper/whisper-cli'),
        'Contents/Info.plist': files.get('Resources/Info.plist'),
    }
    for relative, digest in expected.items():
        require(isinstance(digest, str) and re.fullmatch(r'[0-9a-f]{64}', digest) and sha(bundle / relative) == digest,
                "Input app/core/runtime/Info.plist does not match the verification index")
    require(sha(index_path) == index_digest, "Verification index changed during validation")
    return dict(status='matched-selected-run', runID=run.name, indexSHA256=index_digest,
                selectedSuites=[dict(suite=row['suite'], status=row['status'], passed=row['passed'], failures=row['failures'], exitCode=row['exitCode']) for row in suites],
                bindingScope='Input app executable, core library, Whisper runtime and Info.plist bytes; selected suites only.',
                source=dict(kind='verification-working-tree-snapshot', baseCommit=head,
                            workingTreeWasDirty=bool(source['workingTree']), trackedPatchSHA256=patch,
                            sourceFilesSHA256=canonical_hash(files), sourceFileCount=len(files),
                            snapshotScope='Runner source.files selected code/scripts/tests/References, Resources/Whisper and four selected resource/package files. Does not cover all Library bytes, root LICENSE or THIRD_PARTY_NOTICES.md.',
                            cleanCommitBuildProven=False, publishedSourceTag=None))


def legal_checks(bundle, notice_root):
    mapping = {'LICENSE': 'Legal/LICENSE.txt', 'THIRD_PARTY_NOTICES.md': 'Legal/THIRD_PARTY_NOTICES.md',
               'Resources/Brand/README.md': 'Legal/BRAND.md',
               'Resources/Whisper/THIRD-PARTY-NOTICES.txt': 'Whisper/THIRD-PARTY-NOTICES.txt',
               'Resources/Library/CREDITS.md': 'Library/CREDITS.md'}
    hashes = {}
    for source, relative in mapping.items():
        expected, actual = notice_root / source, bundle / 'Contents/Resources' / relative
        require(expected.stat().st_size > 0 and sha(expected) == sha(actual), 'Missing or stale complete license notice')
        hashes[relative] = sha(actual)
    return dict(status='five-complete-notices-match-current-sources', packagedNoticesSHA256=hashes,
                scope='Complete bytes of these five notices; not a new audit of every asset or copyright claim.')


def bundle_tree(bundle):
    records = {}
    for path in sorted(bundle.rglob('*')):
        require(not path.is_symlink() and (path.is_file() or path.is_dir()), 'Unsupported bundle node')
        if path.is_file():
            records[path.relative_to(bundle).as_posix()] = sha(path)
    return dict(sha256=canonical_hash(records), files=len(records), algorithm='SHA-256 of canonical relative-path-to-file-SHA256 map')


def signed_checks(bundle, result_path):
    require(result_path is not None, "Notarized mode requires the captured notarytool JSON result")
    with result_path.open() as stream:
        result = json.load(stream)
    require(isinstance(result, dict), 'Invalid notarization result')
    require(result.get('status') == 'Accepted' and isinstance(result.get('id'), str) and
            re.fullmatch(r'[0-9a-fA-F-]{36}', result['id']), "Notarization was not accepted")
    subprocess.run(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(bundle)], check=True)
    teams = []
    for part in [bundle, bundle / 'Contents/Frameworks/libJHCutCore.dylib', bundle / 'Contents/Resources/Whisper/whisper-cli']:
        process = subprocess.run(['/usr/bin/codesign', '-d', '-v', str(part)], capture_output=True, text=True, check=True)
        details = process.stdout + process.stderr
        match = re.search(r'^TeamIdentifier=([A-Z0-9]{10})$', details, re.M)
        require(match is not None and re.search(r'^Authority=Developer ID Application:', details, re.M),
                "Package does not carry a Developer ID Application signature")
        teams.append(match.group(1))
    require(len(set(teams)) == 1, "App, core and recogniser Team IDs differ")
    subprocess.run(['/usr/bin/xcrun', 'stapler', 'validate', str(bundle)], check=True)
    subprocess.run(['/usr/sbin/spctl', '--assess', '--type', 'execute', str(bundle)], check=True)
    return dict(developerID='verified', teamIdentifier=teams[0], notarization='accepted',
                notarizationID=result['id'], stapling='validated', gatekeeper='accepted-on-packaging-Mac',
                otherMacInstall='not-verified', cleanSourceTag='not-verified')


def validate_owned_copy(original, owned):
    original_tree = bundle_tree(original)
    require(bundle_tree(owned) == original_tree, 'Owned app is not an exact content copy of the immutable input')
    return original_tree


def package(bundle, output, verification, mode, notice_root, notary_result=None, original_bundle=None):
    info = identity(bundle)
    legal = legal_checks(bundle, notice_root)
    require(mode in ('review-only', 'notarized'), "Invalid package mode")
    if mode == 'notarized':
        require(verification.get('status') == 'matched-selected-run', "Notarized packaging requires a matching verification run")
        checks = signed_checks(bundle, notary_result)
    else:
        checks = dict(developerID='not-verified', notarization='not-performed', stapling='not-verified',
                      gatekeeper='not-verified', otherMacInstall='not-verified', cleanSourceTag='not-verified')
    output = output.resolve()
    require(output.is_dir() and output != bundle.resolve() and bundle.resolve() not in output.parents,
            "Package output must be an existing directory outside the app")
    suffix = '-REVIEW-ONLY' if mode == 'review-only' else ''
    archive_name = info.pop('stem') + suffix + '.zip'
    files = [archive_name, 'SHA256SUMS', 'release-manifest.json', 'RELEASE-NOTES-DRAFT.md']
    require(not any((output / name).exists() or (output / name).is_symlink() for name in files),
            "Refusing to overwrite an existing release artifact")
    tree_before = bundle_tree(bundle)
    original_bundle = original_bundle or bundle
    if mode == 'review-only':
        # Identity equality alone cannot establish that this is the tested app.
        # Compare all file paths/bytes immediately before creating the archive.
        require(validate_owned_copy(original_bundle, bundle) == tree_before,
                'Owned app changed before ZIP preparation')
    # Reserve the ZIP name exclusively before ditto writes our owned file.
    archive = output / archive_name
    with archive.open('xb'):
        pass
    try:
        subprocess.run(['/usr/bin/ditto', '-c', '-k', '--keepParent', str(bundle), str(archive)], check=True)
        require(bundle_tree(bundle) == tree_before, 'Packaged app changed during ZIP preparation')
        if mode == 'review-only':
            require(bundle_tree(original_bundle) == tree_before, 'Immutable input changed during ZIP preparation')
        archive_hash, size = sha(archive), archive.stat().st_size
        require(size > 0, "Package archive is empty")
        components = {relative: sha(bundle / relative) for relative in
                      ('Contents/MacOS/JHCutStudio', 'Contents/Frameworks/libJHCutCore.dylib',
                       'Contents/Resources/Whisper/whisper-cli', 'Contents/Info.plist')}
        manifest = dict(schemaVersion=1, product='JH CUT Studio', createdAt=datetime.datetime.now(datetime.timezone.utc).isoformat(),
                        artifactStage=mode, publicReleaseReady=False, app=info,
                        archive=dict(file=archive_name, bytes=size, sha256=archive_hash),
                        packagedComponentsSHA256=components, packagedBundleContent=tree_before,
                        verification=verification, legalNotices=legal, distributionChecks=checks,
                        packagedSourceEquivalence=(dict(status='exact-content-copy-of-input',
                            scope='Complete relative-file-path and SHA256 map equals the immutable input before ZIP creation and remains unchanged after ZIP creation.')
                            if mode == 'review-only' else dict(status='not-verified',
                            scope='Signatures changed on the notarized copy. The verification binding identifies the original input app, not source equivalence of this final signed copy. Packaged component hashes identify final bytes only.')),
                        remainingReleaseGates=['Published source tag/commit matching the built working tree',
                                               'Install, update and export acceptance on another supported Mac'],
                        privacy='This manifest omits media paths, subtitle contents, credentials, and local absolute paths. This statement does not certify the packaged binaries or past Git history.')
        if mode == 'review-only':
            manifest['remainingReleaseGates'].insert(0, 'Developer ID signing, Apple notarization, stapling and Gatekeeper verification')
        with (output / 'SHA256SUMS').open('x') as stream:
            stream.write(f'{archive_hash}  {archive_name}\n')
        with (output / 'release-manifest.json').open('x') as stream:
            json.dump(manifest, stream, ensure_ascii=False, indent=2, sort_keys=True); stream.write('\n')
        state = 'LOCAL REVIEW ONLY — not signed or notarized by this preparation.' if mode == 'review-only' else \
            'NOTARIZED PACKAGE — other-Mac installation and published source identity are still unverified.'
        with (output / 'RELEASE-NOTES-DRAFT.md').open('x') as stream:
            stream.write(f'# JH CUT Studio {info["version"]} (build {info["build"]}) — draft\n\n{state}\n\n'
                         f'- Deployment target: macOS {info["minimumMacOS"]}; package architecture: {", ".join(info["architectures"])}. '
                         'Tested OS/CPU: see release readiness documentation; this target is not support acceptance.\n'
                         f'- Archive: `{archive_name}`\n- Size: {size} bytes\n- SHA-256: `{archive_hash}`\n'
                         f'- Verification binding: {verification["status"]}; this does not imply all tests or accuracy evaluation passed.\n'
                         '- The source is a local working-tree snapshot when a verification run is supplied; its base commit is not the built source tag.\n'
                         '- Before public release: publish the exact source revision, complete the remaining distribution gates, '
                         'and write reviewed feature changes and known issues.\n'
                         '- 한국어: 로컬 검토용 예비 자료입니다. 최종 배포 승인·다른 Mac 설치 검증·공개 소스 일치 검증은 별도입니다.\n')
        return manifest
    except BaseException:
        # Preserve any incomplete owned outputs as failure evidence; never replace them on retry.
        raise


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--bundle', required=True, type=Path)
    parser.add_argument('--verification-index', type=Path)
    parser.add_argument('--output', type=Path)
    parser.add_argument('--packaged-bundle', type=Path, help='Owned copy to archive; --bundle remains the immutable indexed original')
    parser.add_argument('--notice-root', type=Path, default=Path(__file__).resolve().parent.parent)
    parser.add_argument('--mode', choices=('review-only', 'notarized'), default='review-only')
    parser.add_argument('--notary-result', type=Path)
    args = parser.parse_args()
    try:
        info = identity(args.bundle)
        binding = verification_binding(args.bundle, args.verification_index)
        legal_checks(args.bundle, args.notice_root)
        owned = args.packaged_bundle or args.bundle
        require(identity(owned) == info, 'Owned app identity differs from immutable input')
        if args.packaged_bundle is not None and args.mode == 'review-only':
            validate_owned_copy(args.bundle, owned)
        if args.output is None:
            print(json.dumps(dict(app=info, verification=binding), sort_keys=True))
        else:
            result = package(owned, args.output, binding, args.mode, args.notice_root, args.notary_result, args.bundle)
            print(f'PACKAGE_METADATA stage={result["artifactStage"]} bytes={result["archive"]["bytes"]} sha256={result["archive"]["sha256"]}')
    except (InvalidRelease, OSError, ValueError, subprocess.SubprocessError, KeyError, TypeError):
        print('Release metadata validation failed; no credentials or private input details are printed.', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
