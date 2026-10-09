#!/bin/bash
# Builds build/Lipsync.app, signed and ready to drag into /Applications.
#   scripts/build.sh            build
#   scripts/build.sh --install  build, copy to /Applications and open it
#
# No Apple Developer account is needed. Signing uses, in order: SIGN_IDENTITY if set, an
# "Apple Development" or "Developer ID Application" identity if you have one, or a local
# self-signed identity this script creates once. A stable identity means macOS remembers the
# permissions you grant across rebuilds; ad-hoc signing (the last resort) does not.
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ -f config.env ]]; then
  set -a
  # shellcheck disable=SC1091
  source config.env
  set +a
fi

BUNDLE_ID="${BUNDLE_ID:-app.lipsync.Lipsync}"
SPOTIFY_CLIENT_ID="${SPOTIFY_CLIENT_ID:-}"
BACKEND="${LIPSYNC_BACKEND:-musicapp}"
VERSION="${VERSION:-1.0}"
BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
LOCAL_IDENTITY="Lipsync Local Signing"

make_local_identity() {
  local tmp
  tmp="$(mktemp -d)"
  cat > "$tmp/cert.cfg" <<CFG
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $LOCAL_IDENTITY
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
CFG
  /usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$tmp/cert.cfg" \
    -keyout "$tmp/key.pem" -out "$tmp/cert.pem" >/dev/null 2>&1 &&
  /usr/bin/openssl pkcs12 -export -inkey "$tmp/key.pem" -in "$tmp/cert.pem" -out "$tmp/identity.p12" \
    -passout pass:lipsync >/dev/null 2>&1 &&
  security import "$tmp/identity.p12" -P lipsync -T /usr/bin/codesign >/dev/null 2>&1
  local status=$?
  rm -rf "$tmp"
  return $status
}

if [[ -z "${SIGN_IDENTITY:-}" ]]; then
  SIGN_IDENTITY="$(security find-identity -v -p codesigning | sed -nE 's/.*"((Apple Development|Developer ID Application): [^"]+)".*/\1/p' | head -1)"
fi
if [[ -z "$SIGN_IDENTITY" ]]; then
  if ! security find-identity -p codesigning | grep -q "\"$LOCAL_IDENTITY\""; then
    echo "Creating a local code-signing identity ($LOCAL_IDENTITY) in your login keychain…"
    make_local_identity || echo "Couldn't create it; signing ad-hoc instead."
  fi
  if security find-identity -p codesigning | grep -q "\"$LOCAL_IDENTITY\""; then
    SIGN_IDENTITY="$LOCAL_IDENTITY"
  else
    SIGN_IDENTITY="-"
  fi
fi

echo "Building…"
# One binary for Apple Silicon and Intel where the toolchain can; otherwise for this Mac.
if swift build -c release --product Lipsync --arch arm64 --arch x86_64; then
  BIN_DIR="$(swift build -c release --product Lipsync --arch arm64 --arch x86_64 --show-bin-path)"
else
  echo "Universal build isn't available with this toolchain; building for this Mac only."
  swift build -c release --product Lipsync
  BIN_DIR="$(swift build -c release --show-bin-path)"
fi

APP=build/Lipsync.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Lipsync" "$APP/Contents/MacOS/Lipsync"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
sed -e "s|__BUNDLE_ID__|$BUNDLE_ID|" \
    -e "s|__SPOTIFY_CLIENT_ID__|$SPOTIFY_CLIENT_ID|" \
    -e "s|__BACKEND__|$BACKEND|" \
    -e "s|__VERSION__|$VERSION|" \
    -e "s|__BUILD__|$BUILD_NUMBER|" \
    Resources/Info.plist > "$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist" >/dev/null

echo "Signing with ${SIGN_IDENTITY}…"
codesign --force --timestamp=none --options runtime --entitlements Resources/Lipsync.entitlements --sign "$SIGN_IDENTITY" "$APP"
codesign --verify --strict "$APP"

echo
echo "Built $APP (bundle $BUNDLE_ID, plays through: $BACKEND)."
if [[ "$SIGN_IDENTITY" == "-" ]]; then
  echo "Signed ad-hoc: macOS will ask for Lipsync's permissions again after each rebuild."
fi

if [[ "${1:-}" == "--install" ]]; then
  osascript -e 'tell application id "'"$BUNDLE_ID"'" to quit' >/dev/null 2>&1 || true
  sleep 1
  rm -rf /Applications/Lipsync.app
  ditto "$APP" /Applications/Lipsync.app
  open /Applications/Lipsync.app
  echo "Installed and opened /Applications/Lipsync.app."
else
  echo "Drag it into /Applications and open it, or run: scripts/build.sh --install"
fi
