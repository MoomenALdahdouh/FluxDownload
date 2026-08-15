import SwiftUI
import FluxDownloadCore

struct MainView: View {
    @ObservedObject var services: AppServices

    var body: some View {
        NavigationSplitView {
            SidebarView(services: services)
                .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 280)
        } content: {
            Group {
                switch services.sidebarSelection {
                case .scheduler:
                    SchedulerView(services: services)
                case .grabber:
                    GrabberView(services: services)
                case .diagnostics:
                    DiagnosticsView(services: services)
                default:
                    DownloadsListView(services: services)
                }
            }
        } detail: {
            InspectorView(services: services)
                .navigationSplitViewColumnWidth(min: 260, ideal: 300, max: 420)
        }
        .searchable(text: $services.searchText, prompt: "Search downloads")
        .toolbar { ToolbarView(services: services) }
        .frame(minWidth: 900, minHeight: 480)
    }
}

struct SidebarView: View {
    @ObservedObject var services: AppServices

    var body: some View {
        List(selection: $services.sidebarSelection) {
            Section("Library") {
                Label("All", systemImage: "tray.full").tag(SidebarItem.all)
                Label("In Progress", systemImage: "arrow.down.circle").tag(SidebarItem.inProgress)
                Label("Completed", systemImage: "checkmark.circle").tag(SidebarItem.completed)
                Label("Paused", systemImage: "pause.circle").tag(SidebarItem.paused)
                Label("Failed", systemImage: "exclamationmark.triangle").tag(SidebarItem.failed)
            }
            Section("Types") {
                Label("Video", systemImage: "film").tag(SidebarItem.video)
                Label("Audio", systemImage: "music.note").tag(SidebarItem.audio)
                Label("Documents", systemImage: "doc").tag(SidebarItem.documents)
                Label("Applications", systemImage: "app").tag(SidebarItem.applications)
                Label("Archives", systemImage: "archivebox").tag(SidebarItem.archives)
            }
            Section("Categories") {
                ForEach(services.categories) { category in
                    Label(category.name, systemImage: "folder").tag(SidebarItem.category(category.id))
                }
            }
            Section("Queues") {
                ForEach(services.queueList) { queue in
                    Label(queue.name, systemImage: "list.number").tag(SidebarItem.queue(queue.id))
                }
            }
            Section("Tools") {
                Label("Scheduler", systemImage: "calendar").tag(SidebarItem.scheduler)
                Label("Grabber", systemImage: "globe").tag(SidebarItem.grabber)
                Label("Diagnostics", systemImage: "stethoscope").tag(SidebarItem.diagnostics)
            }
        }
        .listStyle(.sidebar)
        .accessibilityLabel("Sidebar")
    }
}

struct ToolbarView: ToolbarContent {
    @ObservedObject var services: AppServices
    private var selected: DownloadSnapshot? { services.selectedRecords.first }

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button("Add URL") { AppDelegate.shared?.showAddDownload() }
                .accessibilityLabel("Add URL")
            Button("Start") { Task { await services.startSelected() } }
                .disabled(!(selected?.record.status.canResume ?? false) && selected?.record.status != .queued)
            Button("Pause") { Task { await services.pauseSelected() } }
                .disabled(!(selected?.record.status.canPause ?? false))
            Button("Retry") { Task { await services.retrySelected() } }
                .disabled(!(selected?.record.status.canRetry ?? false))
            Button("Delete") { Task { await services.deleteSelected() } }
                .disabled(selected == nil)
            Button("Open") { services.openSelected() }
                .disabled(selected?.record.status != .completed)
            Button("Show in Finder") { services.revealSelected() }
                .disabled(selected?.record.finalPath == nil)
            Button("Settings") { AppDelegate.shared?.showSettings() }
        }
    }
}

struct DownloadsListView: View {
    @ObservedObject var services: AppServices

