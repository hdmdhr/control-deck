# UI languages

ControlDeck supports English (`en`), Simplified Chinese (`zh-Hans`), and Japanese
(`ja`). It follows the macOS language preference, including the per-application
language selected in System Settings → General → Language & Region → Applications.
Restart ControlDeck after changing its language. Unsupported languages fall back
to English.

This translates the interface, onboarding, controller action labels, status and
error messages, screenshot editor, privacy prompts, and Tilt Run. It does not
change a speech model's supported languages: the optional WhisperKit Base English
and Small English models remain English models.

## Resource layout

The canonical `Localizable.strings` and `InfoPlist.strings` files live in
`Sources/ControlDeck/Resources/{en,zh-Hans,ja}.lproj`. SwiftPM packages them in
`ControlDeck_ControlDeck.bundle`. `scripts/build-app.sh` also copies the same
language directories to the outer application's `Contents/Resources`, because
native SwiftUI literals resolve in `Bundle.main` while model/status strings use
`AppResources.localizationBundle`.

The packager accepts both SwiftPM's flat resource-bundle layout and Xcode's
`Contents/Resources` layout, and fails if a supported language is missing. This
keeps localization on the same safe resource-loading path as the startup fix.

Use localized literals directly in native SwiftUI controls. For computed labels,
conditional strings, AppKit controls, and service messages, use
`String(localized: ..., bundle: AppResources.localizationBundle)`. Keep sentences
whole and retain their interpolation placeholders and types. Do not translate
serialized enum values, app identifiers, keyboard shortcuts, semantic automation
selectors, or user-supplied profile names. Built-in profile names have a separate
`displayName`; their stored and exported names remain compatible with old files.

Tilt Run receives a JSON-encoded dictionary from Swift at document start, using
the same selected language as the app. Its standalone browser fallback is English.
After editing `game.js`, regenerate its bundled script with
`./scripts/bundle-gyro-game.sh` (pinned esbuild; requires Node/npm).

## Verification

Run `./scripts/test.sh`. Localization checks exercise main-bundle and nested-bundle
lookup, interpolated messages, built-in and custom profile names, stable action
identifiers, JSON round trips, English fallback, matching catalog keys, and format
placeholder integrity. The native WebKit smoke test checks English, Chinese, and
Japanese start labels and that the start button still enters the playing state.

After packaging, run:

```sh
./scripts/test-localization.sh "$PWD/dist/ControlDeck.app"
```

This checks the resources actually shipped in the app, in separate processes for
English, Chinese, Japanese, and an unsupported language. Language overrides apply
only to those test processes; the script does not modify system or app defaults.
