# Sideloading EDEN onto an iPhone from Windows

There is no way to compile Swift for iOS on Windows. What Windows *can* do is
sign and install an already-built app: that is what Sideloadly does. So the
pipeline is:

1. A Mac (the hosted GitHub runner) compiles an **unsigned** arm64 build and
   wraps it as `EDEN-unsigned.ipa`.
2. Sideloadly on Windows re-signs that IPA with your Apple ID and pushes it to
   the phone over USB.

The IPA is unsigned on purpose. Sideloadly strips and replaces any signature
anyway; shipping one unsigned means no certificate, `.p12` or provisioning
profile ever needs to exist in this repository or on the runner.

## 1. Get the IPA

Follow [HOSTED_MAC.md](HOSTED_MAC.md) to put the `ios/` sources in a private
GitHub repository, then **Actions → EDEN iOS - hosted Mac → Run workflow**. Two
jobs run:

| Job | Produces |
|---|---|
| `simulator` | XCTest results and a simulator app (not installable) |
| `ipa` | `EDEN-ios-unsigned-ipa-…` artifact containing `EDEN-unsigned.ipa` |

The `ipa` job only runs if the simulator tests pass. Download the
`EDEN-ios-unsigned-ipa-…` artifact, unzip it, and keep `EDEN-unsigned.ipa`.
`result.json` in the same folder records the bundle id (`local.eden.EDEN`) and
version; `READ_ME.txt` repeats the essentials.

If you have a Mac instead, `python3 ios/build_ios.py --ipa` writes the same
file under `ios/build/<run>/EDEN-unsigned.ipa`.

## 2. Install with Sideloadly

1. Install [Sideloadly](https://sideloadly.io) and iTunes (the Apple one, not
   the Microsoft Store version; Sideloadly needs its USB driver).
2. Plug the iPhone in over USB and tap **Trust** on the phone.
3. In Sideloadly: drag `EDEN-unsigned.ipa` onto the IPA box, select the
   iPhone in the device list, type your Apple ID, press **Start**, and enter
   the password/2FA code when prompted. Apple sends the code; Sideloadly
   forwards it. Nothing here is typed into EDEN.
4. First launch on the phone: **Settings → General → VPN & Device
   Management → your Apple ID → Trust**. iOS 16+ may also ask you to enable
   **Developer Mode** under **Settings → Privacy & Security**; do so and reboot.

Leave Sideloadly's advanced options alone. It rewrites the bundle id to one
tied to your Apple ID when using a free account; EDEN does not care what its
bundle id is. Do not enable "Remove app extensions", "Inject dylibs" or any
tweak injection — the app has no extensions and needs none of it.

### Free Apple ID vs Developer Program

| | Free Apple ID | $99/yr Developer Program |
|---|---|---|
| Install lasts | **7 days**, then the icon greys out | 1 year |
| App slots | 3 sideloaded apps at a time | unlimited |
| Re-install | plug in, press Start again; data and pairing survive | same |

Sideloadly can auto-refresh over Wi-Fi while your PC is on (**Wi-Fi refresh**
in its settings). That is the only reason to keep it running.

## 3. Pair it with EDEN

Start the server with `EDEN.bat --lan`. Then either:

**One tap (recommended).** Open EDEN's web page in Safari on the phone the way
you already do (tap past the certificate warning if Safari shows one). A blue
notice reads *Native EDEN app installed? Pair it with one tap →*. Tap it,
confirm *Open in "EDEN"*, and the app lands on Setup reading *Ready —
certificate pinned*. Nothing is typed, nothing is installed in iOS Settings.

**Or paste.** The console prints `https://10.0.0.5:8765/?t=…&f=…`. Paste the
whole line into Setup — the trailing "<- from your phone" is tolerated — and
tap Pair. If the link is rejected, Setup says exactly why in red (missing
token, fingerprint not 64 characters, not https…).

The Setup tab always shows the current state: *Not paired*, *Paired without a
token*, or *Ready*. Talk only works in the last one. "That server address
isn't valid" on the Talk tab means the first: nothing was ever saved.

The `f=` part is the SHA-256 of EDEN's certificate; the app pins it and refuses
any other certificate. If EDEN regenerates its certificate (it does when the
PC's Wi-Fi address changes), the app says the certificate no longer matches:
re-pair. A link without `f=` falls back to iOS's own trust settings, which is
what used to fail silently.

Then run the device acceptance list at the bottom of [README.md](README.md).

## What can go wrong

- **"Could not find a valid provisioning profile" in Sideloadly** — Apple ID
  hit its 10-devices/free-account limit, or the 2FA code was entered late.
  Retry.
- **App installs, icon greys out after a week** — free-account expiry. Re-run
  Sideloadly.
- **"Unable to Verify App"** — trust the developer profile (step 4 above).
- **"Certificate doesn't match the one you paired with"** — EDEN made a new
  certificate since you paired. Restart EDEN, paste the new link.
- **"Certificate not trusted"** — you pasted a link without `f=` (an old
  EDEN, or the link was trimmed). Paste the full current link.
- **Microphone permission never appears** — the server is `http`, not
  `https`. iOS will not offer the mic to an insecure origin, native or not.
- **Bluetooth shows nothing** — Bluetooth is off, or the app was denied
  permission; check Settings → EDEN.
- **Workflow `ipa` job skipped** — the `simulator` job failed. Fix the tests;
  the IPA is deliberately gated on them.

## What this does not do

It does not bypass Apple signing, run without an Apple ID, submit to
TestFlight or the App Store, or make the install permanent on a free account.
Anything that promises otherwise is a jailbreak or an enterprise-certificate
abuse, and neither belongs here.
