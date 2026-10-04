import SwiftUI

struct ContentView: View {
    @Environment(MetricsStore.self) private var store
    @AppStorage(PrefKey.selectedPane) private var storedPane = Pane.overview.storageKey
    @State private var windowVisible = true
    @AppStorage(PrefKey.compactMode) private var compact = false
    @AppStorage(PrefKey.keepOnTop) private var keepOnTop = false
    @State private var columns: NavigationSplitViewVisibility = .all
    @State private var windowController = WindowController()
    /// The split view reports its own visibility once after we change it; ignore that echo.
    @State private var ignoreColumnChangesUntil = Date.distantPast

    private var selection: Binding<Pane?> {
        Binding {
            Pane(storageKey: storedPane) ?? .overview
        } set: { pane in
            storedPane = (pane ?? .overview).storageKey
        }
    }

    var body: some View {
        let current = Pane(storageKey: storedPane) ?? .overview
        NavigationSplitView(columnVisibility: $columns) {
            PerfSidebar(selection: selection) { pane in
                storedPane = pane.storageKey
                compact = true
            }
            .toolbar(removing: compact ? .sidebarToggle : nil)
        } detail: {
            ZStack {
                detail(for: current)
                    .id(current)
                    .transition(.opacity)
            }
            .animation(.easeInOut(duration: 0.18), value: current)
            .overlay(alignment: .bottom) {
                if store.frozenAt != nil {
                    FrozenBadge()
                        .padding(.bottom, 18)
                        .transition(.scale(scale: 0.85).combined(with: .opacity))
                }
            }
            .animation(.spring(duration: 0.3), value: store.frozenAt)
            .toolbar {
                // In compact mode the pin takes the sidebar button's place.
                if compact {
                    ToolbarItemGroup(placement: .navigation) {
                        Button {
                            keepOnTop.toggle()
                        } label: {
                            Label(keepOnTop ? "Unpin Window" : "Keep on Top", systemImage: keepOnTop ? "pin.fill" : "pin")
                        }
                        .help(keepOnTop ? "Stop keeping this window on top" : "Keep this window above other apps")
                        Button {
                            compact = false
                        } label: {
                            Label("Exit Compact Mode", systemImage: "arrow.up.left.and.arrow.down.right")
                        }
                        .help("Show the sidebar again")
                    }
                }
            }
        }
        .frame(minWidth: compact ? 380 : 780, minHeight: compact ? 280 : 520)
        .background(WindowAccessor { window in
            windowController.attach(window)
            windowController.setKeepOnTop(keepOnTop)
        })
        .onChange(of: compact, initial: true) { _, isCompact in
            ignoreColumnChangesUntil = Date().addingTimeInterval(1)
            withAnimation(.smooth(duration: 0.3)) {
                columns = isCompact ? .detailOnly : .all
            }
            windowController.setCompact(isCompact)
        }
        .onChange(of: keepOnTop) { _, onTop in windowController.setKeepOnTop(onTop) }
        // Showing the sidebar any other way (⌃⌘S, toolbar) leaves compact mode.
        .onChange(of: columns) { _, visibility in
            guard Date() > ignoreColumnChangesUntil else {
                if compact && visibility != .detailOnly { columns = .detailOnly }
                return
            }
            if compact && visibility != .detailOnly { compact = false }
        }
        .environment(\.graphsPaused, !windowVisible)
        .environment(\.frozenAt, store.frozenAt)
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
        case .power: PowerView()
        case .disk(let id): DiskView(diskID: id)
        case .network(let id): NetworkView(networkID: id)
        case .gpu(let id): GPUView(gpuID: id)
        }
    }

    /// On launch, a remembered disk or adapter may no longer exist.
    private func fallBackIfMissing(_ pane: Pane) {
        let info = store.info
        let exists = switch pane {
        case .overview, .cpu, .memory, .power: true
        case .disk(let id): info.disks.contains { $0.id == id }
        case .network(let id): info.networks.contains { $0.id == id }
        case .gpu(let id): info.gpus.contains { $0.id == id }
        }
        if !exists { storedPane = Pane.overview.storageKey }
    }
}

/// Floating glass badge with a pulsing pause symbol while the display is frozen.
private struct FrozenBadge: View {
    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "pause.fill")
                .symbolEffect(.pulse, options: .repeating)
            Text("Frozen")
                .fontWeight(.medium)
            Text("Space to resume")
                .foregroundStyle(.secondary)
        }
        .font(.callout)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .glassEffect()
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    ContentView()
        .environment(MetricsStore())
        .frame(width: 1080, height: 760)
}
