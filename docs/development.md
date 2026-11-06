# Development

## Repository layout

```
.
├── Hardware Monitor/                 App target (file-system synchronised: new files are picked up automatically)
│   ├── MyApp.swift                   @main: main Window, MenuBarExtra, Settings, View menu commands
│   ├── ContentView.swift             Split view, pane switching, compact mode, frozen badge
│   ├── Model/
│   │   ├── Metrics.swift             SystemInfo (static) and Sample (per-second) value types
│   │   ├── Format.swift              `Fmt`: units, percentages, durations, "nice" axis maxima
│   │   └── Preferences.swift         PrefKey, enums for settings, `Palette`, `MenuBarItem`
│   ├── Services/
│   │   ├── MetricsStore.swift        @Observable store: history, info, processes, freeze
│   │   ├── MetricsCollector.swift    Actor that owns readers and builds each Sample
│   │   ├── CPUReader.swift  GPUReader.swift  MemoryReader.swift
│   │   ├── DiskReader.swift  NetworkReader.swift  ProcessReader.swift
│   │   ├── BatteryReader.swift  SMCReader.swift  TemperatureReader.swift
│   │   ├── IOReportReader.swift      Apple silicon power and frequency counters
│   │   └── SystemUtil.swift          Sysctl, Shell, regex and IOKit helpers
│   ├── Views/
│   │   ├── Sidebar.swift             Pane enum, PerfSidebar, SeriesLibrary
│   │   ├── MenuBarPanel.swift        Status item label and popover panel
│   │   ├── SettingsView.swift
│   │   ├── Panes/                    Overview, CPU, Memory, GPU, Power, Disk, Network
│   │   └── Components/               TimeGraph, PerfPage, Stats, TopProcesses, WindowAccessor
│   └── Assets.xcassets/              AppIcon (generated) and AccentColor
├── Hardware Monitor.xcodeproj
├── Tools/make-icon.swift             Icon generator
└── docs/
```

## Conventions

- **Main actor by default.** The target sets `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`. Anything that runs off the main actor (readers, model types, formatters) is marked `nonisolated` explicitly. Don't touch a reader from the main actor in a way that blocks, because `ps`, `top` and `system_profiler` are slow.
- **Optional means unavailable.** Readers return `nil` rather than a fake zero when a metric doesn't exist on this Mac. Format it with `Fmt.*`, which turns `nil` into a dash.
- **Only data is coloured.** Use the `Palette` constants for series, and leave the chrome neutral.
- **Fail soft on private APIs.** Resolve symbols with `dlsym`, and make the reader report "nothing" if any is missing.
- **Release what you copy.** IOKit objects from `IORegistryEntry…` or `IOServiceGetMatchingServices` must be released. Use the `IOKitUtil` helpers, which do it for you.

## Adding a metric

Say you want to add a fan-speed reading.

1. **Model**: add a field to the relevant struct in `Model/Metrics.swift`, for example `fanRPM: Double?` on a new `FanSample`, and a `fans: FanSample?` on `Sample`.
2. **Reader**: add `Services/FanReader.swift`. If it keeps state between reads, hold it as a property on `MetricsCollector`. Pure reads can be static, like `BatteryReader.read()`.
3. **Collector**: call it in `MetricsCollector.sample(at:)` and include it in the returned `Sample`.
4. **Series**: if you want a graph, add a `GraphSeries` factory to `SeriesLibrary` in `Views/Sidebar.swift` so the sidebar, the pane and the menu bar panel can share it.
5. **View**: show it with `Metric`, `DetailRow` or a `GraphPanel` inside the relevant pane. Wrap the pane in `PerfPage` to get the toolbar and graph options for free.
6. **Menu bar** (optional): add a case to `MenuBarItem`, with a `title` and `caption`, a `template` string in `MenuBarCell` that is the widest value it can show, and a case in `MenuBarLabel.value(for:)`.
7. **Docs**: add it to [data sources](data-sources.md) and [features](features.md).

## Adding a pane

1. Add a case to `Pane` (with an id if it's per-device) and handle its `storageKey` in `Views/Sidebar.swift`.
2. Add a `SidebarRow` for it in `PerfSidebar`.
3. Add it to the `switch` in `ContentView.detail(for:)` and to `fallBackIfMissing`.

## Building and checking

```sh
xcodebuild -project "Hardware Monitor.xcodeproj" -scheme "Hardware Monitor" \
           -configuration Debug -derivedDataPath build build
```

There's no test target yet. Useful manual checks after a change:

- Run with the window hidden: CPU use should drop, because graphs pause when the window isn't visible.
- Press **Space** to confirm values freeze, then again to confirm a gap-free resume.
- Plug in or eject a drive and connect or disconnect a network adapter, and confirm the sidebar updates and a removed pane falls back to Overview.
- Switch **Appearance** between Light and Dark.
- Try compact mode, then exit it, and confirm the window returns to its previous size.

## The app icon

The icon is drawn in code so it can be tweaked without a design tool. To regenerate it:

```sh
swift Tools/make-icon.swift
```

This rewrites every size in `Hardware Monitor/Assets.xcassets/AppIcon.appiconset/` (16 to 512 pt at 1× and 2×, plus `Contents.json`) and a 1024 px preview at `docs/images/icon.png`.

The design is a dark squircle holding a chip with a gradient rim and a live graph. The gradient uses the same blue → purple → pink → orange as the app's data colours. To change it, edit the colour constants at the top of the script or the `draw(in:)` function, where the layout is in a 1024 × 1024 design space. Commit the regenerated PNGs.

## Releasing

1. Set your own bundle identifier and team (see [getting started](getting-started.md#signing-and-the-bundle-identifier)).
2. Bump `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in the target's build settings.
3. Archive with **Product → Archive**, sign with a Developer ID certificate and notarise. The app can't go on the Mac App Store, because it needs the App Sandbox off and uses private system interfaces.
4. After a major macOS release, verify power, frequency and temperature readings before publishing (see [data sources](data-sources.md#stability-of-the-private-interfaces)).
