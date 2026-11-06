# Architecture

Hardware Monitor is a single-target SwiftUI app with no external dependencies. The design has one rule: **readers produce plain value-type samples off the main actor, and one observable store hands them to the views.**

```
                 ┌──────────────────────── Services/ ────────────────────────┐
 Hardware        │                                                            │
 ─────────       │  CPUReader      MemoryReader     DiskReader   NetworkReader│
 Mach, IOKit,    │  GPUReader      BatteryReader    SMCReader    IOReportReader
 SMC, IOReport,  │  TemperatureReader (own 2 s timer)    ProcessReader        │
 IOHID, sysctl   │            │                                               │
                 │            ▼                                               │
                 │     MetricsCollector (actor)  ── one Sample per second ──┐ │
                 └───────────────────────────────────────────────────────────┼─┘
                                                                             ▼
                              MetricsStore (@Observable)  ◄── history: [Sample] (≤ 3600)
                                       │                       info: SystemInfo
                                       │ .environment(store)   processes: [ProcessUsage]
                                       ▼
        ContentView ─ PerfSidebar ─ Panes/* ─ MenuBarPanel ─ MenuBarLabel ─ SettingsView
```

## Concurrency model

The target builds with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` and approachable concurrency. So everything is main-actor by default, and code that must run elsewhere opts out explicitly:

- Model types and pure helpers (`Sample`, `Fmt`, `PrefKey`, `Palette`, `GraphMath`) and all the low-level readers are marked **`nonisolated`**.
- **`MetricsCollector`** is an `actor`. It owns the stateful readers, which keep counters between samples (CPU ticks, network bytes, IOReport snapshots), so each reading is a delta since the previous one.
- **`MetricsStore`** is `@Observable` and lives on the main actor. Views read it through the SwiftUI environment.

## The sampling loop

`MetricsStore.start()` launches four tasks:

| Task | Cadence | Purpose |
| --- | --- | --- |
| Sampling | Every wall-clock second | Calls `collector.sample(at:)` and appends the result to `history` |
| Static info | Once, `.utility` priority | GPU details (Metal) and memory type/manufacturer (System Information is slow) |
| Processes | Every 3 s | `ps` for every process; `top` for the thread count on every 5th pass because it's costly |
| Inventory | Every 5 s; full rediscovery every 30 s | Detect added or removed disks, volumes and network adapters; refresh free space and addresses |

**Wall-clock alignment.** The sampler targets the next whole second strictly after the previous sample. If the timer fires early it sleeps again instead of sampling a few milliseconds later, which would otherwise make per-core deltas flip between 0% and 100%. If the process falls far behind (after sleep, say), it realigns to the current second instead of replaying missed ticks.

**History.** The store keeps the last `historyCapacity = 3600` samples, one hour at one per second. Nothing is persisted to disk.

**Readiness.** `isReady` flips to true once disks, adapters and GPUs have been discovered. Panes use it to tell "still loading" apart from "device removed" so a remembered disk that no longer exists falls back to Overview instead of showing an empty page.

## Freezing

`toggleFreeze()` snapshots `history` and `processes` into a `frozen` tuple. The public `history`, `processes` and `latest` return the snapshot while frozen and the live arrays otherwise. Sampling never stops; unfreezing just drops the snapshot, so the display jumps back to current data with no gap.

## Sample model

`Sample` (in `Model/Metrics.swift`) is one second of everything: CPU (total, user, sys, per-core, per-cluster), memory, disks and network keyed by BSD name, GPUs keyed by id, power, temperatures, thermal state and battery. Fields that may not exist on a given Mac are optional, and views render a dash for `nil` through the `Fmt` helpers instead of special-casing hardware.

`SystemInfo` holds slow-changing facts (host name, model, CPU layout, memory, disks, adapters, GPUs, displays).

## Views

```
MyApp
├── Window "main"           → ContentView
│     NavigationSplitView
│       sidebar:  PerfSidebar          (rows with SidebarRow + thumbnail graphs)
│       detail:   OverviewView / CPUView / MemoryView / GPUView /
│                 PowerView / DiskView / NetworkView
├── MenuBarExtra            → MenuBarPanel (popover) + MenuBarLabel (status item)
└── Settings                → SettingsView
```

- **`Pane`** (in `Sidebar.swift`; an enum with associated device ids) is the sidebar selection. Its `storageKey` is saved in `@AppStorage` so the selected pane survives relaunch.
- **`PerfPage`** is the shared scaffold for every pane: scrolling content, a toolbar with the time-range control, and a Graph Options menu that is also exposed as the graph's context menu.
- **`TimeGraph`** places samples by absolute time and redraws continuously, so data glides in from the right. `GraphSeries` describes one line, `GraphPanel` adds titles and axis labels, and `GraphMath` supplies auto-scaling. Auto-scaled graphs ease toward the new maximum rather than snapping.
- **`SeriesLibrary`** (also in `Sidebar.swift`) holds the reusable series definitions (CPU, memory, GPU, disk, network) so the sidebar thumbnails, the panes and the menu bar panel all draw the same data the same way.
- **`Stats.swift`** has the headline `Metric` tiles, `MetricStrip`, `DetailTable`/`DetailsGrid` and `UsageBar`.
- **`MenuBarLabel`** renders the chosen values with `ImageRenderer` into a single template `NSImage`, using fixed-width cells sized from the widest string each item can show. The status item therefore never resizes.
- **`WindowController`** (via `WindowAccessor`) resizes the `NSWindow` for compact mode, remembering and restoring the expanded frame, and toggles floating level for Keep on Top.
- **`WindowVisibilityReader`** reports whether the window is on screen; hidden windows pause graph redraws via the `graphsPaused` environment value.

## Preferences

All preferences are `@AppStorage` keys declared in `PrefKey`: graph range, CPU and memory graph modes, kernel-time overlay, appearance, selected pane, menu bar visibility and items, compact mode and keep-on-top. Enums such as `TimeRange`, `CPUGraphMode`, `MemoryGraphMode` and `Appearance` are `String`-backed so they store directly.

## Private and unusual APIs

Two data sources use symbols that aren't in the public SDK headers, so they are resolved at runtime with `dlopen`/`dlsym`:

- **IOReport** (`IOReportReader`): power, cluster frequency and residency on Apple silicon.
- **IOHIDEventSystem** (`TemperatureReader`): thermal sensors.

If a symbol is missing, the reader reports nothing and the UI shows dashes. The app degrades instead of crashing. These APIs may change between macOS releases, which is the main maintenance risk of the project. See [data sources](data-sources.md).
