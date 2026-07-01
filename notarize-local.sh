#!/bin/bash
# Build, Developer ID-sign, notarize, and staple Pronto from your own machine —
# producing the same distributable zip the release workflow does, but without a CI
# job's time limit.
#
# Why this exists: Apple's notary service can take a *very* long time on the first
# submission for a new app/team (well beyond a reasonable CI cap). Run this once
# locally to get that first notarization through; afterwards the CI path
# (.github/workflows/release.yml) should notarize quickly on its own.
#
# Usage:
#   ./notarize-local.sh                 # build + notarize + staple + zip
#   APP_VERSION=0.5.4 ./notarize-local.sh
#   SKIP_BUILD=1 ./notarize-local.sh    # notarize the existing dist/Pronto.app as-is
#
# One-time credential setup (recommended) — store the App Store Connect API key in
# your keychain so you don't pass it every run:
#   xcrun notarytool store-credentials pronto-notary \
#     --key /path/to/AuthKey_XXXXXXXXXX.p8 --key-id <KEY_ID> --issuer <ISSUER_ID>
# Then this script picks it up via NOTARY_PROFILE (default "pronto-notary").
# Alternatively, point at the raw key with env vars:
#   NOTARY_KEY=/path/AuthKey_XXXX.p8 NOTARY_KEY_ID=XXXX NOTARY_ISSUER_ID=XXXX ./notarize-local.sh
set -euo pipefail

APP_NAME="Pronto"
DIST="dist"
APP="$DIST/$APP_NAME.app"

# --- Signing identity -------------------------------------------------------
# Auto-detect the Developer ID Application identity unless SIGN_IDENTITY is set.
# make-app.sh applies the hardened runtime + secure timestamp for any "Developer
# ID …" identity (both are notarization requirements).
if [ -z "${SIGN_IDENTITY:-}" ]; then
    SIGN_IDENTITY="$(security find-identity -v -p codesigning \
        | grep 'Developer ID Application' | head -1 | sed -E 's/.*"(.*)"/\1/')"
fi
if [ -z "$SIGN_IDENTITY" ]; then
    echo "✗ No 'Developer ID Application' identity found in your keychain." >&2
    echo "  Create one: Xcode → Settings → Accounts → (team) → Manage Certificates" >&2
    echo "  → + → Developer ID Application. Or set SIGN_IDENTITY=… explicitly." >&2
    exit 1
fi

# --- Notary credentials -----------------------------------------------------
# Prefer raw API-key env vars if given; otherwise use a stored keychain profile.
if [ -n "${NOTARY_KEY:-}" ]; then
    AUTH=(--key "$NOTARY_KEY" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID")
else
    NOTARY_PROFILE="${NOTARY_PROFILE:-pronto-notary}"
    if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
        echo "✗ No notary credentials. Either set NOTARY_KEY/NOTARY_KEY_ID/NOTARY_ISSUER_ID," >&2
        echo "  or store a profile once (recommended):" >&2
        echo "    xcrun notarytool store-credentials $NOTARY_PROFILE \\" >&2
        echo "      --key /path/AuthKey_XXXX.p8 --key-id <KEY_ID> --issuer <ISSUER_ID>" >&2
        exit 1
    fi
    AUTH=(--keychain-profile "$NOTARY_PROFILE")
fi

# --- Build (signed) ---------------------------------------------------------
if [ "${SKIP_BUILD:-}" = "1" ]; then
    echo "▸ Skipping build; notarizing existing $APP"
    [ -d "$APP" ] || { echo "✗ $APP does not exist — run without SKIP_BUILD first." >&2; exit 1; }
else
    echo "▸ Building + signing with '$SIGN_IDENTITY'…"
    SIGN_IDENTITY="$SIGN_IDENTITY" APP_VERSION="${APP_VERSION:-}" ./make-app.sh release
fi

# Sanity-check the signature carries the hardened runtime (flag 'runtime') before we
# waste a notary round-trip on a bundle Apple will reject.
if ! codesign -dv --verbose=4 "$APP" 2>&1 | grep -q 'flags=.*runtime'; then
    echo "✗ $APP is not signed with the hardened runtime — notarization would be rejected." >&2
    echo "  Ensure it was signed with a 'Developer ID …' identity (not ad-hoc/self-signed)." >&2
    exit 1
fi

# --- Submit + wait (resilient) ----------------------------------------------
ZIP="$DIST/$APP_NAME-notarize.zip"
echo "▸ Zipping for submission → $ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

echo "▸ Submitting to Apple's notary service…"
ID="$(xcrun notarytool submit "$ZIP" "${AUTH[@]}" --output-format json | /usr/bin/python3 -c 'import sys,json;print(json.load(sys.stdin)["id"])')"
echo "  Submission ID: $ID"
echo "  (First-time submissions can take a long time — leave this running. Ctrl-C to stop;"
echo "   re-check later with: xcrun notarytool info $ID ${AUTH[*]})"

# Poll instead of `--wait`: a single transient network error mustn't abort a long
# wait, so we retry those. No hard cap — you can Ctrl-C anytime.
status="In Progress"
start="$(date +%s)"
while [ "$status" = "In Progress" ]; do
    sleep 30
    info="$(xcrun notarytool info "$ID" "${AUTH[@]}" --output-format json 2>/dev/null)" \
        || { echo "  … transient error querying status, retrying"; continue; }
    status="$(printf '%s' "$info" | /usr/bin/python3 -c 'import sys,json;print(json.load(sys.stdin).get("status","In Progress"))' 2>/dev/null || echo "In Progress")"
    printf '  status: %s (%dm elapsed)\n' "$status" "$(( ($(date +%s) - start) / 60 ))"
done

if [ "$status" != "Accepted" ]; then
    echo "✗ Notarization $status — full log:" >&2
    xcrun notarytool log "$ID" "${AUTH[@]}" || true
    exit 1
fi

# --- Staple + package -------------------------------------------------------
echo "▸ Stapling the ticket into $APP…"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"

OUT="$DIST/$APP_NAME.zip"
ditto -c -k --keepParent "$APP" "$OUT"
rm -f "$ZIP"

echo "✓ Notarized + stapled. Distributable zip: $OUT"
echo "  Verify a downloaded copy with:"
echo "    spctl -a -vvv --type exec $APP     # → accepted, source=Notarized Developer ID"
echo "    stapler validate $APP"
