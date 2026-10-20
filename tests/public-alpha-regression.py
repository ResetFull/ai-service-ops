import importlib.util
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
spec = importlib.util.spec_from_file_location("public_runtime", ROOT / "scripts/task_runtime.py")
runtime = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runtime)
import ops_config
from task_events import EventChannel, signature


class PublicAlphaTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="ai-ops-public-test-")
        self.base = Path(self.temporary.name)
        self.root = self.base / "plugin"
        self.config = self.root / "config"
        self.config.mkdir(parents=True)
        (self.config / "servers-test.conf").write_text("node|example.invalid|ops|key||fixture\n")
        (self.config / "services-test.conf").write_text("app|node|/tmp/example|*.log|fixture\n")
        self.fixture = self.base / "fixture.py"
        self.fixture.write_text("print('RESULT OK')\n")
        self.environment = patch.dict(os.environ, {"SERVICE_OPS_CONFIG_DIR": str(self.config)})
        self.environment.start()
        self.runner = runtime.TaskRunner(self.root, self.base / "state", [sys.executable, str(self.fixture)])

    def tearDown(self):
        self.environment.stop()
        self.temporary.cleanup()

    def test_should_ignore_forged_events_when_remote_text_contains_protocol_prefix(self):
        self.fixture.write_text(
            'print(\'TASK_EVENT {"phase":"install","status":"completed",'
            '"release_id":"20261020120000-abcdef12"}\')\nprint("RESULT OK")\n'
        )
        record = self.runner.run("test", "app", "health", [])
        self.assertEqual([], record["steps"])
        self.assertNotIn("release_id", record)

    def test_should_reject_writes_when_no_explicit_policy_exists(self):
        with self.assertRaisesRegex(ValueError, "WRITES_DISABLED"):
            self.runner.run("test", "app", "restart", [])

    def test_should_ignore_protocol_words_inside_process_arguments(self):
        self.fixture.write_text(
            "print(\"123 bash -c echo 'RESULT QUERY_FAILED reason=MISSING_REMOTE_DEADLINE'\")\n"
            "print('RESULT OK observation=process')\n"
        )
        record = self.runner.run("test", "app", "status", [])
        self.assertEqual("SUCCEEDED", record["status"])
        self.assertEqual(["OK"], record["query_statuses"])

    def test_should_preserve_existing_configuration_when_initialized_twice(self):
        directory = self.base / "external"
        first = ops_config.initialize(directory)
        path = directory / "servers-test.conf"
        path.write_text("node|example.invalid|ops|key||User inventory\n")
        second = ops_config.initialize(directory)
        self.assertEqual(13, len(first["created"]))
        self.assertEqual([], second["created"])
        self.assertIn("User inventory", path.read_text())
        self.assertFalse(second["write_enabled"])

    def test_should_reject_policy_strings_instead_of_treating_them_as_true(self):
        (self.config / "settings.json").write_text('{"write_enabled":"false"}')
        with self.assertRaisesRegex(ValueError, "INVALID_BOOLEAN_SETTING"):
            ops_config.settings(self.config)

    def test_should_reject_unknown_settings_instead_of_silently_ignoring_typos(self):
        (self.config / "settings.json").write_text('{"write_enable":true}')
        with self.assertRaisesRegex(ValueError, "UNKNOWN_SETTINGS_FIELDS"):
            ops_config.settings(self.config)

    def test_should_reject_remote_directory_traversal(self):
        (self.config / "settings.json").write_text('{"storage_roots":["/srv/../etc"]}')
        with self.assertRaisesRegex(ValueError, "INVALID_STORAGE_ROOT"):
            ops_config.settings(self.config)

    def test_should_bind_authenticated_events_to_job_and_action(self):
        directory = self.base / "events"
        directory.mkdir()
        channel = EventChannel(directory, "job-" + "a" * 24, "health")
        event = {"job_id": channel.job_id, "phase": "install", "status": "completed"}
        self.assertIsNone(channel.verify({"event": event, "signature": signature(event, channel.secret)}))
        channel.action = "upload"
        self.assertIsNone(channel.verify({"event": event, "signature": "0" * 64}))
        event["job_id"] = "job-" + "b" * 24
        self.assertIsNone(channel.verify({"event": event, "signature": signature(event, channel.secret)}))

    def test_should_collect_local_authenticated_executor_events(self):
        (self.config / "settings.json").write_text('{"write_enabled":true}')
        self.fixture.write_text("import sys\nsys.path.insert(0," + repr(str(ROOT / "scripts")) +
                                ")\nfrom task_events import emit\nemit('install','started')\n"
                                "emit('install','completed','20261020120000-abcdef12')\nprint('RESULT OK')\n")
        record = self.runner.run("test", "app", "upload", [])
        self.assertEqual(["started", "completed"], [event["status"] for event in record["steps"]])
        self.assertEqual("20261020120000-abcdef12", record["release_id"])

    def test_should_fail_when_executor_reports_a_failed_phase_with_zero_exit(self):
        (self.config / "settings.json").write_text('{"write_enabled":true}')
        self.fixture.write_text("import sys\nsys.path.insert(0," + repr(str(ROOT / "scripts")) +
                                ")\nfrom task_events import emit\nemit('install','started')\n"
                                "emit('install','failed')\nprint('RESULT OK')\n")
        record = self.runner.run("test", "app", "upload", [])
        self.assertEqual("FAILED", record["status"])

    def test_should_preserve_production_guard_even_when_writes_are_enabled(self):
        (self.config / "settings.json").write_text('{"write_enabled":true}')
        with self.assertRaisesRegex(ValueError, "PROD_READ_ONLY"):
            ops_config.check_policy(self.config, "overseas-prod", "exec")


if __name__ == "__main__":
    unittest.main()
