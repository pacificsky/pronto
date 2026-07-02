#!/bin/bash
# Render packaging/pronto.rb.tmpl to stdout for a given release.
# Usage: render-cask.sh <version-without-v> <zip-sha256>
# Used by the release workflow (Update Homebrew cask step) and for manual
# tap updates; the template is the single source of truth for the cask.
set -euo pipefail
VERSION="$1"
SHA256="$2"
sed -e "s/{{VERSION}}/${VERSION}/g" -e "s/{{SHA256}}/${SHA256}/g" \
  "$(dirname "$0")/pronto.rb.tmpl"
