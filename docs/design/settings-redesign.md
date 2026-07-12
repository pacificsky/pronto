# Handoff: Pronto — Settings Window Redesign

> **As shipped (2026-07-11):** the implementation deviates deliberately in a few
> places — the window is **480 pt wide** (not ~600; user preference), and per this
> spec's own "native control wins" rule the exact hex/pixel values below are
> realized with semantic system colors and native controls (`SettingsGroup` +
> `FullWidthLabeledContentStyle`/`FullWidthToggleStyle` in `SettingsGroup.swift`),
> so both appearances work. Help text sits inline under its row; the window
> auto-resizes per tab (content is intrinsic-height, no List-backed forms).

## Overview
A redesign of the **Pronto** espresso-machine control app's Settings window (macOS). It covers all three tabs — **Account**, **Machine**, **Privacy** — reorganized into a clean, macOS-native "grouped inset card" layout. The goal was to fix alignment problems in the original (orphaned/misaligned section headers, uneven vertical rhythm) by grouping related controls into labeled rounded cards with a consistent label-left / control-right structure.

## About the Design Files
The file in this bundle (`Machine Settings.dc.html`) is a **design reference created in HTML** — a prototype showing the intended look and behavior. It is **not production code to copy directly**. The `.dc.html` format is a self-contained preview artifact; ignore its wrapper mechanics.

The task is to **recreate this design in the app's existing environment**, using its established UI patterns and native controls. Pronto is a macOS desktop app, so the natural target is **native macOS (SwiftUI/AppKit)** using standard system controls (`Form`, `GroupBox`/grouped `List`, `Toggle`, `Stepper`, `Picker`, `Button`). If the app is built with a cross-platform framework instead (Electron/React, Tauri, etc.), recreate it with that stack's components while matching macOS visual conventions. Do **not** ship the HTML.

## Fidelity
**High-fidelity.** Final colors, typography, spacing, and control styling are specified below. Recreate pixel-accurately using the platform's native controls — but prefer real system controls over hand-built replicas (e.g. use a real macOS segmented control / switch / stepper rather than reproducing the exact pixels of the mock). Where a native control differs slightly from the mock, the native control wins.

## Window Shell (shared by all three tabs)
- **Window**: standard macOS window, ~600pt wide, white background, rounded corners, traffic-light controls top-left.
- **Title bar**: ~46px tall, centered bold title equal to the active tab name ("Account" / "Machine" / "Privacy"), hairline bottom border `rgba(0,0,0,0.07)`.
- **Toolbar tab bar**: three items centered — Account, Machine, Privacy — each an icon above a 12.5px label, stacked, ~86px wide, 9px vertical padding, 8px corner radius.
  - **Selected**: background `rgba(0,0,0,0.05)`, icon + label color `#007AFF`, label weight 600.
  - **Unselected**: color `#6e6e73`, label weight 500; hover background `rgba(0,0,0,0.04)`.
  - Icons: Account = person (circle head + shoulders arc); Machine = timer/dial (circle + hand + center dot); Privacy = a lock (rounded rect + shackle arc). In the real app use the existing SF Symbols the app already ships (the original used `person.circle`, a timer/dial glyph, and `hand.raised`). Match whatever the current app uses.
