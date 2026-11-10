# Building ECHO Glasses (no Mac of your own)

## 0. Meta side (needed for real glasses)
1. Update glasses firmware and the **Meta AI** app; enable **Developer Mode** for the glasses
   (Meta's Setup guide: https://wearables.developer.meta.com/docs/develop/dat/getting-started-toolkit/).
2. Developer Mode needs no MetaAppID/ClientToken (leave them empty in `project.yml`).
3. Meta says App Store publishing is not supported yet; share via Meta's release channels.

## 1. Find compile errors from Windows (free)
1. Put this whole folder in a GitHub repo and push.
2. Open **Actions → "iOS build check"**. It runs XcodeGen + `xcodebuild` on a macOS runner.
3. Send me the log if it fails; I'll fix the code.

## 2. Install on your iPhone (needs a Mac for Xcode)
Use a rented cloud Mac or borrow one for ~30 minutes:
```
brew install xcodegen
cd ios-companion
# edit project.yml: bundleIdPrefix, PRODUCT_BUNDLE_IDENTIFIER, DEVELOPMENT_TEAM
xcodegen generate
open EchoGlasses.xcodeproj
```
In Xcode: select your team under Signing & Capabilities, pick your iPhone, Run.
Installing needs the iPhone connected to that Mac (a remote cloud Mac usually can't see your USB device).
iPhone: Settings → Privacy & Security → Developer Mode = On.

* **SDK version**: `project.yml` uses `from: "1.0.0"` (the SDK is only available as version tags; `main` has no Package.swift).
  Tags: https://github.com/facebook/meta-wearables-dat-ios/tags
* **Hotspot Configuration** entitlement is required for Wi-Fi camera streaming (Meta docs). If signing
  fails with a free Apple account, remove it from `project.yml`; streaming then won't work.
* If `.allowBluetoothHFP` doesn't compile, use `.allowBluetooth` in `AudioRoute.swift`.
* If product names differ, check the package's `Package.swift` (expected: MWDATCore, MWDATCamera, MWDATMockDevice).
* MockDeviceKit mode: Meta says the mock device must be powered on and "donned" before streaming.
  This app does not call those controls (not documented for in-app use); use *Simulatie* mode, or see
  Meta's CameraAccess sample for the mock-device debug UI.

## 3. First run
1. Open ECHO webapp → **Koppel bril-app** (copies the config).
2. App → ⚙ → **Plak koppelcode**; optionally set a Vision-model and the bridge address.
3. Mode *Simulatie* → **VERBIND** → **KIJK**. Later: *Echte bril* → **Registreer bij Meta AI-app** → **VERBIND**.
