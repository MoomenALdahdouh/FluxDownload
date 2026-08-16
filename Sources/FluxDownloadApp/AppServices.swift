import AppKit
import Foundation
import UserNotifications
import ServiceManagement
import FluxDownloadCore
import FluxDownloadPersistence
import FluxDownloadEngine
import FluxDownloadScheduler
import FluxDownloadBrowserProtocol
import FluxDownloadIPC
import FluxDownloadGrabber
import FluxDownloadMedia

enum SidebarItem: Hashable {
    case all, inProgress, completed, paused, failed, video, audio, documents, applications, archives
    case category(UUID)
    case queue(UUID)
    case scheduler
    case grabber
    case history
    case diagnostics
}

@MainActor
final class AppServices: ObservableObject {
    let store: Store
    let coordinator: DownloadCoordinator
    let queues: QueueManager
    let scheduler: SchedulerEngine
    let grabber = SiteGrabber()
    private var ipc: IPCServer?
    private var token: String = ""

    @Published var settings: AppSettings
    @Published var downloads: [DownloadSnapshot] = []
    @Published var categories: [FileCategory] = []
    @Published var queueList: [DownloadQueue] = []
    @Published var schedules: [Schedule] = []
    @Published var selection: Set<UUID> = []
    @Published var sidebarSelection: SidebarItem = .all
    @Published var searchText = ""
    @Published var grabberItems: [GrabberItem] = []
    @Published var grabberStatus = "Idle"
    @Published var diagnosticsText = ""
    @Published var clipboardEnabledNotice = false
    @Published var pendingClipboardURL: String?
    var statusItem: NSStatusItem?
    private var clipboardTimer: Timer?
    private var lastChangeCount = NSPasteboard.general.changeCount
    private var seenClipboard = Set<String>()

    static func bootstrap() async throws -> AppServices {
        try AppPaths.ensureSupportDirectories()
        let store = try await Store(path: AppPaths.databaseFile)
        let settings = try await store.loadSettings()
        let coordinator = DownloadCoordinator(store: store, settings: settings)
        let queues = QueueManager(store: store, coordinator: coordinator)
        let scheduler = SchedulerEngine(store: store, queues: queues)
        let services = AppServices(store: store, coordinator: coordinator, queues: queues, scheduler: scheduler, settings: settings)
        try await services.start()
        return services
    }

    init(store: Store, coordinator: DownloadCoordinator, queues: QueueManager, scheduler: SchedulerEngine, settings: AppSettings) {
        self.store = store
        self.coordinator = coordinator
        self.queues = queues
        self.scheduler = scheduler
        self.settings = settings
    }

