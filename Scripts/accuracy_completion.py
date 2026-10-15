"""Maintained completion gate. Synthetic tests are never human reference evidence."""
import argparse
import datetime as dt
import hashlib
import importlib.util
import json
import math
import os
from pathlib import Path
import re
import signal
import stat
import subprocess
import sys
import uuid

POLICY = 'human-source-reference-v1-nonoverlap-nearest-rank-p95'
MODEL_SHA = '60ed5bc3dd14eea856493d334349b405782ddcaf0028d4b5df4088345fba2efe'
MODES = ('full', 'skip-conservative', 'skip-fast')
BINDING = ('segmentID', 'sourceFile', 'sourceSHA256', 'sourceStart', 'sourceEnd')
EXIT = {'verified': 0, 'ready': 0, 'awaiting_human_reference': 2,
        'invalid_input': 3, 'failed': 1, 'unscored': 1, 'interrupted': 130}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def finite(value, minimum=0, maximum=None):
    return (type(value) in (int, float) and math.isfinite(value) and value >= minimum
            and (maximum is None or value <= maximum))


def sha(data):
    return hashlib.sha256(data).hexdigest()


def canonical_sha(value):
    # Swift JSONEncoder.sortedKeys: these identity fields are ASCII strings/integers.
    return sha(json.dumps(value, sort_keys=True, separators=(',', ':'), ensure_ascii=False).encode())


def safe_path(path):
    path = Path(os.path.abspath(path))
    for component in (path, *path.parents):
        # Allow macOS system aliases, but refuse user-controlled symlink paths.
        if component.is_symlink() and str(component) not in ('/var', '/tmp'):
            raise ValueError('Symlink path refused: ' + str(component))
    return path.resolve()


def stable_read(path, maximum=None):
    path = safe_path(path)
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        before = os.fstat(fd)
        require(stat.S_ISREG(before.st_mode), 'Not a regular file: ' + str(path))
        require(maximum is None or before.st_size <= maximum, 'File too large: ' + str(path))
        h, chunks, total = hashlib.sha256(), [], 0
        while True:
            block = os.read(fd, 1024 * 1024)
            if not block:
                break
            total += len(block)
            require(maximum is None or total <= maximum, 'File grew beyond limit: ' + str(path))
            h.update(block)
            if maximum is not None:
                chunks.append(block)
        after = os.fstat(fd)
        current = path.stat(follow_symlinks=False)
        signature = lambda s: (s.st_dev, s.st_ino, s.st_size, s.st_mtime_ns, s.st_ctime_ns)
        require(signature(before) == signature(after) == signature(current) and total == before.st_size,
                'File changed while reading: ' + str(path))
        return b''.join(chunks) if maximum is not None else None, h.hexdigest()
    finally:
        os.close(fd)


def reject_duplicates(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, 'Duplicate JSON key: ' + key)
        result[key] = value
    return result


def read_json(path, maximum=16_000_000):
    raw, digest = stable_read(path, maximum)
    value = json.loads(raw, object_pairs_hook=reject_duplicates,
                       parse_constant=lambda value: require(False, 'Nonfinite JSON: ' + value))
    return value, digest


def valid_uuid(value):
    require(isinstance(value, str), 'UUID must be a string')
    return str(uuid.UUID(value))


