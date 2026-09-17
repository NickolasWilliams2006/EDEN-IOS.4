# Hosted Mac build from Windows

Prepared, not yet run. This builds and tests EDEN's existing native iOS client
on a standard GitHub-hosted macOS runner. It does not require your own Mac,
Apple signing credentials, or paid AI APIs. The `simulator` job produces a
simulator app and test results; the `ipa` job, gated on the simulator tests
passing, produces an **unsigned `EDEN-unsigned.ipa`** for
[Sideloadly](SIDELOAD.md). Nothing is signed on the runner.

## Prepare an iOS-only upload

From the EDEN folder on Windows:

```powershell
python -B ios/ci/hosted.py bundle
```

The command prints a new `ios/build/EDEN-ios-hosted-source-….zip` path. Its
explicit file list includes only the Swift app, Xcode project, tests, build
scripts, documentation, and workflow. It excludes `.env`, tokens, certificates,
private keys, model weights, personal files, build outputs and Git history.
Review the ZIP before sharing; source code itself becomes available to the
repository owner and hosted runner.

1. Create an empty **private** GitHub repository for the iOS client, or choose
   an existing repository you are authorized to use.
2. Extract the ZIP and put its **contents** at the repository root. Include
   the hidden `.github` folder. Commit/push those files using GitHub Desktop,
   Git, or GitHub's website. Uploading just the ZIP does not install a workflow.
3. Ensure `.github/workflows/eden-ios-macos.yml` is on the repository's default
   branch, alongside `build_ios.py` and `EDEN.xcodeproj/` at root.
4. Open **Actions → EDEN iOS - hosted Mac → Run workflow**.
5. After it finishes, download the `EDEN-ios-unsigned-ipa-…` artifact for the
   phone, or `EDEN-ios-simulator-…` for test diagnostics.

Nothing has been pushed, published or dispatched by preparing these files.
No repository is created and no account billing settings are changed.

## If you use the full EDEN repository

Copy `ios/.github/workflows/eden-ios-macos.yml` to the repository-root
`.github/workflows/eden-ios-macos.yml`. GitHub does not discover workflow files
inside an arbitrary `ios/` subdirectory. The workflow supports both layouts
and locates the existing project automatically. Do not upload the whole EDEN
folder or Git history without reviewing it for personal data and credentials.

GitHub documents [workflow location and syntax](https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-syntax).

## What runs and what you receive

- Manual dispatch only: no automatic push, pull-request or scheduled builds.
- Standard `macos-15` runner, read-only repository permission, no saved checkout
  credentials, no signing secrets or cloud AI calls.
- Source preflight and helper tests, then `xcodebuild test` using a real installed
  iPhone simulator. The Xcode version and installed runtimes appear in the log.
- Failed compilation or tests fail the job. Diagnostics upload also runs after
  failure; a successful diagnostics step does not turn a failed build green.
- `result.json` records compilation/test status; `xcodebuild.log` has diagnostics;
  `EDEN.xcresult.zip` contains Xcode's result bundle when available.
- `EDEN-simulator.app.zip` is included only after successful compilation/tests.
  Its inner ZIP preserves executable permissions and bundle metadata.
- If no build report exists, `NO_BUILD_RESULT.txt` directs you to the workflow log.

The workflow has a 40-minute job limit, cancels superseded runs on the same
branch, and retains artifacts for three days. It does not cache DerivedData.
It uses the runner's installed Xcode; no simulator runtime is downloaded by
the workflow. Missing compatible runtimes produce a clear failure.

## Costs and privacy

GitHub provides included usage for private repositories; exceeding it can be
billed. Standard hosted runners are free for public repositories, but **do not
make EDEN public just to get free builds**. Before the first run, check your
account's Actions allowance, artifact storage and spending controls. Manual
dispatch, timeouts and short retention reduce usage but do not guarantee zero
charges. See [GitHub Actions billing](https://docs.github.com/en/billing/concepts/product-billing/github-actions).

## Installing on your actual iPhone

The workflow has no signing job and never will need one: the `ipa` job builds
with `CODE_SIGNING_ALLOWED=NO` and Sideloadly signs the result on your Windows
PC with your Apple ID. Follow [SIDELOAD.md](SIDELOAD.md). Never commit
certificate passwords, `.p12` keys or profiles; none are required.

A simulator app still cannot be installed on a physical phone, and renaming it
to `.ipa` will not work — only the `ipa` job's output is a device build.

The hosted runner also cannot reach your private Windows EDEN server. Native
XCTest does not verify live LAN pairing, speech, or physical Bluetooth. Follow
the device acceptance checklist in `README.md` after a signed device build.
