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
  creates/reuses a self-signed identity. A *stable* signature keeps the Keychain
  ACL valid across rebuilds, so the app stops re-prompting for saved credentials.
  Prefer this when iterating. First build prompts twice: a macOS trust-password
  dialog, then a codesign keychain-access prompt — click **"Always Allow"** on the
  latter or it re-prompts every build (it seeds the key's partition list).
- **CI / release:** `SIGN_IDENTITY=- ./make-app.sh release` → ad-hoc signature
  (no prompts, but identity changes every build → users re-confirm Keychain once
  after each update).

`ensure_identity()` in `make-app.sh` imports the key + cert as **separate PEM
items**, NOT a PKCS#12 bundle — macOS's `security import` rejects OpenSSL 3's
default p12 (SHA-256 MAC / AES-256 bags / empty password), which silently drops
the private key and leaves an orphan cert. Don't switch it back to PKCS#12.

## Releases

Push a `vMAJOR.MINOR.PATCH` tag; `.github/workflows/release.yml` builds, zips, and
publishes a GitHub Release. The version comes from the tag via
`APP_VERSION="<tag without v>"`. See RELEASE.md.

## Architecture

Single executable target, `Sources/Pronto`, `@main` is `ProntoApp`. UI is driven
by one `@MainActor` view-model.

- **`ProntoApp.swift`** — `MenuBarExtra` + `Settings` scenes; accessory activation.
  The menu-bar icon reflects the selected machine's power via *distinct glyphs*
  (filled cup = on, `powersleep` = standby, outline cup = unknown) — **not** color,
  which the menu bar templates away to monochrome.
- **`MachineController.swift`** — the brain. `@MainActor @Observable` view-model
  (the Observation framework, not `ObservableObject`) owning `ConnectionState`, the
  machine list, and the live device. It keeps a shared `LaMarzoccoCloudClient` (an
  `actor`) for auth + the machine list, and one `AngstromUI.LaMarzoccoMachine`
  (`device`) for the **selected** serial — rebuilt on selection change. `power` is a
  computed read of `device.powerState`, so SwiftUI tracks the nested `@Observable`
  and the menu bar updates live. Status comes from the **websocket**, not polling:
  `activateMachine()` does one `refreshDashboard()` (a dashboard must exist before
  `start()` or identity-less pushes are dropped) then `start()`, which self-heals on
  reconnect. Power commands go through `device.setPower`, which (with the socket up)
  **awaits the machine's confirmation frame** and throws `commandTimedOut` /
  `commandFailed` — no more hand-rolled confirmation poll. `pendingTarget` drives the
  in-flight spinner. Transient refresh errors are swallowed to keep last-known state;
  only `LaMarzoccoError.authenticationFailed` downgrades the connection. The
  connection is owned by `MachineController.shared` and brought up at **launch** from
  `AppDelegate.applicationDidFinishLaunching` — its lifetime is the app's, not the
  popover's.
- **Verifying the live socket.** It does **not** show up in `lsof -iTCP`: the cloud
  host is behind CloudFront and the connection rides QUIC / Network.framework, not a
  classic TCP socket FD — so `lsof` is a false negative, not a bug. To confirm it's
  live, use the in-app **Live** badge in the popover footer (`controller.isLive`),
  watch `nettop -p "$(pgrep -x Pronto)"` for the ~15s STOMP heartbeat ticking up
  `bytes_out`, or stream the logs: the client log handler + lifecycle events go to
  `os.Logger` under subsystem `blog.pacificsky.pronto`
  (`log stream --predicate 'subsystem == "blog.pacificsky.pronto"'`, or Console.app
  with *Include Info Messages* on).
- **The cloud client + crypto live in the [Angstrom](https://github.com/pacificsky/angstrom)
  package** (dependency `from: "1.0.0"`, pinned in `Package.resolved`), not in this
  repo. It owns the REST flow (register → sign in → per-request-signed calls), the
  auth crypto (`InstallationKey`, P-256 proof — verified byte-for-byte against
  `pylamarzocco` in Angstrom's own tests), and the `Machine` / `PowerState` /
  `DeviceType` / `LaMarzoccoError` models. Don't reimplement any of this in Pronto.
  Protocol-level changes (new endpoints, device types, status parsing) belong in
  Angstrom + a version bump, not here. Pronto consumes **two** products from the
  package: `Angstrom` (the stateless actor + models) and `AngstromUI` (the
  `@MainActor @Observable` `LaMarzoccoMachine` device layer that merges websocket
  pushes into a `dashboard` and applies optimistic command updates).
- **`Persistence.swift`** — Pronto owns all persistence (Angstrom does none). Secrets
  (username, password, the `Codable` `InstallationKey`) are stored as a *single*
  consolidated Keychain item (service = bundle id), read once and cached, to minimize
  Keychain prompts. The `isRegistered` flag and other non-secret prefs live in
  UserDefaults. The stored key + flag are passed back into the client on launch.
- **`MenuContentView.swift` / `SettingsView.swift`** — the popover (status + power
  buttons) and the credentials/machine-selection window. Devices where
  `Machine.supportsPower == false` (grinders) render **status-only**: the power
  buttons are replaced by a note and `setPower` is guarded. Views observe the
  controller via `@Environment(MachineController.self)` (Observation, not
  `@EnvironmentObject`). The live connection is brought up from `MenuContentView`'s
  `.task` (`bootstrap()`), so the menu-bar icon shows `.unknown` until the popover
  first appears; after that the websocket keeps it current.

## Constraints & scope

- macOS 14+ deployment target. Developed on a newer Swift/Xcode; keep new API use
  guarded to 14.0 or CI will break.
- Cloud-only: the old local LAN HTTP API (port 8081) is gone on current firmware;
  Bluetooth LE is out of scope. Don't reintroduce a local-HTTP path.
- Scope is power on/off + live status only — steam boiler, temperature, and
  schedules are intentionally excluded. Grinders (Pico/Swan) are **status-only**:
  La Marzocco's cloud has no grinder power command, so they show state but no
  controls.
- End-to-end testing needs real La Marzocco account credentials (entered in
  Settings); it is not exercised by the build pipeline.
