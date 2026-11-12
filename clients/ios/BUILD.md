# Building the rehalo iOS app (SmartHalo 2)

Building for iOS **requires macOS + Xcode** (CryptoKit, CommonCrypto, CoreBluetooth and SwiftUI are
Apple APIs that don't exist on Linux). There are three ways, from most to least recommended:

## 1. GitHub Actions (macOS runners) — recommended, no local Mac needed
The workflow in `.github/workflows/ios.yml` runs on every push that touches `clients/ios/`:
- `swift test` on the `SH2Protocol` package (checks the crypto and framing with the real
  CryptoKit/CommonCrypto),
- `xcodegen generate`, then `xcodebuild archive` for a generic iOS device with code signing off,
- packages the archive as an **unsigned `.ipa`** (`rehalo-unsigned.ipa`) and uploads it as the
  `rehalo-unsigned-ipa` artifact.

Download the artifact from the **iOS build** run in the **Actions** tab (GitHub serves artifacts as a
zip, and `gh run download <run-id> -n rehalo-unsigned-ipa` unpacks it for you). A push to `dev` also
publishes the `.ipa` as the rolling **`dev-latest`** prerelease, with a direct link:
`https://github.com/cyberlynx33/open-rehalo/releases/download/dev-latest/rehalo-unsigned.ipa`. A manual
run of the workflow can publish any branch there with its *publish_dev_latest* option.

Build numbers: a `v*` tag keeps `CURRENT_PROJECT_VERSION` from `project.yml`, and every other build
appends its run number to it (`2` becomes `2.45`). AltStore and SideStore offer an update when the build
differs from the installed one, so each `dev-latest` build is a new version for them. After publishing a
release or `dev-latest`, the workflow runs **Website**, which rebuilds the sources at
`https://rehalo.app/altstore/` from the releases (`site/altstore/build-source.mjs`). An unsigned
`.ipa` has to be signed with your own Apple ID before it installs on an iPhone; see the main README. CI
needs no Apple account.

## 2. Your own Mac — the simplest if you have macOS
```
cd clients/ios
brew install xcodegen
xcodegen generate            # -> SmartHalo2.xcodeproj
open SmartHalo2.xcodeproj
cd SH2Protocol && swift test # protocol tests
```
In Xcode: set your **Team** (Signing & Capabilities) and run on a **real iPhone** (the simulator has no
Bluetooth). Flow: Scan → Recover/Re-pair → control.

## 3. Cloud Mac (no Mac, but you want a signed .ipa)
MacStadium, a self-hosted macOS runner, or `xcodebuild archive` + `exportArchive` with your developer
account in CI (add signing steps to the workflow with a certificate in Secrets).

macOS is licensed for Apple hardware only, so a macOS VM on other hardware isn't an option.

## Build notes
- `SH2Protocol` (SPM package) is the portable, testable layer (`swift test`). The app (`project.yml` →
  XcodeGen) uses it as a local dependency.
- `SH2Nav` (commands and ride logic) also builds on Linux, without Xcode:
  `docker run --rm -v "$PWD":/w -w /w/clients/ios/SH2Protocol swift:6.1 swift test`. On Linux,
  `Package.swift` leaves out `SH2Protocol`, which needs CryptoKit.
- Watch for these when building: the `CCCryptorStatus(kCCSuccess)` cast, `import CommonCrypto` (resolves
  on its own in Xcode), and `SWIFT_STRICT_CONCURRENCY: minimal` (raising it to `complete` produces
  warnings for the non-Sendable CBPeripheral).
