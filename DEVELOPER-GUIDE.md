# Developer Guide

Technical reference for building and understanding Pronto. For the user-facing
overview, see the [README](README.md). For publishing releases, see the
[Release Guide](RELEASE.md).

Pronto is a native macOS menu-bar app built with SwiftUI `MenuBarExtra` — no Dock
icon, just a cup in the menu bar — that turns a La Marzocco machine on and off.

## Requirements

- macOS 14+ (deployment target; uses `MenuBarExtra`, `SettingsLink`/`openSettings`).
- Swift toolchain / Xcode (developed on Swift 6.3 / macOS 26).

## Build & run

```sh
./make-app.sh            # builds dist/Pronto.app
open dist/Pronto.app
```

Then click the cup icon → **Settings…** and enter the email/password from the
official La Marzocco app. Pick your machine, and a single state-aware power
button appears (**Turn On** / **Turn Off**, depending on current state). Status
arrives **live over a websocket** — no polling — and a **Live** badge in the
popover header reflects the connection.

`swift build` works too, but `make-app.sh` assembles the proper `.app` bundle
(with `LSUIElement` so there's no Dock icon) and code-signs it.

## How control works

Current La Marzocco firmware no longer exposes the old local HTTP API (port 8081)
that earlier integrations used over the LAN. Today there are two transports:
**Bluetooth LE** (truly local) and the **cloud** (`lion.lamarzocco.io`). This app
uses the **cloud API** — the same path the Home Assistant integration uses as its
primary channel.

"On" / "Off" map to the machine's mode: `BrewingMode` (on) and `StandBy` (off),
sent via `POST /things/{serial}/command/CoffeeMachineChangeMode`.

The cloud protocol — auth and the machine client — lives in the
[**Angstrom**](https://github.com/pacificsky/angstrom) Swift package, which Pronto
depends on (pinned to **1.0.0** in `Package.resolved`). Angstrom is the standalone
extraction of the `pylamarzocco` port and does the work:

1. Generate a per-install identity (`InstallationKey`: P-256 keypair + derived secret).
2. Register the public key: `POST /auth/init`.
3. Sign in with your account: `POST /auth/signin` → access/refresh tokens.
4. Every request carries a bespoke "request proof" + an ECDSA P-256 signature in
   `X-*` headers. This is verified byte-for-byte against the Python reference in
   Angstrom's own tests.

Pronto consumes **two** products from the package:

- **`Angstrom`** — the stateless `LaMarzoccoCloudClient` (an `actor`): auth, the
  machine list, typed dashboard reads, commands, and the websocket transport.
- **`AngstromUI`** — `LaMarzoccoMachine` (`@MainActor @Observable`), a stateful
  device layer wrapping the client for a single machine. It holds the last-known
  `dashboard`, merges live websocket pushes into it, and applies optimistic updates
  after a command is accepted.

**Live status** arrives over a **STOMP websocket** (`wss://lion.lamarzocco.io/ws/connect`):
when the machine changes state — from this app, the official app, the physical
switch, or a schedule — the change is pushed and reflected within seconds. The
socket opens at app launch and auto-reconnects on drops; there is no polling.

**Power commands are confirmed two-tier:** with the socket connected, the command
awaits the machine's own confirmation frame (surfacing rejection/timeout as
`commandFailed` / `commandTimedOut`), while the dashboard also updates optimistically
so the UI feels instant.

> **Verifying the live socket:** it rides CloudFront (QUIC / `Network.framework`),
> so it does **not** show up in `lsof -iTCP` — that's a false negative, not a bug.
> Confirm it with the in-app **Live** badge, `nettop -p "$(pgrep -x Pronto)"` (watch
> the ~15s heartbeat tick `bytes_out`), or the `blog.pacificsky.pronto` log subsystem
> (`log stream --predicate 'subsystem == "blog.pacificsky.pronto"'`).

Angstrom does **no** persistence — Pronto owns that. Credentials and the
`Codable` `InstallationKey` are stored in the **macOS Keychain** (one consolidated
item, read once per launch and cached, keyed by the bundle ID); the `isRegistered`
flag lives in `UserDefaults`. Both are passed back into the client on launch.

## Source layout

| File | Responsibility |
|------|----------------|
| `ProntoApp.swift` | App entry, `MenuBarExtra` + `Settings` scenes, accessory activation; starts the connection at launch via the `AppDelegate` |
| `MenuContentView.swift` | The menu-bar popover (status + single state-aware power button + Live badge) |
| `SettingsView.swift` | Credentials + machine selection window |
| `MachineController.swift` | `@Observable` view-model: connection state and commands. Owns the shared `LaMarzoccoCloudClient` plus one `AngstromUI.LaMarzoccoMachine` (`device`) for the selected serial; `power` derives from its live `dashboard` |
| `Persistence.swift` | Keychain + UserDefaults storage (credentials, `InstallationKey`, `isRegistered`) |

The cloud client, auth crypto, websocket transport, and the `Machine`/`PowerState`/
`Dashboard` models come from the **`Angstrom`** product; the observable
`LaMarzoccoMachine` device layer comes from **`AngstromUI`** — both in the
[Angstrom](https://github.com/pacificsky/angstrom) package.

## Code signing

`make-app.sh` picks a signing identity via the `SIGN_IDENTITY` env var:

- **Default (local dev):** `SIGN_IDENTITY="Pronto Local Signing"`. The script
  creates this self-signed identity once (one-time macOS trust password prompt)
  and reuses it on every build. A stable signature keeps the Keychain ACL valid
  across rebuilds, so the app stops re-prompting for stored credentials.
- **Ad-hoc:** `SIGN_IDENTITY=-` forces a plain ad-hoc signature with no identity
  (used by CI). No prompts, but the signature's identity (a `cdhash`) changes
  every build.
- **Your own cert:** set `SIGN_IDENTITY="Developer ID Application: …"` to sign
  with a real certificate.

Releases are currently **ad-hoc** signed, which means other Macs hit Gatekeeper
on first launch (right-click → Open). Two tracked follow-ups:

- Inject the self-signed cert into CI for a stable identity — [issue #1](https://github.com/pacificsky/pronto/issues/1).
- Apple Developer ID signing + notarization for warning-free installs — [issue #2](https://github.com/pacificsky/pronto/issues/2).

## Status / limits

- Power on/off + live (websocket) status are implemented and the auth crypto is verified.
- End-to-end testing against the live cloud requires real account credentials
  (entered in Settings) — not exercised in the build pipeline.
- Grinders (e.g. Pico) are **status-only**: the cloud has no grinder power command,
  so Pronto shows their state but hides the power button (`Machine.supportsPower`).
- Steam boiler, temperature, schedules, etc. are intentionally out of scope —
  Angstrom 1.0 exposes these, but Pronto deliberately stays a power on/off + status
  app.

## Credits

The La Marzocco cloud protocol and authentication were derived from
[`pylamarzocco`](https://github.com/zweckj/pylamarzocco) (the library behind the
Home Assistant integration). Pronto is an independent reimplementation in Swift.
