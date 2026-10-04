import AppKit
import Observation
import SystemConfiguration

/// The app's single source of truth: static system info plus the last hour of
/// one-second samples, collected on a wall-clock-aligned tick.
@Observable
final class MetricsStore {
    static let historyCapacity = 3600

    private(set) var info = SystemInfo()
    private(set) var history: [Sample] = []
    private(set) var elevation: ElevationState = .off
    private(set) var isRequestingElevation = false
    /// Every process with its CPU and memory use, refreshed every 3 seconds.
    private(set) var processes: [ProcessUsage] = []
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
                await MainActor.run { self.processes = processes }
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

    func requestElevation() {
        guard !isRequestingElevation else { return }
        isRequestingElevation = true
        let power = collector.power
        Task {
            await Task.detached { power.requestElevation() }.value
            isRequestingElevation = false
            elevation = power.state
        }
    }

    private func runSampling() async {
        while !Task.isCancelled {
            // Align each sample to the next wall-clock second.
            // Target the next whole second strictly after the previous sample. If the
            // timer fires a little early we sleep again rather than taking a second
            // sample milliseconds later (which made per-core deltas flip 0 ↔ 100%).
            let last = history.last?.t ?? 0
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
            history.append(sample)
            if history.count > Self.historyCapacity {
                history.removeFirst(history.count - Self.historyCapacity)
            }
            let state = collector.power.state
            if state != elevation { elevation = state }
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
