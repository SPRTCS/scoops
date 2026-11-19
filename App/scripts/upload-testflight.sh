#!/bin/zsh
# Baut AIS Scoops für iOS und macOS, signiert automatisch (Apple Distribution) und lädt beide Builds
# zu App Store Connect / TestFlight hoch (App: com.ais.aisbot, Apple ID 6833654924).
#
# Aufruf:  scripts/upload-testflight.sh <build-nummer> [ios|mac|all]
# Beispiel: scripts/upload-testflight.sh 7
#
# Version (MARKETING_VERSION) steht in project.yml; die Build-Nummer wird per Kommandozeile gesetzt
# und gilt für App und Widget-Extension gleichermaßen.
set -euo pipefail

BUILD="${1:?Build-Nummer angeben, z. B. scripts/upload-testflight.sh 7}"
WHICH="${2:-all}"

cd "${0:A:h:h}"                                   # App/
KEY_DIR="${ASC_KEY_DIR:-$HOME/Documents/Projects/Apps}"  # AuthKey_<KEY_ID>.p8 liegt hier (nie ins Repo kopieren)
KEY_ID=B2M5G9DH6U
ISSUER=0129d0a3-d63c-4162-a69b-f6ff28b5314e
export API_PRIVATE_KEYS_DIR="$KEY_DIR"
OUT=/tmp/claude-501/aisbot-release
DD=/tmp/claude-501/aisbot-release-dd               # DerivedData außerhalb von iCloud Drive
mkdir -p "$OUT"

AUTH=(-allowProvisioningUpdates
      -authenticationKeyPath "$KEY_DIR/AuthKey_$KEY_ID.p8"
      -authenticationKeyID "$KEY_ID"
      -authenticationKeyIssuerID "$ISSUER")

/opt/homebrew/bin/xcodegen generate

archive_and_upload() {
  local platform=$1 destination=$2 options=$3
  local archive="$OUT/AISBot-$platform-$BUILD.xcarchive"
  echo "==> Archiv $platform (Build $BUILD)"
  xcodebuild -project AISBot.xcodeproj -scheme AISBot -configuration Release \
    -destination "$destination" -derivedDataPath "$DD" \
    -archivePath "$archive" archive CURRENT_PROJECT_VERSION="$BUILD" "${AUTH[@]}"
  echo "==> Export + Upload $platform"
  # ExportOptions: method app-store-connect, destination upload → lädt direkt zu App Store Connect hoch.
  xcodebuild -exportArchive -archivePath "$archive" -exportPath "$OUT/export-$platform-$BUILD" \
    -exportOptionsPlist "$options" "${AUTH[@]}"
}

if [[ "$WHICH" == "ios" || "$WHICH" == "all" ]]; then
  archive_and_upload ios 'generic/platform=iOS' ExportOptions-ios.plist
fi
if [[ "$WHICH" == "mac" || "$WHICH" == "all" ]]; then
  archive_and_upload mac 'generic/platform=macOS' ExportOptions-mac.plist
fi

echo "Fertig. Builds erscheinen nach der Verarbeitung in App Store Connect → TestFlight."
