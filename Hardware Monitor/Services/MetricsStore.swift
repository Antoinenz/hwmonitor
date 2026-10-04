import AppKit
import Observation
import SystemConfiguration

/// The app's single source of truth: static system info plus the last hour of
/// one-second samples, collected on a wall-clock-aligned tick.
@Observable
final class MetricsStore {
    static let historyCapacity = 3600

    private(set) var info = SystemInfo()
    /// Collected samples; keeps growing while the display is frozen.
    private var liveHistory: [Sample] = []
    private var liveProcesses: [ProcessUsage] = []
    private var frozen: (history: [Sample], processes: [ProcessUsage], at: Date)?

    /// Samples to display: a snapshot while frozen, otherwise live.
    var history: [Sample] { frozen?.history ?? liveHistory }
    /// Every process with its CPU and memory use, refreshed every 3 seconds.
    var processes: [ProcessUsage] { frozen?.processes ?? liveProcesses }
    /// When the display was frozen, or nil while live.
    var frozenAt: Date? { frozen?.at }

    /// Freezes every graph and value at this moment (sampling continues), or resumes live display.
    func toggleFreeze() {
        if frozen == nil {
            frozen = (liveHistory, liveProcesses, Date())
        } else {
            frozen = nil
        }
    }
    /// True once disks, adapters and GPUs have been discovered, so panes can
    /// tell "still loading" apart from "device removed".
    private(set) var isReady = false
    @ObservationIgnored private var inventoryLoaded = false
    @ObservationIgnored private var gpusLoaded = false

    var latest: Sample? { history.last }

    @ObservationIgnored private let collector = MetricsCollector()
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []

    func start() {
        guard tasks.isEmpty else { return }

        let version = ProcessInfo.processInfo.operatingSystemVersion
        info.hostName = (SCDynamicStoreCopyComputerName(nil, nil) as String?)
            ?? ProcessInfo.processInfo.hostName.replacingOccurrences(of: ".local", with: "")
        info.osVersion = "macOS \(version.majorVersion).\(version.minorVersion)"
            + (version.patchVersion > 0 ? ".\(version.patchVersion)" : "")
        info.modelID = Sysctl.string("hw.model")
        info.cpu = CPUReader.staticInfo()
        info.displays = Self.currentDisplays()

        let collector = collector
        tasks.append(Task {
            await collector.start()
            await self.updateInventory()
            await self.runSampling()
        })
        tasks.append(Task.detached(priority: .utility) {
            let gpus = GPUReader.staticInfo()
            let memory = MemoryReader.staticInfo()
            await MainActor.run {
                self.info.gpus = gpus
                self.info.memory = memory
                self.gpusLoaded = true
                self.updateReadiness()
            }
        })
        tasks.append(Task.detached(priority: .utility) {
            var tick = 0
            while !Task.isCancelled {
                let processes = ProcessReader.read()
                // `top` is the only unprivileged thread counter but it's costly; run it rarely.
                let threads = tick % 5 == 0 ? CPUReader.processCounts().threads : nil
                await collector.setProcessCounts(processes: processes.isEmpty ? nil : processes.count, threads: threads)
                await MainActor.run { self.liveProcesses = processes }
                tick += 1
                try? await Task.sleep(for: .seconds(3))
            }
        })
        tasks.append(Task {
            var tick = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                tick += 1
                if tick % 6 == 0 {
                    await collector.rediscover()
                    self.info.displays = Self.currentDisplays()
                } else {
                    await collector.refresh()
                }
                await self.updateInventory()
            }
        })
    }

    private func runSampling() async {
        while !Task.isCancelled {
            // Target the next whole second strictly after the previous sample. If the
            // timer fires a little early we sleep again rather than taking a second
            // sample milliseconds later (which made per-core deltas flip 0 ↔ 100%).
            let last = liveHistory.last?.t ?? 0
            var target = max(last + 1, Date().timeIntervalSince1970.rounded(.up))
            while true {
                let wait = target - Date().timeIntervalSince1970
                if wait <= 0 { break }
                try? await Task.sleep(for: .seconds(wait), tolerance: .milliseconds(10))
                if Task.isCancelled { return }
            }
            // Running far behind (e.g. after sleep): realign to the current second.
            let now = Date().timeIntervalSince1970
            if now - target > 0.5 { target = now.rounded(.down) }
            let sample = await collector.sample(at: target)
            liveHistory.append(sample)
            if liveHistory.count > Self.historyCapacity {
                liveHistory.removeFirst(liveHistory.count - Self.historyCapacity)
            }
        }
    }

    private func updateInventory() async {
        let inventory = await collector.inventory()
        if inventory.disks != info.disks { info.disks = inventory.disks }
        if inventory.networks != info.networks { info.networks = inventory.networks }
        inventoryLoaded = true
        updateReadiness()
    }

    private func updateReadiness() {
        if !isReady && inventoryLoaded && gpusLoaded { isReady = true }
    }

    private static func currentDisplays() -> [DisplayInfo] {
        NSScreen.screens.map { screen in
            let scale = screen.backingScaleFactor
            let width = Int(screen.frame.width * scale)
            let height = Int(screen.frame.height * scale)
            return DisplayInfo(name: screen.localizedName, resolution: "\(width) × \(height)")
        }
    }
}
