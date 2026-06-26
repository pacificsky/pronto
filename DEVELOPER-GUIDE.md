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
official La Marzocco app. Pick your machine, and the **Turn On / Turn Off**
buttons appear. Status is polled every 30 seconds.

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
depends on (pinned in `Package.resolved`). Angstrom is the standalone extraction of
the `pylamarzocco` port and does the work:

1. Generate a per-install identity (`InstallationKey`: P-256 keypair + derived secret).
2. Register the public key: `POST /auth/init`.
3. Sign in with your account: `POST /auth/signin` → access/refresh tokens.
4. Every request carries a bespoke "request proof" + an ECDSA P-256 signature in
   `X-*` headers. This is verified byte-for-byte against the Python reference in
   Angstrom's own tests.

Angstrom does **no** persistence — Pronto owns that. Credentials and the
`Codable` `InstallationKey` are stored in the **macOS Keychain** (one consolidated
item, read once per launch and cached, keyed by the bundle ID); the `isRegistered`
flag lives in `UserDefaults`. Both are passed back into the client on launch.

## Source layout

| File | Responsibility |
|------|----------------|
| `ProntoApp.swift` | App entry, `MenuBarExtra` + `Settings` scenes, accessory activation |
| `MenuContentView.swift` | The menu-bar popover (status + power buttons) |
| `SettingsView.swift` | Credentials + machine selection window |
| `MachineController.swift` | View-model: connection state, polling, commands (drives Angstrom's client) |
| `Persistence.swift` | Keychain + UserDefaults storage (credentials, `InstallationKey`, `isRegistered`) |

The cloud REST client, auth crypto, and the `Machine`/`PowerState` models come from
the [Angstrom](https://github.com/pacificsky/angstrom) package.

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

- Power on/off + live status are implemented and the auth crypto is verified.
- End-to-end testing against the live cloud requires real account credentials
  (entered in Settings) — not exercised in the build pipeline.
- Steam boiler, temperature, schedules etc. are intentionally out of scope for v1.

## Credits

The La Marzocco cloud protocol and authentication were derived from
[`pylamarzocco`](https://github.com/zweckj/pylamarzocco) (the library behind the
Home Assistant integration). Pronto is an independent reimplementation in Swift.
