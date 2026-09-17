"""Prepare source-only hosted builds; collect results without uploading anything.

Commands: python ios/ci/hosted.py bundle | collect
Only GitHub's workflow uploads artifacts, after the user publishes the sources.
collect packages whichever the latest build produced: a simulator .app.zip
(from --test) or an unsigned EDEN-unsigned.ipa for Sideloadly (from --ipa).
"""
import argparse
from datetime import datetime, timezone
import json
from pathlib import Path
import shutil
import subprocess
import uuid
import zipfile

ROOT = Path(__file__).resolve().parents[1]
SOURCE_FILES = (
    "EDEN/EdenApp.swift", "EDEN/ContentView.swift", "EDEN/EdenClient.swift",
    "EDEN/BluetoothManager.swift", "EDEN/PairingLink.swift", "EDEN/Info.plist",
    "EDENTests/EDENTests.swift", "EDEN.xcodeproj/project.pbxproj",
    "EDEN.xcodeproj/xcshareddata/xcschemes/EDEN.xcscheme",
    "build_ios.py", "README.md", "HOSTED_MAC.md", "SIDELOAD.md", "ci/hosted.py", "ci/test_hosted.py",
    ".github/workflows/eden-ios-macos.yml",
)
IPA_NAME = "EDEN-unsigned.ipa"


def bundle(root=ROOT):
    """An explicit allowlist, not a recursive zip of a personal assistant's data."""
    root = Path(root).resolve()
    sources = []
    for name in SOURCE_FILES:
        path = root / name
        if not path.is_file() or path.is_symlink() or not path.resolve().is_relative_to(root):
            raise ValueError(f"Missing or unsafe source file: {name}")
        sources.append((path, name))
    folder = root / "build"
    folder.mkdir(exist_ok=True)
    target = folder / ("EDEN-ios-hosted-source-" + uuid.uuid4().hex[:12] + ".zip")
    with zipfile.ZipFile(target, "x", compression=zipfile.ZIP_DEFLATED) as archive:
        for path, name in sources:
            archive.write(path, name)
        archive.writestr(".gitignore", "build/\n__pycache__/\n*.pyc\n.DS_Store\n**/xcuserdata/\n*.xcuserstate\n")
    return target


def collect(root=ROOT):
    """Keep logs even on failure; package an app only after a successful build."""
    root = Path(root).resolve()
    build = root / "build"
    output = build / "hosted-artifacts"
    output.mkdir(parents=True, exist_ok=True)
    reports = sorted((path for path in build.glob("*/result.json") if path.parent != output),
                     key=lambda path: path.stat().st_mtime_ns)
    if not reports:
        (output / "NO_BUILD_RESULT.txt").write_text(
            "No native build report was produced. Inspect the workflow log for checkout, preflight or toolchain failures.\n",
            encoding="utf-8")
        return output
    report = reports[-1]
    run = report.parent.resolve()
    if not run.is_relative_to(build.resolve()) or report.is_symlink():
        raise ValueError("Build report is outside the build directory")
    result = json.loads(report.read_text(encoding="utf-8"))
    shutil.copyfile(report, output / "result.json")
    log = run / "xcodebuild.log"
    if log.is_file():
        shutil.copyfile(log, output / "xcodebuild.log")
    result_bundle = run / "EDEN.xcresult"
    if result_bundle.is_dir():
        # ditto preserves the app's executable bits, symlinks and bundle structure.
        subprocess.run(["ditto", "-c", "-k", "--sequesterRsrc", "--keepParent",
                        str(result_bundle), str(output / "EDEN.xcresult.zip")], check=True, timeout=180)
    ipa_run = "ipa" in result
    if result.get("status") == "passed" and result.get("native_compiled") is True:
        if ipa_run:
            ipa = Path(result["ipa"])
            if not ipa.resolve().is_relative_to(run) or not ipa.is_file() or ipa.stat().st_size == 0:
                raise ValueError("Successful IPA build report has no IPA inside its run directory")
            with zipfile.ZipFile(ipa) as archive:
                names = set(archive.namelist())
            if not {"Payload/EDEN.app/Info.plist", "Payload/EDEN.app/EDEN"} <= names:
                raise ValueError("IPA is missing Payload/EDEN.app")
            shutil.copyfile(ipa, output / IPA_NAME)
        else:
            app = run / "DerivedData/Build/Products/Debug-iphonesimulator/EDEN.app"
            if not (app / "EDEN").is_file() or (app / "EDEN").stat().st_size == 0:
                raise ValueError("Successful build report has no simulator executable")
            subprocess.run(["ditto", "-c", "-k", "--sequesterRsrc", "--keepParent",
                            str(app), str(output / "EDEN-simulator.app.zip")], check=True, timeout=180)
    if ipa_run:
        note = ("EDEN hosted unsigned IPA build\n"
                + IPA_NAME + " is an UNSIGNED arm64 app; it will not install by itself.\n"
                + "Open it in Sideloadly on Windows, sign in with your Apple ID and Start. See SIDELOAD.md.\n"
                + "Free Apple IDs: the install expires after 7 days and must be re-sideloaded.\n")
    else:
        note = ("EDEN hosted simulator build\n"
                + "EDEN-simulator.app.zip is NOT an IPA and cannot be installed on an iPhone.\n")
    (output / "READ_ME.txt").write_text(
        note
        + "Collected UTC: " + datetime.now(timezone.utc).isoformat() + "\n"
        + "Read result.json for compilation and XCTest status.\n"
        + "A hosted build does not test your Windows server, LAN pairing, microphone or physical BLE device.\n",
        encoding="utf-8")
    return output


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("bundle", "collect"))
    args = parser.parse_args()
    print(bundle() if args.command == "bundle" else collect())


if __name__ == "__main__":
    main()
