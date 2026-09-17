"""Standard-library tests; run directly on Windows or a hosted Mac."""
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import zipfile

import hosted


class HostedTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="eden-hosted-test-")
        self.addCleanup(self.temp.cleanup)
        # Resolved, because on macOS /var is a symlink to /private/var and
        # tempfile hands back the short form. hosted.py resolves every path it
        # is given — deliberately, since that is how it checks nothing escapes
        # the run directory — so an unresolved fixture compares a real path
        # against the same real path spelt differently and fails on a Mac
        # while passing everywhere it was written.
        self.root = Path(self.temp.name).resolve()

    def sources(self):
        for name in hosted.SOURCE_FILES:
            path = self.root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("test fixture", encoding="utf-8")

    def report(self, status="failed", compiled=False, **extra):
        run = self.root / "build/run-1"
        run.mkdir(parents=True)
        (run / "result.json").write_text(json.dumps({"status": status, "native_compiled": compiled, **extra}))
        (run / "xcodebuild.log").write_text("test log")
        return run

    def ipa(self, run, names=("Payload/EDEN.app/EDEN", "Payload/EDEN.app/Info.plist"), where=None):
        path = (where or run) / hosted.IPA_NAME
        with zipfile.ZipFile(path, "w") as archive:
            for name in names:
                archive.writestr(name, "fixture")
        return path

    def test_bundle_excludes_private_state_and_build_products(self):
        self.sources()
        for name in (".env", "lan-token.txt", "EDEN/private.key", "build/secret.log", "EDEN.xcodeproj/xcuserdata/private.txt"):
            path = self.root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("PRIVATE")
        with zipfile.ZipFile(hosted.bundle(self.root)) as archive:
            self.assertEqual(set(archive.namelist()), set(hosted.SOURCE_FILES) | {".gitignore"})
            self.assertIn(".github/workflows/eden-ios-macos.yml", archive.namelist())
            self.assertFalse(any(b"PRIVATE" in archive.read(name) for name in archive.namelist()))

    def test_bundle_missing_source_fails(self):
        self.sources()
        (self.root / "EDEN/Info.plist").unlink()
        with self.assertRaisesRegex(ValueError, "Missing or unsafe"):
            hosted.bundle(self.root)

    def test_bundle_never_overwrites_previous_bundle(self):
        self.sources()
        first, second = hosted.bundle(self.root), hosted.bundle(self.root)
        self.assertNotEqual(first, second)
        self.assertTrue(first.is_file() and second.is_file())

    def test_no_report_is_not_success(self):
        output = hosted.collect(self.root)
        self.assertTrue((output / "NO_BUILD_RESULT.txt").is_file())
        self.assertFalse((output / "EDEN-simulator.app.zip").exists())

    def test_failed_build_keeps_diagnostics_without_packaging_app(self):
        self.report()
        with patch.object(hosted.subprocess, "run") as process:
            output = hosted.collect(self.root)
        process.assert_not_called()
        self.assertEqual((output / "xcodebuild.log").read_text(), "test log")
        self.assertEqual(json.loads((output / "result.json").read_text())["status"], "failed")

    def test_success_without_executable_fails(self):
        self.report("passed", True)
        with self.assertRaisesRegex(ValueError, "no simulator executable"):
            hosted.collect(self.root)

    def test_success_packages_only_expected_simulator_app(self):
        run = self.report("passed", True)
        app = run / "DerivedData/Build/Products/Debug-iphonesimulator/EDEN.app"
        app.mkdir(parents=True)
        (app / "EDEN").write_bytes(b"test executable fixture, not a compiled app")
        with patch.object(hosted.subprocess, "run") as process:
            hosted.collect(self.root)
        command = process.call_args.args[0]
        self.assertEqual(command[0], "ditto")
        self.assertIn(str(app), command)
        self.assertTrue(command[-1].endswith("EDEN-simulator.app.zip"))

    def test_ipa_report_ships_ipa_and_no_simulator_app(self):
        run = self.report("passed", True, ipa=str(self.root / "build/run-1" / hosted.IPA_NAME), signed=False)
        self.ipa(run)
        with patch.object(hosted.subprocess, "run") as process:
            output = hosted.collect(self.root)
        process.assert_not_called()
        self.assertTrue((output / hosted.IPA_NAME).is_file())
        self.assertFalse((output / "EDEN-simulator.app.zip").exists())
        note = (output / "READ_ME.txt").read_text()
        self.assertIn("UNSIGNED", note)
        self.assertIn("Sideloadly", note)

    def test_ipa_report_without_payload_fails(self):
        run = self.report("passed", True, ipa=str(self.root / "build/run-1" / hosted.IPA_NAME))
        self.ipa(run, names=("Payload/EDEN.app/Info.plist",))
        with self.assertRaisesRegex(ValueError, "missing Payload"):
            hosted.collect(self.root)

    def test_ipa_outside_run_directory_is_rejected(self):
        run = self.report("passed", True, ipa=str(self.root / hosted.IPA_NAME))
        self.ipa(run, where=self.root)
        with self.assertRaisesRegex(ValueError, "inside its run directory"):
            hosted.collect(self.root)

    def test_failed_ipa_build_ships_nothing_installable(self):
        run = self.report("failed", False, ipa=str(self.root / "build/run-1" / hosted.IPA_NAME))
        self.ipa(run)
        output = hosted.collect(self.root)
        self.assertFalse((output / hosted.IPA_NAME).exists())

    def test_workflow_ipa_job_is_unsigned_and_gated_on_tests(self):
        text = (hosted.ROOT / ".github/workflows/eden-ios-macos.yml").read_text()
        ipa_job = text[text.index("  ipa:"):]
        for fragment in ("needs: simulator", "--ipa", "hosted.py\" collect", "EDEN-ios-unsigned-ipa-", "persist-credentials: false"):
            self.assertIn(fragment, ipa_job)
        for fragment in ("DEVELOPMENT_TEAM=", "secrets.", ".p12", "mobileprovision", "--team"):
            self.assertNotIn(fragment, text)

    def test_workflow_is_manual_readonly_and_preserves_failures(self):
        text = (hosted.ROOT / ".github/workflows/eden-ios-macos.yml").read_text()
        for fragment in ("workflow_dispatch:", "contents: read", "persist-credentials: false",
                         "runs-on: macos-15", "--test", "retention-days: 3", "always()"):
            self.assertIn(fragment, text)
        for fragment in ("pull_request_target:", "push:", "schedule:", "continue-on-error:", "secrets."):
            self.assertNotIn(fragment, text)


if __name__ == "__main__":
    unittest.main()
