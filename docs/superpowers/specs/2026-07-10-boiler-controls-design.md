# Boiler Controls — Design

**Date:** 2026-07-10
**Status:** Approved

## Goal

Extend Pronto beyond power on/off with three machine settings, matching the official
La Marzocco app:

1. Set the coffee (brew) boiler target temperature.
2. Set the steam boiler level (1/2/3).
3. Turn the steam boiler on/off (espresso-only sessions).

## Key finding

**No Angstrom changes are needed.** Angstrom 1.5.0 (already pinned) ships all three
commands on `AngstromUI.LaMarzoccoMachine`, each awaiting the machine's confirmation
frame and applying an optimistic dashboard update, exactly like `setPower`:

- `setCoffeeTargetTemperature(celsius:)`
- `setSteam(on:)`
- `setSteamTargetLevel(_: SteamLevel)` — model-gated to Linea Micra / Mini R via
  `requireModel`

Readable state already streams over the existing websocket:

- `dashboard.coffeeBoiler` → `targetTemperature`, `targetTemperatureMin/Max/Step`
- `dashboard.steamBoilerLevel` → `enabled`, `enabledSupported`, `targetLevel`,
  `targetLevelSupported`
- `dashboard.steamBoilerTemperature` → the GS3-family equivalent (temperature-based,
  no levels)

This is a Pronto-only UI + view-model feature.

## Decisions (user-approved)

| Question | Decision |
| --- | --- |
| Placement | New **Machine** tab in Settings; the popover stays untouched |
| Settings shape | Restructure `SettingsView` into macOS toolbar tabs: **Account**, **Machine**, **Privacy** |
| Temperature units | Control steps in **°C** (machine-native, clean increments) with a secondary **°F hint** readout |
| Apply timing | **Auto, debounced**: steam toggle + level send immediately; the temperature stepper debounces ~1 s after the last click and sends one command |

Options considered for placement (mockups: artifact "Pronto — Boiler Controls:
Placement Options"): (A) expandable rows in the popover, (B) always-visible popover
controls, (C) Settings tab. User chose C — keeps the daily popover surface clean.

## UI

### Settings restructure

`SettingsView` becomes a `TabView` (standard Settings toolbar style):

- **Account** — existing account / credentials section, connection status, machine
  picker. Content unchanged.
- **Machine** — new, in a new file `MachineSettingsView.swift`.
- **Privacy** — existing crash-reports toggle and caption.

The `Pronto <version>` footer remains visible beneath the tabs on all tabs. Window
width stays 420 pt.

### Machine tab

Shown when `connection == .connected` and a dashboard exists; otherwise a short
"connect first" note. When `isMachineOffline`, controls are replaced by the same
"machine offline" explanation the popover uses (no remote change is possible).
Grinders (no boiler widgets) show a status-only note.

Controls, each rendered only when its widget/capability is present:

- **Coffee boiler → Target temperature.** Stepper bounded by the machine-reported
  `min`/`max`, stepping by the machine-reported `step`. Value shown in °C with a °F
  equivalent hint (e.g. `94.0 °C · 201 °F`). Caption notes the machine-reported
  range.
- **Steam boiler → Enabled.** Toggle; shown when `enabledSupported` (from
  `steamBoilerLevel` or `steamBoilerTemperature`, whichever the machine reports).
  Caption: turn off when only pulling shots.
- **Steam boiler → Level.** Segmented picker 1/2/3; shown only when
  `steamBoilerLevel.targetLevelSupported` (Micra / Mini R). Disabled while the steam
  boiler is toggled off.

A small `ProgressView` appears beside a control while its command awaits
confirmation; an inline error label (same style as the popover's `actionError`)
appears under the controls on failure.

## Controller & data flow

New surface on `MachineController`, following the `setPower` pattern:

- **Reads** (computed off the live dashboard, so websocket pushes — including
  changes made from the official LM app — re-render the tab): brew-boiler target +
  range/step, steam enabled, steam level, and the capability flags above.
- **Writes**: three methods wrapping the `device` calls. Shared error handling with
  the power path: `authenticationFailed` downgrades `connection`; timeout/rejection
  set an inline machine-settings error string; `isMachineOffline` guarded in both
  UI and method.
- **Debounce (temperature)**: the controller keeps a cancel-and-restart `Task` — a
  new stepper value cancels the pending send, waits ~1 s, then issues one command.
  A `pendingBrewTarget: Double?` property is what the stepper displays while the
  debounce/confirmation is in flight, so clicks feel instant without lying about
  confirmed state. Cleared on completion (success or failure); on failure the
  control snaps back to the dashboard's true value.
- **Steam toggle / level**: sent immediately, one in-flight command at a time
  (subsequent clicks disabled while confirming — same `busy` discipline as power).

No new persistence: all values live on the machine/cloud, none in UserDefaults or
Keychain.

## Error handling

- `LaMarzoccoError.authenticationFailed` → `connection = .failed(…)` (existing
  behavior).
- `commandTimedOut` / `commandFailed(status:)` → inline error in the Machine tab,
  e.g. "Couldn't confirm the temperature change in time." / "The machine rejected
  the steam level change (status)."
- Machine offline → controls hidden behind the offline note; methods also guard
  (race between a push flipping `connected` and a click).
- Out-of-range temperatures are impossible by construction (stepper clamps to the
  machine-reported bounds).

## Testing

- **Unit:** extract the temperature logic (clamp to min/max, step rounding, °C→°F
  hint formatting) as a pure helper; add tests in `Tests/ProntoTests` (CI already
  runs `swift test`).
- **UI iteration:** ImageRenderer mock renders of the Machine tab states (normal,
  offline, grinder, level-unsupported) rather than blind rebuild-and-eyeball.
- **End-to-end (manual, real Micra):** change temp/level/steam in Pronto → verify
  in the official LM app; change them in the LM app → verify the tab updates live
  over the websocket. Verify the steam-off state survives a power cycle
  expectation-wise (whatever the machine reports is what we show).

## Docs to update

- `CLAUDE.md` — the "Constraints & scope" section currently says steam boiler and
  temperature are intentionally excluded; update to reflect the new scope (schedules
  remain excluded).
- `README.md` — feature list gains the three controls (keep the trademark
  disclaimer intact).

## Out of scope

- Schedules / auto on-off, steam **target temperature** for GS3-family machines
  (no such machine to test against; the toggle still works there), popover changes,
  any Angstrom changes.