def validate_reference(ref, scope):
    """Pure structural preflight. Swift remains authoritative for text/metrics."""
    require(isinstance(ref, dict), 'Reference must be an object')
    require(type(ref.get('schemaVersion')) is int and ref['schemaVersion'] == 1, 'Reference schema')
    for key in BINDING:
        require(ref.get(key) == scope[key], 'Reference source/range mismatch: ' + key)
    revision = valid_uuid(ref.get('revisionID'))
    if ref.get('parentRevisionID') is not None:
        require(valid_uuid(ref['parentRevisionID']) != revision, 'Self parent revision')
    require(ref.get('overlapPolicy') == 'exclude', 'Overlap policy')
    require(ref.get('language') in ('ko', 'ja', 'en', 'und'), 'Reference language')
    require(ref.get('reviewMethod') in ('pending', 'human-listened'), 'Review method')
    for flag in ('textReviewed', 'timingReviewed', 'activityReviewed', 'draftExposure'):
        require(type(ref.get(flag)) is bool, 'Review flag: ' + flag)
    reviewer = ref.get('reviewer')
    require(reviewer is None or isinstance(reviewer, str) and len(reviewer.encode()) <= 256, 'Reviewer')
    reviewed = ref.get('reviewedAt')
    if reviewed is not None:
        require(isinstance(reviewed, str) and re.fullmatch(r'\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ', reviewed),
                'Review date must use Swift ISO8601 UTC seconds')
        dt.datetime.fromisoformat(reviewed.replace('Z', '+00:00'))
    human = (ref['textReviewed'] and ref['activityReviewed'] and ref['reviewMethod'] == 'human-listened'
             and isinstance(reviewer, str) and bool(reviewer.strip()) and reviewed is not None)
    require(not any(ref[k] for k in ('textReviewed', 'timingReviewed', 'activityReviewed')) or human,
            'Incomplete human review provenance')
    require(not ref['timingReviewed'] or ref['textReviewed'] and ref['activityReviewed'], 'Timing review flags')
    spans = ref.get('spans')
    require(isinstance(spans, list) and 1 <= len(spans) <= 20_000, 'Reference span count')
    cursor, ids, total, speech = scope['sourceStart'], set(), 0, False
    for span in spans:
        require(isinstance(span, dict), 'Reference span object')
        sid = valid_uuid(span.get('id'))
        require(sid not in ids, 'Duplicate span ID'); ids.add(sid)
        start, end = span.get('start'), span.get('end')
        require(finite(start) and finite(end) and abs(start - cursor) < 1e-6
                and end > start and end <= scope['sourceEnd'] + 1e-6, 'Span gap/overlap/range')
        cursor = end
        text, reason, conditions = span.get('text'), span.get('reason'), span.get('conditions')
        require(isinstance(text, str) and isinstance(reason, str), 'Span text/reason')
        amount = len(text.encode()) + len(reason.encode()); total += amount
        require(amount <= 65_536 and total <= 2_000_000, 'Span text size')
        require(isinstance(conditions, list) and 1 <= len(conditions) <= 6
                and all(isinstance(c, str) for c in conditions) and len(set(conditions)) == len(conditions)
                and set(conditions) <= {'quiet', 'backgroundMusic', 'noise', 'shortResponse', 'overlap', 'unknown'},
                'Span conditions')
        kind = span.get('kind')
        require(kind in ('speech', 'nonspeech', 'excluded'), 'Span kind')
        if kind == 'speech':
            speech = True
            require(any(c.isalnum() for c in text) and 'overlap' not in conditions
                    and ref['language'] in ('ko', 'ja', 'en'), 'Speech text/language/overlap')
        else:
            require(not text.strip() and (kind != 'excluded' or reason.strip()), 'Nonspeech/exclusion text')
            require(not (human and kind == 'excluded' and reason.strip() in ('사람 검수 미완료', '미검수 공백')),
                    'Unreviewed placeholder exclusion')
    require(abs(cursor - scope['sourceEnd']) < 1e-6, 'Reference must cover the entire scope')
    return 'ready' if human and (not speech or ref['timingReviewed']) else 'pending'


def preflight(scopes, reference_dir):
    refs, pending, invalid = {}, [], []
    for scope in scopes:
        sid = scope['segmentID']
        try:
            ref, digest = read_json(reference_dir / (sid + '.reference.json'), 4_000_000)
            state = validate_reference(ref, scope)
            refs[sid] = {'sha256': digest, 'revision': valid_uuid(ref['revisionID']), 'reference': ref}
            if state != 'ready':
                pending.append(sid + ': human text/activity/timing review required')
        except FileNotFoundError:
            pending.append(sid + ': missing human reference')
        except (OSError, ValueError, TypeError, KeyError, OverflowError, RecursionError) as error:
            invalid.append(sid + ': ' + str(error))
    return {'state': 'invalid_input' if invalid else 'awaiting_human_reference' if pending else 'ready',
            'issues': invalid + pending, 'references': refs}


def options_sha(language, channel):
    return canonical_sha(dict(language=language, channel=str(channel), accurate='true', glossary='', windowSeconds='300'))


