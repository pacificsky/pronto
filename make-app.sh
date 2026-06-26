#!/bin/bash
# Build Pronto and assemble a menu-bar .app bundle.
set -euo pipefail

CONFIG="${1:-release}"
APP_NAME="Pronto"
BUNDLE_ID="blog.pacificsky.pronto"
DIST="dist"
APP="$DIST/$APP_NAME.app"

# Stable signing identity. Override with SIGN_IDENTITY=... (e.g. a Developer ID)
# to use your own cert; otherwise we create/reuse a local self-signed one so the
# code signature stays constant across rebuilds and the Keychain stops prompting.
SIGN_IDENTITY="${SIGN_IDENTITY:-Pronto Local Signing}"
LOGIN_KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

# Ensure a usable code-signing identity named "$SIGN_IDENTITY" exists.
# Echoes the identity to sign with on stdout (falls back to "-" ad-hoc on failure).
ensure_identity() {
    # Fast path: already a valid code-signing identity.
    if security find-identity -v -p codesigning 2>/dev/null | grep -qF "$SIGN_IDENTITY"; then
        echo "$SIGN_IDENTITY"; return
    fi

    local tmp; tmp="$(mktemp -d)"
    # Create the cert+key only if one with this name isn't already present.
    if ! security find-certificate -c "$SIGN_IDENTITY" "$LOGIN_KEYCHAIN" >/dev/null 2>&1; then
        echo "▸ Creating self-signed signing identity '$SIGN_IDENTITY'…" >&2
        cat > "$tmp/req.cfg" <<EOF
[req]
distinguished_name = dn
x509_extensions = v3
prompt = no
[dn]
CN = $SIGN_IDENTITY
[v3]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
EOF
        openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
            -keyout "$tmp/key.pem" -out "$tmp/cert.pem" -config "$tmp/req.cfg" >/dev/null 2>&1 || true
        openssl pkcs12 -export -out "$tmp/id.p12" -inkey "$tmp/key.pem" -in "$tmp/cert.pem" \
            -name "$SIGN_IDENTITY" -passout pass: >/dev/null 2>&1 || true
        # -A lets codesign use the key without per-use prompts.
        security import "$tmp/id.p12" -k "$LOGIN_KEYCHAIN" -P "" -T /usr/bin/codesign -A >/dev/null 2>&1 || true
    fi

    # If the cert already existed, export it so we can (re)apply trust.
    if [ ! -f "$tmp/cert.pem" ]; then
        security find-certificate -c "$SIGN_IDENTITY" -p "$LOGIN_KEYCHAIN" > "$tmp/cert.pem" 2>/dev/null || true
    fi

    # Trust it for code signing (user-level; macOS prompts for your password once).
    echo "▸ Trusting the identity for code signing (one-time macOS password prompt)…" >&2
    security add-trusted-cert -r trustRoot -p codeSign -k "$LOGIN_KEYCHAIN" \
        "$tmp/cert.pem" >/dev/null 2>&1 || true
    rm -rf "$tmp"

    if security find-identity -v -p codesigning 2>/dev/null | grep -qF "$SIGN_IDENTITY"; then
        echo "$SIGN_IDENTITY"
    else
        echo "-"  # fall back to ad-hoc
    fi
}

echo "▸ Building ($CONFIG)…"
swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/$APP_NAME"

echo "▸ Assembling $APP …"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>            <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>     <string>$APP_NAME</string>
    <key>CFBundleExecutable</key>      <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>      <string>$BUNDLE_ID</string>
    <key>CFBundlePackageType</key>     <string>APPL</string>
    <key>CFBundleShortVersionString</key> <string>1.0</string>
    <key>CFBundleVersion</key>         <string>1</string>
    <key>LSMinimumSystemVersion</key>  <string>14.0</string>
    <key>LSUIElement</key>             <true/>
    <key>NSHighResolutionCapable</key> <true/>
</dict>
</plist>
PLIST

IDENTITY="$(ensure_identity)"
if [ "$IDENTITY" = "-" ]; then
    echo "▸ Code-signing (ad-hoc — identity unavailable, Keychain will re-prompt)…"
else
    echo "▸ Code-signing with '$IDENTITY'…"
fi
codesign --force --deep --sign "$IDENTITY" "$APP" >/dev/null 2>&1 || echo "  (codesign skipped)"

echo "✓ Built $APP"
