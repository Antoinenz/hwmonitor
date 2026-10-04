import Foundation

/// Owns the stateful readers (which keep counters between samples) and
/// produces one `Sample` per call, off the main actor.
actor MetricsCollector {
    private let cpu = CPUReader()
    private let disks = DiskReader()
    private let network = NetworkReader()
    private var processes: Int?
    private var threads: Int?

    private let ioReport = IOReportReader()
    private let smc = SMCReader()

    nonisolated let temperature = TemperatureReader()

    func start() {
        _ = cpu.read() // prime tick deltas
        _ = ioReport.read(at: Date().timeIntervalSince1970)
        temperature.start()
        disks.discover()
        disks.refreshVolumes()
        network.rediscover()
    }

    func sample(at t: TimeInterval) -> Sample {
        let reading = cpu.read()
        let report = ioReport.read(at: t)

        let clusters = (report?.clusters ?? []).map {
            CPUClusterSample(name: $0.name, mhz: $0.mhz, active: $0.active)
        }
        let activity = clusters.reduce(0) { $0 + $1.active }
        let speed = activity > 0 ? clusters.reduce(0) { $0 + $1.mhz * $1.active } / activity : nil

        // Prefer IOReport's residency-based GPU figures (what powermetrics/macmon show).
        var gpus = GPUReader.read()
        if let report, let usage = report.gpuUsage, var first = gpus["0"] {
            first.util = usage
            first.active = report.gpuActive
            first.mhz = report.gpuMHz
            gpus["0"] = first
        }

        let battery = BatteryReader.read()
        let power = PowerSample(
            cpuW: report?.cpuW,
            gpuW: report?.gpuW,
            aneW: report?.aneW,
            dramW: report?.dramW,
            systemW: smc.number("PSTR") ?? battery?.systemLoad,
            adapterW: battery.map { $0.externalConnected } == false ? 0 : smc.number("PDTR"),
            // The SMC's battery rail is unsigned; voltage × current carries the direction.
            batteryW: battery?.batteryWatts ?? smc.number("PPBR")
        )

        return Sample(
            t: t,
            cpu: CPUSample(
                total: reading.total,
                user: reading.user,
                sys: reading.sys,
                cores: reading.cores,
                speedMHz: speed,
                clusters: clusters,
                processes: processes,
                threads: threads,
                uptime: ProcessInfo.processInfo.systemUptime,
                load: CPUReader.loadAverage()
            ),
            mem: MemoryReader.read(),
            disks: disks.read(at: t),
            net: network.read(at: t),
            gpus: gpus,
            power: power,
            temps: temperature.read(),
            thermalState: ProcessInfo.processInfo.thermalState,
            battery: battery
        )
    }

    func setProcessCounts(processes: Int?, threads: Int?) {
        if let processes { self.processes = processes }
        if let threads { self.threads = threads }
    }

    /// Cheap refresh of volume capacity and adapter addresses.
    func refresh() {
        disks.refreshVolumes()
        network.refresh()
    }

    /// Re-scan for added or removed disks and adapters.
    func rediscover() {
        disks.discover()
        disks.refreshVolumes()
        network.rediscover()
    }

    func inventory() -> (disks: [DiskInfo], networks: [NetworkInfo]) {
        // Unmounted disk images (e.g. simulator runtimes) are just noise.
        (disks.disks.filter { $0.type != "Disk image" || !$0.volumes.isEmpty }, network.interfaces)
    }
}
