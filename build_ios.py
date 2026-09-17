"""Local Xcode build/test runner. --check works on Windows; compilation does not.

No cloud builder, third-party dependencies, certificate bypass or paid API.
Native success requires xcodebuild success AND an actual app executable.

--ipa builds an UNSIGNED arm64 device app and wraps it as Payload/EDEN.app in
an .ipa. That file is what Sideloadly / AltStore consume: they re-sign it with
your own Apple ID on the Windows side, so no signing identity is needed here.
"""
import argparse
from datetime import datetime, timezone
import json
from pathlib import Path
import platform
import plistlib
import re
import shutil
import subprocess
import uuid
import xml.etree.ElementTree as ET
import zipfile

ROOT = Path(__file__).resolve().parent
PROJECT = ROOT / "EDEN.xcodeproj"
IPA_NAME = "EDEN-unsigned.ipa"


def preflight(root=ROOT):
    """Source consistency only. Apple's parser/compiler remains authoritative."""
    root = Path(root)
    project = root / "EDEN.xcodeproj/project.pbxproj"
    text = project.read_text(encoding="utf-8")
    objects = re.findall(r"^\s*([A-F0-9]{24}) = \{isa =", text, re.M)
    if not objects or len(objects) != len(set(objects)):
        raise ValueError("Missing or duplicate Xcode object identifiers")
    references = set(re.findall(r"\b[A-F0-9]{24}\b", text))
    if references - set(objects):
        raise ValueError("Dangling Xcode object reference")
    sources = sorted((root / "EDEN").glob("*.swift")) + sorted((root / "EDENTests").glob("*.swift"))
    if len(sources) < 6:
        raise ValueError("Missing native source/test files")
    referenced_sources = re.findall(r"isa = PBXFileReference;[^\n]*path = ([^;]+\.swift);", text)
    if set(referenced_sources) != {source.name for source in sources}:
        raise ValueError("Project/source file list mismatch (missing or untracked source)")
    phases = " ".join(re.findall(r"isa = PBXSourcesBuildPhase;[^\n]*files = \(([^)]*)\)", text))
    for source in sources:
        match = re.search(r"([A-F0-9]{24}) = \{isa = PBXFileReference;[^\n]*path = "
                          + re.escape(source.name) + r";", text)
        build_file = re.search(r"([A-F0-9]{24}) = \{isa = PBXBuildFile; fileRef = " + match[1] + r";", text) if match else None
        if not build_file or build_file[1] not in phases:
            raise ValueError(f"Source not in the project: {source.name}")
    with (root / "EDEN/Info.plist").open("rb") as stream:
        info = plistlib.load(stream)
    for key in ("NSMicrophoneUsageDescription", "NSBluetoothAlwaysUsageDescription", "NSLocalNetworkUsageDescription"):
        if not isinstance(info.get(key), str) or not info[key].strip():
            raise ValueError(f"Missing privacy description: {key}")
    ats = info.get("NSAppTransportSecurity", {})
    if ats.get("NSAllowsArbitraryLoads") or ats.get("NSExceptionDomains"):
        raise ValueError("Do not disable transport security for pairing")
    scheme = ET.parse(root / "EDEN.xcodeproj/xcshareddata/xcschemes/EDEN.xcscheme")
    for ref in scheme.findall(".//BuildableReference"):
        if ref.get("BlueprintIdentifier") not in objects:
            raise ValueError("Scheme refers to a missing target")
    if not scheme.findall(".//TestableReference"):
        raise ValueError("Shared scheme must include native tests")
    return {"source_preflight": "passed", "swift_files": len(sources), "native_compiled": False,
            "note": "File consistency only; not an Apple SDK compilation or device test."}


def simulator_destination(payload):
    """Use a real installed iPhone simulator, never a guessed model name."""
    def version_key(item):
        match = re.search(r"iOS-(\d+(?:-\d+)*)", item[0])
        return tuple(map(int, match[1].split("-"))) if match else ()

    for runtime, devices in sorted(payload.get("devices", {}).items(), key=version_key, reverse=True):
        version = re.search(r"iOS-(\d+)", runtime)
        if not version or int(version[1]) < 17:
            continue
        for device in devices:
            if device.get("isAvailable") and device.get("name", "").startswith("iPhone") and device.get("udid"):
                return "platform=iOS Simulator,id=" + device["udid"]
    raise ValueError("No iPhone simulator with iOS 17+ installed. Add one in Xcode Settings > Platforms/Components.")


