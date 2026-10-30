#!/bin/zsh
# Builds build/ScreenshotRename.app from Sources/.
set -euo pipefail
cd "$(dirname "$0")"

APP="build/ScreenshotRename.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

swiftc -O -swift-version 5 \
  -framework AppKit -framework Carbon \
  Sources/main.swift -o "$APP/Contents/MacOS/ScreenshotRename"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>local.screenshot-rename</string>
  <key>CFBundleName</key><string>ScreenshotRename</string>
  <key>CFBundleExecutable</key><string>ScreenshotRename</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>12.0</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

# Sign with a stable, self-signed local certificate so the Screen Recording
# permission survives rebuilds. (An ad-hoc signature is tied to the exact binary
# hash, so every code change would silently invalidate the permission.)
# The certificate lives in its own keychain file: the login keychain and system
# trust settings are not touched. uninstall.sh deletes it.
SIGN_DIR="$HOME/Library/Application Support/ScreenshotRename"
KEYCHAIN="$SIGN_DIR/signing.keychain-db"
IDENTITY="ScreenshotRename Local Signing"

if [[ ! -f "$KEYCHAIN" ]]; then
  echo "Creating local signing certificate (one time)..."
  mkdir -p "$SIGN_DIR"
  TMP="$(mktemp -d)"
  trap 'rm -rf "$TMP"' EXIT
  cat > "$TMP/cert.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $IDENTITY
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF
  /usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$TMP/cert.cnf" \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" 2>/dev/null
  /usr/bin/openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
    -out "$TMP/id.p12" -passout pass:import
  security create-keychain -p "" "$KEYCHAIN"
  security set-keychain-settings "$KEYCHAIN"   # never auto-lock
  security unlock-keychain -p "" "$KEYCHAIN"
  security import "$TMP/id.p12" -k "$KEYCHAIN" -P import -T /usr/bin/codesign >/dev/null
  security set-key-partition-list -S apple-tool:,apple: -k "" "$KEYCHAIN" >/dev/null
fi

security unlock-keychain -p "" "$KEYCHAIN"
codesign --force --keychain "$KEYCHAIN" --sign "$IDENTITY" "$APP"
echo "Built $APP"