def record_identity(row):
    return canonical_sha(dict(source=row['sourceSHA256'], range=f"{float(row['sourceStart'])}:{float(row['sourceEnd'])}",
                              reference=row['referenceSHA256'], model=row['modelSHA256'], runtime=row['runtimeSHA256'],
                              options=row['optionsSHA256'], selection=canonical_sha(row.get('audioSelection')),
                              mode=row['mode'], metricPolicy=POLICY))


def judge_records(scopes, refs, rows, context):
    """Pure completion decision: no reads, builds, or publication."""
    issues, warnings, speech_files, seen, groups, selections = [], [], set(), set(), {}, {}
    expected = {(s['segmentID'], mode, trial) for s in scopes for mode in MODES for trial in (1, 2)}
    by_id = {s['segmentID']: s for s in scopes}
    if not isinstance(rows, list) or len(rows) != len(expected):
        return {'state': 'failed', 'stageCompletion': False, 'issues': ['Incomplete trial count'], 'warnings': []}
    unscored = False
    for row in rows:
        try:
            require(isinstance(row, dict), 'Record object')
            key = (row.get('segmentID'), row.get('mode'), row.get('trial'))
            require(type(row.get('trial')) is int and key in expected and key not in seen, 'Duplicate/unknown trial')
            seen.add(key)
            scope, ref = by_id[key[0]], refs[key[0]]
            require(type(row.get('schemaVersion')) is int and row['schemaVersion'] == 1, 'Record schema')
            for field in BINDING:
                require(row.get(field) == scope[field], 'Record source/range: ' + field)
            require(row.get('referenceState') == 'human_reviewed' and not row.get('referenceIssue'), 'Reference state')
            require(row.get('referenceSHA256') == ref['sha256']
                    and valid_uuid(row.get('referenceRevision')) == ref['revision'], 'Reference bytes/revision changed')
            for field in ('modelSHA256', 'runtimeSHA256', 'coreSHA256', 'optionsSHA256', 'pipeline'):
                require(row.get(field) == context[field], 'Mixed run configuration: ' + field)
            require(row.get('metricPolicy') == POLICY and row.get('identitySHA256') == record_identity(row), 'Identity/metric policy')
            selection = row.get('audioSelection')
            require(isinstance(selection, dict), 'Missing audio plan')
            count, primary, secondary = selection.get('channelCount'), selection.get('primary'), selection.get('secondary')
            require(type(count) is int and 1 <= count <= 32 and type(primary) is int and 0 <= primary < count
                    and (secondary is None or type(secondary) is int and 0 <= secondary < count and secondary != primary), 'Audio plan')
            require(context['channel'] == -1 or primary == context['channel'] and secondary is None, 'Requested audio channel')
            require(key[0] not in selections or selections[key[0]] == selection, 'Mixed native audio plan')
            selections[key[0]] = selection
            group = (key[0], key[1])
            require(group not in groups or groups[group] == (row['identitySHA256'], row.get('outputSHA256')), 'Repeat changed output/identity')
            groups[group] = (row['identitySHA256'], row.get('outputSHA256'))
            require(isinstance(row.get('outputSHA256'), str) and re.fullmatch('[0-9a-f]{64}', row['outputSHA256']), 'Output SHA')
            require(finite(row.get('wallSeconds')) and finite(row.get('inputForwardedSeconds'), maximum=scope['sourceEnd']-scope['sourceStart']+0.001), 'Measurement bounds')
            if key[1] != 'full':
                require(finite(row.get('vadSeconds')), 'Missing VAD measurement')
            metrics = row.get('metrics')
            require(isinstance(metrics, dict) and valid_uuid(metrics.get('referenceRevision')) == ref['revision'], 'Metrics reference revision')
            status = metrics.get('status')
            if status == 'unscored':
                unscored = True
                issues.append('/'.join(map(str, key)) + ': unscored')
                continue
            require(status in ('scored', 'nonspeech_control'), 'Unknown metrics status')
            require(row.get('regressionGate') == 'no_baseline' and row.get('baselineIdentity') is None,
                    'Regression hold/incompatible/unexpected inherited baseline')
            require(type(metrics.get('falsePositiveCaptions')) is int and metrics['falsePositiveCaptions'] >= 0, 'False-positive counter')
            for field in ('reviewedSpeechSeconds', 'reviewedNonspeechSeconds', 'excludedSeconds'):
                require(finite(metrics.get(field)), 'Reviewed duration: ' + field)
            expected_durations = {k: sum(s['end'] - s['start'] for s in ref['reference']['spans'] if s['kind'] == v)
                                  for k, v in (('reviewedSpeechSeconds', 'speech'), ('reviewedNonspeechSeconds', 'nonspeech'), ('excludedSeconds', 'excluded'))}
            require(all(abs(metrics[k] - v) < 0.001 for k, v in expected_durations.items()), 'Metric durations differ from frozen reference')
            if status == 'scored':
                require(metrics['reviewedSpeechSeconds'] > 0, 'Scored without speech')
                speech_files.add(scope['sourceFile'])
                require(type(metrics.get('missingSentences')) is int and metrics['missingSentences'] >= 0, 'Missing-sentence counter')
                for field in ('cer', 'wer', 'startErrorP50', 'startErrorP95', 'endErrorP50', 'endErrorP95'):
                    require(finite(metrics.get(field)), 'Missing/invalid scored metric: ' + field)
                require(finite(metrics.get('matchedReferenceShare'), maximum=1), 'Matched share')
                require(metrics['startErrorP50'] <= metrics['startErrorP95'] and metrics['endErrorP50'] <= metrics['endErrorP95'], 'Timing percentile order')
                if key[1] != 'full':
                    require(finite(metrics.get('vadSpeechDurationRecall'), maximum=1), 'VAD speech duration recall')
                require(type(metrics.get('alignmentLimited')) is bool, 'Alignment status')
                if metrics['reviewedSpeechSeconds'] < 60 or metrics['alignmentLimited']:
                    warnings.append('/'.join(map(str, key)) + ': small sample or limited sentence alignment')
            else:
                require(metrics['reviewedSpeechSeconds'] == 0 and metrics['reviewedNonspeechSeconds'] > 0, 'Nonspeech control without reviewed nonspeech')
                require(all(metrics.get(f) is None for f in ('cer', 'wer', 'matchedReferenceShare', 'vadSpeechDurationRecall',
                        'startErrorP50', 'startErrorP95', 'endErrorP50', 'endErrorP95')), 'Invented nonspeech accuracy')
        except (ValueError, TypeError, KeyError, OverflowError) as error:
            issues.append(str(error))
    if seen != expected:
        issues.append('Missing required trials')
    if len(speech_files) < 2:
        issues.append('Need reviewed speech in at least two actual source files')
    return {'state': 'unscored' if unscored else 'failed' if issues else 'verified',
            'stageCompletion': not issues, 'issues': issues, 'warnings': warnings}


