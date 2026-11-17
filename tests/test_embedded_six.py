"""Offline contracts for the shared six backend inside the unified owner."""
from __future__ import annotations

import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


MODULE = Path(__file__).resolve().parents[1] / "modules/mt6639-6g"


class EmbeddedSixTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="embedded-six-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.owner = self.root / "owner"
        self.mod = self.owner / "six"
        shutil.copytree(MODULE, self.mod)
        (self.owner / "bin").mkdir()
        self.work = self.root / "work"
        self.calls = self.root / "calls"
        self.calls.write_text("")
        self.stub = self.root / "stub"
        self.stub.mkdir()
        self.cfg = self.root / "wifi.cfg"
        self.cfg.write_text("DisallowBand6G 1\n")
        self.ko = self.root / "wlan.ko"
        self.ko.write_text("stock fixture\n")
        self.boot_id = "11111111-1111-4111-8111-111111111111"
        self.boot = self.root / "boot"
        self.boot.write_text(self.boot_id + "\n")
        self.mountinfo = self.root / "mountinfo"
        self.mountinfo.write_text("")
        self.script(self.owner / "bin/unified-guard.sh",
                    'echo "guard $*" >> "$CALLS"\nexit "${GUARD_RC:-0}"\n')
        self.script(self.owner / "bin/verify-module.sh",
                    'echo "verify $*" >> "$CALLS"\nexit "${VERIFY_RC:-0}"\n')
        self.script(self.stub / "iw", "exit 0\n")
        self.script(self.stub / "getenforce", "echo Enforcing\n")
        self.env = dict(os.environ, MT6639_TEST_MODE="1",
                        MT6639_TEST_MODULE_OWNER=str(self.owner),
                        MODDIR=str(self.mod), WORK=str(self.work),
                        CFG=str(self.cfg), STOCK_KO=str(self.ko),
                        STOCK_CFG_SHA=hashlib.sha256(self.cfg.read_bytes()).hexdigest(),
                        STOCK_KO_SHA=hashlib.sha256(self.ko.read_bytes()).hexdigest(),
                        BOOT_ID_FILE=str(self.boot), MOUNTINFO_FILE=str(self.mountinfo),
                        INIT_MOUNTINFO_FILE=str(self.mountinfo), INIT_CFG_PATH=str(self.cfg),
                        CALLS=str(self.calls), PATH=f"{self.stub}:{os.environ['PATH']}")

    def script(self, path, body):
        path.write_text("#!/bin/sh\n" + body)
        path.chmod(0o755)

    def run_script(self, name, *args, extra=None, standard_args=True):
        env = dict(self.env, **(extra or {}))
        command = ["sh", str(self.mod / "bin" / name)]
        if standard_args:
            command.append(str(self.mod))
        return subprocess.run(command + list(args), env=env, capture_output=True,
                              text=True, timeout=15)

    def test_production_owner_inference_is_exact_and_ignores_environment(self):
        helper = MODULE / "bin/owner.sh"
        for moddir, owner, embedded in (
            ("/data/adb/modules/mt6639-hotspot/six", "/data/adb/modules/mt6639-hotspot", "1"),
            ("/data/adb/modules/mt6639-6g", "/data/adb/modules/mt6639-6g", "0"),
            ("/tmp/mt6639-hotspot/six", "/tmp/mt6639-hotspot/six", "0"),
            ("/data/adb/modules/mt6639-hotspot/six/", "/data/adb/modules/mt6639-hotspot/six/", "0"),
        ):
            with self.subTest(moddir=moddir):
                result = subprocess.run(
                    ["sh", "-c", '. "$1"; printf "%s %s\\n" "$MODULE_OWNER" "$MODULE_EMBEDDED"',
                     "sh", str(helper)], capture_output=True, text=True,
                    env=dict(self.env, MODDIR=moddir, MT6639_TEST_MODE="0", MODULE_OWNER="/untrusted"))
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout.strip(), f"{owner} {embedded}")

    def test_every_mutation_checks_owner_before_work_or_old_authority(self):
        for name, args in (("control.sh", ("enable",)), ("control.sh", ("disable",)),
                           ("control.sh", ("toggle",)), ("control.sh", ("refresh",)),
                           ("native.sh", ("apply",)), ("native.sh", ("restore",)),
                           ("apply.sh", ()), ("restore.sh", ()),
                           ("refresh-6g.sh", ()), ("softreboot-watch.sh", ("run",))):
            with self.subTest(name=name, args=args):
                self.calls.write_text("")
                result = self.run_script(name, *args, extra={"GUARD_RC": "3"})
                self.assertEqual(result.returncode, 3, result.stdout + result.stderr)
                self.assertEqual(self.calls.read_text(), f"guard {self.owner} check\n")
                self.assertFalse(self.work.exists())
        # A relocated same-boot transaction is retained, never reconciled after
        # the guard rejects the legacy installation or the install boot.
        self.work.mkdir()
        authority = self.work / "active_tx"
        authority.write_text(str(self.work / "transactions/t-old-guardian") + "\n")
        before = authority.read_bytes()
        result = self.run_script("native.sh", "apply", extra={"GUARD_RC": "3"})
        self.assertEqual(result.returncode, 3)
        self.assertEqual(authority.read_bytes(), before)
        self.assertFalse((self.work / "state").exists())

    def test_verification_follows_guard_and_fails_closed(self):
        result = self.run_script("native.sh", "restore", extra={"VERIFY_RC": "3"})
        self.assertEqual(result.returncode, 3)
        self.assertEqual(self.calls.read_text(),
                         f"guard {self.owner} check\nverify {self.owner}\n")
        self.assertFalse(self.work.exists())

    def test_embedded_verifier_delegates_without_six_manifest(self):
        result = self.run_script("verify-module.sh")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.calls.read_text(), f"verify {self.owner}\n")

    def test_observation_cannot_repair_native_permissions_without_owner_guard(self):
        native = self.mod / "bin/mount-txn"
        self.script(native, 'echo "native $*" >> "$CALLS"\n')
        native.chmod(0o644)
        result = self.run_script("native.sh", "inspect", extra={"GUARD_RC": "3"})
        self.assertEqual(result.returncode, 3)
        self.assertEqual(native.stat().st_mode & 0o777, 0o644)
        self.assertEqual(self.calls.read_text(), f"guard {self.owner} check\n")

    def test_status_remains_available_when_guard_rejects(self):
        result = self.run_script("control.sh", "status", extra={"GUARD_RC": "3"})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("active_tx=none", result.stdout)
        self.assertEqual(self.calls.read_text(), "")

    def test_root_markers_prevent_enable_and_refresh(self):
        for marker in ("disable", "remove"):
            (self.owner / marker).touch()
            for name, args in (("control.sh", ("enable",)), ("native.sh", ("apply",)),
                               ("apply.sh", ()), ("refresh-6g.sh", ())):
                with self.subTest(marker=marker, name=name):
                    result = self.run_script(name, *args)
                    self.assertEqual(result.returncode, 3, result.stdout + result.stderr)
                    self.assertIn("module_disabled_or_removing", result.stderr)
            (self.owner / marker).unlink()

    def test_disabled_owner_still_allows_checked_restore(self):
        (self.owner / "disable").touch()
        self.script(self.mod / "bin/mount-txn", 'echo "unexpected-native $*" >> "$CALLS"\nexit 99\n')
        result = self.run_script("native.sh", "restore")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual((self.work / "state").read_text(), "restored\n")
        self.assertNotIn("unexpected-native", self.calls.read_text())

    def test_embedded_card_update_is_noop_and_show_needs_no_metadata(self):
        (self.owner / "module.prop").write_text("owner metadata\n")
        for file in ("module.prop", "module.prop.template"):
            (self.mod / file).unlink(missing_ok=True)
        result = self.run_script("status-card.sh", "update", "enable", "0")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.owner / "module.prop").read_text(), "owner metadata\n")
        self.assertFalse((self.mod / "module.prop").exists())
        (self.owner / "disable").touch()
        result = self.run_script("status-card.sh", "show")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("模块已禁用", result.stdout)
        self.assertIn("事务：空闲", result.stdout)

    def test_checker_uses_owner_manifest_and_rejects_nonfixed_production_path(self):
        (self.owner / "module.prop").write_text("version=fixture\n")
        (self.owner / "SHA256SUMS").write_text("fixture\n")
        (self.mod / "module.prop").unlink(missing_ok=True)
        result = self.run_script("post-reboot-check.sh", "restored", str(self.mod), standard_args=False)
        self.assertIn("module_version=fixture", result.stdout)
        self.assertNotIn("module_prop_missing", result.stdout)
        self.assertNotIn("module_sums_missing", result.stdout)
        self.assertIn(f"verify {self.owner}\n", self.calls.read_text())
        result = self.run_script("post-reboot-check.sh", "restored", str(self.mod),
                                 standard_args=False, extra={"MT6639_TEST_MODE": "0"})
        self.assertEqual(result.returncode, 64)
        self.assertIn("invalid_six_path", result.stderr)

    def test_watchdog_routes_through_owner_and_checks_each_iteration(self):
        self.work.mkdir()
        (self.work / "state").write_text("active\n")
        watch = self.work / "softreboot-watch"
        watch.mkdir()
        (watch / "state").write_text(f"boot={self.boot_id}\nss=500\nattempts=0\n")
        ss = self.root / "ss"
        ss.write_text("500\n")
        self.script(self.stub / "sleep", 'touch "$MT6639_TEST_MODULE_OWNER/remove"\n')
        self.script(self.owner / "bin/radio-control.sh", 'echo "radio $*" >> "$CALLS"\n')
        result = self.run_script("softreboot-watch.sh", "run", extra={
            "MT6639_WATCH_ITER": "2", "MT6639_WATCH_INTERVAL": "0",
            "MT6639_WATCH_CHECK_INTERVAL": "1", "MT6639_TEST_WIFI_ON": "1",
            "SYSTEM_SERVER_PID_FILE": str(ss),
            "MT6639_TEST_REFRESH_CMD": "exit 99",  # Must not bypass embedded routing.
        })
        self.assertEqual(result.returncode, 3, result.stdout + result.stderr)
        calls = self.calls.read_text()
        self.assertEqual(calls.count(f"radio {self.owner} six-refresh\n"), 1)
        self.assertGreaterEqual(calls.count(f"guard {self.owner} check\n"), 3)
        self.assertIn("owner_unavailable; stop", (watch / "watch.log").read_text())


if __name__ == "__main__":
    unittest.main()
