import Foundation
import Darwin

/// Per-core CPU utilisation from kernel tick deltas between successive reads.
nonisolated final class CPUReader {
    struct Reading {
        var total = 0.0
        var user = 0.0
        var sys = 0.0
        var cores: [Double] = []
    }

    private var previous: [[UInt32]] = []

    func read() -> Reading {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &cpuCount, &info, &infoCount) == KERN_SUCCESS,
              let info
        else { return Reading() }
        defer {
            vm_deallocate(
                mach_task_self_,
                vm_address_t(UInt(bitPattern: info)),
                vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride)
            )
        }

        let states = Int(CPU_STATE_MAX)
        var current: [[UInt32]] = []
        for cpu in 0..<Int(cpuCount) {
            current.append((0..<states).map { UInt32(bitPattern: info[cpu * states + $0]) })
        }
        let prev = previous
        previous = current
        guard prev.count == current.count else {
            return Reading(cores: Array(repeating: 0, count: current.count))
        }

        // Tick counters are 32-bit and wrap, so subtract with overflow.
        func delta(_ c: [UInt32], _ p: [UInt32], _ state: Int32) -> Double {
            Double(c[Int(state)] &- p[Int(state)])
        }

        var sumUser = 0.0, sumSys = 0.0, sumAll = 0.0
        var cores: [Double] = []
        for (c, p) in zip(current, prev) {
            let user = delta(c, p, CPU_STATE_USER) + delta(c, p, CPU_STATE_NICE)
            let sys = delta(c, p, CPU_STATE_SYSTEM)
            let idle = delta(c, p, CPU_STATE_IDLE)
            let all = user + sys + idle
            sumUser += user
            sumSys += sys
            sumAll += all
            cores.append(all > 0 ? (user + sys) / all * 100 : 0)
        }
        guard sumAll > 0 else { return Reading(cores: cores) }
        let user = sumUser / sumAll * 100
        let sys = sumSys / sumAll * 100
        return Reading(total: min(100, user + sys), user: user, sys: sys, cores: cores)
    }

    static func loadAverage() -> [Double] {
        var loads = [Double](repeating: 0, count: 3)
        let n = getloadavg(&loads, 3)
        return n == 3 ? loads : []
    }

    static func staticInfo() -> CPUStaticInfo {
        let levels = Sysctl.int("hw.nperflevels") ?? 1
        let p0L2 = Sysctl.int("hw.perflevel0.l2cachesize")
        let p1L2 = Sysctl.int("hw.perflevel1.l2cachesize")
        let freq = Sysctl.int("hw.cpufrequency")
        let hv = Sysctl.int("kern.hv_support")
        let logical = Sysctl.int("hw.logicalcpu") ?? ProcessInfo.processInfo.processorCount
        return CPUStaticInfo(
            model: Sysctl.string("machdep.cpu.brand_string") ?? "Processor",
            logical: logical,
            physical: Sysctl.int("hw.physicalcpu") ?? logical,
            performanceCores: levels > 1 ? Sysctl.int("hw.perflevel0.physicalcpu") : nil,
            efficiencyCores: levels > 1 ? Sysctl.int("hw.perflevel1.physicalcpu") : nil,
            sockets: Sysctl.int("hw.packages") ?? 1,
            l1iBytes: Sysctl.int("hw.perflevel0.l1icachesize") ?? Sysctl.int("hw.l1icachesize"),
            l1dBytes: Sysctl.int("hw.perflevel0.l1dcachesize") ?? Sysctl.int("hw.l1dcachesize"),
            l2Bytes: p0L2.map { $0 + (p1L2 ?? 0) } ?? Sysctl.int("hw.l2cachesize"),
            l3Bytes: Sysctl.int("hw.l3cachesize"),
            baseMHz: freq.map { Double($0) / 1e6 },
            virtualization: hv.map { $0 == 1 }
        )
    }

    /// Process and thread totals. `top` is the only unprivileged source that
    /// counts threads in processes owned by other users.
    static func processCounts() -> (processes: Int?, threads: Int?) {
        let out = Shell.run("/usr/bin/top", ["-l", "1", "-n", "0", "-s", "0"]).output
        guard let g = RX.groups(in: out, #"Processes:\s*(\d+)\s*total[^\n]*?(\d+)\s*threads"#), g.count == 2 else {
            return (nil, nil)
        }
        return (Int(g[0]), Int(g[1]))
    }
}