def load_runner(repository):
    spec = importlib.util.spec_from_file_location('jhcut_verification', repository / 'Scripts/verification-run.py')
    runner = importlib.util.module_from_spec(spec); spec.loader.exec_module(runner)
    return runner


def source_signature(snapshot):
    return {k: snapshot[k] for k in ('head', 'trackedPatchSHA256', 'files')}


def pipeline_version(repository):
    text = (repository / 'Services/LocalTranscription.swift').read_text()
    engine = re.search(r'let engineVersion = "([^"]+)"', text)
    pipeline = re.search(r'let pipelineVersion = engineVersion \+ "([^"]+)"', text)
    require(engine and pipeline, 'Update completion pipeline contract for this source version')
    return engine[1] + pipeline[1]


def load_scopes(repository):
    scopes, _ = read_json(repository / 'References/IPhone/dataset.json', 1_000_000)
    require(isinstance(scopes, list) and len(scopes) == 4, 'Expected four registered corpus scopes')
    triples, ids = set(), set()
    for s in scopes:
        require(isinstance(s, dict) and isinstance(s.get('sourceFile'), str)
                and re.fullmatch(r'IMG_[0-9]+\.mov', s['sourceFile']), 'Corpus file name')
        require(finite(s.get('sourceStart')) and finite(s.get('sourceEnd')) and s['sourceEnd'] > s['sourceStart'], 'Corpus range')
        sid = f"{Path(s['sourceFile']).stem}-{int(s['sourceStart'])}-{int(s['sourceEnd'])}"
        require(s.get('segmentID') == sid and sid not in ids, 'Corpus ID'); ids.add(sid)
        require(isinstance(s.get('sourceSHA256'), str) and re.fullmatch('[0-9a-f]{64}', s['sourceSHA256']), 'Corpus source SHA')
        triples.add((s['sourceFile'], s['sourceStart'], s['sourceEnd']))
    text = (repository / 'Tests/RealAccuracyProbe.swift').read_text()
    actual = {(f, float(a), float(b)) for f, a, b in re.findall(r'Selection\(file:"([^"]+)",start:([0-9.]+),end:([0-9.]+),', text)}
    require(triples == actual and len({s['sourceFile'] for s in scopes}) == 3, 'Corpus differs from maintained Swift probe')
    return scopes


