# Availeth — Process Discovery for macOS

A native menu-bar app that observes how you work, shows where your time goes,
and automatically detects repeated cross-app workflows worth automating.

Built as the V1 of the Availeth task-mining concept, scoped to what is
technically and legally sound on modern macOS:

- **Nothing leaves this Mac.** Everything is stored in a local SQLite database.
  The only network call in the app is to a local Ollama daemon on
  `127.0.0.1:11434`, and only in Storyline mode (below).
- **The baseline needs no permission at all.** Capture starts from NSWorkspace
  app-activation events plus system idle detection: which app, for how long.
- **Everything richer is opt-in, defaults to off, and is permission-gated.**
  Three separate capabilities, each switchable in the Privacy tab:
  - **Window titles** (Accessibility) - turns "Excel" into "Purchase Orders.xlsx"
    and enables task-level grouping. This is the one that earns its keep.
  - **Keyboard and mouse activity** (Input Monitoring) - one switch. Records
    the *structure* of input: which shortcuts were used, Tab moves between
    fields, how many keys and clicks a task took, and the on-screen label of the
    field being typed into. It counts keystrokes; it never reads the characters
    typed. Password fields and excluded apps record nothing.
  - **Screen capture** (Screen Recording) - one switch. Each new screen is read
    by a local vision model (Ollama, `qwen2.5vl:7b`) which writes a description
    of the task, then the image is deleted immediately, and only the text is
    kept. The model is told to avoid specifics and a local scrub strips emails,
    amounts and ID numbers from what it returns.
- **The story layer works with or without a model.** Minute and task summaries
  are written by a small local text model (`qwen2.5:3b`, 1.9 GB) when one is
  installed, and from the captured signals alone when it is not. The Privacy
  tab's Local AI panel shows which models are present, their download sizes
  and the exact `ollama pull` commands.
- **Sample data appears twice only.** On the very first launch, so a new install
  is not an empty screen, and whenever it is switched on in the Privacy tab. It
  is a made-up finance department, is never mixed with real activity and is
  counted in no total.
- **Light and dark themes**, switched from the sidebar footer. Light is the
  default.
- **Automatic workflow mining**: activity is sessionized and repeated
  cross-app sequences (n-grams, greedy non-overlapping counting, subsumption)
  are surfaced with occurrence counts, median durations, a transparent
  automation score, and extrapolated hours/year and $ estimates.
- **Transparency by design**: menu-bar status shows what is being observed
  right now and the dashboard updates every second, including the window you
  are in now; pause/stop choices persist across launches; the first launch asks
  for all three permissions in turn and shows a banner until window titles can
  be read; local policy engine with per-app exclusions (password managers,
  Messages, WhatsApp, Signal, Telegram, Discord and System Settings excluded by
  default - exclusions are per app, so private browser windows are only
  covered by excluding the browser); deleting captured data checkpoints the WAL
  and vacuums the database so the bytes are actually gone.
- **Demo dataset**: ships with a deterministic two-week finance-department
  dataset so the dashboard demonstrates the product before live data exists.
  Toggle **Demo data / My activity** in the toolbar.

## Build & run

```bash
scripts/make_signing_identity.sh   # once per machine, before the first build
scripts/build_app.sh               # builds, signs, installs to /Applications
open -a /Applications/Availeth.app
```

## Packaging a release

```bash
scripts/package_release.sh                                  # self-signed, internal
IDENTITY="Developer ID Application: … (TEAMID)" \
NOTARY_PROFILE=availeth scripts/package_release.sh          # for customers
```

Produces `build/Availeth.dmg`: the app beside an Applications shortcut, the way
a consumer app arrives. The release build maps build paths out of the binary and
strips its symbol table, so it carries no developer paths and no type or function
names. Swift compiles to machine code, so the source itself is never in the
bundle.

The app icon is generated, not drawn by hand: `Resources/AppIcon.svg` is the
availeth.io mark on a macOS tile, and `scripts/make_icon.sh` renders it to
`Resources/AppIcon.icns` at every size (needs `brew install librsvg`). The
in-app mark loads that same icns, so the sidebar, the menu bar popover and the
Dock never drift apart.

Until it is signed with a Developer ID and notarized, macOS warns on first open
and `spctl --assess` reports "rejected". Create the notary profile once:

```bash
xcrun notarytool store-credentials availeth --apple-id you@availeth.io \
  --team-id TEAMID --password <app-specific-password>
```

Run `make_signing_identity.sh` first. Without that certificate the app is signed
ad-hoc, its code identity changes on every build, and macOS silently drops the
Accessibility, Screen Recording and Input Monitoring grants each time you
rebuild.

The dashboard opens on launch; the app then lives in the menu bar
(chart icon). Closing the dashboard keeps discovery running.

## Tests

```bash
swift test
```

97 tests covering the store and its enrichment columns, analytics aggregation,
title normalization, workflow units, the narrative synthesizer, the capture gate,
and the pattern miner (detection, subsumption, sessionization, demo-data
discovery).

## Layout

```
Sources/Availeth/
  AvailethApp.swift      app entry: dashboard window + menu bar extra
  AppState.swift         wiring, demo seeding, settings
  Capture/               capture engine, idle detection, AX reader, capture gate,
                         input monitor, screenshot capture, scene interpreter
  Data/                  models, SQLite store, demo data generator
  Analytics/             aggregations, workflow units, pattern miner, insights,
                         narrative synthesizer
  UI/                    SwiftUI dashboard (Overview, Tasks, Workflows, Story,
                         Logs, Privacy) + welcome sheet
scripts/make_signing_identity.sh  creates the stable self-signed identity (run once)
scripts/build_app.sh              builds, signs and installs Availeth.app
```

## How the story is written

Capture records windows, typing, fields and data movements. Every minute
gets one true line built from that record; the local model never writes a
minute. A job runs until it ends: an idle gap, the safety ceiling, or the
point where the apps in use turn over and the model, shown the job so far
and the minutes that follow, answers NEW rather than SAME. Only then does
the model write the job's account and title, from the whole record, and
its output is kept only if every name and number in it comes from that
record.

## Notes

- Self-signed for local use. Distribution needs a Developer ID certificate,
  Hardened Runtime, and notarization.
- The models are fetched from inside the app. Ollama itself (196 MB, MIT) is a
  one-off install the Privacy tab links to; the models are then pulled there with
  a progress bar. They are not in the download because the text model is 1.9 GB
  and the vision model 6.0 GB, and an app that costs six gigabytes before it
  shows anything does not get installed. Without either model, task stories are
  still built from the captured signals.
- Signed with a local self-signed identity, so Gatekeeper refuses it on any
  other Mac until it is signed with a Developer ID and notarized.
- Window-title capture degrades gracefully: without Accessibility, spans carry
  app names only.
- Estimates in the Workflows tab are heuristic and directional by design.
