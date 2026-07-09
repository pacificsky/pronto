# Machine watermark in the popup

**Date:** 2026-07-08
**Status:** Approved

## What

Render the La Marzocco cloud's color-accurate image of the selected device
(coffee machine or grinder) as a faded background watermark in the popup's
bottom-right — a personal touch showing *your* machine in *its* color.

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

- `.background(alignment: .bottomTrailing)` on the popup content: the image
  `scaledToFit`, ~110pt tall, tucked toward the bottom-right, opacity ~0.12
  (tuned by eye in light and dark mode), `allowsHitTesting(false)`.
- Loaded via `.task(id: controller.selectedMachine?.imageURL)` into local
  `@State` — switching machines in the picker swaps the watermark; no
  selected machine (not configured) means no watermark.
- Shown whenever a machine is selected, including "machine offline" — the
  image is identity, not status.

## Privacy

The URL encodes only model + color, never serial/email/account data. Sentry
network breadcrumbs are already disabled; the loader never logs.

## Testing

Existing scrubber tests unaffected; no new automated tests. Verification is
by eye: `./make-app.sh`, open the popup in light + dark mode, flip the machine
picker to the grinder, and confirm a relaunch loads from disk (no network
request).
