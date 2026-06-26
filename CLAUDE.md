# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Pronto is a native macOS menu-bar app (SwiftUI `MenuBarExtra`, no Dock icon) that
turns a La Marzocco espresso machine (Linea Micra / Mini / GS3) on and off via the
La Marzocco **cloud** API. Bundle id `blog.pacificsky.pronto`. Released on GitHub as
an **unofficial** app (keep the trademark disclaimer in README intact).

## Build & run

```sh
./make-app.sh              # builds dist/Pronto.app (release), code-signs it
open dist/Pronto.app
swift build                # plain build; does NOT assemble the .app bundle
swift build -c release     # what make-app.sh wraps
```

`make-app.sh` is the real build entry point — `swift build` alone produces a bare
binary with no `Info.plist` (so no `LSUIElement`, no menu-bar behavior). There are
no tests and no linter configured; CI (`.github/workflows/ci.yml`) only runs
`swift build` on `macos-15` after selecting the newest installed Xcode (the SDK
must match the macOS 14 deployment target — some APIs like `openSettings` are 14.0).

## Code signing (important — affects Keychain prompts)

The signing identity controls whether stored credentials survive rebuilds:

- **Local dev (default):** `SIGN_IDENTITY="Pronto Local Signing"`. `make-app.sh`
  creates/reuses a self-signed identity (one-time macOS trust-password prompt on
  first build). A *stable* signature keeps the Keychain ACL valid across rebuilds,
  so the app stops re-prompting for saved credentials. Prefer this when iterating.
- **CI / release:** `SIGN_IDENTITY=- ./make-app.sh release` → ad-hoc signature
  (no prompts, but identity changes every build → users re-confirm Keychain once
  after each update).

## Releases

Push a `vMAJOR.MINOR.PATCH` tag; `.github/workflows/release.yml` builds, zips, and
publishes a GitHub Release. The version comes from the tag via
`APP_VERSION="<tag without v>"`. See RELEASE.md.

## Architecture

Single executable target, `Sources/Pronto`, `@main` is `ProntoApp`. UI is driven
by one `@MainActor` view-model.

- **`ProntoApp.swift`** — `MenuBarExtra` + `Settings` scenes; accessory activation.
- **`MachineController.swift`** — the brain. `ObservableObject` view-model owning
  `ConnectionState`, `PowerState`, machine list, and a 30s polling `Task`. It drives
  Angstrom's `LaMarzoccoCloudClient` (an `actor` — calls are `await`-ed). Power
  commands are **optimistic** (UI flips immediately, then confirms via a delayed
  `refreshStatus`). Transient refresh errors are swallowed to keep last-known state;
  only `LaMarzoccoError.authenticationFailed` downgrades the connection.
- **The cloud client + crypto live in the [Angstrom](https://github.com/pacificsky/angstrom)
  package** (a dependency, pinned in `Package.resolved`), not in this repo. It owns
  the REST flow (register → sign in → per-request-signed calls), the auth crypto
  (`InstallationKey`, P-256 proof — verified byte-for-byte against `pylamarzocco` in
  Angstrom's own tests), and the `Machine` / `PowerState` / `LaMarzoccoError` models.
  Don't reimplement any of this in Pronto.
- **`Persistence.swift`** — Pronto owns all persistence (Angstrom does none). Secrets
  (username, password, the `Codable` `InstallationKey`) are stored as a *single*
  consolidated Keychain item (service = bundle id), read once and cached, to minimize
  Keychain prompts. The `isRegistered` flag and other non-secret prefs live in
  UserDefaults. The stored key + flag are passed back into the client on launch.
- **`MenuContentView.swift` / `SettingsView.swift`** — the popover (status + power
  buttons) and the credentials/machine-selection window.

## Constraints & scope

- macOS 14+ deployment target. Developed on a newer Swift/Xcode; keep new API use
  guarded to 14.0 or CI will break.
- Cloud-only: the old local LAN HTTP API (port 8081) is gone on current firmware;
  Bluetooth LE is out of scope. Don't reintroduce a local-HTTP path.
- v1 scope is power on/off + live status only — steam boiler, temperature, and
  schedules are intentionally excluded.
- End-to-end testing needs real La Marzocco account credentials (entered in
  Settings); it is not exercised by the build pipeline.
