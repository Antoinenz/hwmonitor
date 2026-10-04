import Foundation

nonisolated struct ProcessUsage: Identifiable, Equatable, Sendable {
    var id: Int32 { pid }
    var pid: Int32
    var name: String
    /// Executable path; used to find the owning app's icon.
    var path: String
    /// Percent of one core, like Activity Monitor (can exceed 100).
    var cpu: Double
    /// Resident memory in bytes.
    var memory: Double
}

/// Per-process CPU and memory for every process via `ps`, which (unlike
/// `proc_pidinfo`) can see processes owned by other users without root.
nonisolated enum ProcessReader {
    static func read() -> [ProcessUsage] {
        let out = Shell.run("/bin/ps", ["-Axo", "pid=,pcpu=,rss=,comm="]).output
        var result: [ProcessUsage] = []
        for line in out.split(separator: "\n") {
            let fields = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard fields.count == 4,
                  let pid = Int32(fields[0]),
                  let cpu = Double(fields[1]),
                  let rss = Double(fields[2])
            else { continue }
            let path = String(fields[3])
            let name = (path as NSString).lastPathComponent
            result.append(ProcessUsage(pid: pid, name: name.isEmpty ? path : name, path: path, cpu: cpu, memory: rss * 1024))
        }
        return result
    }
}
