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

1. Checks out the tagged commit on a `macos-14` runner.
2. Builds the app bundle with `SIGN_IDENTITY=- APP_VERSION="<tag without v>" ./make-app.sh release`
   (ad-hoc signed; the version from the tag is written into the bundle).
3. Zips it with `ditto -c -k --keepParent`.
4. Creates the GitHub Release with `gh release create` and an install-notes body.

## One-time setup (already done)

These only matter if the repo is recreated or settings drift:

- **Workflow committed** — `.github/workflows/release.yml` must be on the default branch.
- **Public repo** — macOS runner minutes are free for public repos. (Private repos
  bill macOS minutes at a higher rate.)
- **Actions can write releases** — the workflow declares `permissions: contents: write`.
  If a run fails creating the release with a 403, check
  *Settings → Actions → General → Workflow permissions* is set to **Read and write**.

## What people download

The released `.zip` is **ad-hoc signed, not notarized by Apple**. On first launch
of a downloaded copy, macOS Gatekeeper requires the user to **right-click → Open**
once (the release notes tell them this). Because each ad-hoc build has a different
code identity, users also get a one-time Keychain prompt for their saved
credentials after updating to a new version (they click "Always Allow").

To remove this friction in the future:

- Stable identity across releases (kills the post-update Keychain prompt) —
  [issue #1](https://github.com/pacificsky/pronto/issues/1).
- Developer ID signing + notarization (kills the Gatekeeper right-click entirely) —
  [issue #2](https://github.com/pacificsky/pronto/issues/2).

## Tips

- **Re-running a release:** delete the tag locally and remotely
  (`git tag -d v1.0.0 && git push origin :refs/tags/v1.0.0`), delete the GitHub
  Release if one was created, then re-tag and push.
- **Test the build locally first** without publishing:
  `SIGN_IDENTITY=- APP_VERSION=1.0.0 ./make-app.sh release` and check `dist/Pronto.app`.
- Keep `CHANGELOG`-worthy notes in your commit messages — `gh release create` can be
  switched to `--generate-notes` if you'd rather auto-build notes from history.
