import AppKit
import SwiftUI
import FluxDownloadCore

struct WindowTitleSync: NSViewRepresentable {
    var title: String

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ nsView: NSView, context: Context) {
        nsView.window?.title = title
    }
}

struct DownloadStatusView: View {
    @ObservedObject var services: AppServices
    let downloadID: UUID
    var onClose: () -> Void

    @State private var showDetails = true
    @State private var selectedTab = 0
    @State private var openWhenDone = false
    @State private var revealWhenDone = false
    @State private var ranCompletionActions = false

    private var snapshot: DownloadSnapshot? {
        services.downloads.first(where: { $0.id == downloadID })
    }

    var body: some View {
        Group {
            if let item = snapshot {
                content(item)
                    .background(WindowTitleSync(title: windowTitle(item)))
                    .onChange(of: item.record.status) { _, status in
                        handleCompletion(item, status: status)
                    }
            } else {
                VStack(spacing: 12) {
                    Text("This download is no longer in the list.")
                        .foregroundStyle(.secondary)
                    Button("Close") { onClose() }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 430, idealWidth: 450, minHeight: 300)
    }

    @ViewBuilder
    private func content(_ item: DownloadSnapshot) -> some View {
        VStack(spacing: 0) {
            Picker("", selection: $selectedTab) {
                Text("Download status").tag(0)
                Text("On completion").tag(1)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 8)

            if selectedTab == 0 {
                statusTab(item)
            } else {
                completionTab
            }
        }
    }

    private func statusTab(_ item: DownloadSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
                row("URL", item.record.url, selectable: true)
                row("Status", statusLine(item), color: statusColor(item.record.status))
                row("File size", item.record.size.map(ByteFormat.string) ?? "Unknown")
                row("Downloaded", downloadedLine(item))
                row("Transfer rate", item.record.status.isActive ? ByteFormat.speed(item.record.currentSpeed) : "—")
                row("Time left", ByteFormat.eta(item.record.etaSeconds))
                row("Resume", resumeText(item.record.resumeSupported))
            }

            progressBar(item)
                .frame(height: 16)
                .padding(.top, 4)

            HStack(spacing: 10) {
                Button(showDetails ? "Hide details" : "Show details") {
                    showDetails.toggle()
                }
                Spacer()
                if item.record.status == .completed {
                    Button("Open") { services.openItem(item) }
                        .keyboardShortcut(.defaultAction)
                } else if item.record.status.canPause {
                    Button("Pause") { Task { await services.pause(id: downloadID) } }
                } else if item.record.status.canResume || item.record.status == .queued {
                    Button("Start") { Task { await services.start(id: downloadID) } }
                }
                if item.record.status.canCancel {
                    Button("Cancel", role: .destructive) {
                        Task {
                            await services.cancel(id: downloadID)
                            onClose()
                        }
                    }
                } else {
                    Button("Close") { onClose() }
                }
            }
            .padding(.top, 4)

            if showDetails {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Start positions and download progress by connections")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ConnectionMapView(item: item)
                        .frame(height: 10)
                    connectionTable(item)
                }
                .padding(.top, 6)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 14)
    }

