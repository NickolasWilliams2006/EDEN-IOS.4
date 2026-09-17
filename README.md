# EDEN for iPhone (native)

The reason this exists: **iOS Safari has no Web Bluetooth.** The web app does
everything else well, but it can never talk to a BLE device on an iPhone. Only
a native app using CoreBluetooth can.

The app is a *client*. Indexing, the model, tools, memory, downloads and every
guardrail stay in the Python server. Only two things are native: Bluetooth, and
the UI wrapped around it.

## Honest status

The checked-in `EDEN.xcodeproj` now contains the app target, shared EDEN scheme,
XCTest target, and microphone/Bluetooth/local-network privacy descriptions.
It uses iOS 17+ and Swift 5 language mode; there are no Swift package dependencies.

**Native compilation and device testing are still blocked: no Mac is available.**
Windows source checks do not compile Swift or validate the Apple SDK calls.
No signed app or IPA has been produced. The build runner reports this explicitly
instead of treating source checks as a successful build.

Python has automated guardrail and extension tests. That is not an end-to-end
test of the native client, microphone, certificates or the user's hardware.

## What you need

| | |
|---|---|
| A Mac or authorized macOS build runner | **mandatory** for native compilation |
| Full Xcode | Xcode 15+ with an iOS 17+ SDK; Command Line Tools alone are insufficient |
| iPhone simulator | Install an iOS 17+ simulator runtime in Xcode to run XCTest |
| Apple signing setup | Needed for a physical iPhone; not needed for an unsigned simulator build |
| Python 3 | Optional build/test wrapper; no third-party Python packages |

## Build it

**No Mac available?** Use the prepared [hosted Mac workflow](HOSTED_MAC.md).
It packages only the iOS source for a manually triggered GitHub Actions build.
Its `ipa` job produces an unsigned `EDEN-unsigned.ipa` that
[Sideloadly installs from Windows](SIDELOAD.md) with your own Apple ID. The
workflow has not been run yet.

Copy the entire `ios/` directory to a Mac. It is self-contained; do not copy
EDEN's `.env`, certificates' private keys, pairing tokens, model weights, or
personal library. The EDEN Python server remains on the Windows computer.

Open **the existing** `EDEN.xcodeproj` in Xcode, select the **EDEN** scheme and
an installed iPhone simulator, then Build or Test. Do not create another app.
Launch Xcode once to finish its component installation and license prompts.

From the EDEN repository root on the Mac:

```sh
python3 ios/build_ios.py --check
python3 ios/build_ios.py
python3 ios/build_ios.py --test
```

The default build targets the simulator without signing. `--test` discovers an
installed iPhone simulator instead of assuming a specific model. An explicit
destination is also supported:

```sh
python3 ios/build_ios.py --test --destination 'platform=iOS Simulator,id=YOUR-SIMULATOR-UDID'
```

Each native attempt writes a fresh directory under `ios/build/` containing
`xcodebuild.log`, `result.json`, and (when Xcode creates it) `EDEN.xcresult`.
The app is under `DerivedData/Build/Products/Debug-iphonesimulator/EDEN.app`.
The runner requires successful Xcode execution and a nonempty app executable
before reporting native compilation success. An app bundle alone is not an IPA
and an unsigned simulator app cannot run on a physical iPhone.

Without Python, run from the copied `ios/` directory:

```sh
xcodebuild -project EDEN.xcodeproj -scheme EDEN -configuration Debug \
  -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath build/Manual CODE_SIGNING_ALLOWED=NO build
```

For a physical iPhone, use Xcode's Signing & Capabilities tab to select your
team and a bundle identifier registered to that team. Select the connected
iPhone and Run; complete any device Developer Mode/trust prompts. For a
command-line device build with signing already configured locally:

```sh
python3 ios/build_ios.py --device --team YOURTEAMID
```

`YOURTEAMID` is a placeholder for your actual 10-character development team ID.
The script does not log into Apple, install provisioning profiles, upload
source, buy developer membership, or submit to TestFlight/App Store.

For an **unsigned** device build that Sideloadly or AltStore will sign for you:

```sh
python3 ios/build_ios.py --ipa
```

This is a Release arm64 build with code signing disabled, zipped as
`Payload/EDEN.app` into `ios/build/<run>/EDEN-unsigned.ipa`. The runner refuses
to package a simulator build, a bundle that still carries a signature, or one
without an arm64 executable. See [SIDELOAD.md](SIDELOAD.md) for installing it.

Apple documents the underlying commands in its
[Xcode command-line build/test guide](https://developer.apple.com/library/archive/technotes/tn2339/_index.html).

## Checks available on Windows

From the EDEN repository root:

```powershell
python -B ios/build_ios.py --check
python -B -m unittest -v check_ios_build
```

These check project/source references, privacy settings, simulator selection,
signing arguments, and honest failure reporting. The mock-Xcode tests exercise
only the Python wrapper. Native pairing/hex-parser XCTest cases live in
`EDENTests/EDENTests.swift` and remain unexecuted until a Mac is available.

## Device acceptance after compilation

1. Start the existing server with `python -m agent.main --lan`.
2. Paste the full pairing link — including `?t=` and `&f=` — in Setup and
   allow local-network access. `f=` is the certificate's SHA-256; the app pins
   it and accepts no other certificate, so nothing is installed in iOS
   Settings. Without `f=` the app falls back to the system trust store.
4. Verify typed chat, microphone permission, local transcription and spoken reply.
5. Test a denied microphone permission and an unreachable server: neither should
   appear to succeed. Reopen the app and verify Keychain pairing persists.
6. On a physical iPhone, test BLE scan/connect/read/notify and a confirmed write
   to a safe test peripheral. Simulator XCTest does not prove Bluetooth works.

## Using it

- **Talk** — type, or tap the mic to start and tap again to stop. Goes to your
  server, comes back spoken.
- **Bluetooth** — Scan, tap a device to connect, then read characteristics.
  *Ask EDEN* hands a reading to the model so it can interpret it against
  your own files.
- **Setup** — paste the full HTTPS pairing link printed by `--lan`, including
  its `?t=` token and `&f=` certificate fingerprint. The token is kept in
  Keychain, separately for each server; the origin and fingerprint (public,
  not secret) are saved in preferences. Re-pair after rotating tokens or
  regenerating the certificate.
- Voice recordings use 16 kHz mono PCM WAV for local Whisper. If the server
  chooses browser speech, the native client uses iOS speech synthesis.

## The write rule

Reading is free. **Writing to a characteristic asks first**, every time, with
the value shown before it goes. That mirrors what the Python side enforces for
downloads: nothing that changes the physical world happens without you pressing
something. A BLE write can move a motor or trip a relay — it is not a thing to
let a language model do unattended.
