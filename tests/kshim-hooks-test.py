#!/usr/bin/python3
"""Behaviour tests for the kShimC hook wiring in the boot-image lifecycle.

The real armada-bootimg-update and armada-bootimg-finalize shell scripts run
from rewritten copies whose fixed paths (/etc/armada/boot-method and the
sibling helpers) point into a temporary fixture — the same rewrite the
existing bootimg-regen test uses for findmnt and the /run lock. The helpers
behind those paths are recording stubs, so dispatch, exact argv and exit
status are asserted without root, a mounted ESP, a block device, a packer or a
real boot image.
"""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
LIBEXEC = ROOT / "system_files/usr/libexec/armada"
UPDATE = LIBEXEC / "armada-bootimg-update"
FINALIZE = LIBEXEC / "armada-bootimg-finalize"
SYNC_UNIT = (ROOT / "system_files/usr/lib/systemd/system"
             "/armada-bootimg-sync.service")
FINALIZE_DROPIN = (ROOT / "system_files/usr/lib/systemd/system"
                   "/ostree-finalize-staged.service.d/10-armada-bootimg.conf")


def rewrite(source, destination, replacements):
    """Copy a shipped script, pointing its fixed tool paths at the fixture."""
    text = source.read_text(encoding="utf-8")
    for old, new in replacements:
        assert old in text, "fixed path moved out of %s: %s" % (source, old)
        text = text.replace(old, new)
    destination.write_text(text, encoding="utf-8")
    destination.chmod(0o755)


def directives(path, key):
    values = []
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if line.startswith(key + "="):
            values.append(line[len(key) + 1:])
    return values


class HookTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(os.path.realpath(self.tmp.name))
        self.log = self.root / "calls.log"
        self.method = self.root / "boot-method"
        self.state = self.make_stub("stub-kshim-state")
        self.update = self.root / "armada-bootimg-update"
        rewrite(UPDATE, self.update,
                [("/etc/armada/boot-method", str(self.method)),
                 ("/usr/libexec/armada/armada-kshim-state", str(self.state))])
        # If the early dispatch is missing, the legacy path fails on the first
        # of these, so these values also prove the legacy checks were skipped.
        self.legacy = {
            "ESP": str(self.root / "missing-esp"),
            "BOOTROOT": str(self.root / "missing-boot"),
            "SYSROOT": str(self.root / "missing-sysroot"),
            "ARGS_FILE": str(self.root / "missing-args"),
            "DTB_LIST": str(self.root / "missing-dtbs"),
            "MKBOOTIMG": str(self.root / "missing-mkbootimg"),
        }

    # -- fixtures ---------------------------------------------------------

    def make_stub(self, name):
        path = self.root / name
        path.write_text(
            "#!/bin/bash\n"
            'printf "%s\\n" "$0" "$@" >> "' + str(self.log) + '"\n'
            'exit "${STUB_EXIT:-0}"\n',
            encoding="utf-8")
        path.chmod(0o755)
        return path

    def calls(self):
        if not self.log.exists():
            return []
        return self.log.read_text(encoding="utf-8").splitlines()

    def clear_calls(self):
        self.log.unlink(missing_ok=True)

    def run_script(self, script, env=None, args=()):
        environment = {"PATH": "/usr/bin:/bin", "HOME": str(self.root)}
        environment.update(env or {})
        proc = subprocess.run(["bash", str(script)] + list(args),
                              cwd=str(self.root), env=environment,
                              capture_output=True, text=True)
        return proc.returncode, proc.stdout + proc.stderr

    def finalize_copy(self):
        self.updater = self.make_stub("stub-update")
        self.rollback = self.make_stub("stub-bootc")
        finalize = self.root / "armada-bootimg-finalize"
        rewrite(FINALIZE, finalize,
                [("/etc/armada/boot-method", str(self.method)),
                 ("/usr/libexec/armada/armada-bootimg-update",
                  str(self.updater)),
                 ("/usr/bin/bootc", str(self.rollback))])
        return finalize

    # -- update: kShimC dispatch ------------------------------------------

    def test_kshimc_dispatches_sync_with_exact_argv(self):
        self.method.write_text("kshimc\n", encoding="utf-8")
        code, out = self.run_script(self.update, self.legacy)
        self.assertEqual(code, 0, out)
        self.assertEqual(self.calls(), [str(self.state), "sync"])
        self.assertNotIn("missing", out)
        self.assertFalse(Path(self.legacy["ESP"]).exists())

    def test_kshimc_snapshot_prev_records_boot_with_exact_argv(self):
        self.method.write_text("kshimc\n", encoding="utf-8")
        for status in (0, 1):
            with self.subTest(status=status):
                self.clear_calls()
                code, out = self.run_script(
                    self.update, dict(self.legacy, STUB_EXIT=str(status)),
                    ["--snapshot-prev"])
                self.assertEqual(code, status, out)
                self.assertEqual(self.calls(),
                                 [str(self.state), "record-boot"])

    def test_kshimc_preserves_helper_status_without_abl_fallback(self):
        self.method.write_text("kshimc\n", encoding="utf-8")
        for status in (0, 1, 2, 3):
            with self.subTest(status=status):
                self.clear_calls()
                code, out = self.run_script(
                    self.update, dict(self.legacy, STUB_EXIT=str(status)))
                self.assertEqual(code, status, out)
                self.assertEqual(self.calls(), [str(self.state), "sync"])
                self.assertFalse(Path(self.legacy["ESP"]).exists())
                self.assertNotIn(str(self.legacy["MKBOOTIMG"]), out)

    def test_kshimc_refuses_invalid_arguments(self):
        self.method.write_text("kshimc\n", encoding="utf-8")
        for args in (["--snapshot-prev", "extra"], ["--other"], ["a", "b"]):
            with self.subTest(args=args):
                self.clear_calls()
                code, out = self.run_script(self.update, self.legacy, args)
                self.assertEqual(code, 1, out)
                self.assertIn("kshimc takes no arguments", out)
                self.assertEqual(self.calls(), [])

    # -- update: method selection -----------------------------------------

    def test_none_method_does_nothing(self):
        self.method.write_text("none\n", encoding="utf-8")
        for args in ((), ["--snapshot-prev"]):
            with self.subTest(args=args):
                self.clear_calls()
                code, out = self.run_script(self.update, self.legacy, args)
                self.assertEqual(code, 0, out)
                self.assertIn("not managed by bootc", out)
                self.assertEqual(self.calls(), [])
                self.assertFalse(Path(self.legacy["ESP"]).exists())

    def test_unknown_method_is_refused_before_any_legacy_write(self):
        self.method.write_text("nothing\n", encoding="utf-8")
        code, out = self.run_script(self.update, self.legacy)
        self.assertEqual(code, 1, out)
        self.assertIn("unknown boot method", out)
        self.assertEqual(self.calls(), [])
        self.assertFalse(Path(self.legacy["ESP"]).exists())

    def test_method_file_is_not_sourced_as_shell(self):
        marker = self.root / "pwned"
        self.method.write_text("kshimc; touch %s\n" % marker,
                               encoding="utf-8")
        code, out = self.run_script(self.update, self.legacy)
        self.assertEqual(code, 1, out)
        self.assertIn("unknown boot method", out)
        self.assertFalse(marker.exists())

    def test_unreadable_method_file_fails(self):
        self.method.mkdir()
        code, out = self.run_script(self.update, self.legacy)
        self.assertEqual(code, 1, out)
        self.assertIn("cannot read", out)
        self.assertEqual(self.calls(), [])

    def test_absent_or_abl_method_keeps_the_legacy_path(self):
        for value in (None, "abl\n"):
            with self.subTest(method=value):
                if value is None:
                    if self.method.exists():
                        self.method.unlink()
                else:
                    self.method.write_text(value, encoding="utf-8")
                self.clear_calls()
                code, out = self.run_script(self.update, self.legacy)
                self.assertEqual(code, 1, out)
                self.assertIn("missing %s" % self.legacy["DTB_LIST"], out)
                self.assertEqual(self.calls(), [])

    # -- finalize: kShimC vs ABL ------------------------------------------

    def test_finalize_kshimc_propagates_exact_status_without_rollback(self):
        finalize = self.finalize_copy()
        self.method.write_text("kshimc\n", encoding="utf-8")
        for status in (0, 1, 2, 3):
            with self.subTest(status=status):
                self.clear_calls()
                code, out = self.run_script(finalize, {"STUB_EXIT": str(status)})
                self.assertEqual(code, status, out)
                self.assertEqual(self.calls(), [str(self.updater)])
                self.assertNotIn("rollback", out)

    def test_finalize_abl_rolls_back_and_keeps_the_update_status(self):
        finalize = self.finalize_copy()
        for value, status in ((None, 0), ("abl\n", 7)):
            with self.subTest(method=value, status=status):
                if value is None:
                    if self.method.exists():
                        self.method.unlink()
                else:
                    self.method.write_text(value, encoding="utf-8")
                self.clear_calls()
                code, out = self.run_script(finalize, {"STUB_EXIT": str(status)})
                self.assertEqual(code, status, out)
                expected = [str(self.updater)]
                if status != 0:
                    expected += [str(self.rollback), "rollback"]
                    self.assertIn("rolling back", out)
                self.assertEqual(self.calls(), expected)

    def test_finalize_none_method_neither_updates_nor_rolls_back(self):
        finalize = self.finalize_copy()
        self.method.write_text("none\n", encoding="utf-8")
        code, out = self.run_script(finalize, {"STUB_EXIT": "1"})
        self.assertEqual(code, 0, out)
        self.assertIn("nothing to do", out)
        self.assertEqual(self.calls(), [])

    def test_finalize_unknown_method_is_refused(self):
        finalize = self.finalize_copy()
        self.method.write_text("bogus\n", encoding="utf-8")
        code, out = self.run_script(finalize)
        self.assertEqual(code, 1, out)
        self.assertIn("unknown boot method", out)
        self.assertEqual(self.calls(), [])

    def test_finalize_unreadable_method_is_refused(self):
        finalize = self.finalize_copy()
        self.method.mkdir()
        code, out = self.run_script(finalize)
        self.assertEqual(code, 1, out)
        self.assertIn("cannot read", out)
        self.assertEqual(self.calls(), [])