    private var completionTab: some View {
        Form {
            Toggle("Open file when finished", isOn: $openWhenDone)
            Toggle("Show in Finder when finished", isOn: $revealWhenDone)
            Text("These apply to this download window only.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(8)
    }

    private func connectionTable(_ item: DownloadSnapshot) -> some View {
        let rows = connectionRows(item)
        return Table(rows) {
            TableColumn("N.") { row in
                Text("\(row.index + 1)")
            }
            .width(36)
            TableColumn("Downloaded") { row in
                Text(ByteFormat.string(row.downloaded))
            }
            .width(ideal: 110)
            TableColumn("Info") { row in
                Text(row.info)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(minHeight: 88, maxHeight: 140)
    }

    private func row(_ label: String, _ value: String, selectable: Bool = false, color: Color = .primary) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 110, alignment: .leading)
            if selectable {
                Text(value)
                    .textSelection(.enabled)
                    .lineLimit(2)
                    .foregroundStyle(color)
            } else {
                Text(value)
                    .foregroundStyle(color)
                    .lineLimit(2)
            }
        }
    }

    private func progressBar(_ item: DownloadSnapshot) -> some View {
        Group {
            if let size = item.record.size, size > 0 {
                ProgressView(value: item.record.progress)
                    .progressViewStyle(.linear)
            } else if item.record.status.isActive {
                ProgressView()
                    .progressViewStyle(.linear)
            } else {
                ProgressView(value: item.record.status == .completed ? 1 : 0)
                    .progressViewStyle(.linear)
            }
        }
    }

    private func windowTitle(_ item: DownloadSnapshot) -> String {
        let name = item.record.filename
        if let size = item.record.size, size > 0 {
            return "\(Int((item.record.progress * 100).rounded()))% \(name)"
        }
        return name
    }

    private func statusLine(_ item: DownloadSnapshot) -> String {
        switch item.record.status {
        case .downloading: return "Receiving data…"
        case .connecting, .preparing: return "Connecting…"
        case .verifying: return "Verifying…"
        case .stalled: return "Stalled"
        case .retrying: return "Retrying…"
        case .failed: return item.record.errorMessage ?? "Failed"
        default: return item.record.status.displayName
        }
    }

    private func statusColor(_ status: DownloadStatus) -> Color {
        switch status {
        case .downloading, .connecting, .preparing, .verifying: return .accentColor
        case .failed: return .red
        case .completed: return .green
        default: return .primary
        }
    }

    private func downloadedLine(_ item: DownloadSnapshot) -> String {
        let done = ByteFormat.string(item.record.downloadedBytes)
        if let size = item.record.size, size > 0 {
            return "\(done)  ( \(String(format: "%.1f", item.record.progress * 100)) % )"
        }
        return done
    }

    private func resumeText(_ value: Bool?) -> String {
        switch value {
        case .some(true): return "Yes"
        case .some(false): return "No"
        case .none: return "Unknown"
        }
    }

    private func connectionRows(_ item: DownloadSnapshot) -> [ConnectionRow] {
        if item.segments.isEmpty {
            return [
                ConnectionRow(
                    id: item.id,
                    index: 0,
                    downloaded: item.record.downloadedBytes,
                    info: statusLine(item)
                )
            ]
        }
        return item.segments
            .sorted { $0.index < $1.index }
            .map { segment in
                ConnectionRow(
                    id: segment.id,
                    index: segment.index,
                    downloaded: segment.downloaded,
                    info: segmentInfo(segment)
                )
            }
    }

    private func segmentInfo(_ segment: DownloadSegment) -> String {
        switch segment.status {
        case .pending: return "Waiting…"
        case .downloading: return "Receiving data…"
        case .completed: return "Done"
        case .failed: return segment.lastError ?? "Failed"
        }
    }

    private func handleCompletion(_ item: DownloadSnapshot, status: DownloadStatus) {
        guard status == .completed, !ranCompletionActions else { return }
        ranCompletionActions = true
        if openWhenDone { services.openItem(item) }
        if revealWhenDone { services.revealItem(item) }
    }
}

private struct ConnectionRow: Identifiable {
    var id: UUID
    var index: Int
    var downloaded: Int64
    var info: String
}

struct ConnectionMapView: View {
    let item: DownloadSnapshot

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.primary.opacity(0.08))
                if item.segments.isEmpty {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.accentColor.opacity(0.85))
                        .frame(width: max(2, geo.size.width * CGFloat(item.record.progress)))
                } else {
                    let total = max(1, item.segments.reduce(Int64(0)) { $0 + $1.length })
                    HStack(spacing: 1) {
                        ForEach(item.segments.sorted { $0.index < $1.index }) { segment in
                            let width = geo.size.width * CGFloat(Double(segment.length) / Double(total))
                            ZStack(alignment: .leading) {
                                Rectangle().fill(Color.primary.opacity(0.12))
                                Rectangle()
                                    .fill(Color.accentColor.opacity(0.85))
                                    .frame(width: width * CGFloat(segment.length > 0 ? Double(segment.downloaded) / Double(segment.length) : 0))
                            }
                            .frame(width: max(2, width))
                        }
                    }
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 2))
    }
}