def verify_hash_map(base, entries):
    require(isinstance(entries, dict) and entries, 'Missing artifact/binary/input hash map')
    for relative, expected in entries.items():
        p = Path(relative)
        require(not p.is_absolute() and '..' not in p.parts, 'Escaping evidence path')
        require(stable_read(base / p)[1] == expected, 'Evidence bytes changed: ' + relative)


def verify_run(repository, run, before, frozen, scopes, refs, context, runner):
    """Verify actual filesystem evidence before calling the pure decision."""
    index, _ = read_json(run / 'verification-index.json')
    require(index.get('schemaVersion') == 1 and index.get('runID') == run.name and index.get('status') == 'passed'
            and index.get('requestID') == context['requestID']
            and index.get('buildExitCode') == 0 and index.get('appBuildRequested') is True
            and index.get('sourceUnchanged') is True and index.get('inputUnchanged') is True, 'Fresh verification build failed/incomplete')
    require(source_signature(index['source']) == source_signature(before)
            == source_signature(index['sourceAfter']) == source_signature(runner.snapshot()), 'Source changed during evaluation')
    infrastructure = index.get('infrastructure', {})
    require(infrastructure.get('status') == 'passed' and infrastructure.get('passed', 0) > 0
            and infrastructure.get('failures') == 0 and infrastructure.get('exitCode') == 0, 'Workspace infrastructure incomplete')
    suites = index.get('suites', [])
    require(len(suites) == 2 and {s.get('suite') for s in suites} == {'accuracy-dataset', 'real-accuracy'}, 'Required suite set incomplete')
    core = index['binaries'].get('Build/libJHCutCore.dylib')
    require(isinstance(core, str) and re.fullmatch('[0-9a-f]{64}', core), 'Missing fresh core')
    for suite in suites:
        require(suite.get('status') == 'passed' and suite.get('exitCode') == 0 and suite.get('failures') == 0
                and type(suite.get('passed')) is int and suite['passed'] > 0 and suite.get('coreSHA256') == core, 'Suite failure/stale core')
        verify_hash_map(run, {suite['log']: suite['logSHA256']})
    for relative in ('Build/JH CUT Studio.app/Contents/MacOS/JHCutStudio', 'Build/RealAccuracyProbe', 'Build/AccuracyDatasetProbe'):
        require(relative in index['binaries'], 'Missing fresh executable: ' + relative)
    verify_hash_map(run, index['binaries']); verify_hash_map(run, index['artifactHashes'])
    inputs = dict(index['inputs'])
    require(inputs.pop('localModels/ggml-base.bin', None) == context['modelSHA256'], 'Actual installed model alias mismatch')
    verify_hash_map(repository, inputs)
    for path, digest in frozen.items():
        require(stable_read(Path(path))[1] == digest, 'Frozen input/reference/model/runtime changed: ' + path)
    for scope in scopes:
        relative = 'Artifacts/Upgrade-0.7/RealCopies/' + scope['sourceFile']
        require(inputs.get(relative) == scope['sourceSHA256'], 'Source copy hash mismatch')
        snapshot = 'Outputs/real-accuracy/' + scope['segmentID'] + '/reference-snapshot.json'
        require(index['artifactHashes'].get(snapshot) == refs[scope['segmentID']]['sha256'], 'Different frozen reference bytes')
    summary = 'Outputs/real-accuracy/summary.json'
    require(summary in index['artifactHashes'], 'Summary missing from hashed artifacts')
    rows, _ = read_json(run / summary)
    context = dict(context, coreSHA256=core)
    verdict = judge_records(scopes, refs, rows, context)
    if verdict['stageCompletion']:
        for row in rows:
            prefix = f"Outputs/real-accuracy/{row['segmentID']}/{row['mode']}-trial-{row['trial']}"
            require(index['artifactHashes'].get(prefix + '.asr.srt') == row['outputSHA256'], 'ASR output SHA mismatch')
            require(prefix + '.transcript.json' in index['artifactHashes'], 'Missing raw transcript evidence')
    return verdict


