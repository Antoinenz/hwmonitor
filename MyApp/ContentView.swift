import SwiftUI

struct ContentView: View {
    @Environment(MetricsStore.self) private var store
    @AppStorage(PrefKey.selectedPane) private var storedPane = Pane.overview.storageKey
    @State private var windowVisible = true

    private var selection: Binding<Pane?> {
        Binding {
            Pane(storageKey: storedPane) ?? .overview
        } set: { pane in
            storedPane = (pane ?? .overview).storageKey
        }
    }

    var body: some View {
        let current = Pane(storageKey: storedPane) ?? .overview
        NavigationSplitView {
            PerfSidebar(selection: selection)
        } detail: {
            ZStack {
                detail(for: current)
                    .id(current)
                    .transition(.opacity)
            }
            .animation(.easeInOut(duration: 0.18), value: current)
        }
        .frame(minWidth: 780, minHeight: 520)
        .environment(\.graphsPaused, !windowVisible)
        .background(WindowVisibilityReader(isVisible: $windowVisible))
        .task { store.start() }
        // A removed device falls back to the overview instead of an empty pane.
        .onChange(of: store.isReady) { fallBackIfMissing(current) }
    }

    @ViewBuilder private func detail(for pane: Pane) -> some View {
        switch pane {
        case .overview: OverviewView(selection: selection)
        case .cpu: CPUView()
        case .memory: MemoryView()
        case .disk(let id): DiskView(diskID: id)
        case .network(let id): NetworkView(networkID: id)
        case .gpu(let id): GPUView(gpuID: id)
        }
    }

    /// On launch, a remembered disk or adapter may no longer exist.
    private func fallBackIfMissing(_ pane: Pane) {
        let info = store.info
        let exists = switch pane {
        case .overview, .cpu, .memory: true
        case .disk(let id): info.disks.contains { $0.id == id }
        case .network(let id): info.networks.contains { $0.id == id }
        case .gpu(let id): info.gpus.contains { $0.id == id }
        }
        if !exists { storedPane = Pane.overview.storageKey }
    }
}

#Preview {
    ContentView()
        .environment(MetricsStore())
        .frame(width: 1080, height: 760)
}
