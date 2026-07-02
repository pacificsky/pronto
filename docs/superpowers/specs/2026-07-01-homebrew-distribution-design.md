# Homebrew distribution for Pronto — design

Date: 2026-07-01
Status: approved

## Goal

Let users install Pronto with `brew install --cask pacificsky/tap/pronto`, with the
cask kept up to date automatically on every release. The tap already exists at
`github.com/pacificsky/homebrew-tap` (currently `Formula/cage.rb` only).

## Approach

Pronto ships as a prebuilt, Developer ID-signed, notarized `.app` zip on GitHub
Releases, so the vehicle is a Homebrew **cask** (not a formula), added under a new
`Casks/` directory in the tap.

The cask file is **generated**: the single source of truth is a template checked
into the pronto repo, rendered and pushed to the tap by the release workflow. Manual
edits to `Casks/pronto.rb` in the tap will be overwritten on the next release (the
tap README will say so).

## Components

### 1. `Casks/pronto.rb` in pacificsky/homebrew-tap

- `version` / `sha256` of the release asset
- `url "https://github.com/pacificsky/pronto/releases/download/v#{version}/Pronto-v#{version}.zip"`
- `name "Pronto"`, `desc`, `homepage` pointing at the pronto repo
- `depends_on macos: ">= :sonoma"` — matches the macOS 14 deployment target
- `app "Pronto.app"`
- `uninstall quit: "blog.pacificsky.pronto"` — quits the running menu-bar app on
  upgrade/uninstall
- `zap trash: "~/Library/Preferences/blog.pacificsky.pronto.plist"`
- `caveats`: credentials live in the macOS Keychain (service = bundle id) and are
  not removed by uninstall; unofficial / not affiliated with La Marzocco
- `livecheck` block using the `:github_latest` strategy

### 2. Template in pronto: `packaging/pronto.rb.tmpl`

Same content with `{{VERSION}}` / `{{SHA256}}` placeholders (exact placeholder
syntax up to implementation; simple `sed`-able tokens).

### 3. Release workflow step (pronto `.github/workflows/release.yml`)

New final step, after "Publish GitHub Release":

- Skipped with a `::warning::` if the `HOMEBREW_TAP_TOKEN` secret is unset
  (consistent with the Sentry steps — the release still publishes).
- Otherwise: `shasum -a 256` the built `Pronto-<tag>.zip`, render the template,
  and push via the GitHub contents API
  (`gh api PUT /repos/pacificsky/homebrew-tap/contents/Casks/pronto.rb`, sending
  the current file's SHA when it exists so updates don't 409).
- A push failure **fails the step loudly** — the release is already published at
  that point, so nothing is lost, but the failure is visible.

### 4. Auth

Fine-grained PAT scoped to `pacificsky/homebrew-tap` only, permission
Contents: Read and write, stored as the `HOMEBREW_TAP_TOKEN` secret on the pronto
repo (`gh secret set HOMEBREW_TAP_TOKEN --repo pacificsky/pronto`). Created
manually by Aakash (PAT creation is interactive).

### 5. Bootstrap (one-time, done now)

- Compute sha256 of the already-published `Pronto-v0.6.0.zip`.
- Write the initial `Casks/pronto.rb` to the tap via `gh api`.
- Update the tap README: install instructions + "this file is CI-generated" note.
- Update pronto README (Install section gains the brew command) and RELEASE.md
  (document the tap-update step and the `HOMEBREW_TAP_TOKEN` secret).

## Error handling

- Missing secret → step skipped with warning, release unaffected.
- Tap push failure → job step fails (visible in Actions), manual fallback is
  re-running the step or pushing the rendered cask by hand.
- `uninstall quit:` is best-effort; brew proceeds if the app isn't running.

## Testing

- Bootstrap verified with a real `brew tap pacificsky/tap` +
  `brew install --cask pronto` (and `brew uninstall`) on this machine.
- `brew style` / `brew audit --cask` on the cask.
- The CI path is exercised on the next version tag (or a throwaway test tag).

## Out of scope

- Submitting Pronto to homebrew-cask core (third-party tap only for now).
- Sparkle/self-updating; `brew upgrade` is the update path.
- Migrating `Formula/cage.rb` or any other tap contents.