class UnitTest(unittest.TestCase):
    """The requested mount and ordering semantics of the shipped units."""

    def test_sync_unit_adds_var_and_keeps_its_order_and_timeout(self):
        mounts = directives(SYNC_UNIT, "RequiresMountsFor")
        self.assertEqual(len(mounts), 1, mounts)
        self.assertEqual(set(mounts[0].split()),
                         {"/sysroot", "/boot", "/boot/efi", "/var"})
        self.assertEqual(directives(SYNC_UNIT, "TimeoutStopSec"), ["180"])
        starts = directives(SYNC_UNIT, "ExecStart")
        self.assertEqual(len(starts), 1, starts)
        self.assertTrue(starts[0].startswith("-"), starts)
        self.assertTrue(starts[0].endswith(
            "/usr/libexec/armada/armada-bootimg-update --snapshot-prev"),
            starts)
        self.assertEqual(directives(SYNC_UNIT, "ExecStop"),
                         ["/usr/libexec/armada/armada-bootimg-update"])
        after = " ".join(directives(SYNC_UNIT, "After"))
        self.assertIn("local-fs.target", after)
        self.assertIn("systemd-journal-flush.service", after)
        before = " ".join(directives(SYNC_UNIT, "Before"))
        self.assertIn("ostree-finalize-staged.service", before)
        self.assertIn("final.target", before)
        self.assertEqual(directives(SYNC_UNIT, "Conflicts"), ["final.target"])

    def test_finalize_dropin_adds_var_and_appends_one_hook(self):
        mounts = directives(FINALIZE_DROPIN, "RequiresMountsFor")
        self.assertEqual(len(mounts), 1, mounts)
        self.assertEqual(set(mounts[0].split()), {"/boot/efi", "/var"})
        self.assertEqual(directives(FINALIZE_DROPIN, "ExecStop"),
                         ["/usr/libexec/armada/armada-bootimg-finalize"])
        self.assertEqual(directives(FINALIZE_DROPIN, "TimeoutStopSec"), [])

    def test_units_do_not_provision_or_mask(self):
        for path in (SYNC_UNIT, FINALIZE_DROPIN):
            text = path.read_text(encoding="utf-8")
            self.assertNotIn("provision", text)
            self.assertNotIn("Mask", text)
            self.assertNotIn("ConditionPathExists=!", text)


if __name__ == "__main__":
    unittest.main()
