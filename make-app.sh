#!/bin/bash
# Build Pronto and assemble a menu-bar .app bundle.
set -euo pipefail

CONFIG="${1:-release}"
APP_NAME="Pronto"
BUNDLE_ID="blog.pacificsky.pronto"
DIST="dist"
APP="$DIST/$APP_NAME.app"

# Version shown in the bundle. Release CI sets this explicitly from the tag
# (APP_VERSION=1.2.0). Otherwise derive it from git so a local build reflects
# the last released tag — exact (e.g. 0.4.0) when built on a tag, or
# 0.4.0-3-gabc1234[-dirty] when ahead of / dirty against it. Falls back to
# 0.0.0-unknown outside a git checkout.
APP_VERSION="${APP_VERSION:-$(git describe --tags --always --dirty 2>/dev/null | sed 's/^v//')}"
APP_VERSION="${APP_VERSION:-0.0.0-unknown}"

# Sentry DSN, baked into the bundle for opt-in crash reporting. Empty by default,
# so local/dev builds ship no DSN and crash reporting never initializes (see
# CrashReporting.swift). Release CI injects it from a repository secret.
SENTRY_DSN="${SENTRY_DSN:-}"

# Stable signing identity. Override with SIGN_IDENTITY=... (e.g. a Developer ID)
# to use your own cert; otherwise we create/reuse a local self-signed one so the
# code signature stays constant across rebuilds and the Keychain stops prompting.
# Set SIGN_IDENTITY=- to force a plain ad-hoc signature (used in CI).
SIGN_IDENTITY="${SIGN_IDENTITY:-Pronto Local Signing}"
LOGIN_KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

