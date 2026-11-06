# Data sources

Every value comes from the operating system. Nothing is estimated from a lookup table of chip specs, and nothing needs root. This page lists where each number comes from, in the order you'd debug it.

## Summary

| Metric | Source | Reader |
| --- | --- | --- |
| Per-core CPU utilisation | `host_processor_info(PROCESSOR_CPU_LOAD_INFO)` tick deltas | `CPUReader` |
| CPU cluster frequency and activity | IOReport, group `CPU Stats` / `CPU Complex Performance States` | `IOReportReader` |
| CPU / GPU / ANE / DRAM power | IOReport, group `Energy Model` | `IOReportReader` |
| GPU utilisation and frequency | IOReport, group `GPU Stats` / `GPU Performance States` | `IOReportReader` |
| GPU name, cores, Metal support, memory | IORegistry `IOAccelerator` and the Metal device | `GPUReader` |
| Memory usage breakdown | `host_statistics64(HOST_VM_INFO64)` | `MemoryReader` |
| Memory pressure | `sysctl kern.memorystatus_level` and `kern.memorystatus_vm_pressure_level` | `MemoryReader` |
| Swap | `sysctl vm.swapusage` | `MemoryReader` |
| Memory type and manufacturer | `system_profiler SPMemoryDataType -json` (once) | `MemoryReader` |
| Disk I/O and response time | IORegistry `IOBlockStorageDriver` statistics | `DiskReader` |
| Volumes and free space | Mounted filesystems, mapped to their physical disk through the IORegistry | `DiskReader` |
| Network throughput | 64-bit interface counters via `sysctl NET_RT_IFLIST2` | `NetworkReader` |
| Network adapters and addresses | SystemConfiguration and `getifaddrs` | `NetworkReader` |
| Temperatures | IOHIDEventSystem thermal sensors | `TemperatureReader` |
| System / adapter / battery power rails | SMC keys `PSTR`, `PDTR`, `PPBR` | `SMCReader` |
| Battery and charger | IORegistry `AppleSmartBattery`, plus IOPowerSources for health | `BatteryReader` |
| Process list (CPU %, memory) | `ps -Axo pid=,pcpu=,rss=,comm=` | `ProcessReader` |
| Process and thread counts | `top -l 1 -n 0 -s 0` | `CPUReader` |
| CPU model, cores, caches, virtualisation | `sysctl` (`machdep.cpu.brand_string`, `hw.*`, `kern.hv_support`) | `CPUReader` |
| Marketing model name | Device tree `IODeviceTree:/product` | `MetricsStore` |
| Host name | `SCDynamicStoreCopyComputerName` | `MetricsStore` |
| Thermal state | `ProcessInfo.thermalState` | `MetricsCollector` |

## Notes on individual sources

### CPU
Utilisation is a delta: each second the reader compares kernel tick counters to the previous read, which is why the first sample after launch is "priming" only. Cluster frequency comes from IOReport residency across DVFS states, weighted by the frequency table in the device tree (`voltage-states1-sram` for efficiency cores, `voltage-states5-sram` for performance cores). The headline CPU speed is the activity-weighted average across clusters.

### GPU
On Apple silicon, utilisation uses IOReport's frequency-weighted active residency, the same figure `powermetrics` and `macmon` report. That differs from the driver's `PerformanceStatistics` number, which is used on other Macs. Both **Active residency** and **Average frequency** are shown separately in the GPU pane.

### Memory
```
used       = app + wired + compressed
app        = anonymous − purgeable
cached     = external (file-backed) + purgeable
pressure % = 100 − kern.memorystatus_level
level      = kern.memorystatus_vm_pressure_level   (1 normal, 2 warning, 4 critical)
```
This follows Activity Monitor's grouping, so "Memory Used" should match what it shows.

### Power
CPU, GPU, Neural Engine and DRAM watts come from IOReport's energy counters, converted to power over the sample interval. The whole-system figure comes from the SMC `PSTR` key, falling back to the battery's reported system load. Adapter input is `PDTR`. Battery watts are voltage × current from `AppleSmartBattery`, which carries the sign (charging positive, discharging negative), because the SMC's own battery rail is unsigned. On a desktop Mac with no battery, the battery fields are simply absent.

### Temperatures
Sensors are found by name and averaged into groups:

| Group | Matches |
| --- | --- |
| Performance cores | `pACC` / `PACC` |
| Efficiency cores | `eACC` / `EACC` |
| CPU | performance + efficiency, falling back to `tdie`, then anything containing `CPU` |
| GPU, SoC, NAND, battery | names containing `GPU`, `SOC`/`PMGR`, `NAND`, `battery`/`gas gauge` |

Readings outside 0–150 °C are dropped, `tcal` calibration sensors are ignored, and power-gated `MTR` sensors that report a flat 30.0 °C placeholder at idle are skipped. Sensors are polled every 2 s on a background queue and the latest result is reused for 10 s before temperatures are reported as unavailable.

### Disks
Physical disks are enumerated from `IOBlockStorageDriver`. Each mounted volume is walked up the IORegistry (through any APFS container) to its physical disk, which is how "Disk 0 (Macintosh HD)" is named. Only an internal SSD is treated as having a NAND temperature sensor.

### Processes
`ps` is used instead of `proc_pidinfo` because it can see processes owned by other users without root. CPU % is of one core, as in Activity Monitor, so it can exceed 100. Process icons come from the owning `.app` bundle, so helper processes show their parent app's icon. `top` is the only unprivileged way to count threads across users, but it's costly, so it runs every 15 seconds.

## What can be missing

The app is built to degrade gracefully. Missing data shows as a dash.

| You see | Likely reason |
| --- | --- |
| No CPU/GPU/ANE/DRAM power, no cluster frequencies | No IOReport channels (typically Intel Macs), or the library changed in a new macOS release |
| No temperatures | HID thermal sensors unavailable or renamed |
| No system or adapter power | SMC keys not present on this model |
| No battery section | Desktop Mac, or no battery detected |
| No NAND temperature | Disk is external, or not an SSD |
| Fewer network adapters than expected | Only adapters with an address, plus VPN tunnels, are shown |

## Stability of the private interfaces

`libIOReport.dylib` and the IOHIDEventSystem client functions are not public API. They're loaded with `dlopen`/`dlsym` at runtime, so a missing symbol disables the feature instead of breaking the launch. Apple can change them in any release, so after each major macOS update check the Power and Temperature readings first.