def create_attempt(repository, reference_dir, output_dir):
    output = safe_path(output_dir)
    model = (Path.home() / 'Library/Application Support/JHCutStudio/Models').resolve()
    for protected in (repository, reference_dir, model):
        require(output != protected and not protected.is_relative_to(output), 'Output overlaps protected directory')
    require(not output.is_relative_to(reference_dir) and not output.is_relative_to(model), 'Output inside protected input directory')
    if output.is_relative_to(repository):
        require(output.is_relative_to(repository / 'Artifacts/AccuracyCompletion'),
                'Repository receipts must be under Artifacts/AccuracyCompletion; historical runs/deliveries are read-only')
    output.mkdir(parents=True, exist_ok=True)
    attempt = output / (dt.datetime.now().strftime('%Y%m%d-%H%M%S') + '-' + uuid.uuid4().hex)
    attempt.mkdir(exist_ok=False)
    return attempt


def write_receipt(attempt, receipt):
    # Only the exclusively created attempt is updated; no last-success pointer.
    temporary = attempt / ('receipt-' + uuid.uuid4().hex + '.tmp')
    with temporary.open('x') as f:
        json.dump(receipt, f, ensure_ascii=False, indent=2, allow_nan=False); f.write('\n')
    temporary.replace(attempt / 'receipt.json')


