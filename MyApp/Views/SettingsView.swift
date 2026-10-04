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
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
    }
}
