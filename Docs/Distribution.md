# Safe macOS distribution

## Resource bundle lookup

Packaged apps keep `ControlDeck_ControlDeck.bundle` in `Contents/Resources`.
All app resource consumers use `AppResources.bundle`, which resolves that
location explicitly. SwiftPM 6.2's generated `Bundle.module` accessor searches the
`.app` root and then the original build directory; calling it from a distributed
app can trap before the first window appears. Only unbundled development runs
use that accessor. Missing packaged resources use the existing image, game and
customization error fallbacks instead of trapping.

Run `./scripts/test-resource-bundle.sh` to exercise the production image/resource
loaders in a small SwiftPM fixture. It verifies direct development execution,
then relocates a macOS app and removes the build directory before loading its
images, game and customization files. Both the current toolchain's accessor and
the SwiftPM 6.2 accessor used by v1.1.1 are tested, including missing bundles.
The test is included in `./scripts/test.sh` and needs no controller or permissions.

## Signing

Local builds fall back to ad-hoc signing so they can run during development on
the Mac that built them. Features protected by TCC, including Accessibility,
need a stable signing identity to preserve permission across rebuilt binaries.
A public download must use an Apple **Developer ID Application** certificate,
hardened runtime, Apple notarization and a stapled ticket. Do not remove
quarantine attributes or ask users to bypass Gatekeeper.

`./script/build_and_run.sh` uses the single-architecture development build and
never auto-discovers a signing identity. It is the canonical reload path for
Codex work. Set `CONTROLDECK_DEVELOPMENT_SIGNING_IDENTITY`, or put an identity
name or SHA-1 fingerprint in the Git-ignored
`.codex/development-signing-identity` file, to keep a stable identity across
reloads. This Mac-specific configuration is not used for universal builds,
notarization, DMG signing or publication. The release certificate and notary
keychain profile are accessed only by the explicit packaging command below.

## One-time Apple setup

1. Install a Developer ID Application certificate in the login keychain.
2. Store App Store Connect credentials in a notarytool keychain profile:

   ```bash
   xcrun notarytool store-credentials "control-deck-notary"
   ```

## Build and notarize

```bash
export DEVELOPER_ID_APPLICATION="Developer ID Application: Example (TEAMID)"
export NOTARYTOOL_PROFILE="control-deck-notary"
./scripts/package-notarized-release.sh
```

The script signs the bundled Opus framework and ControlDeck with hardened
runtime, submits the archive to Apple, staples and validates the ticket, runs
Gatekeeper assessment, then creates and separately notarizes a signed DMG. Only
after both formats pass validation does it replace `dist/ControlDeck.dmg` and
`dist/ControlDeck.zip`. The DMG opens a branded Finder window with the app and
Applications shortcut positioned around a clear drag arrow; its background and
Finder layout are validated before publication. The ZIP remains available in
the repository, while the website uses the DMG as the default download. The
script builds separate arm64 and x86_64 executables and merges them into one
universal app, so both artifacts support Apple Silicon and Intel Macs.

For an already-built app bundle, append `--no-build`.

The process intentionally fails closed: missing credentials, signing failures,
notarization rejection, staple failures, invalid DMG contents, or Gatekeeper
rejection prevent either release artifact from being published.

Speech model weights are never part of the app bundle. Parakeet and WhisperKit
are optional downloads stored in the user's ControlDeck Application Support
directory. Both local builds and release packaging run
`verify-no-bundled-speech-models.sh` and stop if a model package or weight file
has entered the bundle.
