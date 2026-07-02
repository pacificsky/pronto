# Release Guide

How to publish a new version of Pronto. Releases are automated by GitHub Actions
(`.github/workflows/release.yml`): pushing a version tag builds the app on a macOS
runner, zips it, and publishes a GitHub Release with the download attached.

## Cutting a release

Pick the next version number (Pronto uses [semantic versioning](https://semver.org/):
`vMAJOR.MINOR.PATCH`, e.g. `v1.0.0`), then:

```sh
git tag v1.0.0
git push origin v1.0.0
```

That's the whole process. In a couple of minutes a new **Pronto v1.0.0** release
appears on the [Releases page](https://github.com/pacificsky/pronto/releases) with
`Pronto-v1.0.0.zip` attached and install instructions in the notes.

Watch progress under the repo's **Actions** tab.

### What the workflow does

1. Checks out the tagged commit on a `macos-15` runner.
2. Imports the **Developer ID Application** certificate into a throwaway keychain,
   then builds with `APP_VERSION="<tag without v>" ./make-app.sh release`, signing with
   that identity **plus the hardened runtime + a secure timestamp** (make-app.sh adds
   those automatically for a `Developer ID …` identity — both are notarization
   requirements).
3. **Notarizes** the signed bundle with `xcrun notarytool submit … --wait` (App Store
   Connect API key) and **staples** the ticket into the app, so Gatekeeper approves it
   offline with no first-launch warning.
4. If Sentry is configured (see below): uploads the `dist/Pronto.dSYM` debug symbols
   so crash reports symbolicate, and creates + finalizes a Sentry **release** for the
   version with its commits (so events group by version). Skipped otherwise.
5. Zips the **stapled** app with `ditto -c -k --keepParent`.
6. Creates the GitHub Release with `gh release create` and an install-notes body.
7. Updates the Homebrew tap: renders `packaging/pronto.rb.tmpl` with the new
   version + zip sha256 and pushes `Casks/pronto.rb` to
   [pacificsky/homebrew-tap](https://github.com/pacificsky/homebrew-tap).
   Skipped (with a warning) if the `HOMEBREW_TAP_TOKEN` secret is unset; a
   push failure fails the job (the GitHub Release is already published by
   then — fix and re-run just this step, or render + push by hand).

## One-time setup (already done)

These only matter if the repo is recreated or settings drift:

- **Workflow committed** — `.github/workflows/release.yml` must be on the default branch.
- **Public repo** — macOS runner minutes are free for public repos. (Private repos
  bill macOS minutes at a higher rate.)
- **Actions can write releases** — the workflow declares `permissions: contents: write`.
  If a run fails creating the release with a 403, check
  *Settings → Actions → General → Workflow permissions* is set to **Read and write**.
- `HOMEBREW_TAP_TOKEN` repo secret: fine-grained PAT scoped to
  `pacificsky/homebrew-tap` only, permission **Contents: Read and write**.
  Used by the "Update Homebrew cask" step.

## Code signing & notarization

Releases are signed with an **Apple Developer ID Application** certificate and
**notarized** by Apple, so downloaded copies open with no Gatekeeper warning and keep a
*stable* code identity across updates (no post-update Keychain re-prompt). This is
gated on repo **secrets** — if `DEVELOPER_ID_CERT_P12_BASE64` is missing the release
**fails** (a release must be signed). Set them once:

```sh
# Developer ID Application cert exported from Keychain Access / Xcode as a .p12:
base64 -i DeveloperID.p12 | gh secret set DEVELOPER_ID_CERT_P12_BASE64
gh secret set DEVELOPER_ID_CERT_PASSWORD --body '<the .p12 export password>'

# App Store Connect API key (Users and Access → Integrations → App Store Connect API,
# Developer role). The .p8 is downloadable only once:
base64 -i AuthKey_XXXXXXXXXX.p8 | gh secret set NOTARY_API_KEY_P8_BASE64
gh secret set NOTARY_API_KEY_ID    --body '<Key ID>'
gh secret set NOTARY_API_ISSUER_ID --body '<Issuer ID>'
```

The temp keychain's unlock password is generated inline in the workflow, so it is *not*
a stored secret. `make-app.sh` still self-signs local dev builds (`Pronto Local
Signing`) — only CI uses the Developer ID identity, and only a `Developer ID …`
identity triggers the hardened-runtime + timestamp signing options.

### Notarizing by hand (`notarize-local.sh`)

Apple's notary service is usually quick (~30s), but it can fall into a **backlog** and
sit "In Progress" for 40–60+ minutes — sometimes even while the [status page](https://developer.apple.com/system-status/)
shows green — which can blow past the CI job's notarization cap. When that happens (or
whenever you want to hand-cut a release), notarize from your own machine instead, where
the wait has no time limit:

```sh
# One-time: store the App Store Connect API key in your keychain.
xcrun notarytool store-credentials pronto-notary \
  --key /path/AuthKey_XXXXXXXXXX.p8 --key-id <KEY_ID> --issuer <ISSUER_ID>

# Build + sign (Developer ID) + notarize + staple + zip. Leave it running.
./notarize-local.sh
```

It auto-detects your `Developer ID Application` identity, builds via `make-app.sh`
(hardened runtime + timestamp), submits, polls resiliently (retries transient network
errors, no hard cap — Ctrl-C anytime), staples, and writes `dist/Pronto.zip`. Use
`SKIP_BUILD=1` to notarize an already-built `dist/Pronto.app`, or `APP_VERSION=…` to
stamp a version. Export `SENTRY_DSN` too if you're hand-cutting a shipping build (CI
bakes it in; this script doesn't by default). If a CI release fails at the notarize
step because Apple was slow, re-running the job once the backlog clears is usually
enough — this script is the fallback for when it won't clear in time.

## Sentry (crash reporting)

Opt-in crash reporting is wired into the release pipeline but **gated on these repo
secrets/variables** — if they're absent, the Sentry steps are skipped and the release
still publishes normally. Set them once (values come from your Sentry project under
*Settings → Client Keys (DSN)* and *Auth Tokens*):

```sh
gh secret set SENTRY_DSN --body "https://…@…ingest.sentry.io/…"   # public/embeddable
gh secret set SENTRY_AUTH_TOKEN --body "sntrys_…"                 # write-scoped — real secret
gh variable set SENTRY_ORG --body "your-org"                      # not sensitive
gh variable set SENTRY_PROJECT --body "pronto"                    # not sensitive
```

Why the split: the **DSN** is baked into the shipped app (it's meant to be public), so
it lives as a secret only to keep it out of the repo. The **auth token** can write to
your Sentry project (uploads symbols, creates releases), so it's a genuine secret —
prefer a scoped *organization* auth token. The **org/project slugs** aren't sensitive,
so they're plain repo *variables* (`vars.*`, not `secrets.*`).

Verify what's set with `gh secret list` and `gh variable list`. The app only sends
data when the user opts in *and* a DSN is baked in; see the crash-reporting notes in
`CLAUDE.md` for the privacy design.

## What people download

The released `.zip` is **Developer ID signed and notarized by Apple**, with the
notarization ticket **stapled** into the bundle. A downloaded copy opens on first
launch with no Gatekeeper warning (even offline), and because the Developer ID identity
is stable across releases, users get **no** Keychain re-prompt for their saved
credentials after updating.

Homebrew users get the exact same zip: the cask downloads the release asset
from GitHub, so signature, notarization ticket, and Keychain identity are
identical to a manual download.

To verify a build locally after downloading (or after
`xattr -dr com.apple.quarantine /Applications/Pronto.app`):

```sh
spctl -a -vvv --type exec /Applications/Pronto.app   # accepted, source=Notarized Developer ID
codesign -dv --verbose=4 /Applications/Pronto.app    # Authority: Developer ID Application; flags=runtime
stapler validate /Applications/Pronto.app            # The validate action worked!
```

If notarization is **rejected** during a release, the workflow fails at the *Notarize
and staple* step; run `xcrun notarytool log <submission-id> --key … --key-id … --issuer …`
to see why.

## Tips

- **Re-running a release:** delete the tag locally and remotely
  (`git tag -d v1.0.0 && git push origin :refs/tags/v1.0.0`), delete the GitHub
  Release if one was created, then re-tag and push.
- **Test the build locally first** without publishing:
  `SIGN_IDENTITY=- APP_VERSION=1.0.0 ./make-app.sh release` and check `dist/Pronto.app`.
- Keep `CHANGELOG`-worthy notes in your commit messages — `gh release create` can be
  switched to `--generate-notes` if you'd rather auto-build notes from history.