# Ensure a usable code-signing identity named "$SIGN_IDENTITY" exists.
# Echoes the identity to sign with on stdout (falls back to "-" ad-hoc on failure).
# Diagnostic/progress chatter goes to stderr so it doesn't pollute the captured value.
ensure_identity() {
    # Fast path: a valid code-signing identity (cert + matching private key) exists.
    if security find-identity -v -p codesigning 2>/dev/null | grep -qF "$SIGN_IDENTITY"; then
        echo "$SIGN_IDENTITY"; return
    fi

    # We have no usable identity. A certificate with this name may still linger
    # WITHOUT its private key (e.g. a previous run where the key import failed) —
    # an "orphan" that is useless for signing and blocks recreating the pair.
    # Remove any such cert so the create step below always starts clean.
    if security find-certificate -c "$SIGN_IDENTITY" "$LOGIN_KEYCHAIN" >/dev/null 2>&1; then
        echo "▸ Removing stale '$SIGN_IDENTITY' certificate (no usable private key)…" >&2
        security delete-certificate -c "$SIGN_IDENTITY" "$LOGIN_KEYCHAIN" >/dev/null 2>&1 || true
    fi

    local tmp; tmp="$(mktemp -d)"
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

    if ! openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
            -keyout "$tmp/key.pem" -out "$tmp/cert.pem" -config "$tmp/req.cfg" 2>"$tmp/err"; then
        echo "  ⚠︎ openssl could not generate the cert/key — falling back to ad-hoc:" >&2
        sed 's/^/    /' "$tmp/err" >&2; rm -rf "$tmp"; echo "-"; return
    fi

    # Import the private key and certificate as separate PEM items, NOT as a
    # PKCS#12 bundle. macOS's `security import` runs a legacy PKCS#12 decoder
    # that only implements the *original* PKCS#12 algorithms (SHA-1 MAC, 3DES/RC2
    # bag encryption). OpenSSL 3 (2021) flipped its defaults to SHA-256 + AES-256,
    # so a default p12 from `openssl pkcs12 -export` fails to import — and there
    # are THREE independent ways it fails:
    #
    #   1. SHA-256 outer MAC      -> "MAC verification failed during PKCS12 import"
    #   2. AES-256-CBC bags       -> "Unknown format in import" (after MAC passes)
    #   3. empty export password  -> MAC mismatch (RFC 7292 leaves empty-password
    #                                encoding ambiguous; OpenSSL and Apple differ)
    #
    # Fixing one surfaces the next, and the catch-all "(wrong password?)" message
    # hides which is which. The p12 path only works with ALL of: `-legacy` (SHA-1
    # MAC) + legacy bag encryption + a non-empty `-passout`/`-P` password.
    #
    # When the import fails, the cert still lands (via add-trusted-cert below) but
    # the PRIVATE KEY is dropped -> an orphan cert that's useless for signing.
    # Importing PEMs skips the PKCS#12 decoder entirely, so none of the above
    # apply (and there's no `-legacy` flag to depend on, which LibreSSL lacks).
    # -A lets codesign use the key without per-use prompts.
    if ! security import "$tmp/key.pem" -k "$LOGIN_KEYCHAIN" -T /usr/bin/codesign -A 2>"$tmp/err"; then
        echo "  ⚠︎ Importing the private key into the keychain failed — falling back to ad-hoc:" >&2
        sed 's/^/    /' "$tmp/err" >&2; rm -rf "$tmp"; echo "-"; return
    fi
    if ! security import "$tmp/cert.pem" -k "$LOGIN_KEYCHAIN" -T /usr/bin/codesign -A 2>"$tmp/err"; then
        echo "  ⚠︎ Importing the certificate into the keychain failed — falling back to ad-hoc:" >&2
        sed 's/^/    /' "$tmp/err" >&2; rm -rf "$tmp"; echo "-"; return
    fi

    # Trust it for code signing (user-level; macOS prompts for your password once).
    echo "▸ Trusting the identity for code signing (one-time macOS password prompt)…" >&2
    if ! security add-trusted-cert -r trustRoot -p codeSign -k "$LOGIN_KEYCHAIN" "$tmp/cert.pem" 2>"$tmp/err"; then
        echo "  ⚠︎ Could not add trust settings (signing may still work):" >&2
        sed 's/^/    /' "$tmp/err" >&2
    fi
    rm -rf "$tmp"

    if security find-identity -v -p codesigning 2>/dev/null | grep -qF "$SIGN_IDENTITY"; then
        echo "$SIGN_IDENTITY"
    else
        echo "  ⚠︎ '$SIGN_IDENTITY' still isn't a valid signing identity — falling back to ad-hoc." >&2
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
    <key>CFBundleShortVersionString</key> <string>$APP_VERSION</string>
    <key>CFBundleVersion</key>         <string>$APP_VERSION</string>
    <key>SentryDSN</key>               <string>$SENTRY_DSN</string>
    <key>LSMinimumSystemVersion</key>  <string>14.0</string>
    <key>LSUIElement</key>             <true/>
    <key>NSHighResolutionCapable</key> <true/>
</dict>
</plist>
PLIST

if [ "$SIGN_IDENTITY" = "-" ]; then
    IDENTITY="-"   # forced ad-hoc (CI / distribution build)
else
    IDENTITY="$(ensure_identity)"
fi
# The app is a single self-contained binary (Sentry/Angstrom are statically linked;
# it links only system frameworks + OS Swift dylibs), so there's no nested code to
# sign — hence no `--deep`, which is deprecated for distribution anyway.
SIGN_ARGS=(--force --sign "$IDENTITY")
case "$IDENTITY" in
    "Developer ID"*)
        # Distribution build. Notarization REQUIRES the hardened runtime
        # (--options runtime) and a secure timestamp (--timestamp, contacts Apple's
        # TSA over the network). A broken Developer ID signature must never ship, so
        # let set -e abort the build if codesign fails — don't swallow the error.
        echo "▸ Code-signing with '$IDENTITY' (hardened runtime + timestamp)…"
        codesign "${SIGN_ARGS[@]}" --options runtime --timestamp "$APP"
        ;;
    -)
        echo "▸ Code-signing (ad-hoc)…"
        codesign "${SIGN_ARGS[@]}" "$APP" >/dev/null 2>&1 || echo "  (codesign skipped)"
        ;;
    *)
        # Local self-signed identity: no timestamp/hardened runtime so iteration
        # stays offline and fast. Best-effort (don't block a dev build on signing).
        echo "▸ Code-signing with '$IDENTITY'…"
        codesign "${SIGN_ARGS[@]}" "$APP" >/dev/null 2>&1 || echo "  (codesign skipped)"
        ;;
esac

# Debug symbols for Sentry symbolication. dsymutil gathers DWARF from the build's
# .o files (via the binary's debug map) into a .dSYM keyed by the binary's LC_UUID
# — which code-signing doesn't change, so it matches the shipped binary. Kept
# beside the bundle (not inside it); the release workflow uploads it to Sentry.
echo "▸ Generating dSYM…"
dsymutil "$BIN" -o "$DIST/$APP_NAME.dSYM"

echo "✓ Built $APP"
