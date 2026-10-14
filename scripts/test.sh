#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT="${TMPDIR:-/tmp}/control-deck-logic-tests"

swiftc \
  -parse-as-library \
  -framework AppKit \
  -framework ApplicationServices \
  -framework Carbon \
  -o "$OUTPUT" \
  "$ROOT/Sources/ControlDeck/AppResources.swift" \
  "$ROOT/Sources/ControlDeck/Models.swift" \
  "$ROOT/Sources/ControlDeck/GyroModels.swift" \
  "$ROOT/Sources/ControlDeck/InputMappingModels.swift" \
  "$ROOT/Sources/ControlDeck/ProfileTransfer.swift" \
  "$ROOT/Sources/ControlDeck/ExpandedProfileCatalog.swift" \
  "$ROOT/Sources/ControlDeck/ShiftLayerModels.swift" \
  "$ROOT/Sources/ControlDeck/QuickTutorial.swift" \
  "$ROOT/Sources/ControlDeck/CodexDictationIntent.swift" \
  "$ROOT/Sources/ControlDeck/TouchpadGestureEngine.swift" \
  "$ROOT/Sources/ControlDeck/PointerService.swift" \
  "$ROOT/Sources/ControlDeck/ScreenshotEditorModels.swift" \
  "$ROOT/Sources/ControlDeck/ScreenshotEditorController.swift" \
  "$ROOT/Sources/ControlDeck/CodexTaskMonitor.swift" \
  "$ROOT/Sources/ControlDeck/DualSenseBluetoothAudioProtocol.swift" \
  "$ROOT/Tests/ControlDeckTests/ControlDeckTests.swift"

"$OUTPUT"
"$ROOT/scripts/test-resource-bundle.sh"

GYRO_GAME="$ROOT/Sources/ControlDeck/Resources/GyroGame"
node --check "$GYRO_GAME/game.js"
node --check "$GYRO_GAME/game.bundle.js"
for resource in \
  index.html styles.css game.js game.bundle.js three.module.min.js \
  three.core.min.js THREE-LICENSE.txt
do
  if [[ ! -s "$GYRO_GAME/$resource" ]]; then
    print -u2 "FAIL: Tilt Run resource is missing: $resource"
    exit 1
  fi
done
if ! grep -q "three.core.min.js" "$GYRO_GAME/three.module.min.js"; then
  print -u2 "FAIL: bundled Three.js module/core versions do not match"
  exit 1
fi
echo "PASS: Tilt Run Three.js bundle"
"$ROOT/scripts/test-gyro-webkit.sh"

EXTENSION_SERVICE="$ROOT/Sources/ControlDeck/CodexExtensionService.swift"
MCP_SERVER="$ROOT/Sources/ControlDeck/Resources/control_deck_mcp.py"

if grep -Eq 'Process[(]|executableURL|/usr/bin/env' "$EXTENSION_SERVICE"; then
  print -u2 "FAIL: Codex customization must not launch a CLI executable"
  exit 1
fi

if grep -Eq \
  'shell[[:space:]]*=[[:space:]]*True|os\\.system|subprocess\\.Popen|socket|urllib|requests' \
  "$MCP_SERVER"; then
  print -u2 "FAIL: controller MCP exceeded its local preference-only boundary"
  exit 1
fi

echo "PASS: Codex customization security boundaries"

CONTROLLER_SERVICE="$ROOT/Sources/ControlDeck/DualSenseControllerService.swift"
SPEECH_SERVICE="$ROOT/Sources/ControlDeck/AppleSpeechTranscriptionService.swift"
SPEECH_TARGET="$ROOT/Sources/ControlDeck/SpeechTextInsertionTarget.swift"
DICTATION_FOCUS_GUARD="$ROOT/Sources/ControlDeck/DictationFocusGuard.swift"
BUILD_APP="$ROOT/scripts/build-app.sh"
BUILD_AND_RUN="$ROOT/script/build_and_run.sh"
PACKAGE_RELEASE="$ROOT/scripts/package-notarized-release.sh"
APP_ENTITLEMENTS="$ROOT/Resources/ControlDeck.entitlements"
MODEL_BUNDLE_GUARD="$ROOT/scripts/verify-no-bundled-speech-models.sh"

if grep -Eq 'preferredSystemGestureState[[:space:]]*=[[:space:]]*[.]alwaysReceive' \
  "$CONTROLLER_SERVICE" ||
  ! grep -Eq 'preferredSystemGestureState[[:space:]]*=[[:space:]]*[.]disabled' \
    "$CONTROLLER_SERVICE"
then
  print -u2 "FAIL: mapped controller buttons can still trigger macOS game gestures"
  exit 1
fi

if ! grep -q 'AVAudioApplication.shared.recordPermission' "$SPEECH_SERVICE" ||
  grep -q 'AVCaptureDevice.authorizationStatus(for: .audio)' "$SPEECH_SERVICE"
then
  print -u2 "FAIL: dictation is not using the AVAudioEngine microphone permission path"
  exit 1
fi

echo "PASS: controller gesture ownership and microphone permission path"

