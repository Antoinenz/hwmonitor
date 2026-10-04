import Foundation

/// Elevated metrics (CPU speed, power draw, GPU frequency, thermal pressure).
///
/// macOS only exposes these through `powermetrics`, which requires root. When
/// the user grants access we start a small root loop with the standard
/// administrator prompt. One long-running powermetrics process streams a
/// sample per second into a root-owned file under /var/run (restarted every
/// two minutes to bound the file size); the loop exits when this app quits.
nonisolated final class PowerReader: @unchecked Sendable {
    private let lock = NSLock()
    private var _state: ElevationState = .off
    private var startedAt = Date.distantPast
    private let outFile: String
    private var helperStarted = false
    private var lastReading: PowerSample?
    private var lastModified: Date?
    /// Output older than this is treated as stale (the last reading is reused).
    private static let freshness: TimeInterval = 4
    /// Silence longer than this is reported as an error.
    private static let stallTimeout: TimeInterval = 30
    private static let startupGrace: TimeInterval = 30

    init() {
        // Distinct from the old web app's helper file so the two can't collide.
        outFile = "/var/run/system-monitor-native-\(getuid()).txt"
    }

    var state: ElevationState { lock.withLock { _state } }

    private func setState(_ state: ElevationState) {
        lock.withLock { _state = state }
    }

    private var rootCommand: String {
        let pid = ProcessInfo.processInfo.processIdentifier
        #if arch(arm64)
        let samplers = "cpu_power,gpu_power,thermal"
        #else
        let samplers = "cpu_power,gpu_power,thermal,smc"
        #endif
        // Relaunching powermetrics every second is expensive, so stream 120
        // samples per run. The inner loop keeps the file readable and stops
        // powermetrics as soon as the app is gone. (No single quotes allowed.)
        let loop = [
            "while /bin/kill -0 \(pid) 2>/dev/null; do",
            "/bin/rm -f \(outFile);",
            "/usr/bin/powermetrics -i 1000 -n 120 --samplers \(samplers) -o \(outFile) > /dev/null 2>&1 & PM=$!;",
            "while /bin/kill -0 $PM 2>/dev/null; do",
            "/bin/chmod 644 \(outFile) 2>/dev/null;",
            "/bin/kill -0 \(pid) 2>/dev/null || /bin/kill $PM;",
            "/bin/sleep 1;",
            "done;",
            "done;",
            "/bin/rm -f \(outFile)",
        ].joined(separator: " ")
        return "/bin/sh -c '\(loop)' > /dev/null 2>&1 &"
    }

    private static func appleScriptString(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// Shows the administrator prompt and starts the helper. Blocks until the
    /// prompt is dismissed, so call it off the main actor.
    func requestElevation() {
        switch state {
        case .on, .starting: return
        default: break
        }
        let script = "do shell script \(Self.appleScriptString(rootCommand)) "
            + "with prompt \(Self.appleScriptString("System Monitor needs administrator access to read CPU speed, power usage and GPU frequency.")) "
            + "with administrator privileges"
        let result = Shell.run("/usr/bin/osascript", ["-e", script])
        if result.status != 0 {
            let message = result.error.trimmingCharacters(in: .whitespacesAndNewlines)
            if message.contains("-128") || message.lowercased().contains("cancel") { return }
            setState(.error(message.isEmpty ? "Could not start the privileged helper." : message))
            return
        }
        lock.withLock {
            _state = .starting
            startedAt = Date()
            helperStarted = true
        }
    }

    /// Reads the helper's latest output; called once per sample. Keeps polling
    /// after a stall so a helper that catches up flips back to `.on`.
    func read() -> PowerSample? {
        let (state, startedAt, started) = lock.withLock { (_state, self.startedAt, helperStarted) }
        guard started else { return nil }
        let sinceStart = Date().timeIntervalSince(startedAt)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: outFile),
              let modified = attributes[.modificationDate] as? Date
        else {
            if sinceStart > Self.startupGrace { setState(.error("The privileged helper did not start.")) }
            return nil
        }
        let age = Date().timeIntervalSince(modified)
        if age > Self.freshness {
            // powermetrics can lag well behind under heavy load; only report a
            // problem after a long silence, and keep polling so we recover.
            if age > Self.stallTimeout && (state == .on || sinceStart > Self.startupGrace) {
                setState(.error("The privileged helper stopped responding."))
            }
            return age <= Self.stallTimeout ? lock.withLock { lastReading } : nil
        }
        if modified == lastModified, let cached = lock.withLock({ lastReading }) {
            setState(.on)
            return cached
        }
        guard let text = latestSampleText() else { return nil }
        let reading = Self.parse(text)
        lock.withLock {
            lastReading = reading
            lastModified = modified
        }
        setState(.on)
        return reading
    }

    /// The newest complete sample from the end of the streaming output file.
    private func latestSampleText() -> String? {
        guard let handle = FileHandle(forReadingAtPath: outFile) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > 32_768 ? size - 32_768 : 0)
        guard let data = try? handle.readToEnd() else { return nil }
        let text = String(decoding: data, as: UTF8.self)
        let samples = text.components(separatedBy: "*** Sampled system activity").dropFirst()
        guard let last = samples.last else { return nil }
        // The final sample may still be being written; the thermal section comes last.
        if last.contains("pressure level") || samples.count < 2 { return last }
        return samples[samples.index(before: samples.endIndex - 1)]
    }

    static func parse(_ text: String) -> PowerSample {
        let milliwatts = { (pattern: String) -> Double? in
            RX.number(in: text, pattern, options: .anchorsMatchLines).map { $0 / 1000 }
        }

        // Average per-CPU frequency weighted by active residency.
        var frequencies: [String: Double] = [:]
        for g in RX.allGroups(in: text, #"CPU (\d+) frequency:\s*([\d.]+)\s*MHz"#) where g.count == 2 {
            frequencies[g[0]] = Double(g[1])
        }
        var weighted = 0.0, weight = 0.0
        for g in RX.allGroups(in: text, #"CPU (\d+) active residency:\s*([\d.]+)%"#) where g.count == 2 {
            if let f = frequencies[g[0]], let r = Double(g[1]) {
                weighted += f * r
                weight += r
            }
        }
        var cpuMHz: Double? = weight > 0 ? weighted / weight : nil
        if cpuMHz == nil {
            cpuMHz = RX.allGroups(in: text, #"Cluster HW active frequency:\s*([\d.]+)\s*MHz"#)
                .compactMap { $0.first.flatMap(Double.init) }.max()
        }
        if cpuMHz == nil {
            // Intel: "CPU Average frequency as fraction of nominal: 75.00% (1650.00 Mhz)"
            cpuMHz = RX.number(in: text, #"average frequency[^(]*\(([\d.]+)\s*Mhz\)"#, options: .caseInsensitive)
        }

        return PowerSample(
            cpuW: milliwatts(#"^CPU Power:\s*([\d.]+)\s*mW"#),
            gpuW: milliwatts(#"^GPU Power:\s*([\d.]+)\s*mW"#),
            aneW: milliwatts(#"^ANE Power:\s*([\d.]+)\s*mW"#),
            totalW: milliwatts(#"Combined Power[^:]*:\s*([\d.]+)\s*mW"#)
                ?? RX.number(in: text, #"package power[^:]*:\s*([\d.]+)\s*W"#, options: .caseInsensitive),
            gpuMHz: RX.number(in: text, #"GPU (?:HW )?active frequency:\s*([\d.]+)\s*MHz"#),
            cpuMHz: cpuMHz,
            thermal: RX.groups(in: text, #"Current pressure level:\s*(\w+)"#)?.first
        )
    }
}
