import importlib.util
import json
import os
from pathlib import Path
import shutil
import sys
import tempfile
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[1]
sys.dont_write_bytecode = True
sys.path.insert(0, str(ROOT / 'scripts'))
spec = importlib.util.spec_from_file_location('task_runtime', ROOT / 'scripts' / 'task_runtime.py')
runtime = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runtime)


class TaskRuntimeTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='service-ops-task-test-')
        self.root = Path(self.temp.name) / 'plugin'
        self.root.mkdir()
        (self.root / 'config').mkdir()
        (self.root / 'config' / 'servers-test.conf').write_text('node|fixture.invalid|fixture|key|127.0.0.1|fixture\n', encoding='utf-8')
        (self.root / 'config' / 'services-test.conf').write_text('app|node|/tmp/fixture|*.log|fixture\n', encoding='utf-8')
        (self.root / 'config' / 'settings.json').write_text('{"schema_version":1,"write_enabled":true}\n', encoding='utf-8')
        self.fixture = self.root / 'fixture.py'
        self.fixture.write_text("import sys\nprint('SAMPLE time=2026-10-20T12:00:00+0800 timezone=CST host=fixture')\nprint('password=private-value phone=13812345678')\nprint('RESULT OK files=1 bytes=20 output_limit=50')\n", encoding='utf-8')
        self.runner = runtime.TaskRunner(self.root, Path(self.temp.name) / 'state', [sys.executable, str(self.fixture)])

    def tearDown(self):
        self.temp.cleanup()

    def test_should_persist_redacted_evidence_when_query_finishes(self):
        result = self.runner.run('test', 'app', 'health', ['node'], request_id='query-one')
        self.assertEqual('SUCCEEDED', result['status'])
        evidence = self.runner.evidence(result['job_id'])
        self.assertNotIn('private-value', json.dumps(evidence))
        self.assertNotIn('13812345678', json.dumps(evidence))
        self.assertIn('RESULT OK', evidence['output'])

    def test_should_return_same_receipt_when_request_is_repeated(self):
        first = self.runner.run('test', 'app', 'health', ['node'], request_id='same-request')
        self.fixture.write_text("raise RuntimeError('must not execute again')\n", encoding='utf-8')
        second = self.runner.run('test', 'app', 'health', ['node'], request_id='same-request')
        self.assertEqual(first['job_id'], second['job_id'])
        self.assertEqual('SUCCEEDED', second['status'])

    def test_should_reject_changed_request_when_id_is_reused(self):
        self.runner.run('test', 'app', 'health', ['node'], request_id='bound-request')
        with self.assertRaisesRegex(ValueError, 'REQUEST_ID_CONFLICT'):
            self.runner.run('test', 'app', 'logs', ['10', 'node'], request_id='bound-request')

    def test_should_reject_production_write_before_child_starts(self):
        with self.assertRaisesRegex(ValueError, 'PROD_READ_ONLY'):
            self.runner.run('prod', 'app', 'restart', [])

    def test_should_keep_unknown_when_child_reports_uncertain_write(self):
        self.fixture.write_text("import sys\nprint('RESULT UNKNOWN reason=SSH_FAILED')\nsys.exit(75)\n", encoding='utf-8')
        result = self.runner.run('test', 'app', 'restart', [])
        self.assertEqual('UNKNOWN', result['status'])
        repeated = self.runner.run('test', 'app', 'restart', [], request_id=result['request_id'])
        self.assertEqual('UNKNOWN', repeated['status'])

    def test_should_keep_partial_when_log_coverage_is_incomplete(self):
        self.fixture.write_text("import sys\nprint('RESULT PARTIAL files=1 bytes=10 output_limit=1')\nsys.exit(2)\n", encoding='utf-8')
        result = self.runner.run('test', 'app', 'health', ['node'])
        self.assertEqual('PARTIAL', result['status'])

    def test_should_reject_arbitrary_commands_when_task_interface_is_used(self):
        with self.assertRaisesRegex(ValueError, 'UNSUPPORTED_ACTION'):
            self.runner.run('test', 'node', 'exec', ['touch /tmp/forbidden'])

    def test_should_reject_changed_configuration_before_reconciliation(self):
        result = self.runner.run('test', 'app', 'restart', [])
        (self.root / 'config' / 'servers-test.conf').write_text('node|other.invalid|fixture|key||fixture\n', encoding='utf-8')
        with self.assertRaisesRegex(ValueError, 'CONFIG_CHANGED'):
            self.runner.reconcile(result['job_id'])

    def test_should_report_unknown_without_editing_receipt_when_owner_has_disappeared(self):
        result = self.runner.run('test', 'app', 'restart', [])
        path = self.runner.directory(result['job_id']) / 'job.json'
        result.update(status='RUNNING', owner_pid=0, owner_identity='old-process')
        runtime.atomic_json(path, result)
        self.assertEqual('UNKNOWN', self.runner.status(result['job_id'])['status'])
        self.assertEqual('RUNNING', json.loads(path.read_text())['status'])

    def test_should_fail_when_query_reports_failure_with_zero_exit_code(self):
        self.fixture.write_text("print('RESULT QUERY_FAILED reason=fixture')\n", encoding='utf-8')
        self.assertEqual('FAILED', self.runner.run('test', 'app', 'health', [])['status'])

    def test_should_preserve_no_match_without_claiming_service_health(self):
        self.fixture.write_text("print('RESULT NO_MATCH files=1')\n", encoding='utf-8')
        result = self.runner.run('test', 'app', 'grep', ['fixture'])
        self.assertEqual('SUCCEEDED', result['status'])
        self.assertEqual(['NO_MATCH'], result['query_statuses'])

    def test_should_bound_evidence_when_output_exceeds_budget(self):
        self.fixture.write_text("print(('x' * 200 + '\\n') * 2000)\n", encoding='utf-8')
        result = self.runner.run('test', 'app', 'health', [])
        self.assertEqual('PARTIAL', result['status'])
        self.assertTrue(result['output_truncated'])
        path = self.runner.directory(result['job_id']) / 'output.txt'
        self.assertLessEqual(path.stat().st_size, runtime.OUTPUT_LIMIT)

    def test_should_drop_overlong_line_instead_of_saving_unbounded_secret(self):
        self.fixture.write_text("print('password=' + 'x' * 100000)\n", encoding='utf-8')
        result = self.runner.run('test', 'app', 'health', [])
        self.assertEqual('PARTIAL', result['status'])
        self.assertIn('OUTPUT_LINE_TOO_LONG', self.runner.evidence(result['job_id'])['output'])

    def test_should_distinguish_read_and_write_when_deadline_interrupts_child(self):
        self.fixture.write_text("import time\ntime.sleep(20)\n", encoding='utf-8')
        self.runner.timeout = 1
        self.assertEqual('PARTIAL', self.runner.run('test', 'app', 'health', [])['status'])
        self.assertEqual('UNKNOWN', self.runner.run('test', 'app', 'restart', [])['status'])

    def test_should_capture_release_identity_without_following_current_index(self):
        release = '20261020120000-abcdef12'
        self.fixture.write_text("import sys\nsys.path.insert(0," + repr(str(ROOT / 'scripts')) +
                                ")\nfrom task_events import emit\nemit('install','started','" + release +
                                "')\nemit('install','completed','" + release + "')\n", encoding='utf-8')
        result = self.runner.run('test', 'app', 'upload', [])
        self.assertEqual(release, result['release_id'])
        with patch.object(self.runner, 'run', return_value={'job_id': 'observation'}) as execute:
            reconciled = self.runner.reconcile(result['job_id'])
        self.assertEqual('SUCCEEDED', reconciled['status'])
        self.assertEqual(['release-status', 'verify'], [call.args[2] for call in execute.call_args_list])
        self.assertEqual([release], execute.call_args_list[1].args[3])

    def test_should_save_partial_diagnostic_when_time_and_proxy_evidence_are_missing(self):
        report = self.runner.diagnose('test', 'app', 'http502')
        self.assertEqual('PARTIAL', report['status'])
        self.assertEqual('UNDETERMINED', report['root_cause'])
        self.assertEqual(2, len(report['missing_evidence']))
        self.assertEqual(4, len(report['evidence_jobs']))
        self.assertEqual('diagnose', self.runner.status(report['job_id'])['action'])
        self.assertIn(report['job_id'], [item['job_id'] for item in self.runner.list_jobs()['jobs']])

    def test_should_reject_diagnostic_node_outside_service_scope(self):
        with self.assertRaisesRegex(ValueError, 'INVALID_DIAGNOSTIC_SCOPE'):
            self.runner.diagnose('test', 'app', 'startup', server='other')

    def test_should_name_incomplete_queries_in_diagnostic_gaps(self):
        self.fixture.write_text("print('RESULT PARTIAL files=1 bytes=100')\n", encoding='utf-8')
        report = self.runner.diagnose('test', 'app', 'startup', start='2026-10-20 16:30', end='2026-10-20 16:32')
        self.assertEqual('PARTIAL', report['status'])
        self.assertEqual(4, len(report['missing_evidence']))
        self.assertTrue(any('logsrange: PARTIAL' in gap for gap in report['missing_evidence']))

    def test_should_not_leave_run_lock_when_receipt_creation_fails(self):
        with patch.object(runtime, 'config_fingerprint', side_effect=ValueError('fixture')):
            with self.assertRaisesRegex(ValueError, 'fixture'):
                self.runner.run('test', 'app', 'health', [], request_id='failed-receipt')
        job_id = 'job-' + runtime.digest('failed-receipt')[:24]
        self.assertFalse((self.runner.directory(job_id) / 'run.lock').exists())

    def test_should_ignore_malformed_phase_events_without_crashing_task(self):
        self.fixture.write_text("print('TASK_EVENT []')\nprint('TASK_EVENT {\"phase\":\"install\",\"status\":[]}')\nprint('RESULT OK')\n", encoding='utf-8')
        result = self.runner.run('test', 'app', 'upload', [])
        self.assertEqual('SUCCEEDED', result['status'])
        self.assertEqual([], result['steps'])

    def test_should_enforce_deadline_after_child_closes_output_streams(self):
        self.fixture.write_text("import os, time\nos.close(1)\nos.close(2)\ntime.sleep(20)\n", encoding='utf-8')
        self.runner.timeout = 1
        self.assertEqual('UNKNOWN', self.runner.run('test', 'app', 'restart', [])['status'])

    @unittest.skipUnless(shutil.which('pwsh'), 'PowerShell 7 required for entrypoint integration')
    def test_should_preserve_chinese_failure_evidence_without_connecting_ssh(self):
        scripts = self.root / 'scripts'
        scripts.mkdir()
        shutil.copyfile(ROOT / 'scripts/service-ops.ps1', scripts / 'service-ops.ps1')
        shutil.copyfile(ROOT / 'scripts/ops_config.py', scripts / 'ops_config.py')
        command = [shutil.which('pwsh'), '-NoProfile', '-File', str(scripts / 'service-ops.ps1')]
        runner = runtime.TaskRunner(self.root, self.runner.state, command)
        result = runner.run('test', 'app', 'logsrange', ['bad', 'bad', '', 'node'])
        evidence = runner.evidence(result['job_id'])['output']
        self.assertEqual('FAILED', result['status'])
        self.assertIn('时间必须为有效的', evidence)
        self.assertNotIn('\ufffd', evidence)


if __name__ == '__main__':
    unittest.main()