    var body: some View {
        VStack(spacing: 0) {
            if services.filteredDownloads.isEmpty {
                EmptyStateView(
                    title: "No downloads",
                    subtitle: "Add a URL, drop a link here, or capture a file from Chrome."
                )
            } else {
                Table(services.filteredDownloads, selection: $services.selection) {
                    TableColumn("Name") { item in
                        HStack {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: item.record.finalPath ?? item.record.filename))
                                .resizable()
                                .frame(width: 16, height: 16)
                            Text(item.record.filename)
                                .lineLimit(1)
                        }
                    }
                    TableColumn("Status") { item in
                        Text(item.record.status.displayName)
                            .foregroundStyle(item.record.status == .failed ? .red : .primary)
                    }
                    .width(ideal: 110)
                    TableColumn("Size") { item in
                        Text(item.record.size.map(ByteFormat.string) ?? "—")
                    }
                    .width(ideal: 90)
                    TableColumn("Progress") { item in
                        ProgressView(value: item.record.progress)
                            .progressViewStyle(.linear)
                    }
                    .width(ideal: 140)
                    TableColumn("Speed") { item in
                        Text(item.record.status.isActive ? ByteFormat.speed(item.record.currentSpeed) : "—")
                    }
                    .width(ideal: 90)
                    TableColumn("ETA") { item in
                        Text(ByteFormat.eta(item.record.etaSeconds))
                    }
                    .width(ideal: 70)
                }
                .contextMenu(forSelectionType: UUID.self) { ids in
                    Button("Open") {
                        ids.compactMap { id in services.downloads.first(where: { $0.id == id }) }
                            .forEach(services.openItem)
                    }
                    Button("Show in Finder") { services.revealSelected() }
                    Divider()
                    Button("Download status") {
                        ids.forEach { AppDelegate.shared?.showDownloadStatus(id: $0) }
                    }
                    Divider()
                    Button("Start") { Task { await services.startSelected() } }
                    Button("Pause") { Task { await services.pauseSelected() } }
                    Button("Retry") { Task { await services.retrySelected() } }
                    Divider()
                    Button("Delete", role: .destructive) { Task { await services.deleteSelected() } }
                } primaryAction: { ids in
                    services.activateSelection(ids)
                }
                .onDrop(of: [.url, .plainText], isTargeted: nil) { providers in
                    for provider in providers {
                        _ = provider.loadObject(ofClass: URL.self) { url, _ in
                            if let url {
                                Task { @MainActor in
                                    AppDelegate.shared?.showAddDownload(url: url.absoluteString)
                                }
                            }
                        }
                    }
                    return true
                }
            }
            Divider()
            HStack {
                let active = services.downloads.filter { $0.record.status.isActive }
                let speed = active.reduce(Int64(0)) { $0 + $1.record.currentSpeed }
                Text("\(active.count) active")
                Spacer()
                Text(ByteFormat.speed(speed))
                Text("·")
                Text("\(services.downloads.count) total")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
    }
}

struct InspectorView: View {
    @ObservedObject var services: AppServices

    var body: some View {
        if let item = services.selectedRecords.first {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(item.record.filename).font(.headline)
                    LabeledContent("Status", value: item.record.status.displayName)
                    LabeledContent("Progress", value: "\(Int(item.record.progress * 100))%")
                    LabeledContent("Downloaded", value: ByteFormat.string(item.record.downloadedBytes))
                    LabeledContent("Size", value: item.record.size.map(ByteFormat.string) ?? "Unknown")
                    LabeledContent("Speed", value: ByteFormat.speed(item.record.currentSpeed))
                    LabeledContent("ETA", value: ByteFormat.eta(item.record.etaSeconds))
                    LabeledContent("Connections", value: "\(item.record.connectionCount)")
                    LabeledContent("Source", value: item.record.url)
                    LabeledContent("Destination", value: item.record.saveDirectory)
                    LabeledContent("Retries", value: "\(item.record.retryCount)")
                    if let error = item.record.errorMessage {
                        Text(error).foregroundStyle(.red)
                        DisclosureGroup("Diagnostics") {
                            Text(item.record.errorCode ?? "").font(.system(.caption, design: .monospaced))
                        }
                    }
                    if !item.segments.isEmpty {
                        Text("Connections").font(.subheadline.weight(.semibold))
                        ForEach(item.segments) { segment in
                            HStack {
                                Text("Connection \(segment.index + 1)")
                                Spacer()
                                Text(ByteFormat.speed(segment.speed))
                                Text("\(ByteFormat.string(segment.offset))–\(ByteFormat.string(segment.endInclusive))")
                                    .foregroundStyle(.secondary)
                            }
                            .font(.caption)
                        }
                    }
                }
                .padding()
            }
        } else {
            EmptyStateView(title: "Details", subtitle: "Select a download to inspect progress, connections, and errors.")
        }
    }
}

struct EmptyStateView: View {
    var title: String
    var subtitle: String
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text(title).font(.title3.weight(.semibold))
            Text(subtitle)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}
