"""Synthetic infrastructure fixtures only. No actual human truth or ASR accuracy claim."""
import contextlib
import copy
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import types
import unittest
from unittest.mock import patch, Mock
import uuid

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'Scripts'))
import accuracy_completion as gate


def dump(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, ensure_ascii=False, allow_nan=False))
    return gate.stable_read(path)[1]


class CompletionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='jhcut-completion-synthetic-')
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name).resolve()
        self.repo, self.refdir = self.base / 'repo', self.base / 'human-fixtures'
        self.repo.mkdir(); self.refdir.mkdir()
        self.scopes = copy.deepcopy(gate.load_scopes(ROOT))
        self.context = dict(modelSHA256='a'*64, runtimeSHA256='b'*64, coreSHA256='c'*64,
                            optionsSHA256=gate.options_sha('auto', -1), pipeline=gate.pipeline_version(ROOT), channel=-1, requestID='f'*32)
        self.references = {}
        for index, scope in enumerate(self.scopes):
            speech = index != 3
            ref = dict(scope, schemaVersion=1, revisionID=str(uuid.uuid4()), language='ko' if speech else 'und',
                       reviewer='SYNTHETIC FIXTURE — NOT A HUMAN REVIEW', reviewedAt='2026-10-03T00:00:00Z',
                       reviewMethod='human-listened', textReviewed=True, activityReviewed=True, timingReviewed=True,
                       draftExposure=False, overlapPolicy='exclude', spans=[dict(id=str(uuid.uuid4()),
                       start=scope['sourceStart'], end=scope['sourceEnd'], kind='speech' if speech else 'nonspeech',
                       text='합성 테스트 대사입니다' if speech else '', reason='', conditions=['unknown'])])
            sid = scope['segmentID']
            digest = dump(self.refdir / (sid + '.reference.json'), ref)
            self.references[sid] = dict(sha256=digest, revision=ref['revisionID'], reference=ref)
        self.rows = self.records()

    def records(self):
        rows = []
        for scope in self.scopes:
            ref = self.references[scope['segmentID']]
            speech = ref['reference']['spans'][0]['kind'] == 'speech'
            duration = scope['sourceEnd'] - scope['sourceStart']
            for mode in gate.MODES:
                for trial in (1, 2):
                    metrics = dict(status='scored' if speech else 'nonspeech_control', referenceRevision=ref['revision'],
                                   falsePositiveCaptions=0, reviewedSpeechSeconds=duration if speech else 0,
                                   reviewedNonspeechSeconds=0 if speech else duration, excludedSeconds=0, events=[])
                    if speech:
                        metrics.update(cer=0.1, wer=0.2, matchedReferenceShare=0.9, missingSentences=0,
                                       startErrorP50=0.1, startErrorP95=0.2, endErrorP50=0.1, endErrorP95=0.2, alignmentLimited=False)
                        if mode != 'full': metrics['vadSpeechDurationRecall'] = 0.95
                    row = dict(scope, schemaVersion=1, referenceRevision=ref['revision'], referenceSHA256=ref['sha256'],
                               referenceState='human_reviewed', mode=mode, trial=trial, metricPolicy=gate.POLICY,
                               audioSelection=dict(channelCount=2, primary=0, secondary=1), outputSHA256='d'*64,
                               wallSeconds=1, inputForwardedSeconds=duration, metrics=metrics, regressionGate='no_baseline',
                               **{k:v for k,v in self.context.items() if k not in ('channel','requestID')})
                    if mode != 'full': row['vadSeconds'] = 0.5
                    row['identitySHA256'] = gate.record_identity(row)
                    rows.append(row)
        return rows

    def verdict(self, rows=None):
        return gate.judge_records(self.scopes, self.references, self.rows if rows is None else rows, self.context)

    def test_synthetic_complete_matrix_verified_with_warning(self):
        result = self.verdict()
        self.assertTrue(result['stageCompletion']); self.assertEqual(result['state'], 'verified')
        self.assertEqual(len(result['warnings']), 6)

    def test_zero_references_waits(self):
        self.assertEqual(gate.preflight(self.scopes, self.base / 'empty')['state'], 'awaiting_human_reference')

    def test_three_references_waits(self):
        (self.refdir / (self.scopes[3]['segmentID'] + '.reference.json')).unlink()
        result = gate.preflight(self.scopes, self.refdir)
        self.assertEqual((result['state'], len(result['references'])), ('awaiting_human_reference', 3))

    def test_four_references_ready(self):
        self.assertEqual(gate.preflight(self.scopes, self.refdir)['state'], 'ready')

    def test_invalid_json_separate_from_missing(self):
        (self.refdir / (self.scopes[0]['segmentID'] + '.reference.json')).write_text('{bad')
        self.assertEqual(gate.preflight(self.scopes, self.refdir)['state'], 'invalid_input')

    def test_wrong_source_and_range_refused(self):
        scope = self.scopes[0]
        for key, value in [('sourceSHA256', '0'*64), ('sourceFile', 'other.mov'), ('sourceStart', 661), ('sourceEnd', 781)]:
            with self.subTest(key=key):
                ref = copy.deepcopy(self.references[scope['segmentID']]['reference']); ref[key] = value
                with self.assertRaises(ValueError): gate.validate_reference(ref, scope)

    def test_unreviewed_pending_reference_waits(self):
        scope = self.scopes[0]; ref = copy.deepcopy(self.references[scope['segmentID']]['reference'])
        ref.update(reviewMethod='pending', textReviewed=False, activityReviewed=False, timingReviewed=False, reviewer=None, reviewedAt=None)
        self.assertEqual(gate.validate_reference(ref, scope), 'pending')

    def test_speech_without_timing_waits(self):
        scope = self.scopes[0]; ref = copy.deepcopy(self.references[scope['segmentID']]['reference'])
        ref['timingReviewed'] = False
        self.assertEqual(gate.validate_reference(ref, scope), 'pending')

    def test_invalid_reference_spans_and_provenance(self):
        scope = self.scopes[0]; original = self.references[scope['segmentID']]['reference']
        mutations = [lambda r:r.update(reviewer=''), lambda r:r.update(reviewedAt='tomorrow'),
                     lambda r:r['spans'][0].update(start=661), lambda r:r['spans'][0].update(end=779),
                     lambda r:r['spans'][0].update(conditions=['overlap']), lambda r:r['spans'][0].update(text='...'),
                     lambda r:r.update(parentRevisionID=r['revisionID']), lambda r:r.update(textReviewed=1)]
        for mutation in mutations:
            ref = copy.deepcopy(original); mutation(ref)
            with self.assertRaises(ValueError): gate.validate_reference(ref, scope)

    def test_same_revision_different_bytes_refused(self):
        row = self.rows[0]; row['referenceSHA256'] = 'e'*64; row['identitySHA256'] = gate.record_identity(row)
        self.assertFalse(self.verdict()['stageCompletion'])

    def test_reference_revision_changed_refused(self):
        self.rows[0]['referenceRevision'] = str(uuid.uuid4())
        self.assertFalse(self.verdict()['stageCompletion'])

    def test_duplicate_trial_refused(self):
        self.rows[-1] = copy.deepcopy(self.rows[0])
        self.assertFalse(self.verdict()['stageCompletion'])

    def test_missing_trial_refused(self):
        self.assertFalse(self.verdict(self.rows[:-1])['stageCompletion'])

    def test_unscored_never_completes(self):
        self.rows[0]['metrics'] = dict(status='unscored', referenceRevision=self.rows[0]['referenceRevision'], events=[])
        result = self.verdict(); self.assertFalse(result['stageCompletion']); self.assertEqual(result['state'], 'unscored')

    def test_mixed_configuration_refused_even_with_recomputed_identity(self):
        original = copy.deepcopy(self.rows[0])
        for field in ('modelSHA256', 'runtimeSHA256', 'coreSHA256', 'optionsSHA256', 'pipeline', 'metricPolicy'):
            with self.subTest(field=field):
                self.rows[0] = copy.deepcopy(original); self.rows[0][field] = '0'*64
                self.rows[0]['identitySHA256'] = gate.record_identity(self.rows[0])
                self.assertFalse(self.verdict()['stageCompletion'])

    def test_bad_identity_refused(self):
        self.rows[0]['identitySHA256'] = 'f'*64
        self.assertFalse(self.verdict()['stageCompletion'])

    def test_mixed_audio_plan_refused(self):
        self.rows[1]['audioSelection'] = dict(channelCount=2, primary=1)
        self.rows[1]['identitySHA256'] = gate.record_identity(self.rows[1])
        self.assertFalse(self.verdict()['stageCompletion'])

    def test_repeat_output_change_refused(self):
        self.rows[1]['outputSHA256'] = 'f'*64
        self.assertFalse(self.verdict()['stageCompletion'])

    def test_nonfinite_boolean_negative_metrics_refused(self):
        original = copy.deepcopy(self.rows[0])
        for value in (True, -0.01, float('inf'), float('nan'), None):
            self.rows[0] = copy.deepcopy(original); self.rows[0]['metrics']['cer'] = value
            self.assertFalse(self.verdict()['stageCompletion'])

    def test_missing_timing_and_vad_refused(self):
        self.rows[0]['metrics'].pop('startErrorP95')
        self.assertFalse(self.verdict()['stageCompletion'])
        self.rows = self.records(); self.rows[2]['metrics'].pop('vadSpeechDurationRecall')
        self.assertFalse(self.verdict()['stageCompletion'])

    def test_duration_or_share_outside_bounds_refused(self):
        original = copy.deepcopy(self.rows[0])
        for field, value in [('matchedReferenceShare', 1.1), ('reviewedSpeechSeconds', 119), ('startErrorP50', 0.3)]:
            self.rows[0] = copy.deepcopy(original); self.rows[0]['metrics'][field] = value
            self.assertFalse(self.verdict()['stageCompletion'])

    def test_nonspeech_has_no_invented_cer(self):
        self.rows[-1]['metrics']['cer'] = 0
        self.assertFalse(self.verdict()['stageCompletion'])

    def test_regression_hold_or_incompatible_block(self):
        for value in ('hold_regression', 'unscored_or_incompatible', 'within_provisional_limits'):
            self.rows[0]['regressionGate'] = value
            self.assertFalse(self.verdict()['stageCompletion'])

    def test_two_distinct_speech_sources_required(self):
        for scope in self.scopes[:2]:
            ref = self.references[scope['segmentID']]['reference']; ref['spans'][0].update(kind='nonspeech', text='')
        self.rows = self.records()
        self.assertFalse(self.verdict()['stageCompletion'])

    def test_strict_json_duplicate_nan_and_oversize(self):
        path = self.base / 'unsafe.json'
        for text in ('{"a":1,"a":2}', '{"a":NaN}', '{"a":Infinity}'):
            path.write_text(text)
            with self.assertRaises(ValueError): gate.read_json(path)
        path.write_bytes(b' ' * 20)
        with self.assertRaises(ValueError): gate.read_json(path, 10)

    def test_symlink_and_fifo_refused_without_blocking(self):
        target = self.base / 'target'; target.write_text('{}')
        link = self.base / 'link'; link.symlink_to(target)
        with self.assertRaises(ValueError): gate.read_json(link)
        fifo = self.base / 'fifo'; os.mkfifo(fifo)
        with self.assertRaises(ValueError): gate.read_json(fifo)

    def test_same_revision_bytes_changed_are_detected_in_preflight_sha(self):
        before = gate.preflight(self.scopes, self.refdir)
        path = self.refdir / (self.scopes[0]['segmentID'] + '.reference.json')
        path.write_text(path.read_text() + '\n')
        after = gate.preflight(self.scopes, self.refdir)
        sid = self.scopes[0]['segmentID']
        self.assertEqual(before['references'][sid]['revision'], after['references'][sid]['revision'])
        self.assertNotEqual(before['references'][sid]['sha256'], after['references'][sid]['sha256'])

    def test_failed_attempt_preserves_previous_success(self):
        output = self.base / 'receipts'
        old = gate.create_attempt(self.repo, self.refdir, output)
        gate.write_receipt(old, dict(state='verified', stageCompletion=True))
        digest = gate.stable_read(old / 'receipt.json')[1]
        new = gate.create_attempt(self.repo, self.refdir, output)
        gate.write_receipt(new, dict(state='failed', stageCompletion=False))
        self.assertNotEqual(old, new); self.assertEqual(gate.stable_read(old / 'receipt.json')[1], digest)

    def test_output_cannot_write_into_references_historical_runs_or_source(self):
        for path in (self.refdir, self.refdir / 'nested', self.repo, self.repo / 'Scripts', self.repo / 'Artifacts/Runs', self.base):
            with self.subTest(path=path), self.assertRaises(ValueError): gate.create_attempt(self.repo, self.refdir, path)

    def test_file_modified_during_read_refused(self):
        path = self.base / 'changing'; path.write_bytes(b'x' * 20)
        real_read = os.read; changed = False
        def mutate(fd, count):
            nonlocal changed
            data = real_read(fd, count)
            if data and not changed:
                changed = True; path.write_bytes(b'y' * 20)
            return data
        with patch.object(gate.os, 'read', side_effect=mutate), self.assertRaises(ValueError): gate.stable_read(path, 100)

    def test_swift_option_identity_contract(self):
        self.assertEqual(gate.options_sha('auto', -1), '47cd70f996d19cdbfbe2e4306d3e29f6f5f6130525063a54ed6764e71d595c4e')
        # Frozen Swift-produced identity vector from a PENDING, UNSCORED record.
        # No dependency on a delivery folder or historical artifact being installed.
        row = dict(sourceSHA256='eb18b109fc16ae38b78ec357723b1cc735d5ed10baa9a016a27d6e36b4f6c29f',
                   sourceStart=660, sourceEnd=780, referenceSHA256='1830defe785ba8986e06aa9548e178733d75e9a8b77d4abf0a1dfa73f099bd25',
                   modelSHA256=gate.MODEL_SHA, runtimeSHA256='4fa74953727faadbff4e49e1a828e96e05942ba87e31d14a9675de74a783070e',
                   optionsSHA256=gate.options_sha('auto', -1), audioSelection=dict(channelCount=2,primary=0,secondary=1), mode='full')
        self.assertEqual(gate.record_identity(row), '17e2bb1a6e48a8c966ad130f062627a2dff05c393802e4b8cd989f334e48ef27')

    def test_exit_codes(self):
        self.assertEqual(gate.EXIT, dict(verified=0, ready=0, awaiting_human_reference=2, invalid_input=3, failed=1, unscored=1, interrupted=130))

    def test_cli_missing_refs_never_launches_runner(self):
        with patch.object(gate, 'execute_runner') as execute, contextlib.redirect_stdout(io.StringIO()):
            code = gate.main(['--repository', str(ROOT), '--reference-dir', str(self.base / 'absent'), '--output-dir', str(self.base / 'cli-receipts')])
        self.assertEqual(code, 2); execute.assert_not_called()
        receipts = list((self.base / 'cli-receipts').glob('*/receipt.json'))
        receipt = json.loads(receipts[0].read_text())
        self.assertEqual(receipt['state'], 'awaiting_human_reference'); self.assertFalse(receipt['stageCompletion'])

    def test_cli_check_only_ready_not_complete(self):
        with patch.object(gate, 'execute_runner') as execute, contextlib.redirect_stdout(io.StringIO()):
            code = gate.main(['--reference-dir', str(self.refdir), '--output-dir', str(self.base / 'cli'), '--check-only'])
        self.assertEqual(code, 0); execute.assert_not_called()
        receipt = json.loads(next((self.base / 'cli').glob('*/receipt.json')).read_text())
        self.assertEqual(receipt['state'], 'ready'); self.assertFalse(receipt['stageCompletion'])

    def test_cli_invalid_json_exit_three(self):
        (self.refdir / (self.scopes[0]['segmentID'] + '.reference.json')).write_text('[]')
        with contextlib.redirect_stdout(io.StringIO()):
            code = gate.main(['--reference-dir', str(self.refdir), '--output-dir', str(self.base / 'cli'), '--check-only'])
        self.assertEqual(code, 3)

    def test_runner_timeout_signals_only_its_process_group(self):
        child = Mock(pid=87654); child.poll.return_value = None
        child.wait.side_effect = [subprocess.TimeoutExpired('fixture', 1), 130]
        with patch.object(gate.subprocess, 'Popen', return_value=child) as popen, patch.object(gate.os, 'killpg') as kill:
            with self.assertRaises(subprocess.TimeoutExpired): gate.execute_runner(self.repo, self.base, {}, 1)
        kill.assert_called_once_with(87654, gate.signal.SIGINT)
        self.assertTrue(popen.call_args.kwargs['start_new_session'])
        self.assertNotIn('--core-only', popen.call_args.args[0])

    def prepare_evidence(self):
        run = self.repo / 'Artifacts/Runs/SYNTHETIC-run'
        build = run / 'Build'; build.mkdir(parents=True)
        source = dict(head='fixture-head', trackedPatchSHA256='fixture-patch', files={'Scripts/fake.py':'fixture-hash'})
        runner = types.SimpleNamespace(snapshot=lambda:copy.deepcopy(source))
        model = self.base / 'installed-base.bin'; model.write_bytes(b'synthetic model')
        runtime = self.base / 'whisper-cli'; runtime.write_bytes(b'synthetic runtime')
        self.context['modelSHA256'] = gate.stable_read(model)[1]
        self.context['runtimeSHA256'] = gate.stable_read(runtime)[1]
        self.context['coreSHA256'] = gate.sha(b'synthetic core')
        frozen = {str(p):gate.stable_read(p)[1] for p in (model, runtime)}
        inputs = {'localModels/ggml-base.bin':self.context['modelSHA256']}
        for scope in self.scopes:
            relative = 'Artifacts/Upgrade-0.7/RealCopies/' + scope['sourceFile']
            path = self.repo / relative; path.parent.mkdir(parents=True, exist_ok=True); path.write_bytes(scope['sourceFile'].encode())
            scope['sourceSHA256'] = gate.stable_read(path)[1]; inputs[relative] = scope['sourceSHA256']; frozen[str(path)] = inputs[relative]
            ref = self.references[scope['segmentID']]; ref['reference']['sourceSHA256'] = scope['sourceSHA256']
            p = self.refdir / (scope['segmentID'] + '.reference.json'); ref['sha256'] = dump(p, ref['reference']); frozen[str(p)] = ref['sha256']
        self.rows = self.records(); artifacts, binaries, suites = {}, {}, []
        for name, data in [('Build/libJHCutCore.dylib',b'synthetic core'), ('Build/RealAccuracyProbe',b'probe'),
                           ('Build/AccuracyDatasetProbe',b'dataset'), ('Build/JH CUT Studio.app/Contents/MacOS/JHCutStudio',b'app')]:
            p=run/name; p.parent.mkdir(parents=True,exist_ok=True); p.write_bytes(data); binaries[name]=gate.stable_read(p)[1]
        for name in ('accuracy-dataset','real-accuracy'):
            log='Logs/'+name+'.log'; p=run/log; p.parent.mkdir(parents=True,exist_ok=True); p.write_text('synthetic test evidence')
            suites.append(dict(suite=name,status='passed',exitCode=0,failures=0,passed=1,coreSHA256=self.context['coreSHA256'],log=log,logSHA256=gate.stable_read(p)[1]))
        for scope in self.scopes:
            relative='Outputs/real-accuracy/'+scope['segmentID']+'/reference-snapshot.json'
            p=run/relative; p.parent.mkdir(parents=True,exist_ok=True)
            p.write_bytes((self.refdir/(scope['segmentID']+'.reference.json')).read_bytes()); artifacts[relative]=gate.stable_read(p)[1]
        for row in self.rows:
            prefix=f"Outputs/real-accuracy/{row['segmentID']}/{row['mode']}-trial-{row['trial']}"
            p=run/(prefix+'.asr.srt'); p.write_text('synthetic SRT'); row['outputSHA256']=gate.stable_read(p)[1]; artifacts[prefix+'.asr.srt']=row['outputSHA256']
            artifacts[prefix+'.transcript.json']=dump(run/(prefix+'.transcript.json'),dict(syntheticFixture=True))
        artifacts['Outputs/real-accuracy/summary.json']=dump(run/'Outputs/real-accuracy/summary.json',self.rows)
        index=dict(schemaVersion=1,runID=run.name,requestID=self.context['requestID'],status='passed',buildExitCode=0,appBuildRequested=True,
                   sourceUnchanged=True,inputUnchanged=True,source=source,sourceAfter=source,
                   infrastructure=dict(status='passed',passed=1,failures=0,exitCode=0),suites=suites,binaries=binaries,inputs=inputs,artifactHashes=artifacts)
        dump(run/'verification-index.json',index)
        return run, source, frozen, runner, index

    def check_evidence(self, fixture):
        run, source, frozen, runner, index = fixture
        dump(run/'verification-index.json',index)
        return gate.verify_run(self.repo,run,source,frozen,self.scopes,self.references,self.context,runner)

    def test_synthetic_filesystem_evidence_success(self):
        self.assertTrue(self.check_evidence(self.prepare_evidence())['stageCompletion'])

    def test_source_change_blocks_filesystem_gate(self):
        fixture=self.prepare_evidence(); fixture[3].snapshot=lambda:dict(fixture[1],files={'Scripts/new.py':'changed'})
        with self.assertRaisesRegex(ValueError,'Source changed'): self.check_evidence(fixture)

    def test_other_attempt_run_is_refused(self):
        fixture=self.prepare_evidence(); fixture[4]['requestID']='0'*32
        with self.assertRaises(ValueError): self.check_evidence(fixture)

    def test_model_alias_maps_to_actual_installed_bytes(self):
        fixture=self.prepare_evidence()
        fixture[4]['inputs']['localModels/ggml-base.bin']='0'*64
        with self.assertRaisesRegex(ValueError,'model alias'): self.check_evidence(fixture)
        fixture[4]['inputs']['localModels/ggml-base.bin']=self.context['modelSHA256']
        (self.base/'installed-base.bin').write_bytes(b'changed same filename')
        with self.assertRaisesRegex(ValueError,'Frozen input'): self.check_evidence(fixture)

    def test_middle_failure_or_missing_suite_blocks(self):
        fixture=self.prepare_evidence(); fixture[4]['suites'][1]['status']='failed'
        with self.assertRaises(ValueError): self.check_evidence(fixture)
        fixture[4]['suites'].pop()
        with self.assertRaises(ValueError): self.check_evidence(fixture)

    def test_artifact_or_binary_tamper_blocks(self):
        fixture=self.prepare_evidence(); (fixture[0]/'Build/RealAccuracyProbe').write_bytes(b'old binary')
        with self.assertRaisesRegex(ValueError,'Evidence bytes changed'): self.check_evidence(fixture)

    def test_same_revision_reference_modified_after_run_blocks(self):
        fixture=self.prepare_evidence(); p=self.refdir/(self.scopes[0]['segmentID']+'.reference.json'); p.write_text(p.read_text()+'\n')
        with self.assertRaisesRegex(ValueError,'Frozen input'): self.check_evidence(fixture)

    def test_summary_sha_or_snapshot_missing_blocks(self):
        fixture=self.prepare_evidence(); fixture[4]['artifactHashes'].pop('Outputs/real-accuracy/summary.json')
        with self.assertRaisesRegex(ValueError,'Summary missing'): self.check_evidence(fixture)

    def test_evidence_path_cannot_escape(self):
        with self.assertRaises(ValueError): gate.verify_hash_map(self.repo,{'../escape':'0'*64})

    def orchestrate_fixture(self, action='success'):
        fixture = self.prepare_evidence()
        run, source, frozen, runner, index = fixture
        prepared = self.base / 'prepared-SYNTHETIC-evidence'
        run.rename(prepared)
        (self.repo / 'Scripts').mkdir()
        (self.repo / 'Scripts/accuracy_completion.py').write_bytes((ROOT / 'Scripts/accuracy_completion.py').read_bytes())
        home = self.base / 'synthetic-home'
        model = home / 'Library/Application Support/JHCutStudio/Models/ggml-base.bin'
        model.parent.mkdir(parents=True); model.write_bytes(b'synthetic model')
        runtime = self.repo / 'Resources/Whisper/whisper-cli'
        runtime.parent.mkdir(parents=True); runtime.write_bytes(b'synthetic runtime'); runtime.chmod(0o700)
        output = self.base / 'orchestrated'
        old = gate.create_attempt(self.repo, self.refdir, output)
        gate.write_receipt(old, dict(state='verified', stageCompletion=True, syntheticFixture=True))
        old_hash = gate.stable_read(old / 'receipt.json')[1]
        def execute(repository, attempt, env, timeout):
            self.assertNotIn('JHCUT_ACCURACY_BASELINE', env)
            self.assertNotIn('JHCUT_BUILD_DIR', env)
            self.assertEqual(env['JHCUT_ACCURACY_CHANNEL'], '-1')
            if action == 'interrupt': raise KeyboardInterrupt()
            if action == 'timeout': raise subprocess.TimeoutExpired('fixture', timeout)
            prepared.rename(run)
            index['requestID']=attempt.name.rsplit('-',1)[-1]
            dump(run/'verification-index.json',index)
            (attempt / 'evaluation.log').write_text('VERIFICATION_RUN=' + str(run) + '\n')
            if action == 'source-change': runner.snapshot=lambda:dict(source,files={'changed':'0'*64})
            if action == 'unscored':
                rows=copy.deepcopy(self.rows); rows[0]['metrics'].update(status='unscored')
                index['artifactHashes']['Outputs/real-accuracy/summary.json']=dump(run/'Outputs/real-accuracy/summary.json',rows)
                dump(run/'verification-index.json',index)
            return 1 if action == 'failure' else 0
        with patch.object(gate, 'load_scopes', return_value=self.scopes), patch.object(gate, 'load_runner', return_value=runner), \
             patch.object(gate, 'pipeline_version', return_value=self.context['pipeline']), patch.object(gate.Path, 'home', return_value=home), \
             patch.object(gate, 'MODEL_SHA', self.context['modelSHA256']), patch.object(gate, 'execute_runner', side_effect=execute), \
             patch.dict(os.environ, {'JHCUT_ACCURACY_BASELINE':'stale','JHCUT_BUILD_DIR':'old'}), contextlib.redirect_stdout(io.StringIO()):
            code=gate.main(['--repository',str(self.repo),'--reference-dir',str(self.refdir),'--output-dir',str(output)])
        receipts=[p for p in output.glob('*/receipt.json') if p.parent != old]
        self.assertEqual(len(receipts),1)
        self.assertEqual(gate.stable_read(old/'receipt.json')[1],old_hash)
        return code,json.loads(receipts[0].read_text())

    def test_synthetic_orchestration_success_publishes_verified_only_after_gates(self):
        code,receipt=self.orchestrate_fixture()
        self.assertEqual(code,0); self.assertEqual(receipt['state'],'verified'); self.assertTrue(receipt['stageCompletion'])

    def test_orchestration_middle_failure_preserves_success(self):
        code,receipt=self.orchestrate_fixture('failure')
        self.assertEqual(code,1); self.assertEqual(receipt['state'],'failed'); self.assertFalse(receipt['stageCompletion'])

    def test_orchestration_source_change_preserves_success(self):
        code,receipt=self.orchestrate_fixture('source-change')
        self.assertEqual(code,1); self.assertFalse(receipt['stageCompletion'])

    def test_orchestration_unscored_preserves_success(self):
        code,receipt=self.orchestrate_fixture('unscored')
        self.assertEqual(code,1); self.assertEqual(receipt['state'],'unscored'); self.assertFalse(receipt['stageCompletion'])

    def test_orchestration_cancel_preserves_success(self):
        code,receipt=self.orchestrate_fixture('interrupt')
        self.assertEqual(code,130); self.assertEqual(receipt['state'],'interrupted'); self.assertFalse(receipt['stageCompletion'])

    def test_orchestration_timeout_preserves_success(self):
        code,receipt=self.orchestrate_fixture('timeout')
        self.assertEqual(code,1); self.assertEqual(receipt['state'],'failed'); self.assertFalse(receipt['stageCompletion'])


if __name__ == '__main__':
    output = None
    if '--output' in sys.argv:
        at = sys.argv.index('--output'); output=Path(sys.argv[at+1]); del sys.argv[at:at+2]
        output.mkdir(parents=True,exist_ok=False)
    from VerificationRunnerTests import VerificationRunnerTests
    suite=unittest.TestSuite([unittest.defaultTestLoader.loadTestsFromTestCase(CompletionTests),
                              unittest.defaultTestLoader.loadTestsFromTestCase(VerificationRunnerTests)])
    result=unittest.TextTestRunner(verbosity=2).run(suite)
    if output is not None:
        dump(output/'checks.json',dict(syntheticInfrastructureOnly=True,checks=result.testsRun,
             failures=len(result.failures),errors=len(result.errors),skipped=len(result.skipped)))
    print(f'ACCURACY_COMPLETION_RESULT checks={result.testsRun} failures={len(result.failures)+len(result.errors)}')
    sys.exit(0 if result.wasSuccessful() else 1)
