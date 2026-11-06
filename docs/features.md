# Features

## Window layout

The main window is a sidebar plus a detail pane. Every sidebar row shows a live thumbnail graph and a one-line summary, so you can watch everything at once and open whichever subsystem you care about.

```
Sidebar                         Detail pane
┌───────────────────┐          ┌────────────────────────────────────┐
│ Overview          │          │  Graph of the selected metric      │
│ ─ System          │          │  Stat tiles (utilisation, speed…)  │
│   CPU             │          │  Detail rows (cores, cache, …)     │
│   Memory          │          │  Top processes                     │
│   GPU 0           │          └────────────────────────────────────┘
│   Power           │
│ ─ Storage         │
│   Disk 0 (…)      │
│ ─ Network         │
│   Wi-Fi           │
└───────────────────┘
```

Disks, network adapters and GPUs appear and disappear as hardware is attached or removed. If the pane you were viewing disappears (an unplugged drive, say), the app falls back to Overview.

## Panes

### Overview
A dashboard for the whole machine:
- **Hero card**: host name, model (for example "MacBook Air (M1, 2020)"), macOS version, uptime, process and thread counts, and a **status pill** that summarises health in one line: "Everything looks normal", or a warning such as thermal throttling likely, critical memory pressure, low battery, CPU running hot, or CPU fully loaded.
- **Gauges** for CPU, GPU, Memory and Temperature.
- **Power flow**: adapter input → system → battery, with a bar that splits consumption across CPU, GPU, Neural Engine and DRAM.
- **Thermals**: a chip for each available temperature sensor.
- **Throughput**: network send/receive and disk read/write.
- **Storage**: each mounted volume with free and total space.
- **Top processes**: the five busiest by CPU.

### CPU
- Utilisation (user time, with optional kernel time overlaid), speed, power, temperature, process and thread counts, uptime and load averages.
- Graph modes: **Overall Utilization**, **Logical Processors** (one graph per core), **Temperature**.
- On Apple silicon, each performance and efficiency cluster shows its own frequency and activity.
- Static details: model, core counts (performance and efficiency), sockets, caches, virtualisation support.
- A **Top processes** list.

### Memory
- Graph modes: **Memory Pressure** (green → yellow → red by height) or **Memory Used**.
- Breakdown into app, wired, compressed, cached and free memory, plus swap used.
- Memory type and manufacturer, read once from System Information.
- A **Top processes** list sorted by memory.

### GPU
Utilisation, active residency, average frequency, GPU and Neural Engine power, and temperature, plus name, core count, Metal version and dedicated memory (when it isn't shared with the system). On Apple silicon utilisation is frequency-weighted active residency, which matches `macmon` and `powermetrics`.

### Power
- Whole-system draw, adapter input and battery charge or discharge rate.
- Component power: CPU, GPU, Neural Engine, DRAM.
- Battery health, cycle count against design cycles, time to empty or full.
- Charger details: negotiated voltage and current, and the USB-C PD profiles the charger offers, with the active one marked "In use".

### Disk
Active time, read and write throughput, response time and temperature (internal SSD only). Also the disk model, type (SSD, HDD, disk image, removable), interconnect, location, and the volumes on it.

### Network
Send and receive throughput with peak values, plus adapter type (Wi-Fi, Ethernet, VPN), MAC address and IPv4/IPv6 addresses.

## Menu bar

The menu bar item is a single fixed-width image, so it never changes width as numbers change.

- **Readout**: choose any combination of CPU usage, GPU usage, memory pressure, CPU temperature, system power, battery, network throughput and disk activity in **Settings → Menu Bar**. Selecting nothing shows just a gauge icon.
- **Panel**: click the item for mini graphs of CPU, memory, GPU and the primary network adapter, with uptime and a button to open the main window.

## Compact mode and Keep on Top

- **Double-click** any sidebar row, or press **⌥⌘C**, to collapse the window to a small view of one pane. The sidebar hides and the window shrinks, keeping its top-left corner in place.
- **Keep on Top** (**⌥⌘T**, or the pin button in compact mode) floats the window above other apps.
- Showing the sidebar again, or choosing **Exit Compact Mode**, restores the previous window size.

## Freezing the display

Press **Space** to freeze every graph, value and process list at that instant. A pulsing badge shows it's frozen. Sampling continues in the background, so resuming jumps straight back to live data with nothing missing.

## Time range

**⌘1 / ⌘2 / ⌘3** switch the graph window between 1 minute, 5 minutes and 1 hour. The grid divides at 10 seconds, 1 minute and 10 minutes respectively. The app holds one hour of one-second samples (3,600).

## Settings

Open with **⌘,** or the gear in the menu bar panel.

| Setting | Options |
| --- | --- |
| Show in menu bar | On/off, plus which values to show |
| Appearance | Automatic, Light, Dark |
| Graph time range | 1 min, 5 min, 1 hour |

Your selected pane, graph modes, compact mode and keep-on-top state are remembered between launches.

## Colour language

Only data is coloured; the interface itself stays neutral.

| Colour | Meaning |
| --- | --- |
| Blue | CPU |
| Purple | Memory |
| Pink | GPU |
| Green | Disk |
| Orange | Network and temperature |
| Teal | Power |
