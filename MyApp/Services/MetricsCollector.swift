import Foundation

/// Owns the stateful readers (which keep counters between samples) and
/// produces one `Sample` per call, off the main actor.
actor MetricsCollector {
    private let cpu = CPUReader()
    private let disks = DiskReader()
    private let network = NetworkReader()
    private var processes: Int?
    private var threads: Int?

    nonisolated let temperature = TemperatureReader()
    nonisolated let power = PowerReader()

    func start() {
        _ = cpu.read() // prime tick deltas
        temperature.start()
        disks.discover()
        disks.refreshVolumes()
        network.rediscover()
    }

    func sample(at t: TimeInterval) -> Sample {
        let reading = cpu.read()
        let power = power.read()
        return Sample(
            t: t,
            cpu: CPUSample(
                total: reading.total,
                user: reading.user,
                sys: reading.sys,
                cores: reading.cores,
                speedMHz: power?.cpuMHz,
                processes: processes,
                threads: threads,
                uptime: ProcessInfo.processInfo.systemUptime,
                load: CPUReader.loadAverage()
            ),
            mem: MemoryReader.read(),
            disks: disks.read(at: t),
            net: network.read(at: t),
            gpus: GPUReader.read(),
            power: power,
            temps: temperature.read(),
            thermalState: ProcessInfo.processInfo.thermalState
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
