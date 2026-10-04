import SwiftUI

@main struct MyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var store: MetricsStore
    @AppStorage(PrefKey.appearance) private var appearance: Appearance = .system
    @AppStorage(PrefKey.showMenuBar) private var showMenuBar = true

    init() {
        UserDefaults.standard.register(defaults: [PrefKey.showMenuBar: true])
        // Start sampling at launch so the menu bar extra works even before the window opens.
        let store = MetricsStore()
        store.start()
        _store = State(initialValue: store)
    }

    var body: some Scene {
        Window("Hardware Monitor", id: "main") {
            ContentView()
                .environment(store)
                .onChange(of: appearance, initial: true) {
                    NSApp.appearance = appearance.nsAppearance
                }
        }
        .defaultSize(width: 1080, height: 760)
        .commands {
            SidebarCommands()
            ViewCommands(store: store)
        }

        MenuBarExtra(isInserted: $showMenuBar) {
            MenuBarPanel()
                .environment(store)
        } label: {
            MenuBarLabel()
                .environment(store)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(store)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Keep running in the menu bar after the window closes, if the extra is shown.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !UserDefaults.standard.bool(forKey: PrefKey.showMenuBar)
    }
}

/// View menu: freeze (Space) and time range (⌘1–⌘3).
private struct ViewCommands: Commands {
    var store: MetricsStore
    @AppStorage(PrefKey.range) private var range: TimeRange = .oneMinute

    var body: some Commands {
        CommandGroup(after: .sidebar) {
            Divider()
            Button(store.frozenAt == nil ? "Freeze Graphs" : "Resume Live Graphs") {
                store.toggleFreeze()
            }
            .keyboardShortcut(.space, modifiers: [])
            Divider()
            Picker("Time Range", selection: $range) {
                ForEach(Array(TimeRange.allCases.enumerated()), id: \.element) { index, range in
                    Text(range.label)
                        .tag(range)
                        .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
                }
            }
            .pickerStyle(.inline)
        }
    }
}