- **Content area**: light gray background `#f2f2f5`, padding ~22px top / 24px sides / 18px bottom.
- **Footer**: centered, 11.5px, color `#a1a1a6`, text `Pronto 0.7.0-8-g2b6487f-dirty` (this is a live version string — bind it to the real build version, don't hard-code).

## Grouped-card pattern (the core of the redesign)
Every settings tab is a vertical stack of **groups**. Each group is:
1. A **section header** — 13px, weight 600, color `#6e6e73`, 4px left padding, 8px bottom margin (20px top margin for groups after the first).
2. A **card** — white `#fff`, 10px radius, 1px border `rgba(0,0,0,0.06)`.

Inside a card, each **row** is: `display:flex; justify-content:space-between; align-items:center; padding:12–13px 16px`. Label on the left (15px, `#1d1d1f`); control on the right. Multiple rows in one card are separated by a 1px divider `rgba(0,0,0,0.06)` inset 16px from the left. Optional **help text** sits directly under a row's content: 12px, color `#8a8a8e`, ~4–5px top margin.

## Screens / Views

### 1. Account
Two groups.

**Group "Account"** — single card, one row:
- Row label **"Signed in as"** (top-aligned). Right side is a right-aligned two-line stack:
  - Line 1: `La Marzocco Account` — 15px, `#1d1d1f`.
  - Line 2: `aakash.kambuj@gmail.com` — 13px, `#8a8a8e` (bind to the signed-in user's email).
- Below, right-aligned: a push button **"Sign Out & Clear Credentials"** — background `#f0f0f2`, 1px border `#d2d2d7`, 7px radius, padding 7px 15px, 14px `#1d1d1f`; hover background `#e8e8ec`. (Use a standard macOS push button.)

**Group "Connection"** — single card, two rows separated by a divider:
- Row **"Status"** → status indicator: a 18px green (`#34C759`) filled circle with a white check, followed by **"Connected"** in `#2fa84f`, weight 500. (Reflect real connection state; show a red/gray variant when disconnected.)
- Row **"Machine"** → a popup/dropdown button reading `MR013437 — Linea Micra` with up/down chevrons — a native `Picker`/`NSPopUpButton` populated from paired machines.

### 2. Machine
Two groups.

**Group "Coffee Boiler"** — single card, one row:
- Row **"Target temperature"** → value `93.0 °C · 199 °F` (15px, `#1d1d1f`, tabular numbers) + a vertical **stepper** (native `Stepper`) to its right.
- Help text: `80–100 °C in 0.1° steps, as reported by the machine.`
- Behavior: adjustable 80–100 °C in 0.1° increments; °F is a derived read-only display (`F = C * 9/5 + 32`, rounded to whole degrees).

**Group "Steam Boiler"** — single card, two rows separated by a divider:
- Row **"Steam boiler"** → a **switch/toggle** (on). Native `Toggle`, on-tint green `#34C759`.
  - Help text: `Turn off when you're only pulling shots.`
- Row **"Steam level"** → a **segmented control** with options `1` `2` `3`, selection = `2`. Selected segment is filled `#007AFF` with white text; track `#e9e9eb`, 8px radius. (Use a native segmented control; the blue selected fill is the app accent — a standard segmented control's selection styling is acceptable too.)
  - Consider disabling / dimming this row when the steam boiler toggle is off.

### 3. Privacy
One group.

**Group "Privacy"** — single card, one row:
- Row **"Send anonymous crash reports"** → a **switch/toggle** (native `Toggle`, green on-tint).
- Help text: `Helps fix crashes. Never includes your La Marzocco account or machine details — only the crash itself. Off by default.`
- Note: copy says "Off by default"; the mock shows it on for illustration. Default the real setting to **off**.

## Interactions & Behavior
- **Tab switching**: clicking a toolbar item swaps the content and updates the title-bar text and selected-tab styling. Standard macOS `TabView`/toolbar behavior.
- **Stepper**: ± adjusts target temperature by 0.1 °C within 80–100 °C; °F display recomputes live.
- **Toggles**: standard switch animation; persist immediately.
- **Segmented control**: single-select; persist immediately.
- **Dropdown**: opens native menu of available machines.
- **Sign Out button**: clears stored credentials and returns to a signed-out state (confirm with existing app flow).
- **Hover states**: toolbar items and buttons lighten on hover (values above). Native controls use their built-in hover/press states.

## State Management
- `selectedTab`: `.account | .machine | .privacy`
- `account`: `{ displayName, email, isSignedIn }`
- `connection`: `{ status: connected|disconnected, currentMachineId, availableMachines[] }`
- `machine.coffeeBoiler`: `{ targetTempC: Double (80.0–100.0, 0.1 step) }` — °F derived
- `machine.steamBoiler`: `{ enabled: Bool, level: Int (1–3) }`
- `privacy`: `{ sendCrashReports: Bool (default false) }`
- `appVersion`: string for the footer, from the real build.

Values are read from / written to the machine and local prefs per the app's existing data layer. Temperature is "as reported by the machine," so treat the device as the source of truth and reflect updates.

## Design Tokens
Colors:
- Text primary `#1d1d1f`
- Text secondary / help `#8a8a8e`
- Section header `#6e6e73`
- Footer `#a1a1a6`
- Accent (selected, links) `#007AFF`
- Success circle `#34C759`, success text `#2fa84f`
- Card background `#ffffff`, content background `#f2f2f5`
- Card border `rgba(0,0,0,0.06)`, row divider `rgba(0,0,0,0.06)`, title/tab-bar hairline `rgba(0,0,0,0.07)`
- Control border `#d2d2d7`, button fill `#f0f0f2` (hover `#e8e8ec`), segmented track `#e9e9eb`
- Traffic lights: red `#ff5f57`, yellow `#febc2e`, green `#28c840`

Typography (system font — SF Pro / `-apple-system`):
- Row label / value: 15px, regular
- Section header: 13px, weight 600
- Tab label: 12.5px, weight 500 (600 selected)
- Help text: 12px
- Footer: 11.5px
- Tabular numerals for the temperature value.

Radii: cards 10px, buttons/controls 6–7px, tab items 8px, window 12px.
Spacing: content padding 22/24/18px; rows 12–13px vertical, 16px horizontal; group gap ~20px; dividers inset 16px left.

## Assets
- **No raster assets.** Toolbar icons are SF Symbols (person, timer/dial, lock/hand) — use the app's existing symbols. The mock draws simple placeholder SVGs; replace with native symbols.

## Files
- `Machine Settings.dc.html` — the HTML design reference containing all three tabs (Account, Machine, Privacy) rendered side by side. Open in a browser to inspect exact styling; use browser dev tools to read computed values.
