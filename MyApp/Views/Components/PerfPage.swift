import SwiftUI

/// Shared scaffold for every pane: scrolling content plus the toolbar with the
/// time-range control and a "Graph Options" menu.
struct PerfPage<Options: View, Content: View>: View {
    var title: String
    var subtitle: String?
    var options: Options
    var content: Content

    @AppStorage(PrefKey.range) private var range: TimeRange = .oneMinute

    init(
        title: String,
        subtitle: String? = nil,
        @ViewBuilder options: () -> Options,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.options = options()
        self.content = content()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                content
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(title)
        .navigationSubtitle(subtitle ?? "")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Picker("Time Range", selection: $range) {
                    ForEach(TimeRange.allCases) { range in
                        Text(range.label).tag(range)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .help("Graph time range")
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    GraphMenuContent { options }
                } label: {
                    Label("Graph Options", systemImage: "slider.horizontal.3")
                }
                .menuIndicator(.hidden)
                .help("Graph Options")
            }
        }
    }
}

extension PerfPage where Options == EmptyView {
    init(title: String, subtitle: String? = nil, @ViewBuilder content: () -> Content) {
        self.init(title: title, subtitle: subtitle, options: { EmptyView() }, content: content)
    }
}

/// Pane-specific graph options followed by the time range, for the toolbar
/// menu and the graphs' context menu (like Task Manager's "Change graph to").
struct GraphMenuContent<Options: View>: View {
    var options: Options
    @AppStorage(PrefKey.range) private var range: TimeRange = .oneMinute

    init(@ViewBuilder options: () -> Options) {
        self.options = options()
    }

    var body: some View {
        options
        if Options.self != EmptyView.self {
            Divider()
        }
        Picker("Time Range", selection: $range) {
            ForEach(TimeRange.allCases) { range in
                Text(range.label).tag(range)
            }
        }
        .pickerStyle(.inline)
    }
}

/// Empty state for a device that disappeared while selected.
struct DeviceGoneView: View {
    var title: String
    var systemImage: String

    var body: some View {
        ContentUnavailableView(title, systemImage: systemImage)
            .navigationTitle("")
    }
}