    private func terminateOtherAppInstances() {
        let pid = ProcessInfo.processInfo.processIdentifier
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: Brand.bundleIdentifier) where app.processIdentifier != pid {
            app.terminate()
        }
        Thread.sleep(forTimeInterval: 0.4)
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: Brand.bundleIdentifier) where app.processIdentifier != pid {
            app.forceTerminate()
        }
    }

    func start() async throws {
        terminateOtherAppInstances()
        token = try IPCToken.loadOrCreate()
        let server = IPCServer(token: token) { [weak self] envelope in
            await self?.handleBrowser(envelope) ?? BrowserResponse(id: envelope.id, ok: false, error: "App not ready")
        }
        try server.start()
        ipc = server
        await coordinator.setHandlers(
            onChange: { [weak self] snapshot in
                Task { @MainActor in
                    self?.apply(snapshot)
                }
            },
            onState: { [weak self] record in
                Task { @MainActor in
                    self?.notify(record)
                }
            }
        )
        try await coordinator.recoverIncomplete(autoResume: settings.autoResumeOnLaunch)
        if settings.userAgent.contains("FluxDownload/") || settings.userAgent.isEmpty {
            settings.userAgent = Brand.userAgent
            try? await store.saveSettings(settings)
            await coordinator.updateSettings(settings)
        }
        await scheduler.start()
        try await reload()
        configureClipboard()
        requestNotifications()
        applyLaunchAtLogin()
        registerNativeMessagingHost()
        repairIPCIfNeeded()
        refreshDiagnostics()
        applyLaunchAtLogin()
    }

    func repairIPCIfNeeded() {
        if ipc?.ownsSocketFile() == true { return }
        ipc?.stop()
        let server = IPCServer(token: token) { [weak self] envelope in
            await self?.handleBrowser(envelope) ?? BrowserResponse(id: envelope.id, ok: false, error: "App not ready")
        }
        do {
            try server.start()
            ipc = server
        } catch {
            AppLog.warning("IPC repair failed", category: "ipc")
        }
    }

    func shutdown() async {
        ipc?.stop()
        await scheduler.stop()
        await coordinator.shutdown()
        clipboardTimer?.invalidate()
    }

    func reload() async throws {
        downloads = try await coordinator.currentSnapshots()
        categories = try await store.allCategories()
        queueList = try await store.allQueues()
        schedules = try await store.allSchedules()
        settings = try await store.loadSettings()
        refreshStatusItem()
    }

    func saveSettings() async {
        try? await store.saveSettings(settings)
        await coordinator.updateSettings(settings)
        configureClipboard()
        applyLaunchAtLogin()
        if settings.menuBarEnabled && statusItem == nil {
            AppDelegate.shared?.showMainWindow()
        }
        try? await reload()
    }

    func addURL(_ urlString: String, filename: String?, destination: URL?, categoryID: UUID?, queueID: UUID?, connections: Int, startNow: Bool, referrer: String?) async throws {
        let url = try URLValidator.parse(urlString)
        let record = try await coordinator.add(
            NewDownloadRequest(
                url: url,
                filename: filename?.isEmpty == false ? filename : nil,
                destination: destination,
                categoryID: categoryID,
                queueID: queueID,
                connections: connections,
                referrer: referrer,
                startImmediately: startNow
            )
        )
        try await reload()
        if startNow {
            AppDelegate.shared?.showDownloadStatus(id: record.id)
        }
    }

    func probe(_ urlString: String) async throws -> RemoteMetadata {
        let url = try URLValidator.parse(urlString)
        let probe = ProbeClient(session: URLSession(configuration: .ephemeral), userAgent: settings.userAgent)
        return try await probe.probe(url: url)
    }

    var filteredDownloads: [DownloadSnapshot] {
        downloads.filter { snapshot in
            if !searchText.isEmpty {
                let q = searchText.lowercased()
                let rec = snapshot.record
                let blob = "\(rec.filename) \(rec.url) \(rec.descriptionText ?? "") \(rec.sourcePageURL ?? "")".lowercased()
                if !blob.contains(q) { return false }
            }
            switch sidebarSelection {
            case .all: return true
            case .inProgress: return snapshot.record.status.isActive || snapshot.record.status == .queued
            case .completed: return snapshot.record.status == .completed
            case .paused: return snapshot.record.status == .paused
            case .failed: return snapshot.record.status == .failed
            case .video: return snapshot.record.fileExtension.isVideo
            case .audio: return snapshot.record.fileExtension.isAudio
            case .documents: return snapshot.record.fileExtension.isDocument
            case .applications: return snapshot.record.fileExtension.isApplication
            case .archives: return snapshot.record.fileExtension.isArchive
            case .category(let id): return snapshot.record.categoryID == id
            case .queue(let id): return snapshot.record.queueID == id
            case .scheduler, .grabber, .history, .diagnostics: return true
            }
        }
    }

    var selectedRecords: [DownloadSnapshot] {
        downloads.filter { selection.contains($0.id) }
    }

    func startSelected() async {
        for item in selectedRecords { await start(id: item.id) }
        try? await reload()
    }

    func pauseSelected() async {
        for item in selectedRecords { await pause(id: item.id) }
        try? await reload()
    }

    func retrySelected() async {
        for item in selectedRecords { try? await coordinator.retry(item.id) }
        try? await reload()
    }

    func deleteSelected() async {
        for item in selectedRecords { try? await coordinator.remove(item.id, deleteFile: false) }
        selection.removeAll()
        try? await reload()
    }

    func start(id: UUID) async {
        try? await coordinator.start(id)
        try? await reload()
    }

    func pause(id: UUID) async {
        try? await coordinator.pause(id)
        try? await reload()
    }

    func cancel(id: UUID) async {
        try? await coordinator.cancel(id)
        try? await reload()
    }

    func activateSelection(_ ids: Set<UUID>) {
        let items = downloads.filter { ids.contains($0.id) }
        if items.isEmpty { return }
        if items.allSatisfy({ $0.record.status == .completed }) {
            items.forEach(openItem)
            return
        }
        for item in items {
            if item.record.status == .completed {
                openItem(item)
            } else {
                AppDelegate.shared?.showDownloadStatus(id: item.id)
            }
        }
    }

    func openSelected() {
        selectedRecords.forEach(openItem)
    }

    func revealSelected() {
        selectedRecords.forEach(revealItem)
    }

    func openItem(_ item: DownloadSnapshot) {
        guard item.record.status == .completed, let url = fileURL(for: item) else { return }
        NSWorkspace.shared.open(url)
    }

    func revealItem(_ item: DownloadSnapshot) {
        guard let url = fileURL(for: item) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func fileURL(for item: DownloadSnapshot) -> URL? {
        if let path = item.record.finalPath, FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        let fallback = URL(fileURLWithPath: item.record.saveDirectory, isDirectory: true)
            .appendingPathComponent(item.record.filename)
        if FileManager.default.fileExists(atPath: fallback.path) {
            return fallback
        }
        return nil
    }

    func handleBrowser(_ envelope: BrowserEnvelope) async -> BrowserResponse {
        switch envelope.type {
        case .ping, .statusQuery:
            if envelope.id == "pause-all" {
                try? await coordinator.pauseAll()
            }
            if envelope.id == "resume-all" {
                try? await coordinator.resumeAll()
            }
            return BrowserResponse(id: envelope.id, ok: true, captureEnabled: settings.browserCaptureEnabled)
        case .settingsGet:
            return BrowserResponse(id: envelope.id, ok: true, captureEnabled: settings.browserCaptureEnabled)
        case .downloadRequest, .downloadCapture:
            guard case .download(let payload) = envelope.payload else {
                return BrowserResponse(id: envelope.id, ok: false, error: "Missing download payload")
            }
            do {
                let url = try URLValidator.parse(payload.url)
                if settings.browserAskBeforeDownload && envelope.type == .downloadCapture {
                    AppDelegate.shared?.showAddDownload(url: payload.url)
                    return BrowserResponse(id: envelope.id, ok: true)
                }
                let browserUA = payload.userAgent?.isEmpty == false ? payload.userAgent : Brand.userAgent
                let record = try await coordinator.add(
                    NewDownloadRequest(
                        url: url,
                        filename: payload.filename,
                        referrer: payload.referrer,
                        userAgent: browserUA,
                        headers: payload.headers ?? [:],
                        cookieHeader: payload.cookies,
                        sourceBrowser: payload.source.rawValue,
                        sourcePageURL: payload.pageURL,
                        browserRequestID: payload.browserRequestId,
                        startImmediately: true
                    )
                )
                try? await store.insertBrowserEvent(type: envelope.type.rawValue, url: payload.url, detail: nil)
                try await reload()
                if payload.openStatusWindow != false {
                    AppDelegate.shared?.showDownloadStatus(id: record.id)
                }
                return BrowserResponse(id: envelope.id, ok: true, downloadID: record.id.uuidString)
            } catch let error as FluxError {
                return BrowserResponse(id: envelope.id, ok: false, error: error.userMessage, diagnostic: error.diagnosticDetail)
            } catch {
                return BrowserResponse(id: envelope.id, ok: false, error: error.localizedDescription)
            }
        case .mediaDetected:
            return BrowserResponse(id: envelope.id, ok: true)
        }
    }

    func runGrabber(start: String, scope: GrabberScope, types: [GrabberResourceType], depth: Int) async {
        grabberStatus = "Crawling…"
        do {
            let url = try URLValidator.parse(start)
            let items = try await grabber.crawl(GrabberOptions(startURL: url, scope: scope, types: types, maxDepth: depth))
            grabberItems = items
            grabberStatus = "Found \(items.count) resources"
        } catch let error as FluxError {
            grabberStatus = error.userMessage
        } catch {
            grabberStatus = error.localizedDescription
        }
    }

    func enqueueGrabberSelection() async {
        for item in grabberItems where item.selected {
            if let url = try? URLValidator.parse(item.url) {
                _ = try? await coordinator.add(NewDownloadRequest(url: url, filename: item.filename, startImmediately: true))
            }
        }
        try? await reload()
    }

    func chromeStatus() -> (chrome: Bool, host: Bool) {
        let chrome = FileManager.default.fileExists(atPath: "/Applications/Google Chrome.app")
        let host = FileManager.default.fileExists(atPath: nativeHostManifestPath.path)
        return (chrome, host)
    }

    func refreshDiagnostics() {
        let chrome = chromeStatus()
        let db = FileManager.default.fileExists(atPath: AppPaths.databaseFile.path)
        let active = downloads.filter { $0.record.status.isActive }.count
        diagnosticsText = """
        App \(Brand.version)
        Database: \(db ? "ok" : "missing")
        IPC: \(AppPaths.ipcSocket.path)
        Active downloads: \(active)
        Chrome installed: \(chrome.chrome)
        Native host manifest: \(chrome.host)
        Safari: NOT IMPLEMENTED — BLOCKED BY VERIFIED PLATFORM LIMITATION (Xcode required)
        """
    }

    private func apply(_ snapshot: DownloadSnapshot) {
        if let idx = downloads.firstIndex(where: { $0.id == snapshot.id }) {
            downloads[idx] = snapshot
        } else {
            downloads.insert(snapshot, at: 0)
        }
        refreshStatusItem()
    }

    private func notify(_ record: DownloadRecord) {
        guard settings.notificationsEnabled else { return }
        if record.status == .completed && settings.notifyOnComplete {
            postNotification(title: "Download completed", body: record.filename)
        }
        if record.status == .failed && settings.notifyOnFailure {
            postNotification(title: "Download failed", body: record.filename)
        }
    }

    private func postNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    private func requestNotifications() {
        guard Bundle.main.bundleIdentifier == Brand.bundleIdentifier else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func configureClipboard() {
        clipboardTimer?.invalidate()
        guard settings.clipboardMonitoringEnabled else { return }
        lastChangeCount = NSPasteboard.general.changeCount
        clipboardTimer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.inspectClipboard() }
        }
    }

    private func inspectClipboard() {
        let board = NSPasteboard.general
        guard board.changeCount != lastChangeCount else { return }
        lastChangeCount = board.changeCount
        guard let string = board.string(forType: .string) else { return }
        let urls = URLValidator.extractURLs(from: string)
        guard let first = urls.first else { return }
        let key = first.absoluteString
        guard !seenClipboard.contains(key) else { return }
        seenClipboard.insert(key)
        pendingClipboardURL = key
        AppDelegate.shared?.showAddDownload(url: key)
    }

    private func applyLaunchAtLogin() {
        let packaged = Bundle.main.bundleURL.pathExtension == "app"
        let service = SMAppService.mainApp
        do {
            if settings.launchAtLogin && packaged {
                try service.register()
            } else if service.status == .enabled {
                try service.unregister()
            }
        } catch {
            AppLog.warning("Launch at login change failed", category: "lifecycle")
        }
    }

    private func refreshStatusItem() {
        let active = downloads.filter { $0.record.status.isActive }
        let speed = active.reduce(Int64(0)) { $0 + $1.record.currentSpeed }
        statusItem?.button?.image = NSImage(systemSymbolName: "arrow.down.circle.fill", accessibilityDescription: Brand.name)
        statusItem?.button?.image?.isTemplate = true
        statusItem?.button?.title = active.isEmpty ? "" : " \(active.count) \(ByteFormat.speed(speed))"
    }

    private var nativeHostManifestPath: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Google/Chrome/NativeMessagingHosts/\(Brand.nativeMessagingHostName).json")
    }

    func registerNativeMessagingHost() {
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/FluxDownloadNativeHost")
        let installed = URL(fileURLWithPath: "/Applications/FluxDownload.app/Contents/MacOS/FluxDownloadNativeHost")
        let sibling = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("FluxDownloadNativeHost")
        let hostPath = [bundled, installed, sibling]
            .map(\.path)
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) })
        guard let hostPath else { return }
        let manifest: [String: Any] = [
            "name": Brand.nativeMessagingHostName,
            "description": Brand.name,
            "path": hostPath,
            "type": "stdio",
            "allowed_origins": ["chrome-extension://cdhmompibjahkccghpbepifodgcallpi/"]
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted]) else { return }
        let dir = nativeHostManifestPath.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? data.write(to: nativeHostManifestPath)
    }
}

private extension String {
    var isVideo: Bool { ["mp4", "mkv", "webm", "mov", "m4v", "avi"].contains(self) }
    var isAudio: Bool { ["mp3", "m4a", "aac", "wav", "flac", "ogg"].contains(self) }
    var isDocument: Bool { ["pdf", "doc", "docx", "txt", "rtf", "csv", "xls", "xlsx", "ppt", "pptx"].contains(self) }
    var isApplication: Bool { ["dmg", "pkg", "app", "exe"].contains(self) }
    var isArchive: Bool { ["zip", "rar", "7z", "tar", "gz", "tgz"].contains(self) }
}
