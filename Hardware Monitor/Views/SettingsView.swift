import SwiftUI

struct SettingsView: View {
    @Environment(MetricsStore.self) private var store
    @AppStorage(PrefKey.appearance) private var appearance: Appearance = .system
    @AppStorage(PrefKey.range) private var range: TimeRange = .oneMinute
    @AppStorage(PrefKey.showMenuBar) private var showMenuBar = true
    @AppStorage(PrefKey.menuBarItems) private var rawItems = MenuBarItem.cpu.rawValue

    var body: some View {
        Form {
            Section {
                Toggle("Show in menu bar", isOn: $showMenuBar)
                if showMenuBar {
                    ForEach(MenuBarItem.allCases) { item in
                        Toggle(item.title, isOn: binding(for: item))
                            .padding(.leading, 12)
                    }
                }
            } header: {
                Text("Menu Bar")
            } footer: {
                Text("With nothing selected, the menu bar shows just the icon.")
                    .foregroundStyle(.secondary)
            }

            Section {
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
        .animation(.default, value: showMenuBar)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func binding(for item: MenuBarItem) -> Binding<Bool> {
        Binding {
            MenuBarItem.decode(rawItems).contains(item)
        } set: { isOn in
            var items = MenuBarItem.decode(rawItems)
            if isOn { items.append(item) } else { items.removeAll { $0 == item } }
            rawItems = MenuBarItem.encode(MenuBarItem.allCases.filter(items.contains))
        }
    }
}
