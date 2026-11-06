# Getting started

## Requirements

| | |
| --- | --- |
| macOS | 27.0 or later (`MACOSX_DEPLOYMENT_TARGET = 27.0`) |
| Xcode | 27 (the project uses object version 90) |
| Hardware | Apple silicon recommended. Intel works but has no IOReport data (see [data sources](data-sources.md#what-can-be-missing)) |
| Privileges | None. The app never asks for root or an admin password |

There are no third-party dependencies and no package manager step. Everything is Apple frameworks: SwiftUI, AppKit, IOKit, SystemConfiguration, Metal, Observation.

## Build in Xcode

1. Clone the repo and open the project:
   ```sh
   git clone https://github.com/Antoinenz/hwmonitor.git
   cd hwmonitor
   open "Hardware Monitor.xcodeproj"
   ```
2. Select the **Hardware Monitor** scheme and **My Mac** as the destination.
3. Press **⌘R**.

## Build from the command line

```sh
xcodebuild -project "Hardware Monitor.xcodeproj" \
           -scheme "Hardware Monitor" \
           -configuration Release \
           -derivedDataPath build \
           build
```

The app is at `build/Build/Products/Release/Hardware Monitor.app`. Copy it to `/Applications` if you want to keep it.

If you don't have a signing team configured, add `CODE_SIGNING_ALLOWED=NO` to run an unsigned local build.

## Signing and the bundle identifier

The project currently uses Xcode's placeholder bundle identifier (`devplaceholder.<unique>.Hardware-Monitor`) with automatic signing. Before sharing a build, set your own:

1. Select the project in Xcode, then the **Hardware Monitor** target.
2. Under **Signing & Capabilities**, choose your team and set a bundle identifier such as `com.yourname.HardwareMonitor`.

## Why the App Sandbox is off

`ENABLE_APP_SANDBOX` is `NO`. The sandbox blocks the IORegistry, SMC and IOReport reads that this app is built around, as well as running `ps` and `top` to see other users' processes. Consequences:

- The app can't be published on the Mac App Store.
- For distribution outside the store, sign with a Developer ID certificate and notarise it.

## First launch

On launch the app starts sampling immediately and adds a gauge to the menu bar. Closing the window leaves it running in the menu bar. Quit from the menu bar panel's power button or with **⌘Q**. If you turn the menu bar item off in Settings, closing the window quits the app instead.

## Troubleshooting

| Symptom | Cause and fix |
| --- | --- |
| Temperatures show `–` | The HID thermal sensors aren't available on this Mac or macOS version. Everything else keeps working |
| Power and CPU frequency are blank | IOReport has no channels on this machine (typically Intel). Expected |
| Network pane is empty | Only adapters with an address, plus VPN tunnels, are listed. Connect first |
| No icon in a Debug build | Make sure `ASSETCATALOG_COMPILER_APPICON_NAME` is `AppIcon` in both build configurations |
