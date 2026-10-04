import SwiftUI
import UniformTypeIdentifiers

/// The busiest processes by CPU or memory, with app icons. Rows animate as
/// processes trade places.
struct TopProcesses: View {
    enum Sort { case cpu, memory }

    @Environment(MetricsStore.self) private var store
    var sort: Sort
    var count = 8

    var body: some View {
        let rows = topRows
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(sort == .cpu ? "Top processes by CPU" : "Top processes by memory")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Open Activity Monitor", action: openActivityMonitor)
                    .buttonStyle(.link)
                    .font(.caption)
            }

            if rows.isEmpty {
                Text("Loading…")
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, minHeight: 60)
            } else {
                VStack(spacing: 0) {
                    ForEach(rows) { process in
                        ProcessRow(process: process, value: value(for: process), fraction: fraction(for: process), color: color)
                        if process.id != rows.last?.id {
                            Divider().padding(.leading, 28)
                        }
                    }
                }
                .animation(.smooth(duration: 0.45), value: rows.map(\.id))
            }
        }
    }

    private var topRows: [ProcessUsage] {
        switch sort {
        case .cpu: Array(store.processes.sorted { $0.cpu > $1.cpu }.prefix(count))
        case .memory: Array(store.processes.sorted { $0.memory > $1.memory }.prefix(count))
        }
    }

    private var color: Color { sort == .cpu ? Palette.cpu : Palette.memory }

    private func value(for process: ProcessUsage) -> String {
        switch sort {
        case .cpu: Fmt.pct(process.cpu, digits: 1)
        case .memory: Fmt.bytes(process.memory)
        }
    }

    private func fraction(for process: ProcessUsage) -> Double {
        switch sort {
        case .cpu: process.cpu / (100 * Double(max(1, store.info.cpu.logical)))
        case .memory: process.memory / max(1, store.info.memory.total)
        }
    }

    private func openActivityMonitor() {
        let url = URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app")
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }
}

private struct ProcessRow: View {
    var process: ProcessUsage
    var value: String
    var fraction: Double
    var color: Color

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: ProcessIcons.icon(for: process.path))
                .resizable()
                .frame(width: 18, height: 18)
            Text(process.name)
                .lineLimit(1)
                .truncationMode(.middle)
                .help("\(process.name) — PID \(process.pid)\n\(process.path)")
            Spacer(minLength: 12)
            UsageBar(fraction: fraction, color: color)
                .frame(width: 72)
            Text(value)
                .monospacedDigit()
                .contentTransition(.numericText())
                .animation(.smooth(duration: 0.4), value: value)
                .frame(width: 72, alignment: .trailing)
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .contextMenu {
            Button("Copy Process Name") { copy(process.name) }
            Button("Copy PID") { copy(String(process.pid)) }
            if let bundle = ProcessIcons.bundlePath(for: process.path) {
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: bundle)])
                }
            }
        }
    }

    private func copy(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }
}

/// Icons for processes: the owning app's icon when the executable lives inside
/// an app bundle (so helpers show their parent app), otherwise a generic one.
enum ProcessIcons {
    private static var cache: [String: NSImage] = [:]
    private static let generic = NSWorkspace.shared.icon(for: .unixExecutable)

    static func bundlePath(for path: String) -> String? {
        guard let range = path.range(of: ".app/") else { return nil }
        return String(path[..<range.lowerBound]) + ".app"
    }

    static func icon(for path: String) -> NSImage {
        guard let bundle = bundlePath(for: path) else { return generic }
        if let cached = cache[bundle] { return cached }
        let icon = NSWorkspace.shared.icon(forFile: bundle)
        cache[bundle] = icon
        return icon
    }
}