def execute_runner(repository, attempt, env, timeout):
    command = [sys.executable, '-B', str(repository / 'Scripts/verification-run.py'), '--suites', 'accuracy-dataset', 'real-accuracy',
               '--request-id', attempt.name.rsplit('-', 1)[-1]]
    with (attempt / 'evaluation.log').open('x') as log:
        child = subprocess.Popen(command, cwd=repository, env=env, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
        try:
            return child.wait(timeout=timeout)
        except (KeyboardInterrupt, subprocess.TimeoutExpired):
            # Runner handles SIGINT and cleans up its separately grouped active child.
            if child.poll() is None:
                os.killpg(child.pid, signal.SIGINT)
            try:
                child.wait(timeout=12)
            except subprocess.TimeoutExpired:
                os.killpg(child.pid, signal.SIGKILL); child.wait()
            raise


def main(argv=None):
    parser = argparse.ArgumentParser(description='사람 정답 기반 실사 평가. 사전 확인은 정확도 합격이 아닙니다.')
    parser.add_argument('--repository', type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument('--reference-dir', type=Path)
    parser.add_argument('--output-dir', type=Path)
    parser.add_argument('--check-only', action='store_true')
    parser.add_argument('--language', choices=('auto', 'ko', 'ja', 'en'), default='auto')
    parser.add_argument('--channel', type=int, choices=range(-1, 32), default=-1)
    parser.add_argument('--timeout-seconds', type=int, default=7200)
    try:
        args = parser.parse_args(argv)
    except SystemExit as error:
        return 0 if error.code == 0 else EXIT['invalid_input']
    receipt, attempt = dict(schemaVersion=1, state='invalid_input', stageCompletion=False, issues=[],
                            note='검수된 표본의 평가 완료 여부입니다. 전체 영상의 품질 점수 보증이 아닙니다.'), None
    try:
        require(args.timeout_seconds > 0, 'Timeout must be positive')
        repository = safe_path(args.repository)
        require(stable_read(repository / 'Scripts/accuracy_completion.py')[1] == stable_read(Path(__file__))[1],
                'Run the maintained completion tool from the selected repository version')
        reference_dir = safe_path(args.reference_dir or repository / 'References/IPhone')
        scopes = load_scopes(repository)
        attempt = create_attempt(repository, reference_dir, args.output_dir or repository / 'Artifacts/AccuracyCompletion')
        receipt.update(repository=str(repository), referenceDirectory=str(reference_dir), scopes=scopes,
                       options=dict(language=args.language, channel=args.channel), startedAt=dt.datetime.now(dt.timezone.utc).isoformat())
        check = preflight(scopes, reference_dir)
        receipt.update(state=check['state'], issues=check['issues'], referenceBindings={sid: {k: r[k] for k in ('sha256', 'revision')} for sid, r in check['references'].items()})
        write_receipt(attempt, receipt)
        if receipt['state'] != 'ready' or args.check_only:
            return EXIT[receipt['state']]
        runner = load_runner(repository)
        before = runner.snapshot()
        model = safe_path(Path.home() / 'Library/Application Support/JHCutStudio/Models/ggml-base.bin')
        runtime = repository / 'Resources/Whisper/whisper-cli'
        frozen = {str(model): stable_read(model)[1], str(runtime): stable_read(runtime)[1]}
        require(frozen[str(model)] == MODEL_SHA, 'Installed model is not the approved base multilingual model')
        require(os.access(runtime, os.X_OK), 'Whisper runtime is not executable')
        for scope in scopes:
            source = repository / 'Artifacts/Upgrade-0.7/RealCopies' / scope['sourceFile']
            digest = stable_read(source)[1]
            require(digest == scope['sourceSHA256'], 'Source copy differs from registered corpus')
            frozen[str(source)] = digest
            frozen[str(reference_dir / (scope['segmentID'] + '.reference.json'))] = check['references'][scope['segmentID']]['sha256']
        context = dict(modelSHA256=frozen[str(model)], runtimeSHA256=frozen[str(runtime)],
                       optionsSHA256=options_sha(args.language, args.channel), pipeline=pipeline_version(repository), channel=args.channel,
                       requestID=attempt.name.rsplit('-', 1)[-1])
        receipt.update(state='running', source=before, frozenInputs=frozen, configuration=context, issues=[])
        write_receipt(attempt, receipt)
        runs = repository / 'Artifacts/Runs'
        existing = {p.name for p in runs.iterdir()} if runs.exists() else set()
        env = os.environ.copy()
        for name in tuple(env):
            if name.startswith('JHCUT_') and name not in ('JHCUT_DEVELOPER_DIR', 'JHCUT_SDK'):
                env.pop(name)
        env.update(JHCUT_REFERENCE_DIR=str(reference_dir), JHCUT_ACCURACY_LANGUAGE=args.language,
                   JHCUT_ACCURACY_CHANNEL=str(args.channel), PYTHONDONTWRITEBYTECODE='1')
        code = execute_runner(repository, attempt, env, args.timeout_seconds)
        log, _ = stable_read(attempt / 'evaluation.log', 32_000_000)
        matches = re.findall(r'VERIFICATION_RUN=([^\r\n]+)', log.decode(errors='replace'))
        require(len(matches) == 1, 'Runner did not identify exactly one fresh run')
        run = safe_path(matches[0])
        require(run.parent == runs.resolve() and run.name not in existing, 'Stale or external run refused')
        receipt['run'] = str(run)
        require(code == 0, 'Verification runner failed: exit ' + str(code))
        receipt.update(verify_run(repository, run, before, frozen, scopes, check['references'], context, runner))
    except KeyboardInterrupt:
        receipt.update(state='interrupted', stageCompletion=False, issues=['Evaluation interrupted'])
    except subprocess.TimeoutExpired:
        receipt.update(state='failed', stageCompletion=False, issues=['Evaluation timed out; runner cancellation requested'])
    except (OSError, ValueError, TypeError, KeyError, OverflowError, RecursionError, subprocess.SubprocessError) as error:
        receipt.update(state='invalid_input' if receipt['state'] in ('invalid_input', 'ready') else 'failed',
                       stageCompletion=False, issues=[str(error)])
    finally:
        receipt['finishedAt'] = dt.datetime.now(dt.timezone.utc).isoformat()
        if attempt is not None:
            write_receipt(attempt, receipt)
            print('ACCURACY_COMPLETION_RECEIPT=' + str(attempt / 'receipt.json'))
        print('ACCURACY_COMPLETION_STATE=' + receipt['state'])
        for issue in receipt['issues']:
            print('- ' + issue)
    return EXIT[receipt['state']]