if ! grep -q 'com.apple.security.device.audio-input' "$APP_ENTITLEMENTS" ||
  ! grep -q -- '--entitlements "$APP_ENTITLEMENTS"' "$BUILD_APP" ||
  ! grep -q -- '--entitlements "$APP_ENTITLEMENTS"' "$PACKAGE_RELEASE"
then
  print -u2 "FAIL: a ControlDeck signing path can strip microphone access"
  exit 1
fi

if grep -Eq \
  'security[[:space:]]+find-identity|DEVELOPER_ID_APPLICATION' \
  "$BUILD_APP" ||
  ! grep -q 'CONTROLDECK_DEVELOPMENT_SIGNING_IDENTITY' "$BUILD_APP" ||
  ! grep -q 'development-signing-identity' "$BUILD_APP" ||
  ! grep -q 'build-app.sh" --development' "$BUILD_AND_RUN"
then
  print -u2 "FAIL: development signing is not explicit and local-only"
  exit 1
fi

if ! grep -q -- '--sign "$DEVELOPER_ID_APPLICATION"' "$PACKAGE_RELEASE" ||
  ! grep -q 'notarytool submit' "$PACKAGE_RELEASE"
then
  print -u2 "FAIL: Developer ID signing is not confined to the release path"
  exit 1
fi

if [[ ! -x "$MODEL_BUNDLE_GUARD" ]] ||
  ! grep -q 'verify-no-bundled-speech-models.sh' "$BUILD_APP" ||
  ! grep -q 'verify-no-bundled-speech-models.sh' "$PACKAGE_RELEASE"
then
  print -u2 "FAIL: speech model weights can enter a release bundle"
  exit 1
fi

if ! grep -q 'for element in gamepad.allElements' "$CONTROLLER_SERVICE"
then
  print -u2 "FAIL: analogue controller elements can still trigger system gestures"
  exit 1
fi

if ! grep -q 'reinforceSystemGestureSuppression' "$CONTROLLER_SERVICE" ||
  ! grep -q 'com.apple.games' "$DICTATION_FOCUS_GUARD"
then
  print -u2 "FAIL: Bluetooth dictation can lose focus to macOS Games"
  exit 1
fi

if ! grep -q 'accessibility-opaque window' "$SPEECH_TARGET" ||
  ! grep -q 'target: SpeechTextInsertionTarget' "$SPEECH_SERVICE"
then
  print -u2 "FAIL: dictation rejects editors without a named AX text role"
  exit 1
fi

echo "PASS: development/release signing split and full gesture ownership"

LOCAL_SPEECH="$ROOT/Sources/ControlDeck/LocalSpeechTranscriptionService.swift"
SPEECH_PIPELINE="$ROOT/Sources/ControlDeck/SpeechAudioPipeline.swift"
APPLE_BUFFER_FALLBACK="$ROOT/Sources/ControlDeck/AppleSpeechBufferTranscriber.swift"
PACKAGE_MANIFEST="$ROOT/Package.swift"

if grep -REqi --exclude-dir=.build --exclude-dir=.git \
  'import Moonshine|moonshine-swift|MoonshineTranscriptionService|MoonshineSmoke' \
  "$ROOT/Sources" "$ROOT/Package.swift" "$ROOT/Tools"
then
  print -u2 "FAIL: retired Moonshine code is still part of the app"
  exit 1
fi

if ! grep -q 'FluidInference/FluidAudio.git' "$PACKAGE_MANIFEST" ||
  ! grep -q 'argmaxinc/argmax-oss-swift.git' "$PACKAGE_MANIFEST" ||
  ! grep -q 'StreamingEouAsrManager' "$LOCAL_SPEECH" ||
  ! grep -q 'WhisperKitConfig' "$LOCAL_SPEECH" ||
  ! grep -q 'drainAudioPump' "$LOCAL_SPEECH" ||
  ! grep -q 'ContinuousSpeechAudioProcessor' "$SPEECH_PIPELINE" ||
  ! grep -q 'recognitionSamples' "$SPEECH_PIPELINE" ||
  ! grep -q 'trailingPadding: 1.1' "$LOCAL_SPEECH" ||
  ! grep -q 'convertToMonoSamples' "$LOCAL_SPEECH" ||
  ! grep -q 'parakeetFeedFrames' "$LOCAL_SPEECH" ||
  ! grep -q 'transcribeWithAppleFallback' "$LOCAL_SPEECH" ||
  ! grep -q 'AnalysisContext' "$APPLE_BUFFER_FALLBACK" ||
  ! grep -q 'DualSenseBluetoothPacketTimeline' "$CONTROLLER_SERVICE" \
      "$ROOT/Sources/ControlDeck/DualSenseBluetoothAudioProtocol.swift" \
      "$ROOT/Sources/ControlDeck/BluetoothMicrophoneService.swift"
then
  print -u2 "FAIL: continuous transcription, fallback or model integration is missing"
  exit 1
fi

echo "PASS: continuous Parakeet, WhisperKit and Apple fallback integration"
