import Foundation

/// Display formatting shared by every pane. Memory uses binary units (like
/// Activity Monitor); storage and transfer rates use decimal units.
nonisolated enum Fmt {
    static let dash = "—"
    private static let units = ["B", "KB", "MB", "GB", "TB", "PB"]

    static func bytes(_ bytes: Double, base: Double = 1024, digits: Int = 1) -> String {
        guard bytes.isFinite, bytes > 0 else { return "0 B" }
        var value = bytes
        var i = 0
        while value >= base && i < units.count - 1 {
            value /= base
            i += 1
        }
        let d = (i == 0 || value >= 100) ? 0 : digits
        return "\(fixed(value, d)) \(units[i])"
    }

    /// Bytes-per-second transfer rate, e.g. "0 KB/s", "12.4 MB/s".
    static func rate(_ bytesPerSec: Double?) -> String {
        guard let bytesPerSec else { return dash }
        guard bytesPerSec.isFinite, bytesPerSec > 0 else { return "0 KB/s" }
        if bytesPerSec < 1000 { return "\(fixed(bytesPerSec / 1000, 1)) KB/s" }
        return "\(bytes(bytesPerSec, base: 1000))/s"
    }

    /// Network throughput in bits per second from a bytes-per-second value.
    static func bits(_ bytesPerSec: Double?) -> String {
        guard let bytesPerSec else { return dash }
        let bits = max(0, bytesPerSec * 8)
        if bits < 1e6 { return "\(fixed(bits / 1e3, bits > 0 && bits < 1e5 ? 1 : 0)) Kbps" }
        if bits < 1e9 { return "\(fixed(bits / 1e6, 1)) Mbps" }
        return "\(fixed(bits / 1e9, 2)) Gbps"
    }

    static func pct(_ value: Double?, digits: Int = 0) -> String {
        guard let value, value.isFinite else { return dash }
        return "\(fixed(value, digits))%"
    }

    static func temp(_ celsius: Double?) -> String {
        guard let celsius, celsius.isFinite else { return dash }
        return "\(Int(celsius.rounded())) °C"
    }

    static func uptime(_ seconds: Double?) -> String {
        guard let seconds else { return dash }
        let total = Int(seconds)
        let d = total / 86_400
        let h = (total % 86_400) / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        let clock = d > 0
            ? String(format: "%02d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d:%02d", h, m, s)
        return d > 0 ? "\(d)d \(clock)" : clock
    }

    static func mhz(_ mhz: Double?) -> String {
        guard let mhz, mhz > 0 else { return dash }
        return mhz >= 1000 ? "\(fixed(mhz / 1000, 2)) GHz" : "\(Int(mhz.rounded())) MHz"
    }

    static func watts(_ watts: Double?) -> String {
        guard let watts else { return dash }
        return "\(fixed(watts, watts < 10 ? 2 : 1)) W"
    }

    static func count(_ n: Int?) -> String {
        guard let n else { return dash }
        return n.formatted()
    }

    static func ms(_ value: Double?) -> String {
        guard let value else { return dash }
        return "\(fixed(value, 1)) ms"
    }

    /// Joins the non-empty parts with " · ".
    static func join(_ parts: [String?]) -> String {
        parts.compactMap { $0 }.filter { !$0.isEmpty && $0 != dash }.joined(separator: " · ")
    }

    /// Rounds up to a "nice" axis maximum: 1, 2, 5 × 10ⁿ.
    static func niceCeil(_ value: Double) -> Double {
        guard value.isFinite, value > 0 else { return 1 }
        let exp = floor(log10(value))
        let f = value / pow(10, exp)
        let nf: Double = f <= 1 ? 1 : f <= 2 ? 2 : f <= 5 ? 5 : 10
        return nf * pow(10, exp)
    }

    /// Nice axis maximum for byte values in binary units (e.g. 512 MB, 1 GB, 2 GB),
    /// so the scale label reads cleanly when formatted with `bytes(_:)`.
    static func niceCeilBytes(_ value: Double) -> Double {
        guard value.isFinite, value > 0 else { return 1 }
        var unit = 1.0
        while value / unit >= 1024 { unit *= 1024 }
        let scaled = niceCeil(value / unit)
        return scaled > 512 ? unit * 1024 : scaled * unit
    }

    static func pressureLabel(_ level: Int) -> String {
        if level >= 4 { return "Critical" }
        if level >= 2 { return "Warning" }
        return "Normal"
    }

    /// True when a pressure level deserves attention (warning or critical).
    static func pressureIsElevated(_ level: Int) -> Bool { level >= 2 }

    static func thermalLabel(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: "Nominal"
        case .fair: "Fair"
        case .serious: "Serious"
        case .critical: "Critical"
        @unknown default: "Unknown"
        }
    }

    /// Splits "6.6 GB" → ("6.6", "GB") and "44%" → ("44", "%") so units can be de-emphasized.
    static func splitUnit(_ text: String) -> (figure: String, unit: String) {
        if text == dash { return (text, "") }
        if text.hasSuffix("%") { return (String(text.dropLast()), "%") }
        guard let space = text.lastIndex(of: " "), space != text.startIndex else { return (text, "") }
        let unit = String(text[text.index(after: space)...])
        if unit.allSatisfy({ $0.isNumber || $0 == "." || $0 == "," || $0 == ":" }) { return (text, "") }
        return (String(text[..<space]), unit)
    }

    private static func fixed(_ value: Double, _ digits: Int) -> String {
        String(format: "%.\(digits)f", value)
    }
}