def build_settings(args):
    """(configuration, sdk) for the requested build flavour."""
    ipa = getattr(args, "ipa", False)
    return ("Release" if ipa else "Debug"), ("iphoneos" if (args.device or ipa) else "iphonesimulator")


def build_command(args, run_dir, destination):
    configuration, sdk = build_settings(args)
    command = ["xcodebuild", "-project", str(PROJECT), "-scheme", "EDEN",
               "-configuration", configuration, "-sdk", sdk,
               "-destination", destination, "-derivedDataPath", str(run_dir / "DerivedData"),
               "-resultBundlePath", str(run_dir / "EDEN.xcresult")]
    if args.device:
        command.append("DEVELOPMENT_TEAM=" + args.team)
    elif getattr(args, "ipa", False):
        # Sideloadly signs later; Xcode must neither sign nor demand a profile.
        command += ["CODE_SIGNING_ALLOWED=NO", "CODE_SIGNING_REQUIRED=NO", "CODE_SIGN_IDENTITY=",
                    "CODE_SIGN_ENTITLEMENTS=", "PROVISIONING_PROFILE_SPECIFIER=", "DEVELOPMENT_TEAM="]
    else:
        command.append("CODE_SIGNING_ALLOWED=NO")
    command.append("test" if args.test else "build")
    return command


def check_unsigned_app(app):
    """An .app that Sideloadly can re-sign: real device binary, no stale signature."""
    app = Path(app)
    executable = app / "EDEN"
    if not executable.is_file() or executable.stat().st_size == 0:
        raise ValueError("App bundle has no executable")
    with (app / "Info.plist").open("rb") as stream:
        info = plistlib.load(stream)
    for key in ("CFBundleIdentifier", "CFBundleExecutable", "CFBundleShortVersionString", "CFBundleVersion"):
        if not str(info.get(key, "")).strip() or "$(" in str(info[key]):
            raise ValueError(f"Info.plist {key} was not resolved by Xcode")
    if info.get("DTPlatformName", "iphoneos") != "iphoneos":
        raise ValueError("App was built for " + str(info["DTPlatformName"]) + ", not iphoneos; a simulator app cannot be sideloaded")
    if (app / "_CodeSignature").exists() or (app / "embedded.mobileprovision").exists():
        raise ValueError("App carries a signature or profile; the IPA must be unsigned so Sideloadly can sign it")
    if shutil.which("lipo"):
        archs = subprocess.run(["lipo", "-archs", str(executable)], check=True, capture_output=True, text=True, timeout=30)
        if "arm64" not in archs.stdout.split():
            raise ValueError("Executable is not arm64: " + archs.stdout.strip())
    return info


