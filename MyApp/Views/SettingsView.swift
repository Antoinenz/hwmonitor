import SwiftUI

struct SettingsView: View {
    @Environment(MetricsStore.self) private var store
    @AppStorage(PrefKey.appearance) private var appearance: Appearance = .system
    @AppStorage(PrefKey.range) private var range: TimeRange = .oneMinute
    @AppStorage(PrefKey.showMenuBar) private var showMenuBar = true

    var body: some View {
        Form {
            Section {
                Toggle("Show in menu bar", isOn: $showMenuBar)
                Picker("Appearance", selection: $appearance) {
                    ForEach(Appearance.allCases) { appearance in
                        Text(appearance.label).tag(appearance)
                    }
                }
                Picker("Graph time range", selection: $range) {
                    ForEach(TimeRange.allCases) { range in
                        Text(range.label).tag(range)
                    }
                }
            }

            Section {
                LabeledContent("Status", value: elevationStatus)
                if store.elevation != .on {
                    Button("Grant Administrator Access…") { store.requestElevation() }
                        .disabled(store.isRequestingElevation || store.elevation == .starting)
                }
            } header: {
                Text("Administrator Access")
            } footer: {
                Text("CPU speed, power usage and GPU frequency are only available to administrators. Access lasts until System Monitor quits.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var elevationStatus: String {
        switch store.elevation {
        case .off: "Not granted"
        case .starting: "Starting…"
        case .on: "Granted"
        case .error(let message): message
        }
    }
}
