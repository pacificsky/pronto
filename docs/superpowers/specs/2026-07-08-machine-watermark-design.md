# Machine image in the popup

**Date:** 2026-07-08 (revised 2026-07-09 after visual iteration)
**Status:** Implemented

## What

Render the La Marzocco cloud's color-accurate image of the selected device
(coffee machine or grinder) in the popup — a personal touch showing *your*
machine in *its* color.

The cloud's `/things` response carries an `imageUrl` per device (e.g.
`https://lion.lamarzocco.io/img/thing-model/list/lineamicra/lineamicra-1-c-bianco.png`)
that encodes the exact model and color. Angstrom already decodes it as
`Machine.imageURL`, so this is purely a Pronto UI change — no Angstrom bump.

## Design

### `MachineImageCache` (new file)

A small fetch-once image loader with two cache tiers:

- **Memory:** `[URL: NSImage]` for the session.
- **Disk:** `Application Support/Pronto/images/<sha256(url)>.png`. Hit → load
  from disk, no network. Miss → one `URLSession` download, write, return.

Net effect: exactly one network request per unique image URL, ever. A new
machine or recolor changes the URL → one new fetch. All failures (no URL,
network down, non-2xx, corrupt data) degrade silently to `nil` — no error UI,
no logging of the URL.

Disk/network I/O runs off the main actor; only the `NSImage` construction and
memory cache live on `@MainActor`.

### `MenuContentView` changes

- The image is a **real layout element**, not a background watermark: an
  `HStack` pairs the content section (below the header, above the divider)
  with the render at ~0.9 opacity — 84pt tall beside the roomy controls
  layout (boiler rows + power button), 56pt beside compact notes (machine
  offline, status-only, errors).
- Loaded via `.task(id: controller.selectedMachine?.imageURL)` into local
  `@State` — switching machines in the picker swaps the image; no selected
  machine (not configured) means no image.
- Shown whenever a machine is selected, including "machine offline" — the
  image is identity, not status.

**Why not a watermark:** the original design (faded image behind the content,
bottom-right, ~0.12 opacity) was tried first and iterated twice. The popup is
too short and dense for it — in compact states the image either collided with
the header/Live badge or shrank to an unreadable smudge. Four placements were
rendered side-by-side with an offline SwiftUI `ImageRenderer` mock harness
(full-background watermark, dedicated space, header thumbnail,
watermark-only-when-tall); dedicated space at full opacity read best in every
state and was chosen by eye.

## Privacy

The URL encodes only model + color, never serial/email/account data. Sentry
network breadcrumbs are already disabled; the loader never logs.

## Testing

Existing scrubber tests unaffected; no new automated tests. Verification is
by eye: `./make-app.sh`, open the popup in light + dark mode, flip the machine
picker to the grinder, and confirm a relaunch loads from disk (no network
request).