def package_ipa(app, target):
    """Zip Payload/EDEN.app as target. Pure zipfile: preserves file modes; no symlinks expected."""
    app, target = Path(app), Path(target)
    info = check_unsigned_app(app)
    with zipfile.ZipFile(target, "x", compression=zipfile.ZIP_DEFLATED) as archive:
        for path in sorted(app.rglob("*")):
            if path.is_symlink():
                raise ValueError("Symlink inside app bundle: " + str(path))
            if path.is_dir():
                continue
            entry = zipfile.ZipInfo.from_file(path, "Payload/" + app.name + "/" + path.relative_to(app).as_posix())
            mode = path.stat().st_mode
            if path == app / "EDEN":
                mode |= 0o111  # main binary must stay executable after re-signing
            entry.external_attr = (mode & 0xFFFF) << 16
            entry.compress_type = zipfile.ZIP_DEFLATED
            archive.writestr(entry, path.read_bytes())
    if target.stat().st_size == 0:
        raise ValueError("IPA is empty")
    return {"ipa": str(target), "bundle_id": info["CFBundleIdentifier"],
            "version": f"{info['CFBundleShortVersionString']} ({info['CFBundleVersion']})", "signed": False}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="Validate source/project consistency; do not compile")
    parser.add_argument("--test", action="store_true", help="Build and run XCTest on an installed iPhone simulator")
    parser.add_argument("--device", action="store_true", help="Build a signed device app using locally configured signing")
    parser.add_argument("--ipa", action="store_true", help="Build an unsigned arm64 Release app and package it as an .ipa for Sideloadly/AltStore")
    parser.add_argument("--team", help="Apple development team ID, for --device only")
    parser.add_argument("--destination", help="Explicit xcodebuild destination, e.g. platform=iOS Simulator,id=UDID")
    args = parser.parse_args(argv)
    if args.check and (args.test or args.device or args.destination or args.team or args.ipa):
        parser.error("--check is source-only and cannot be combined with native build options")
    if args.ipa and (args.test or args.device or args.team or args.destination):
        parser.error("--ipa is a standalone unsigned device build; it takes no test, signing or destination options")
    if args.device and (args.test or not args.team):
        parser.error("--device requires --team and cannot be combined with --test; run device tests in Xcode")
    if args.team and (not args.device or not re.fullmatch(r"[A-Z0-9]{10}", args.team)):
        parser.error("--team must be a 10-character Apple team ID used with --device")
    try:
        result = preflight()
    except (OSError, ValueError, ET.ParseError) as exc:
        print(json.dumps({"source_preflight": "failed", "native_compiled": False, "why": str(exc)}, indent=2))
        return 1
    if args.check:
        print(json.dumps(result, indent=2))
        return 0
    if platform.system() != "Darwin" or not shutil.which("xcodebuild"):
        result.update(status="blocked", why="Native iOS compilation requires a Mac with full Xcode, not Windows or Swift alone.")
        print(json.dumps(result, indent=2))
        return 2
    run_dir = ROOT / "build" / (datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ") + "-" + uuid.uuid4().hex[:8])
    result.update(status="failed", native_tests="not run", artifact_dir=str(run_dir))
    try:
        run_dir.mkdir(parents=True, exist_ok=False)
        # Use Apple's real project parser before invoking the compiler.
        subprocess.run(["plutil", "-lint", str(PROJECT / "project.pbxproj")], check=True, capture_output=True, text=True, timeout=30)
        version = subprocess.run(["xcodebuild", "-version"], check=True, capture_output=True, text=True, timeout=30)
        result["xcode"] = version.stdout.strip()
        destination = args.destination
        if not destination and args.test:
            devices = subprocess.run(["xcrun", "simctl", "list", "devices", "available", "--json"],
                                     check=True, capture_output=True, text=True, timeout=30)
            destination = simulator_destination(json.loads(devices.stdout))
        destination = destination or ("generic/platform=iOS" if (args.device or args.ipa) else "generic/platform=iOS Simulator")
        command = build_command(args, run_dir, destination)
        result["command"] = command
        print("Building EDEN. Log: " + str(run_dir / "xcodebuild.log"), flush=True)
        with (run_dir / "xcodebuild.log").open("w", encoding="utf-8") as log:
            completed = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, timeout=1800)
        result["returncode"] = completed.returncode
        configuration, sdk = build_settings(args)
        executable = run_dir / f"DerivedData/Build/Products/{configuration}-{sdk}/EDEN.app/EDEN"
        if completed.returncode != 0:
            if args.test:
                result["native_tests"] = "failed or not reached; inspect xcresult"
            raise ValueError("xcodebuild failed; inspect xcodebuild.log and EDEN.xcresult")
        if not executable.is_file() or executable.stat().st_size == 0:
            raise ValueError("xcodebuild returned success but the app executable is missing")
        if args.ipa:
            result.update(package_ipa(executable.parent, run_dir / IPA_NAME))
        result.update(status="passed", native_compiled=True, app=str(executable.parent),
                      native_tests="passed" if args.test else "not run", device_runtime="not tested")
    except (OSError, ValueError, subprocess.SubprocessError) as exc:
        result["why"] = str(exc)
    try:
        (run_dir / "result.json").write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    except OSError as exc:
        result.update(status="failed", report_error=str(exc))
    print(json.dumps(result, indent=2))
    return 0 if result["status"] == "passed" else 1


if __name__ == "__main__":
    raise SystemExit(main())
