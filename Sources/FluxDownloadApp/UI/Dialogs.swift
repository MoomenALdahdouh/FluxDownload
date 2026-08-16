import SwiftUI
import AppKit
import FluxDownloadCore
import FluxDownloadEngine

struct AddDownloadView: View {
    @ObservedObject var services: AppServices
    @State var url: String
    @State var filename = ""
    @State var destination: String
    @State var connections = 8
    @State var startNow = true
    @State var referrer = ""
    @State var categoryID: UUID?
    @State var queueID: UUID?
    @State var metadata: RemoteMetadata?
    @State var error: String?
    @State var probing = false

    init(services: AppServices, initialURL: String) {
        self.services = services
        _url = State(initialValue: initialURL)
        _destination = State(initialValue: services.settings.defaultDownloadFolder)
        _categoryID = State(initialValue: services.categories.first?.id)
        _queueID = State(initialValue: services.queueList.first?.id)
        _connections = State(initialValue: services.settings.maxConnectionsPerDownload)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Download").font(.title2.weight(.semibold))
            TextField("URL", text: $url)
                .textFieldStyle(.roundedBorder)
                .onSubmit { Task { await probe() } }
            HStack {
                Button("Detect") { Task { await probe() } }
                    .disabled(probing)
                if probing { ProgressView().controlSize(.small) }
            }
            if let metadata {
                LabeledContent("Server", value: metadata.server ?? metadata.finalURL.host ?? "—")
                LabeledContent("Type", value: metadata.mimeType ?? "—")
                LabeledContent("Size", value: metadata.size.map(ByteFormat.string) ?? "Unknown")
                LabeledContent("Resumable", value: metadata.acceptRanges ? "Yes" : "No")
            }
            TextField("Filename", text: $filename).textFieldStyle(.roundedBorder)
            TextField("Save to", text: $destination).textFieldStyle(.roundedBorder)
            Picker("Category", selection: $categoryID) {
                Text("Automatic").tag(Optional<UUID>.none)
                ForEach(services.categories) { Text($0.name).tag(Optional($0.id)) }
            }
            Picker("Queue", selection: $queueID) {
                ForEach(services.queueList) { Text($0.name).tag(Optional($0.id)) }
            }
            Stepper("Connections: \(connections)", value: $connections, in: 1...32)
            Toggle("Start now", isOn: $startNow)
            TextField("Referrer", text: $referrer).textFieldStyle(.roundedBorder)
            if let error {
                Text(error).foregroundStyle(.red).font(.callout)
            }
            Spacer()
            HStack {
                Button("Cancel") { NSApp.keyWindow?.close() }
                Spacer()
                Button("Download Later") { Task { await submit(start: false) } }
                Button("Download") { Task { await submit(start: true) } }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 500, height: 540)
        .onAppear { if !url.isEmpty { Task { await probe() } } }
    }

    func probe() async {
        error = nil
        probing = true
        defer { probing = false }
        do {
            let meta = try await services.probe(url)
            metadata = meta
            if filename.isEmpty {
                filename = meta.filename ?? (try? FilenameSanitizer.fromURL(meta.finalURL)) ?? ""
            }
        } catch let flux as FluxError {
            error = flux.userMessage
        } catch {
            self.error = error.localizedDescription
        }
    }

