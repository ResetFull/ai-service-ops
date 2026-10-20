import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
import zipfile

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
from package_release import build
from privacy_check import inspect_bytes, scan_archive, scan_source
from run_checks import engines
from task_events import EventChannel


class PublicationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="ai-ops-publication-")
        self.base = Path(self.temporary.name)

    def tearDown(self):
        self.temporary.cleanup()

    def test_should_reject_ssh_files_and_private_key_material(self):
        material = ("-----BEGIN " + "OPENSSH PRIVATE KEY-----\n").encode()
        self.assertTrue(inspect_bytes("innocent.txt", material))
        for name in (".ssh/config", "nested/.SSH/known_hosts", "key.pem", "id_ed25519",
                     "config/servers-test.conf", "standalone.pub"):
            self.assertTrue(inspect_bytes(name, b""), name)

    def test_should_detect_addresses_without_printing_the_matched_value(self):
        address = ".".join(("10", "20", "30", "40"))
        findings = inspect_bytes("README.md", address.encode())
        self.assertEqual("NON_EXAMPLE_ADDRESS", findings[0]["category"])
        self.assertNotIn(address, json.dumps(findings))
        self.assertFalse(inspect_bytes("README.md", b"203.0.113.10 127.0.0.1"))

    def test_should_check_forced_tracked_keys_even_when_gitignores_them(self):
        self.git("init", "-q")
        (self.base / ".gitignore").write_text(".ssh/\n")
        (self.base / ".ssh").mkdir()
        (self.base / ".ssh/config").write_text("fixture")
        self.git("add", "-f", ".ssh/config")
        self.assertTrue(scan_source(self.base))

    def test_should_reject_unsafe_archive_paths(self):
        path = self.base / "bad.zip"
        with zipfile.ZipFile(path, "w") as archive:
            archive.writestr("../outside", "fixture")
        self.assertEqual("UNSAFE_PATH", scan_archive(path)[0]["category"])

    def test_should_package_reproducibly_and_exclude_tests_and_local_state(self):
        self.git("init", "-q")
        for name in ("plugin.json", ".codex-plugin/plugin.json", "README.md"):
            target = self.base / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(ROOT / name, target)
        (self.base / ".gitignore").write_text("dist/\n")
        (self.base / "tests").mkdir()
        (self.base / "tests/fixture.txt").write_text("not in plugin archive")
        first, digest = build(self.base, allow_dirty=True)
        before = first.read_bytes()
        second, again = build(self.base, allow_dirty=True)
        self.assertEqual(digest, again)
        self.assertEqual(before, second.read_bytes())
        with zipfile.ZipFile(second) as archive:
            self.assertNotIn("tests/fixture.txt", archive.namelist())
            metadata = json.loads(archive.read("release.json"))
            self.assertTrue(metadata["preview"])
            for name, expected in metadata["files"].items():
                self.assertEqual(expected, hashlib.sha256(archive.read(name)).hexdigest())
        with self.assertRaisesRegex(ValueError, "CLEAN_CHECKOUT_REQUIRED"):
            build(self.base)

    def git(self, *arguments):
        subprocess.run(["git", "-C", str(self.base), *arguments], check=True, capture_output=True)

    def test_should_reject_writes_at_both_native_entrypoints(self):
        config = self.base / "config"
        config.mkdir()
        (config / "settings.json").write_text('{"write_enabled":false}')
        environment = dict(os.environ, SERVICE_OPS_CONFIG_DIR=str(config), SERVICE_OPS_PYTHON=sys.executable)
        for extension in (".ps1", ".sh"):
            prefix = engines()[extension]
            if not prefix:
                continue
            result = subprocess.run(prefix + [str(ROOT / ("scripts/service-ops" + extension)), "test", "absent", "restart"],
                                    env=environment, capture_output=True, timeout=30)
            self.assertNotEqual(0, result.returncode, extension)
            self.assertIn(b"WRITES_DISABLED", result.stdout + result.stderr, extension)

    def test_should_accept_signed_events_from_both_native_producers(self):
        for extension in (".ps1", ".sh"):
            prefix = engines()[extension]
            if not prefix:
                continue
            directory = self.base / extension[1:]
            directory.mkdir()
            channel = EventChannel(directory, "job-" + "a" * 24, "build")
            environment = dict(os.environ, **channel.environment(), SERVICE_OPS_TASK_EVENTS="1",
                               SERVICE_OPS_PYTHON=sys.executable.replace("\\", "/"))
            if extension == ".ps1":
                script = directory / "emit.ps1"
                script.write_text(
                    "$PluginRoot=$env:PROJECT_ROOT\n"
                    "$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PluginRoot 'scripts/service-ops.ps1'),[ref]$null,[ref]$null)\n"
                    "$function=$ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Write-TaskEvent'},$false)[0]\n"
                    "Invoke-Expression $function.Extent.Text\nWrite-TaskEvent build started @{}\n", encoding="utf-8")
                command = prefix + [str(script)]
            else:
                command = prefix + ["-c", "source <(sed '/^usage(){/,$d' scripts/service-ops.sh)\nPLUGIN_ROOT=$(pwd)\ntask_event build started"]
            environment["PROJECT_ROOT"] = str(ROOT)
            result = subprocess.run(command, cwd=ROOT, env=environment, capture_output=True, timeout=30)
            self.assertEqual(0, result.returncode, result.stderr.decode(errors="replace"))
            self.assertEqual(["started"], [event["status"] for event in channel.read()])
            self.assertNotIn(b"TASK_EVENT", result.stdout)


if __name__ == "__main__":
    unittest.main()
