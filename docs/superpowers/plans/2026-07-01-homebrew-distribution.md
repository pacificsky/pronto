# Homebrew Distribution Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Install Pronto via `brew install --cask pacificsky/tap/pronto`, with the cask auto-updated by pronto's release workflow.

**Architecture:** A cask template (`packaging/pronto.rb.tmpl`) + render script live in the pronto repo as the single source of truth. The release workflow renders it with the new version + zip sha256 and pushes `Casks/pronto.rb` to `pacificsky/homebrew-tap` via the GitHub contents API. A one-time bootstrap publishes the cask for the already-released v0.6.0 using the local tap clone.

**Tech Stack:** Homebrew cask DSL, bash, GitHub Actions, `gh api`.

## Global Constraints

- Spec: `docs/superpowers/specs/2026-07-01-homebrew-distribution-design.md`.
- Pronto repo work happens on the existing `homebrew-distribution` branch; tap repo work happens in `/Users/aakash/src/homebrew-tap` and is pushed directly to its `main` (the tap's convention — see its log: "Update cage to v0.9.0").
- Bundle id `blog.pacificsky.pronto`; macOS 14 (Sonoma) minimum; release asset name `Pronto-v<version>.zip`.
- v0.6.0 zip sha256: `76b79ccf34f3af3ec57d6ba15a6c167a6a904744f5cf7ab806d733a73decd8a6`.
- Keep the "unofficial / not affiliated with La Marzocco" disclaimer in all user-facing copy.
- The CI tap-update step must be **skipped with a warning** when `HOMEBREW_TAP_TOKEN` is unset, and **fail loudly** on push errors.
- No tests exist for packaging; verification is `brew style` / `brew audit --cask` plus a real local install (Task 2) and the next tagged release (CI path).

---

### Task 1: Cask template + render script in pronto

**Files:**
- Create: `packaging/pronto.rb.tmpl`
- Create: `packaging/render-cask.sh` (executable)

**Interfaces:**
- Produces: `./packaging/render-cask.sh <version> <sha256>` → rendered cask on **stdout**. Placeholders `{{VERSION}}` / `{{SHA256}}` (used verbatim by Tasks 2 and 3).

- [ ] **Step 1: Write the template**

`packaging/pronto.rb.tmpl`:

```ruby
cask "pronto" do
  version "{{VERSION}}"
  sha256 "{{SHA256}}"

  url "https://github.com/pacificsky/pronto/releases/download/v#{version}/Pronto-v#{version}.zip"
  name "Pronto"
  desc "Menu-bar app to turn a La Marzocco espresso machine on and off"
  homepage "https://github.com/pacificsky/pronto"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: ">= :sonoma"

  app "Pronto.app"

  uninstall quit: "blog.pacificsky.pronto"

  zap trash: "~/Library/Preferences/blog.pacificsky.pronto.plist"

  caveats <<~EOS
    Your La Marzocco credentials are stored in the macOS Keychain (service
    "blog.pacificsky.pronto") and are not removed on uninstall; delete them
    with Keychain Access if you want them gone.

    Pronto is unofficial and not affiliated with or endorsed by La Marzocco S.r.l.
  EOS
end
```

- [ ] **Step 2: Write the render script**

`packaging/render-cask.sh`:

```bash
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
```

Then: `chmod +x packaging/render-cask.sh`

- [ ] **Step 3: Verify rendering**

Run:
```bash
./packaging/render-cask.sh 0.6.0 76b79ccf34f3af3ec57d6ba15a6c167a6a904744f5cf7ab806d733a73decd8a6 | grep -n 'version\|sha256'
./packaging/render-cask.sh 0.6.0 76b79ccf34f3af3ec57d6ba15a6c167a6a904744f5cf7ab806d733a73decd8a6 | grep -c '{{'
```
Expected: first command shows `version "0.6.0"` and the real sha256; second prints `0` (no unrendered placeholders; note `grep -c` exits 1 on zero matches — that exit code is the pass signal here, e.g. run as `... | grep -c '{{' || true`).

- [ ] **Step 4: Commit**

```bash
git add packaging/pronto.rb.tmpl packaging/render-cask.sh
git commit -m "Add Homebrew cask template + render script"
```

---

### Task 2: Bootstrap the tap with the v0.6.0 cask

**Files:**
- Create: `/Users/aakash/src/homebrew-tap/Casks/pronto.rb` (rendered, not hand-written)
- Modify: `/Users/aakash/src/homebrew-tap/README.md`

**Interfaces:**
- Consumes: `packaging/render-cask.sh` from Task 1.
- Produces: published cask `pacificsky/tap/pronto` (release workflow in Task 3 overwrites this same path).

- [ ] **Step 1: Render the cask into the tap clone**

```bash
cd /Users/aakash/src/homebrew-tap && git pull
mkdir -p Casks
/Users/aakash/src/pronto/packaging/render-cask.sh 0.6.0 \
  76b79ccf34f3af3ec57d6ba15a6c167a6a904744f5cf7ab806d733a73decd8a6 > Casks/pronto.rb
```

- [ ] **Step 2: Update the tap README**

Replace the "Available Formulae" section of `/Users/aakash/src/homebrew-tap/README.md` so the full file reads:

````markdown
# Homebrew Tap

Homebrew formulae and casks for [pacificsky](https://github.com/pacificsky) projects.

## Installation

```bash
brew tap pacificsky/tap
```

## Available Formulae

| Formula | Description |
|---------|-------------|
| [cage](https://github.com/pacificsky/cage) | Run coding agents safely in containers on macOS |

### cage

```bash
brew install cage
```

## Available Casks

| Cask | Description |
|------|-------------|
| [pronto](https://github.com/pacificsky/pronto) | Menu-bar app to turn a La Marzocco espresso machine on and off |

### pronto

```bash
brew install --cask pronto
```

> `Casks/pronto.rb` is generated by pronto's release workflow from
> [`packaging/pronto.rb.tmpl`](https://github.com/pacificsky/pronto/blob/main/packaging/pronto.rb.tmpl);
> edits here are overwritten on the next pronto release.
````

- [ ] **Step 3: Lint the cask**

```bash
brew tap pacificsky/tap 2>/dev/null || true   # no-op if already tapped
brew style /Users/aakash/src/homebrew-tap/Casks/pronto.rb
```
Expected: no offenses. (If the local tap directory differs from brew's tapped copy, that's fine — style checks the file directly. `brew audit --cask pacificsky/tap/pronto` can only run after the file is pushed; do it in Step 6.)

- [ ] **Step 4: Commit and push the tap**

```bash
cd /Users/aakash/src/homebrew-tap
git add Casks/pronto.rb README.md
git commit -m "Add pronto cask (v0.6.0)"
git push origin main
```

- [ ] **Step 5: Real install test**

Pronto is likely already installed manually at `/Applications/Pronto.app` and running; `brew install --cask` refuses to overwrite an unmanaged app. Migrate to the brew-managed copy (same signed bundle → Keychain credentials survive):

```bash
osascript -e 'quit app "Pronto"' 2>/dev/null || true
[ -d /Applications/Pronto.app ] && mv /Applications/Pronto.app "$HOME/.Trash/Pronto-premanual.app"
brew update
brew install --cask pacificsky/tap/pronto
open /Applications/Pronto.app
```
Expected: install succeeds ("🍺  pronto was successfully installed!"), app launches, menu-bar icon appears, still signed in (Keychain item untouched).

- [ ] **Step 6: Audit the published cask**

```bash
brew audit --cask pacificsky/tap/pronto
```
Expected: no errors (audit warnings that only apply to homebrew/cask core, e.g. about `livecheck` or token conventions, are acceptable — note them but don't block).

---

### Task 3: Auto-update step in release.yml

**Files:**
- Modify: `.github/workflows/release.yml` (append a step after "Publish GitHub Release", currently the last step, ending line 201)

**Interfaces:**
- Consumes: `packaging/render-cask.sh` (Task 1), `HOMEBREW_TAP_TOKEN` repo secret (already set), the `Pronto-${GITHUB_REF_NAME}.zip` built by the "Zip the .app" step.

- [ ] **Step 1: Append the workflow step**

Add at the end of `.github/workflows/release.yml`:

```yaml
      # Update the Homebrew tap (pacificsky/homebrew-tap) so `brew upgrade`
      # picks up this release. Skipped with a warning when HOMEBREW_TAP_TOKEN
      # (fine-grained PAT, contents:write on homebrew-tap only) isn't set; any
      # other failure fails the job loudly — the GitHub Release is already
      # published at this point, so nothing is lost, but a stale cask must be
      # visible. Casks/pronto.rb in the tap is fully generated from
      # packaging/pronto.rb.tmpl; the contents API needs the existing blob SHA
      # on update (omitting it is only valid for the first-ever create).
      - name: Update Homebrew cask
        env:
          GH_TOKEN: ${{ secrets.HOMEBREW_TAP_TOKEN }}
        run: |
          if [ -z "$GH_TOKEN" ]; then
            echo "::warning::HOMEBREW_TAP_TOKEN not set — skipping Homebrew cask update"
            exit 0
          fi
          VERSION="${GITHUB_REF_NAME#v}"
          SHA256="$(shasum -a 256 "Pronto-${GITHUB_REF_NAME}.zip" | cut -d' ' -f1)"
          ./packaging/render-cask.sh "$VERSION" "$SHA256" > "$RUNNER_TEMP/pronto.rb"
          EXISTING_SHA="$(gh api repos/pacificsky/homebrew-tap/contents/Casks/pronto.rb --jq .sha 2>/dev/null || true)"
          gh api --method PUT repos/pacificsky/homebrew-tap/contents/Casks/pronto.rb \
            -f message="Update pronto to v${VERSION}" \
            -f content="$(base64 -i "$RUNNER_TEMP/pronto.rb")" \
            ${EXISTING_SHA:+-f sha="$EXISTING_SHA"} \
            --jq '.commit.sha'
          echo "Tap updated for v${VERSION}"
```

- [ ] **Step 2: Validate the workflow file**

```bash
actionlint .github/workflows/release.yml 2>/dev/null || python3 -c "import yaml,sys; yaml.safe_load(open('.github/workflows/release.yml')); print('YAML OK')"
```
Expected: no errors / `YAML OK`.

- [ ] **Step 3: Dry-run the step's shell logic locally**

Simulate with the real v0.6.0 asset (read-only: uses `GET`, skips the `PUT`):

```bash
VERSION=0.6.0
SHA256="$(shasum -a 256 /private/tmp/claude-501/-Users-aakash-src-pronto/411c40e3-98c8-4c49-b99c-fe1418d964bb/scratchpad/Pronto-v0.6.0.zip | cut -d' ' -f1)"
./packaging/render-cask.sh "$VERSION" "$SHA256" | diff - /Users/aakash/src/homebrew-tap/Casks/pronto.rb
gh api repos/pacificsky/homebrew-tap/contents/Casks/pronto.rb --jq .sha
```
Expected: `diff` silent (rendered output identical to what Task 2 published); `gh api` prints a 40-char blob SHA (proves the EXISTING_SHA lookup works).

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/release.yml
git commit -m "Release workflow: push updated cask to homebrew-tap"
```

---

### Task 4: Documentation (pronto README + RELEASE.md)

**Files:**
- Modify: `README.md:17-28` (Install section)
- Modify: `RELEASE.md` ("What the workflow does" list around line 23, "One-time setup" around line 40, "What people download" around line 126)

- [ ] **Step 1: Add Homebrew to README Install section**

Insert a Homebrew option at the top of the existing `## Install` section (keeping the manual steps as the alternative):

````markdown
## Install

**Homebrew** (recommended — updates via `brew upgrade`):

```sh
brew install --cask pacificsky/tap/pronto
```

**Or manually:**

1. **[Download the latest version here](https://github.com/pacificsky/pronto/releases/latest)**
   (grab the file ending in `.zip`).
2. Open the downloaded file to unzip it, then drag **Pronto** into your
   **Applications** folder.
3. Double-click **Pronto** to open it. (It's signed with an Apple Developer ID and
   notarized by Apple, so it opens with no security warnings.)

Then click the coffee-cup icon in your menu bar → **Settings…** and sign in with
the **same email and password you use in the official La Marzocco app**.

That's it! Pick your machine and you'll see **Turn On** / **Turn Off** buttons.
````

(Note this folds old steps 3–4's post-install copy into one "Then …" paragraph shared by both install paths; keep surrounding sections untouched.)

- [ ] **Step 2: Document the tap update in RELEASE.md**

Three edits:
1. In "What the workflow does" (~line 23), append a bullet:
   ```markdown
   - Updates the Homebrew tap: renders `packaging/pronto.rb.tmpl` with the new
     version + zip sha256 and pushes `Casks/pronto.rb` to
     [pacificsky/homebrew-tap](https://github.com/pacificsky/homebrew-tap).
     Skipped (with a warning) if the `HOMEBREW_TAP_TOKEN` secret is unset; a
     push failure fails the job (the GitHub Release is already published by
     then — fix and re-run just this step, or render + push by hand).
   ```
2. In "One-time setup (already done)" (~line 40), append:
   ```markdown
   - `HOMEBREW_TAP_TOKEN` repo secret: fine-grained PAT scoped to
     `pacificsky/homebrew-tap` only, permission **Contents: Read and write**.
     Used by the "Update Homebrew cask" step.
   ```
3. In "What people download" (~line 126), add a line noting the Homebrew path:
   ```markdown
   Homebrew users get the exact same zip: the cask downloads the release asset
   from GitHub, so signature, notarization ticket, and Keychain identity are
   identical to a manual download.
   ```
   (Adjust placement to fit the section's existing prose; wording above is the content, not a literal diff.)

- [ ] **Step 3: Commit, push, open PR**

```bash
git add README.md RELEASE.md
git commit -m "Document Homebrew install + tap auto-update"
git push -u origin homebrew-distribution
gh pr create --title "Distribute Pronto via Homebrew (pacificsky/homebrew-tap)" --body "$(cat <<'EOF'
Adds Homebrew distribution per docs/superpowers/specs/2026-07-01-homebrew-distribution-design.md:

- `packaging/pronto.rb.tmpl` + `render-cask.sh` — single source of truth for the cask
- Release workflow pushes the rendered cask to pacificsky/homebrew-tap (HOMEBREW_TAP_TOKEN; skip-if-unset, fail-loud-on-error)
- README/RELEASE.md docs

Tap side (already live): Casks/pronto.rb bootstrapped at v0.6.0, verified with a real `brew install --cask pacificsky/tap/pronto`.

The CI path gets its first real exercise on the next version tag.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

---

## Verification (whole feature)

1. `brew install --cask pacificsky/tap/pronto` works on this machine (Task 2 Step 5).
2. `brew style` clean; `brew audit --cask` clean-or-core-only-warnings (Task 2 Steps 3/6).
3. Rendered template byte-identical to the published cask (Task 3 Step 3).
4. Full CI path: verified on the next `v*` tag — check the "Update Homebrew cask" step output and that the tap gets a "Update pronto to v…" commit.