    func submit(start: Bool) async {
        do {
            try await services.addURL(
                url,
                filename: filename.isEmpty ? nil : filename,
                destination: URL(fileURLWithPath: destination, isDirectory: true),
                categoryID: categoryID,
                queueID: queueID,
                connections: connections,
                startNow: start,
                referrer: referrer.isEmpty ? nil : referrer
            )
            NSApp.keyWindow?.close()
        } catch let flux as FluxError {
            error = flux.userMessage
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct SettingsView: View {
    @ObservedObject var services: AppServices

    var body: some View {
        TabView {
            Form {
                Toggle("Launch at login", isOn: $services.settings.launchAtLogin)
                Toggle("Launch in menu bar (no windows)", isOn: $services.settings.launchMinimized)
                Toggle("Menu bar extra", isOn: $services.settings.menuBarEnabled)
                Toggle("Notifications", isOn: $services.settings.notificationsEnabled)
                Toggle("Notify on complete", isOn: $services.settings.notifyOnComplete)
                Toggle("Notify on failure", isOn: $services.settings.notifyOnFailure)
                Toggle("Resume unfinished downloads on launch", isOn: $services.settings.autoResumeOnLaunch)
            }
            .tabItem { Label("General", systemImage: "gear") }

            Form {
                TextField("Default folder", text: $services.settings.defaultDownloadFolder)
                Picker("Duplicate files", selection: $services.settings.duplicatePolicy) {
                    ForEach(DuplicatePolicy.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                Stepper("Concurrent downloads: \(services.settings.maxConcurrentDownloads)", value: $services.settings.maxConcurrentDownloads, in: 1...20)
                Stepper("Connections per download: \(services.settings.maxConnectionsPerDownload)", value: $services.settings.maxConnectionsPerDownload, in: 1...32)
            }
            .tabItem { Label("Downloads", systemImage: "arrow.down.circle") }

            Form {
                Toggle("Capture browser downloads", isOn: $services.settings.browserCaptureEnabled)
                Toggle("Ask before capturing", isOn: $services.settings.browserAskBeforeDownload)
                Toggle("Video download panel", isOn: $services.settings.videoPanelEnabled)
                let status = services.chromeStatus()
                LabeledContent("Chrome") { Text(status.chrome ? "Installed" : "Not installed") }
                LabeledContent("Native host") { Text(status.host ? "Registered" : "Not registered") }
                LabeledContent("Safari") { Text("Not implemented — Xcode required") }
                Button("Register Chrome native host") { services.registerNativeMessagingHost() }
            }
            .tabItem { Label("Browser", systemImage: "globe") }

            Form {
                Picker("Proxy", selection: $services.settings.proxyMode) {
                    ForEach(ProxyMode.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                TextField("Proxy host", text: Binding(get: { services.settings.proxyHost ?? "" }, set: { services.settings.proxyHost = $0 }))
                TextField("User-Agent", text: $services.settings.userAgent)
                Stepper("Retry limit: \(services.settings.retryLimit)", value: $services.settings.retryLimit, in: 0...20)
            }
            .tabItem { Label("Network", systemImage: "network") }

            Form {
                Toggle("Clipboard monitoring", isOn: $services.settings.clipboardMonitoringEnabled)
                Text("When enabled, copied http(s) URLs open the Add Download dialog. Clipboard text is not stored.")
                    .foregroundStyle(.secondary)
            }
            .tabItem { Label("Clipboard", systemImage: "doc.on.clipboard") }

            Form {
                Button("Export configuration") { export() }
                Button("Import configuration") { importConfig() }
                Button("Reset settings", role: .destructive) {
                    services.settings = AppSettings()
                    Task { await services.saveSettings() }
                }
            }
            .tabItem { Label("Advanced", systemImage: "wrench") }
        }
        .padding(16)
        .safeAreaInset(edge: .bottom, spacing: 8) {
            HStack {
                Text("FluxDownload is free and open source.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Link("Buy me a coffee", destination: Brand.supportLink)
                    .font(.caption)
            }
            .padding(.horizontal, 4)
        }
        .onDisappear { Task { await services.saveSettings() } }
        .frame(minWidth: 560, minHeight: 420)
    }

    func export() {
        Task {
            guard let data = try? await services.store.exportConfiguration() else { return }
            let panel = NSSavePanel()
            panel.nameFieldStringValue = "fluxdownload-config.json"
            if panel.runModal() == .OK, let url = panel.url {
                try? data.write(to: url)
            }
        }
    }

    func importConfig() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        if panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url) {
            Task {
                try? await services.store.importConfiguration(data)
                try? await services.reload()
            }
        }
    }
}

struct SchedulerView: View {
    @ObservedObject var services: AppServices
    @State private var name = "Weeknights"
    @State private var startHour = 22
    @State private var stopHour = 6

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Scheduler").font(.title2.weight(.semibold))
            Text("Schedules run while FluxDownload is open or in the menu bar. They do not fire after a full Quit unless Launch at Login brings the app back.")
                .foregroundStyle(.secondary)
            List(services.schedules) { schedule in
                HStack {
                    Toggle(schedule.name, isOn: Binding(
                        get: { schedule.isEnabled },
                        set: { value in
                            var copy = schedule
                            copy.isEnabled = value
                            Task { try? await services.store.upsertSchedule(copy); try? await services.reload() }
                        }
                    ))
                    Spacer()
                    Text(String(format: "%02d:00–%02d:00", schedule.startHour, schedule.stopHour))
                        .foregroundStyle(.secondary)
                }
            }
            HStack {
                TextField("Name", text: $name)
                Stepper("Start \(startHour):00", value: $startHour, in: 0...23)
                Stepper("Stop \(stopHour):00", value: $stopHour, in: 0...23)
                Button("Add") {
                    Task {
                        var schedule = Schedule(name: name, startHour: startHour, stopHour: stopHour)
                        schedule.queueID = services.queueList.first?.id
                        try? await services.store.upsertSchedule(schedule)
                        try? await services.reload()
                    }
                }
            }
            Spacer()
        }
        .padding()
    }
}

struct GrabberView: View {
    @ObservedObject var services: AppServices
    @State private var startURL = ""
    @State private var scope: GrabberScope = .page
    @State private var depth = 1

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Site Grabber").font(.title2.weight(.semibold))
            TextField("Starting URL", text: $startURL).textFieldStyle(.roundedBorder)
            Picker("Scope", selection: $scope) {
                Text("This page").tag(GrabberScope.page)
                Text("Same directory").tag(GrabberScope.directory)
                Text("Same domain").tag(GrabberScope.domain)
            }
            Stepper("Max depth: \(depth)", value: $depth, in: 0...5)
            HStack {
                Button("Discover") {
                    Task {
                        await services.runGrabber(start: startURL, scope: scope, types: GrabberResourceType.allCases, depth: depth)
                    }
                }
                Button("Download selected") { Task { await services.enqueueGrabberSelection() } }
                    .disabled(services.grabberItems.isEmpty)
                Text(services.grabberStatus).foregroundStyle(.secondary)
            }
            List {
                ForEach($services.grabberItems) { $item in
                    Toggle(isOn: $item.selected) {
                        VStack(alignment: .leading) {
                            Text(item.filename ?? item.url).lineLimit(1)
                            Text(item.url).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
            }
        }
        .padding()
    }
}

struct DiagnosticsView: View {
    @ObservedObject var services: AppServices
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Diagnostics").font(.title2.weight(.semibold))
            Button("Refresh") { services.refreshDiagnostics() }
            ScrollView {
                Text(services.diagnosticsText)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding()
        .onAppear { services.refreshDiagnostics() }
    }
}

struct OnboardingView: View {
    @ObservedObject var services: AppServices
    @State private var step = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Welcome to \(Brand.name)").font(.title.weight(.semibold))
            Group {
                switch step {
                case 0:
                    Text("A native macOS download manager for HTTP and HTTPS. Downloads keep running if you close this window. Quit from the menu when you want them to stop.")
                case 1:
                    Text("Optional Chrome extension can send downloads and media URLs to this app. Safari is not available until Xcode can package a Safari Web Extension.")
                case 2:
                    Toggle("Capture Chrome downloads", isOn: $services.settings.browserCaptureEnabled)
                    Toggle("Show a confirmation first", isOn: $services.settings.browserAskBeforeDownload)
                case 3:
                    Toggle("Watch the clipboard for download URLs", isOn: $services.settings.clipboardMonitoringEnabled)
                    Text("Off by default. Nothing is uploaded.")
                default:
                    TextField("Default download folder", text: $services.settings.defaultDownloadFolder)
                    Toggle("Launch at login", isOn: $services.settings.launchAtLogin)
                    Toggle("Resume unfinished downloads", isOn: $services.settings.autoResumeOnLaunch)
                }
            }
            .foregroundStyle(.primary)
            Spacer()
            HStack {
                if step > 0 { Button("Back") { step -= 1 } }
                Spacer()
                Button(step == 4 ? "Done" : "Continue") {
                    if step == 4 {
                        services.settings.onboardingCompleted = true
                        Task { await services.saveSettings() }
                        NSApp.keyWindow?.close()
                        AppDelegate.shared?.showMainWindow()
                    } else {
                        step += 1
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(28)
        .frame(width: 520, height: 420)
    }
}

struct PropertiesView: View {
    let record: DownloadRecord
    var body: some View {
        Form {
            LabeledContent("URL", value: record.url)
            LabeledContent("Final URL", value: record.finalURL ?? "—")
            LabeledContent("Filename", value: record.filename)
            LabeledContent("Status", value: record.status.displayName)
            LabeledContent("MIME", value: record.mimeType ?? "—")
            LabeledContent("Server", value: record.serverName ?? "—")
        }
        .padding()
    }
}

struct AboutView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 64, height: 64)
            Text(Brand.name)
                .font(.title2.weight(.semibold))
            Text("Version \(Brand.version)")
                .foregroundStyle(.secondary)
            Text(Brand.copyright)
                .font(.caption)
                .foregroundStyle(.secondary)
            Divider()
            Text("A native macOS download manager. Closing the window does not stop downloads.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Link("Buy me a coffee", destination: Brand.supportLink)
                .font(.callout)
        }
        .padding(28)
        .frame(width: 360)
    }
}
