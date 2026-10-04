import Foundation
import Darwin

nonisolated enum MemoryReader {
    static func read() -> MemorySample {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        _ = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }

        let page = Double(getpagesize())
        let total = Double(ProcessInfo.processInfo.physicalMemory)
        // Same categories Activity Monitor uses.
        let anonymous = Double(stats.internal_page_count) * page
        let purgeable = Double(stats.purgeable_count) * page
        let app = max(0, anonymous - purgeable)
        let wired = Double(stats.wire_count) * page
        let compressed = Double(stats.compressor_page_count) * page
        let cached = Double(stats.external_page_count) * page + purgeable
        let used = min(total, app + wired + compressed)
        let free = max(0, total - used - cached)

        var swap = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.size
        sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0)

        let freeLevel = Sysctl.int("kern.memorystatus_level")
        return MemorySample(
            pressure: freeLevel.map { max(0, min(100, 100 - Double($0))) } ?? 0,
            level: Sysctl.int("kern.memorystatus_vm_pressure_level") ?? 1,
            total: total,
            used: used,
            app: app,
            wired: wired,
            compressed: compressed,
            cached: cached,
            free: free,
            swapUsed: Double(swap.xsu_used),
            swapTotal: Double(swap.xsu_total)
        )
    }

    /// Memory type and manufacturer from System Information (slow; call once, off the main actor).
    static func staticInfo() -> MemoryStaticInfo {
        var info = MemoryStaticInfo(total: Double(ProcessInfo.processInfo.physicalMemory))
        let out = Shell.run("/usr/sbin/system_profiler", ["SPMemoryDataType", "-json"]).output
        guard let data = out.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = root["SPMemoryDataType"] as? [[String: Any]]
        else { return info }

        var records = items
        for item in items {
            if let nested = item["_items"] as? [[String: Any]] { records += nested }
        }
        for record in records {
            if info.type == nil, let type = record["dimm_type"] as? String, type != "empty" {
                info.type = type
            }
            if info.manufacturer == nil, let maker = record["dimm_manufacturer"] as? String, maker != "empty" {
                info.manufacturer = maker
            }
        }
        return info
    }
}
