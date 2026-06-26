# Pronto

A native macOS menu-bar app to turn a **La Marzocco Linea Micra / Linea Mini**
(or GS3) espresso machine **on** and **off**, with a settings screen to connect
your account.

Built with SwiftUI `MenuBarExtra` — no Dock icon, just a cup in the menu bar.

> **Unofficial.** Pronto is not affiliated with, endorsed by, or sponsored by
> La Marzocco S.r.l. "La Marzocco", "Linea Micra", and "Linea Mini" are
> trademarks of their respective owner, used here only to describe compatibility.

## How control works

Current La Marzocco firmware no longer exposes the old local HTTP API (port 8081)
that earlier integrations used over the LAN. Today there are two transports:
**Bluetooth LE** (truly local) and the **cloud** (`lion.lamarzocco.io`). This app
uses the **cloud API** — the same path the Home Assistant integration uses as its
primary channel.

"On" / "Off" map to the machine's mode: `BrewingMode` (on) and `StandBy` (off),
sent via `POST /things/{serial}/command/CoffeeMachineChangeMode`.

Auth mirrors `pylamarzocco`'s `LaMarzoccoCloudClient`:
1. Generate a per-install identity (P-256 keypair + a derived 32-byte secret).
2. Register the public key: `POST /auth/init`.
3. Sign in with your account: `POST /auth/signin` → access/refresh tokens.
4. Every request carries a bespoke "request proof" + an ECDSA P-256 signature
   in `X-*` headers (see `LMCrypto.swift`). This port is verified byte-for-byte
   against the Python reference.

Credentials and the installation key are stored in the **macOS Keychain**.

## Build & run

```sh
./make-app.sh            # builds dist/Pronto.app
open dist/Pronto.app
```

Then click the cup icon → **Settings…** and enter the email/password from the
official La Marzocco app. Pick your machine, and the **Turn On / Turn Off**
buttons appear. Status is polled every 30 seconds.

Requirements: macOS 14+, Xcode/Swift toolchain (developed on Swift 6.3 / macOS 26).

## Source layout

| File | Responsibility |
|------|----------------|
| `ProntoApp.swift` | App entry, `MenuBarExtra` + `Settings` scenes, accessory activation |
| `MenuContentView.swift` | The menu-bar popover (status + power buttons) |
| `SettingsView.swift` | Credentials + machine selection window |
| `MachineController.swift` | View-model: connection state, polling, commands |
| `LMCloudClient.swift` | REST client: auth, list things, dashboard, set power |
| `LMCrypto.swift` | Installation key, request-proof, signed headers |
| `Persistence.swift` | Keychain + UserDefaults storage |

## Status / limits

- Power on/off + live status are implemented and the auth crypto is verified.
- End-to-end testing against the live cloud requires real account credentials
  (entered by you in Settings) — not exercised in the build pipeline.
- Steam boiler, temperature, schedules etc. are intentionally out of scope for v1.
