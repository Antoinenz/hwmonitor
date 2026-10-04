import Foundation
import IOKit

/// Apple silicon performance counters via the private IOReport library — the
/// same source `powermetrics` and macmon use, but readable without root.
///
/// Provides per-component power (CPU, GPU, ANE, DRAM), CPU cluster and GPU
/// frequency, and frequency-weighted utilisation. Functions are resolved at
/// runtime; on Macs without IOReport channels (Intel) `read()` returns nil.
nonisolated final class IOReportReader {
    struct Cluster: Sendable {
        var name: String
        /// Average active frequency in MHz.
        var mhz: Double
        /// Share of time spent in an active state, 0–100.
        var active: Double
    }

    struct Reading: Sendable {
        var cpuW: Double?
        var gpuW: Double?
        var aneW: Double?
        var dramW: Double?
        var clusters: [Cluster]
        var gpuMHz: Double?
        /// Frequency-weighted GPU utilisation (active residency × freq / max), 0–100.
        var gpuUsage: Double?
        /// Plain GPU active residency, 0–100.
        var gpuActive: Double?
    }

    private typealias CopyChannelsInGroup = @convention(c) (CFString?, CFString?, UInt64, UInt64, UInt64) -> Unmanaged<CFDictionary>?
    private typealias MergeChannels = @convention(c) (CFDictionary, CFDictionary, CFTypeRef?) -> Void
    private typealias CreateSubscription = @convention(c) (UnsafeRawPointer?, CFMutableDictionary, UnsafeMutablePointer<Unmanaged<CFMutableDictionary>?>, UInt64, CFTypeRef?) -> OpaquePointer?
    private typealias CreateSamples = @convention(c) (OpaquePointer, CFMutableDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
    private typealias CreateSamplesDelta = @convention(c) (CFDictionary, CFDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
    private typealias ChannelGetString = @convention(c) (CFDictionary) -> Unmanaged<CFString>?
    private typealias SimpleGetIntegerValue = @convention(c) (CFDictionary, Int32) -> Int64
    private typealias StateGetCount = @convention(c) (CFDictionary) -> Int32
    private typealias StateGetNameForIndex = @convention(c) (CFDictionary, Int32) -> Unmanaged<CFString>?
    private typealias StateGetResidency = @convention(c) (CFDictionary, Int32) -> Int64

    private struct API {
        var copyChannels: CopyChannelsInGroup
        var merge: MergeChannels
        var subscribe: CreateSubscription
        var samples: CreateSamples
        var delta: CreateSamplesDelta
        var group: ChannelGetString
        var subgroup: ChannelGetString
        var name: ChannelGetString
        var unit: ChannelGetString
        var integer: SimpleGetIntegerValue
        var stateCount: StateGetCount
        var stateName: StateGetNameForIndex
        var residency: StateGetResidency
    }

    private let api: API?
    private var subscription: OpaquePointer?
    private var channels: CFMutableDictionary?
    private var previous: (sample: CFDictionary, time: TimeInterval)?
    private var cpuFrequencies: [String: [Double]] = [:]
    private var gpuFrequencies: [Double] = []

    init() {
        api = Self.loadAPI()
        guard api != nil else { return }
        loadFrequencyTables()
        subscribe()
    }

    var isAvailable: Bool { subscription != nil }

    private static func loadAPI() -> API? {
        guard let handle = dlopen("/usr/lib/libIOReport.dylib", RTLD_NOW) else { return nil }
        func symbol<T>(_ name: String, as type: T.Type) -> T? {
            guard let pointer = dlsym(handle, name) else { return nil }
            return unsafeBitCast(pointer, to: type)
        }
        guard let copyChannels = symbol("IOReportCopyChannelsInGroup", as: CopyChannelsInGroup.self),
              let merge = symbol("IOReportMergeChannels", as: MergeChannels.self),
              let subscribe = symbol("IOReportCreateSubscription", as: CreateSubscription.self),
              let samples = symbol("IOReportCreateSamples", as: CreateSamples.self),
              let delta = symbol("IOReportCreateSamplesDelta", as: CreateSamplesDelta.self),
              let group = symbol("IOReportChannelGetGroup", as: ChannelGetString.self),
              let subgroup = symbol("IOReportChannelGetSubGroup", as: ChannelGetString.self),
              let name = symbol("IOReportChannelGetChannelName", as: ChannelGetString.self),
              let unit = symbol("IOReportChannelGetUnitLabel", as: ChannelGetString.self),
              let integer = symbol("IOReportSimpleGetIntegerValue", as: SimpleGetIntegerValue.self),
              let stateCount = symbol("IOReportStateGetCount", as: StateGetCount.self),
              let stateName = symbol("IOReportStateGetNameForIndex", as: StateGetNameForIndex.self),
              let residency = symbol("IOReportStateGetResidency", as: StateGetResidency.self)
        else { return nil }
        return API(copyChannels: copyChannels, merge: merge, subscribe: subscribe, samples: samples, delta: delta,
                   group: group, subgroup: subgroup, name: name, unit: unit, integer: integer,
                   stateCount: stateCount, stateName: stateName, residency: residency)
    }

    private func subscribe() {
        guard let api else { return }
        let groups: [(String, String?)] = [
            ("Energy Model", nil),
            ("CPU Stats", "CPU Complex Performance States"),
            ("GPU Stats", "GPU Performance States"),
        ]
        var merged: CFDictionary?
        for (group, subgroup) in groups {
            guard let dict = api.copyChannels(group as CFString, subgroup as CFString?, 0, 0, 0)?.takeRetainedValue() else { continue }
            if let merged { api.merge(merged, dict, nil) } else { merged = dict }
        }
        guard let merged,
              let mutable = CFDictionaryCreateMutableCopy(kCFAllocatorDefault, CFDictionaryGetCount(merged), merged)
        else { return }
        var subscribed: Unmanaged<CFMutableDictionary>?
        guard let sub = api.subscribe(nil, mutable, &subscribed, 0, nil) else { return }
        subscribed?.release()
        subscription = sub
        channels = mutable
    }

    /// DVFS tables (MHz per performance state) from the power manager node.
    private func loadFrequencyTables() {
        IOKitUtil.forEachService("AppleARMIODevice") { entry in
            var nameBuffer = [CChar](repeating: 0, count: 128)
            IORegistryEntryGetName(entry, &nameBuffer)
            guard cString(nameBuffer) == "pmgr" else { return }
            func table(_ key: String) -> [Double] {
                guard let data = IOKitUtil.property(entry, key) as? Data, data.count >= 8 else { return [] }
                let raw: [UInt32] = data.withUnsafeBytes { bytes in
                    stride(from: 0, to: data.count - 7, by: 8).map { bytes.loadUnaligned(fromByteOffset: $0, as: UInt32.self) }
                }
                // Older chips store Hz, M4 and later kHz.
                let divisor = (raw.max() ?? 0) > 100_000_000 ? 1_000_000.0 : 1_000.0
                return raw.map { Double($0) / divisor }
            }
            cpuFrequencies["ECPU"] = table("voltage-states1-sram")
            cpuFrequencies["PCPU"] = table("voltage-states5-sram")
            gpuFrequencies = table("voltage-states9").filter { $0 > 0 }
        }
    }

    func read(at time: TimeInterval) -> Reading? {
        guard let api, let subscription, let channels,
              let sample = api.samples(subscription, channels, nil)?.takeRetainedValue()
        else { return nil }
        defer { previous = (sample, time) }
        guard let previous, time > previous.time,
              let delta = api.delta(previous.sample, sample, nil)?.takeRetainedValue(),
              let items = (delta as NSDictionary)["IOReportChannels"] as? [NSDictionary]
        else { return nil }
        let dt = time - previous.time

        var cpuW = 0.0, gpuW = 0.0, aneW = 0.0, dramW = 0.0
        var sawEnergy = false
        var clusters: [Cluster] = []
        var gpuMHz: Double?, gpuUsage: Double?, gpuActive: Double?

        for item in items {
            let channel = item as CFDictionary
            let group = api.group(channel)?.takeUnretainedValue() as String? ?? ""
            let name = api.name(channel)?.takeUnretainedValue() as String? ?? ""

            switch group {
            case "Energy Model":
                let unit = api.unit(channel)?.takeUnretainedValue() as String? ?? ""
                let divisor: Double
                switch unit.trimmingCharacters(in: .whitespaces) {
                case "mJ": divisor = 1e3
                case "uJ", "µJ": divisor = 1e6
                case "nJ": divisor = 1e9
                default: continue
                }
                let watts = Double(api.integer(channel, 0)) / divisor / dt
                sawEnergy = true
                if name == "GPU Energy" { gpuW += watts }
                else if name.hasSuffix("CPU Energy") { cpuW += watts }
                else if name.hasPrefix("ANE") { aneW += watts }
                else if name.hasPrefix("DRAM") { dramW += watts }

            case "CPU Stats":
                // Cluster channels: ECPU / PCPU (M1) or ECPU0, PCPU0, PCPU1… (Pro/Max/later).
                guard name.hasPrefix("ECPU") || name.hasPrefix("PCPU") else { continue }
                let table = cpuFrequencies[String(name.prefix(4))] ?? []
                if let result = frequency(channel, api: api, table: table) {
                    clusters.append(Cluster(name: name, mhz: result.mhz, active: result.active))
                }

            case "GPU Stats":
                guard name == "GPUPH", let result = frequency(channel, api: api, table: gpuFrequencies) else { continue }
                gpuMHz = result.mhz
                gpuActive = result.active
                gpuUsage = result.weighted

            default:
                continue
            }
        }

        return Reading(
            cpuW: sawEnergy ? cpuW : nil,
            gpuW: sawEnergy ? gpuW : nil,
            aneW: sawEnergy ? aneW : nil,
            dramW: sawEnergy ? dramW : nil,
            clusters: clusters.sorted { $0.name < $1.name },
            gpuMHz: gpuMHz,
            gpuUsage: gpuUsage,
            gpuActive: gpuActive
        )
    }

    /// Average active frequency from per-state residency, macmon-style: idle
    /// states (IDLE/DOWN/OFF) come first; active states map onto the DVFS table.
    private func frequency(_ channel: CFDictionary, api: API, table: [Double]) -> (mhz: Double, active: Double, weighted: Double)? {
        let count = Int(api.stateCount(channel))
        guard count > 0 else { return nil }
        var states: [(name: String, residency: Double)] = []
        for i in 0..<count {
            let name = api.stateName(channel, Int32(i))?.takeUnretainedValue() as String? ?? ""
            states.append((name, Double(api.residency(channel, Int32(i)))))
        }
        guard let offset = states.firstIndex(where: { !["IDLE", "DOWN", "OFF"].contains($0.name) }) else { return nil }
        let total = states.reduce(0) { $0 + $1.residency }
        let active = states[offset...].reduce(0) { $0 + $1.residency }
        guard total > 0 else { return nil }

        var mhz = 0.0
        if active > 0 && !table.isEmpty {
            for (i, freq) in table.enumerated() where offset + i < states.count {
                mhz += states[offset + i].residency / active * freq
            }
        }
        let ratio = active / total
        let maxFreq = table.last ?? 0
        let minFreq = table.first ?? 0
        let weighted = maxFreq > 0 ? max(mhz, minFreq) * ratio / maxFreq * 100 : ratio * 100
        return (mhz, ratio * 100, min(100, weighted))
    }
}
