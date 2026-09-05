# Availeth — Process Discovery for macOS

A native menu-bar app that observes how you work, shows where your time goes,
and automatically detects repeated cross-app workflows worth automating.

Built as the V1 of the Availeth task-mining concept, scoped to what is
technically and legally sound on modern macOS:

- **No screenshots, no keystrokes, no uploads.** Capture uses permission-free
  NSWorkspace app-activation events plus system idle detection. Everything is
  stored in a local SQLite database.
- **Optional window titles** via the Accessibility permission — enables
  task-level grouping ("Purchase Orders.xlsx", "Vendor Bills — NetSuite").
- **Automatic workflow mining**: activity is sessionized and repeated
  cross-app sequences (n-grams, greedy non-overlapping counting, subsumption)
  are surfaced with occurrence counts, median durations, a transparent
  automation score, and extrapolated hours/year and $ estimates.
- **Transparency by design**: menu-bar status shows what is being observed
  right now; pause/stop choices persist across launches; local policy engine
  with per-app exclusions (common password managers and messaging apps excluded
  by default — exclusions are per app, so private browser windows are only
  covered by excluding the browser); deleting captured data checkpoints the WAL
  and vacuums the database so the bytes are actually gone.
- **Demo dataset**: ships with a deterministic two-week finance-department
  dataset so the dashboard demonstrates the product before live data exists.
  Toggle **Demo data / My activity** in the toolbar.

## Build & run

```bash
scripts/build_app.sh
open Availeth.app
```

The dashboard opens on launch; the app then lives in the menu bar
(chart icon). Closing the dashboard keeps discovery running.

## Tests

```bash
swift test
```

Covers the store, analytics aggregation, title normalization, and the
pattern miner (detection, subsumption, sessionization, demo-data discovery).

## Layout

```
Sources/Availeth/
  AvailethApp.swift      app entry: dashboard window + menu bar extra
  AppState.swift         wiring, demo seeding, settings
  Capture/               NSWorkspace/AX capture engine, idle detection
  Data/                  models, SQLite store, demo data generator
  Analytics/             aggregations + workflow pattern miner
  UI/                    SwiftUI dashboard (Overview, Tasks, Workflows, Privacy)
scripts/build_app.sh     builds Availeth.app (ad-hoc signed)
```

## Notes

- Ad-hoc signed for local use. Distribution needs a Developer ID certificate,
  Hardened Runtime, and notarization.
- Window-title capture degrades gracefully: without Accessibility, spans carry
  app names only.
- Estimates in the Workflows tab are heuristic and directional by design.
