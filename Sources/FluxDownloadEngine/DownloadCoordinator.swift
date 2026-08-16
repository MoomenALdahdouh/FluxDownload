import Foundation
import Network
import FluxDownloadCore
import FluxDownloadPersistence
import FluxDownloadMedia

public struct NewDownloadRequest: Sendable {
    public var url: URL
    public var filename: String?
    public var destination: URL?
    public var categoryID: UUID?
    public var queueID: UUID?
    public var priority: DownloadPriority
    public var connections: Int
    public var referrer: String?
    public var userAgent: String?
    public var headers: [String: String]
    public var cookieHeader: String?
    public var sourceBrowser: String?
    public var sourcePageURL: String?
    public var browserRequestID: String?
    public var startImmediately: Bool
    public var descriptionText: String?

    public init(
        url: URL,
        filename: String? = nil,
        destination: URL? = nil,
        categoryID: UUID? = nil,
        queueID: UUID? = nil,
        priority: DownloadPriority = .normal,
        connections: Int = 8,
        referrer: String? = nil,
        userAgent: String? = nil,
        headers: [String: String] = [:],
        cookieHeader: String? = nil,
        sourceBrowser: String? = nil,
        sourcePageURL: String? = nil,
        browserRequestID: String? = nil,
        startImmediately: Bool = true,
        descriptionText: String? = nil
    ) {
        self.url = url
        self.filename = filename
        self.destination = destination
        self.categoryID = categoryID
        self.queueID = queueID
        self.priority = priority
        self.connections = connections
        self.referrer = referrer
        self.userAgent = userAgent
        self.headers = headers
        self.cookieHeader = cookieHeader
        self.sourceBrowser = sourceBrowser
        self.sourcePageURL = sourcePageURL
        self.browserRequestID = browserRequestID
        self.startImmediately = startImmediately
        self.descriptionText = descriptionText
    }
}

public actor DownloadCoordinator {
    public let store: Store
    public let bandwidth: BandwidthManager
    private var settings: AppSettings
    private var session: URLSession
    private var running: [UUID: Task<Void, Never>] = [:]
    private var pauseFlags: [UUID: Bool] = [:]
    private var snapshots: [UUID: DownloadSnapshot] = [:]
    private var continuations: [UUID: AsyncStream<DownloadSnapshot>.Continuation] = [:]
    public var onChange: (@Sendable (DownloadSnapshot) -> Void)?
    public var onState: (@Sendable (DownloadRecord) -> Void)?
    private let pathMonitor = NWPathMonitor()
    private var networkAvailable = true
    private var maxConcurrent: Int

    public init(store: Store, settings: AppSettings) {
        self.store = store
        self.settings = settings
        self.maxConcurrent = settings.maxConcurrentDownloads
        self.bandwidth = BandwidthManager(globalLimit: settings.globalBandwidthLimit)
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = settings.requestTimeoutSeconds
        if settings.resourceTimeoutSeconds > 0 {
            config.timeoutIntervalForResource = settings.resourceTimeoutSeconds
        }
        config.httpMaximumConnectionsPerHost = settings.maxGlobalConnections
        config.waitsForConnectivity = true
        applyProxy(settings, to: config)
        self.session = URLSession(configuration: config)
        pathMonitor.pathUpdateHandler = { [weak self] path in
            Task { await self?.setNetworkAvailable(path.status == .satisfied) }
        }
        pathMonitor.start(queue: DispatchQueue(label: "flux.path"))
    }

    public func setHandlers(
        onChange: (@Sendable (DownloadSnapshot) -> Void)?,
        onState: (@Sendable (DownloadRecord) -> Void)?
    ) {
        self.onChange = onChange
        self.onState = onState
    }

    public func updateSettings(_ settings: AppSettings) {
        self.settings = settings
        self.maxConcurrent = settings.maxConcurrentDownloads
        Task { await bandwidth.setGlobalLimit(settings.globalBandwidthLimit) }
    }

    public func snapshotStream() -> AsyncStream<DownloadSnapshot> {
        AsyncStream { continuation in
            let id = UUID()
            continuations[id] = continuation
            continuation.onTermination = { _ in
                Task { await self.removeContinuation(id) }
            }
        }
    }

    public func currentSnapshots() async throws -> [DownloadSnapshot] {
        let records = try await store.allDownloads()
        var result: [DownloadSnapshot] = []
        for record in records {
            if let cached = snapshots[record.id] {
                result.append(cached)
            } else {
                let segments = try await store.segments(for: record.id)
                result.append(DownloadSnapshot(record: record, segments: segments))
            }
        }
        return result
    }

    public func add(_ request: NewDownloadRequest) async throws -> DownloadRecord {
        let normalized = URLValidator.normalized(request.url)
        if try await store.findDuplicate(normalizedURL: request.url.absoluteString, browserRequestID: request.browserRequestID) != nil {
            throw FluxError.duplicateDownload
        }
        if try await store.findDuplicate(normalizedURL: normalized, browserRequestID: request.browserRequestID) != nil {
            throw FluxError.duplicateDownload
        }
        let categories = try await store.allCategories()
        let queues = try await store.allQueues()
        let filename = try request.filename.map { try FilenameSanitizer.sanitize($0) } ?? FilenameSanitizer.fromURL(request.url)
        let ext = FilenameSanitizer.extension(from: filename)
        let category = request.categoryID.flatMap { id in categories.first(where: { $0.id == id }) }
            ?? BuiltInCategories.assign(filename: filename, mimeType: nil, host: request.url.host, categories: categories)
        let destination = request.destination
            ?? URL(fileURLWithPath: category?.destination ?? settings.defaultDownloadFolder, isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let queue = request.queueID.flatMap { id in queues.first(where: { $0.id == id }) } ?? queues.first
        var record = DownloadRecord(
            url: request.url.absoluteString,
            originalURL: request.url.absoluteString,
            filename: filename,
            fileExtension: ext,
            status: .queued,
            categoryID: category?.id,
            queueID: queue?.id,
            priority: request.priority,
            saveDirectory: destination.path,
            referrer: request.referrer,
            userAgent: request.userAgent ?? settings.userAgent,
            requestedConnections: min(max(1, request.connections), settings.maxConnectionsPerDownload),
            sourceBrowser: request.sourceBrowser,
            sourcePageURL: request.sourcePageURL,
            browserRequestID: request.browserRequestID,
            descriptionText: request.descriptionText
        )
        if !request.headers.isEmpty || !(request.cookieHeader ?? "").isEmpty {
            var headers = request.headers.filter { !Redactor.isSensitiveHeader($0.key) }
            if let cookie = request.cookieHeader, !cookie.isEmpty {
                headers["Cookie"] = cookie
            }
            if !headers.isEmpty {
                record.customHeadersJSON = String(data: try JSONEncoder().encode(headers), encoding: .utf8)
            }
        }
        try await store.upsertDownload(record)
        publish(DownloadSnapshot(record: record, segments: []))
        if request.startImmediately {
            pauseFlags[record.id] = false
            if running[record.id] == nil {
                startTask(record.id)
            }
            await schedule()
        }
        return record
    }

    public func start(_ id: UUID) async throws {
        guard var record = try await store.download(id: id) else { throw FluxError.downloadNotFound(id) }
        if record.status == .failed {
            record.status = try DownloadStateMachine.transition(from: .failed, to: .queued)
            try await store.upsertDownload(record)
        }
        pauseFlags[id] = false
        if running[id] == nil {
            startTask(id)
        }
        await schedule()
    }

    public func pause(_ id: UUID) async throws {
        guard var record = try await store.download(id: id) else { throw FluxError.downloadNotFound(id) }
        guard record.status.canPause, DownloadStateMachine.canTransition(from: record.status, to: .paused) else { return }
        pauseFlags[id] = true
        running[id]?.cancel()
        record.status = try DownloadStateMachine.transition(from: record.status, to: .paused)
        record.currentSpeed = 0
        try await store.upsertDownload(record)
        let segments = try await store.segments(for: id)
        publish(DownloadSnapshot(record: record, segments: segments))
    }

    public func pauseAll() async throws {
        let records = try await store.activeDownloads()
        for record in records where record.status.canPause {
            try await pause(record.id)
        }
    }

    public func resumeAll() async throws {
        let records = try await store.allDownloads()
        for record in records where record.status.canResume {
            try await start(record.id)
        }
    }

    public func cancel(_ id: UUID) async throws {
        pauseFlags[id] = true
        running[id]?.cancel()
        guard var record = try await store.download(id: id) else { throw FluxError.downloadNotFound(id) }
        if record.status.canCancel {
            record.status = try DownloadStateMachine.transition(from: record.status, to: .cancelled)
            record.currentSpeed = 0
            try await store.upsertDownload(record)
            if let path = record.temporaryPath {
                try? FileManager.default.removeItem(atPath: path)
            }
            publish(DownloadSnapshot(record: record, segments: []))
        }
    }

    public func retry(_ id: UUID) async throws {
        guard var record = try await store.download(id: id) else { throw FluxError.downloadNotFound(id) }
        record.status = try DownloadStateMachine.transition(from: record.status, to: .queued)
        record.errorMessage = nil
        record.errorCode = nil
        try await store.upsertDownload(record)
        pauseFlags[id] = false
        await schedule()
    }

    public func remove(_ id: UUID, deleteFile: Bool) async throws {
        running[id]?.cancel()
        if var record = try await store.download(id: id) {
            if record.status != .removed && DownloadStateMachine.canTransition(from: record.status, to: .removed) {
                record.status = .removed
            } else if record.status != .cancelled && record.status.canCancel {
                record.status = try DownloadStateMachine.transition(from: record.status, to: .cancelled)
                record.status = try DownloadStateMachine.transition(from: record.status, to: .removed)
            } else {
                record.status = .removed
            }
            try await store.upsertDownload(record)
            if deleteFile {
                if let path = record.finalPath { try? FileManager.default.removeItem(atPath: path) }
                if let path = record.temporaryPath { try? FileManager.default.removeItem(atPath: path) }
            }
        }
        try await store.deleteDownload(id: id)
        snapshots[id] = nil
    }

    public func recoverIncomplete(autoResume: Bool) async throws {
        let records = try await store.activeDownloads()
        for var record in records {
            if record.status.isActive {
                record.status = .paused
                record.currentSpeed = 0
                try await store.upsertDownload(record)
            }
            if autoResume {
                pauseFlags[record.id] = false
            }
        }
        if autoResume {
            await schedule()
        }
    }

    public func schedule() async {
        let records = (try? await store.allDownloads()) ?? []
        let activeCount = running.values.count
        let queued = records.filter { record in
            if running[record.id] != nil { return false }
            if pauseFlags[record.id] == true { return false }
            if record.status == .queued { return true }
            if record.status == .paused && pauseFlags[record.id] == false { return true }
            return false
        }
            .sorted {
                if $0.priority != $1.priority { return $0.priority.rawValue > $1.priority.rawValue }
                return $0.createdAt > $1.createdAt
            }
        let slots = max(0, maxConcurrent - activeCount)
        for record in queued.prefix(slots) {
            if running[record.id] != nil { continue }
            startTask(record.id)
        }
    }

    public func shutdown() async {
        for task in running.values { task.cancel() }
        running.removeAll()
        pathMonitor.cancel()
        session.invalidateAndCancel()
    }

    private func startTask(_ id: UUID) {
        running[id] = Task { [weak self] in
            await self?.run(id: id)
            await self?.finished(id)
        }
    }

    private func finished(_ id: UUID) async {
        running[id] = nil
        await schedule()
    }

    private func run(id: UUID) async {
        do {
            guard var record = try await store.download(id: id) else { return }
            if pauseFlags[id] == true { return }
            if record.status == .queued {
                record.status = try DownloadStateMachine.transition(from: .queued, to: .preparing)
                try await persist(record)
                record.status = try DownloadStateMachine.transition(from: .preparing, to: .connecting)
            } else if record.status == .paused {
                record.status = try DownloadStateMachine.transition(from: .paused, to: .connecting)
            } else if record.status == .retrying {
                record.status = try DownloadStateMachine.transition(from: .retrying, to: .connecting)
            } else if record.status == .failed {
                record.status = try DownloadStateMachine.transition(from: .failed, to: .queued)
                try await persist(record)
                record.status = try DownloadStateMachine.transition(from: .queued, to: .preparing)
                try await persist(record)
                record.status = try DownloadStateMachine.transition(from: .preparing, to: .connecting)
            }
            record.startedAt = record.startedAt ?? Date()
            try await persist(record)

            let url = try URLValidator.parse(record.finalURL ?? record.url)
            var headers: [String: String] = [:]
            if let json = record.customHeadersJSON, let data = json.data(using: .utf8) {
                headers = (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
            }
            let googlevideo = url.host?.localizedCaseInsensitiveContains("googlevideo") == true
            let linkedIn = HLSParser.isLinkedInHost(url)
            let capturedSegments = popSegmentURLs(from: &headers)
            if linkedIn {
                headers.removeValue(forKey: "Cookie")
                if headers["Accept"] == nil { headers["Accept"] = "*/*" }
                if headers["Accept-Language"] == nil { headers["Accept-Language"] = "en-US,en;q=0.9" }
            }
            let destinationDir: URL
            let temp: URL
            if googlevideo {
                if headers["Accept"] == nil { headers["Accept"] = "*/*" }
                if headers["Accept-Language"] == nil { headers["Accept-Language"] = "en-US,en;q=0.9" }
                destinationDir = URL(fileURLWithPath: record.saveDirectory, isDirectory: true)
                try FileManager.default.createDirectory(at: destinationDir, withIntermediateDirectories: true)
                temp = destinationDir.appendingPathComponent("\(record.filename).\(Brand.partialExtension)")
                record.temporaryPath = temp.path
                record.connectionCount = 1
                record.resumeSupported = false
                if let clen = youtubeQuery(url, "clen").flatMap(Int64.init), clen > 0 {
                    record.size = clen
                }
                record.status = try DownloadStateMachine.transition(from: .connecting, to: .downloading)
                try await persist(record)
                try await downloadSingle(record: &record, url: url, temp: temp, headers: headers, resume: false, omitRange: true)
                if record.downloadedBytes < 8192 {
                    throw FluxError.unsupportedMedia
                }
            } else if !capturedSegments.isEmpty || HLSParser.isLinkedInSegment(url) {
                let urls = capturedSegments.isEmpty ? [url] : capturedSegments
                destinationDir = URL(fileURLWithPath: record.saveDirectory, isDirectory: true)
                try FileManager.default.createDirectory(at: destinationDir, withIntermediateDirectories: true)
                let list = HLSSegmentList(segments: urls.map { HLSSegment(url: $0) })
                try await writeHLSSegments(record: &record, list: list, headers: headers, destinationDir: destinationDir)
                temp = URL(fileURLWithPath: record.temporaryPath ?? destinationDir.appendingPathComponent("\(record.filename).\(Brand.partialExtension)").path)
            } else if HLSParser.looksLikePlaylist(url: url, mimeType: record.mimeType) {
                destinationDir = URL(fileURLWithPath: record.saveDirectory, isDirectory: true)
                try FileManager.default.createDirectory(at: destinationDir, withIntermediateDirectories: true)
                try await downloadHLS(record: &record, url: url, headers: headers, destinationDir: destinationDir)
                temp = URL(fileURLWithPath: record.temporaryPath ?? destinationDir.appendingPathComponent("\(record.filename).\(Brand.partialExtension)").path)
            } else {
            let probe = ProbeClient(session: session, userAgent: record.userAgent ?? settings.userAgent, extraHeaders: headers)
            let meta = try await probe.probe(url: url, referrer: record.referrer)
            record.finalURL = meta.finalURL.absoluteString
            record.mimeType = meta.mimeType ?? record.mimeType
            record.serverName = meta.server
            record.resumeSupported = meta.acceptRanges
            if let name = meta.filename, record.filename == (try? FilenameSanitizer.fromURL(url)) {
                record.filename = name
                record.fileExtension = FilenameSanitizer.extension(from: name)
            }
            if record.size == nil { record.size = meta.size }
            if let size = record.size {
                try DiskSpace.ensureAvailable(at: URL(fileURLWithPath: record.saveDirectory), needed: size - record.downloadedBytes)
            }

            destinationDir = URL(fileURLWithPath: record.saveDirectory, isDirectory: true)
            try FileManager.default.createDirectory(at: destinationDir, withIntermediateDirectories: true)
            temp = destinationDir.appendingPathComponent("\(record.filename).\(Brand.partialExtension)")
            record.temporaryPath = temp.path
            record.status = try DownloadStateMachine.transition(from: .connecting, to: .downloading)
            try await persist(record)

            let useRange = meta.acceptRanges && (record.size ?? 0) >= 64 * 1024 && record.requestedConnections > 1
            if useRange, let size = record.size {
                try await downloadRanged(record: &record, url: meta.finalURL, size: size, temp: temp, headers: headers)
            } else {
                record.connectionCount = 1
                try await downloadSingle(record: &record, url: meta.finalURL, temp: temp, headers: headers, resume: record.downloadedBytes > 0 && (meta.acceptRanges || record.resumeSupported == true))
            }
            }

            if pauseFlags[id] == true { return }
            record.status = try DownloadStateMachine.transition(from: .downloading, to: .verifying)
            try await persist(record)
            let final = destinationDir.appendingPathComponent(record.filename)
            let uniqueName = FilenameSanitizer.uniquify(directory: destinationDir, filename: record.filename)
            let finalURL = destinationDir.appendingPathComponent(uniqueName)
            try PartialFile.finalize(temporary: temp, final: finalURL, expectedSize: record.size)
            record.filename = uniqueName
            record.finalPath = finalURL.path
            record.status = try DownloadStateMachine.transition(from: .verifying, to: .completed)
            record.completedAt = Date()
            record.currentSpeed = 0
            record.downloadedBytes = record.size ?? record.downloadedBytes
            try await persist(record)
            try await store.insertHistory(from: record)
            _ = final
        } catch is CancellationError {
            return
        } catch let error as FluxError {
            await fail(id: id, error: error)
        } catch {
            await fail(id: id, error: map(error))
        }
    }

    private func downloadRanged(record: inout DownloadRecord, url: URL, size: Int64, temp: URL, headers: [String: String]) async throws {
        let connections = max(1, min(record.requestedConnections, settings.maxConnectionsPerDownload, settings.maxGlobalConnections))
        record.connectionCount = connections
        var segments = try await store.segments(for: record.id)
        if segments.isEmpty || segments.reduce(Int64(0), { $0 + $1.length }) != size {
            let part = size / Int64(connections)
            segments = (0..<connections).map { index in
                let offset = Int64(index) * part
                let length = index == connections - 1 ? size - offset : part
                return DownloadSegment(downloadID: record.id, index: index, offset: offset, length: length)
            }
            try await store.replaceSegments(downloadID: record.id, segments: segments)
        }
        let fd = try PartialFile.create(at: temp, size: size)
        defer { PartialFile.syncAndClose(fd) }
        let downloader = SegmentDownloader(
            session: session,
            userAgent: record.userAgent ?? settings.userAgent,
            timeout: settings.requestTimeoutSeconds
        )
        let downloadID = record.id
        let referrer = record.referrer
        try await withThrowingTaskGroup(of: DownloadSegment.self) { group in
            for segment in segments where segment.status != .completed && segment.downloaded < segment.length {
                let copy = segment
                group.addTask {
                    var updated = copy
                    updated.status = .downloading
                    let written = try await downloader.download(
                        url: url,
                        offset: copy.offset,
                        length: copy.length,
                        resumeFrom: copy.downloaded,
                        referrer: referrer,
                        headers: headers,
                        fd: fd,
                        shouldCancel: { false },
                        onProgress: { _, _ in }
                    )
                    updated.downloaded = written
                    updated.status = .completed
                    updated.speed = 0
                    return updated
                }
            }
            for try await segment in group {
                if let idx = segments.firstIndex(where: { $0.id == segment.id }) {
                    segments[idx] = segment
                }
                try await store.upsertSegment(segment)
                await progress(recordID: downloadID, segment: segment)
            }
        }
        record.downloadedBytes = segments.reduce(0) { $0 + $1.downloaded }
        record.currentSpeed = 0
        try await persist(record, segments: segments)
    }

    private func downloadSingle(record: inout DownloadRecord, url: URL, temp: URL, headers: [String: String], resume: Bool, omitRange: Bool = false) async throws {
        let fd = try PartialFile.create(at: temp, size: record.size)
        defer { PartialFile.syncAndClose(fd) }
        let downloader = SegmentDownloader(
            session: session,
            userAgent: record.userAgent ?? settings.userAgent,
            timeout: settings.requestTimeoutSeconds
        )
        let id = record.id
        let written = try await downloader.download(
            url: url,
            offset: 0,
            length: omitRange ? nil : record.size,
            resumeFrom: resume ? record.downloadedBytes : 0,
            referrer: record.referrer,
            headers: headers,
            fd: fd,
            shouldCancel: { false },
            onProgress: { downloaded, speed in
                Task { await self.noteProgress(id: id, downloaded: downloaded, speed: speed) }
            }
        )
        record.downloadedBytes = written
        if record.size == nil { record.size = written }
    }

    private func downloadHLS(record: inout DownloadRecord, url: URL, headers: [String: String], destinationDir: URL) async throws {
        let userAgent = record.userAgent ?? settings.userAgent
        var playlistURL = HLSParser.normalizedPlaylistURL(url)
        var triedPlaylists = Set<String>()
        if HLSParser.isJunkLinkedInMedia(url) {
            throw FluxError.unsupportedMedia
        }
        var hops = 0
        while hops < 3 {
            hops += 1
            triedPlaylists.insert(playlistURL.absoluteString)
            let data: Data
            let response: HTTPURLResponse
            do {
                (data, response) = try await fetchBytes(url: playlistURL, headers: headers, referrer: record.referrer, userAgent: userAgent)
            } catch {
                if let next = playlistAlternates(from: HLSParser.normalizedPlaylistURL(url)).first(where: { !triedPlaylists.contains($0.absoluteString) }) {
                    playlistURL = next
                    continue
                }
                throw error
            }
            playlistURL = response.url ?? playlistURL
            if HLSParser.isPlaylistData(data) {
                let playlistText = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
                let list = try HLSParser.segmentList(playlistText, base: playlistURL)
                if list.isMaster {
                    let group = try HLSParser.parse(playlistText, base: playlistURL)
                    if group.isProtected { throw FluxError.protectedMedia }
                    guard let best = bestHLSVariant(group.representations) else {
                        throw FluxError.unsupportedMedia
                    }
                    playlistURL = best.url
                    continue
                }
                try await writeHLSSegments(record: &record, list: list, headers: headers, destinationDir: destinationDir)
                return
            }
            if isLikelyMediaFile(data) {
                ensureMediaFilename(&record, ext: mediaExtension(for: data, fallback: record.fileExtension))
                let temp = destinationDir.appendingPathComponent("\(record.filename).\(Brand.partialExtension)")
                record.temporaryPath = temp.path
                record.connectionCount = 1
                record.resumeSupported = false
                record.status = try DownloadStateMachine.transition(from: .connecting, to: .downloading)
                try await persist(record)
                try writeWholeFile(data, to: temp)
                record.downloadedBytes = Int64(data.count)
                record.size = Int64(data.count)
                try await persist(record)
                return
            }
            if let next = playlistAlternates(from: HLSParser.normalizedPlaylistURL(url)).first(where: { !triedPlaylists.contains($0.absoluteString) }) {
                playlistURL = next
                continue
            }
            throw FluxError.unsupportedMedia
        }
        throw FluxError.unsupportedMedia
    }

    private func popSegmentURLs(from headers: inout [String: String]) -> [URL] {
        let raw = headers.removeValue(forKey: "X-Flux-Segment-URLs")
            ?? headers.removeValue(forKey: "x-flux-segment-urls")
        guard let raw, let data = raw.data(using: .utf8),
              let strings = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return strings.compactMap { try? URLValidator.parse($0) }
    }

    private func playlistAlternates(from url: URL) -> [URL] {
        var result = [url]
        guard url.pathExtension.isEmpty else { return result }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.path = url.path + ".m3u8"
        if let next = components?.url { result.append(next) }
        components?.path = url.path + "/playlist.m3u8"
        if let next = components?.url { result.append(next) }
        return result
    }

    private func writeHLSSegments(
        record: inout DownloadRecord,
        list: HLSSegmentList,
        headers: [String: String],
        destinationDir: URL
    ) async throws {
        ensureMediaFilename(&record, ext: list.usesFMP4 || list.segments.contains(where: { HLSParser.isLinkedInHost($0.url) }) ? "mp4" : "ts")
        let temp = destinationDir.appendingPathComponent("\(record.filename).\(Brand.partialExtension)")
        record.temporaryPath = temp.path
        record.connectionCount = 1
        record.resumeSupported = false
        record.size = nil
        record.status = try DownloadStateMachine.transition(from: .connecting, to: .downloading)
        try await persist(record)

        let fd = try PartialFile.create(at: temp, size: nil)
        defer { PartialFile.syncAndClose(fd) }
        let downloader = SegmentDownloader(
            session: session,
            userAgent: record.userAgent ?? settings.userAgent,
            timeout: settings.requestTimeoutSeconds
        )
        let id = record.id
        let referrer = record.referrer
        var fileOffset: Int64 = 0
        var items: [(url: URL, range: (start: Int64, end: Int64)?)] = []
        if let mapURL = list.mapURL {
            let range: (start: Int64, end: Int64)?
            if let length = list.mapByteLength, length > 0 {
                let start = list.mapByteOffset ?? 0
                range = (start, start + length - 1)
            } else {
                range = nil
            }
            items.append((mapURL, range))
        }
        for segment in list.segments {
            let range: (start: Int64, end: Int64)?
            if let length = segment.byteLength, length > 0 {
                let start = segment.byteOffset ?? 0
                range = (start, start + length - 1)
            } else {
                range = nil
            }
            items.append((segment.url, range))
        }
        guard !items.isEmpty else { throw FluxError.unsupportedMedia }
        for (index, item) in items.enumerated() {
            if Task.isCancelled { throw CancellationError() }
            let baseOffset = fileOffset
            let written = try await downloader.download(
                url: item.url,
                offset: baseOffset,
                length: nil,
                resumeFrom: 0,
                referrer: referrer,
                headers: headers,
                fd: fd,
                shouldCancel: { Task.isCancelled },
                onProgress: { downloaded, speed in
                    Task { await self.noteProgress(id: id, downloaded: baseOffset + downloaded, speed: speed) }
                },
                httpRange: item.range
            )
            fileOffset += written
            record.downloadedBytes = fileOffset
            if index == items.count - 1 || index % 8 == 0 {
                try await persist(record)
            }
        }
        if ftruncate(fd, off_t(fileOffset)) != 0 {
            throw FluxError.filesystem("Could not set the assembled media file size.")
        }
        if fileOffset < 8192 {
            throw FluxError.unsupportedMedia
        }
        record.downloadedBytes = fileOffset
        record.size = fileOffset
        try await persist(record)
    }

    private func fetchBytes(url: URL, headers: [String: String], referrer: String?, userAgent: String) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.apple.mpegurl,application/x-mpegURL,*/*", forHTTPHeaderField: "Accept")
        if let referrer { request.setValue(referrer, forHTTPHeaderField: "Referer") }
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        request.timeoutInterval = settings.requestTimeoutSeconds
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw FluxError.networkUnavailable }
        if http.statusCode == 401 || http.statusCode == 403 { throw FluxError.accessDenied }
        if http.statusCode == 404 { throw FluxError.notFound }
        if http.statusCode == 429 { throw FluxError.rateLimited }
        if http.statusCode >= 500 { throw HTTPStatusMapper.error(for: http.statusCode) }
        if !(200...399).contains(http.statusCode) { throw HTTPStatusMapper.error(for: http.statusCode) }
        return (data, http)
    }

    private func writeWholeFile(_ data: Data, to url: URL) throws {
        let fd = try PartialFile.create(at: url, size: Int64(data.count))
        defer { PartialFile.syncAndClose(fd) }
        try PartialFile.write(fd: fd, data: data, offset: 0)
    }

    private func bestHLSVariant(_ representations: [MediaRepresentation]) -> MediaRepresentation? {
        representations
            .filter { !$0.isProtected }
            .max { left, right in
                if (left.height ?? 0) != (right.height ?? 0) {
                    return (left.height ?? 0) < (right.height ?? 0)
                }
                return (left.bandwidth ?? 0) < (right.bandwidth ?? 0)
            }
    }

    private func ensureMediaFilename(_ record: inout DownloadRecord, ext: String) {
        let current = record.fileExtension.lowercased()
        if current == ext { return }
        if current.isEmpty || ["m3u8", "m3u", "html", "htm", "txt"].contains(current) {
            record.filename = replaceFilenameExtension(record.filename, with: ext)
            record.fileExtension = ext
        }
    }

    private func replaceFilenameExtension(_ filename: String, with ext: String) -> String {
        let ns = filename as NSString
        let base = ns.deletingPathExtension
        let stem = base.isEmpty ? "download" : base
        return "\(stem).\(ext)"
    }

    private func mediaExtension(for data: Data, fallback: String) -> String {
        if data.count >= 12, data.subdata(in: 4..<8) == Data("ftyp".utf8) { return "mp4" }
        if data.starts(with: [0x1A, 0x45, 0xDF, 0xA3]) { return "webm" }
        if data.starts(with: Data("ID3".utf8)) || data.starts(with: [0xFF, 0xFB]) { return "mp3" }
        let current = fallback.lowercased()
        if !current.isEmpty && current != "m3u8" && current != "m3u" { return current }
        return "mp4"
    }

    private func isLikelyMediaFile(_ data: Data) -> Bool {
        if let head = String(data: data.prefix(80), encoding: .utf8)?.lowercased() {
            if head.contains("<html") || head.contains("<!doctype") || head.hasPrefix("{") { return false }
        }
        if data.count >= 12, data.subdata(in: 4..<8) == Data("ftyp".utf8) { return true }
        if data.starts(with: [0x1A, 0x45, 0xDF, 0xA3]) { return true }
        if data.starts(with: Data("ID3".utf8)) { return true }
        return data.count > 64 * 1024
    }

    private func noteProgress(id: UUID, downloaded: Int64, speed: Int64) async {
        guard var snap = snapshots[id] else { return }
        snap.record.downloadedBytes = downloaded
        snap.record.currentSpeed = speed
        snap.record.peakSpeed = max(snap.record.peakSpeed, speed)
        snapshots[id] = snap
        publish(snap)
    }

    private func persist(_ record: DownloadRecord, segments: [DownloadSegment] = []) async throws {
        try await store.upsertDownload(record)
        publish(DownloadSnapshot(record: record, segments: segments))
    }

    private func progress(recordID: UUID, segment: DownloadSegment) async {
        guard var snap = snapshots[recordID] else { return }
        if let idx = snap.segments.firstIndex(where: { $0.id == segment.id }) {
            snap.segments[idx] = segment
        } else {
            snap.segments.append(segment)
        }
        snap.record.downloadedBytes = snap.segments.reduce(0) { $0 + $1.downloaded }
        snap.record.currentSpeed = snap.segments.reduce(0) { $0 + $1.speed }
        snap.record.peakSpeed = max(snap.record.peakSpeed, snap.record.currentSpeed)
        snapshots[recordID] = snap
        publish(snap)
        try? await store.upsertDownload(snap.record)
        try? await store.upsertSegment(segment)
    }

    private func fail(id: UUID, error: FluxError) async {
        guard var record = try? await store.download(id: id) else { return }
        record.retryCount += 1
        record.errorMessage = error.userMessage
        record.errorCode = error.diagnosticDetail
        record.currentSpeed = 0
        if error.isRetryable, record.retryCount <= settings.retryLimit, pauseFlags[id] != true {
            if DownloadStateMachine.canTransition(from: record.status, to: .retrying) {
                record.status = .retrying
            }
            try? await store.upsertDownload(record)
            publish(DownloadSnapshot(record: record, segments: []))
            let delay = RetryPolicy.delay(forAttempt: record.retryCount)
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            if pauseFlags[id] != true {
                if DownloadStateMachine.canTransition(from: record.status, to: .connecting) {
                    record.status = .connecting
                } else if DownloadStateMachine.canTransition(from: record.status, to: .queued) {
                    record.status = .queued
                }
                try? await store.upsertDownload(record)
            }
        } else {
            if DownloadStateMachine.canTransition(from: record.status, to: .failed) {
                record.status = .failed
            } else {
                record.status = .failed
            }
            try? await store.upsertDownload(record)
            publish(DownloadSnapshot(record: record, segments: []))
        }
    }

    private func map(_ error: Error) -> FluxError {
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain {
            switch ns.code {
            case NSURLErrorTimedOut: return .timeout
            case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost: return .networkUnavailable
            case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed: return .dnsFailure
            case NSURLErrorCancelled: return .cancelled
            default: return .connectionReset
            }
        }
        return .filesystem(error.localizedDescription)
    }

    private func publish(_ snapshot: DownloadSnapshot) {
        snapshots[snapshot.id] = snapshot
        onChange?(snapshot)
        onState?(snapshot.record)
        for continuation in continuations.values {
            continuation.yield(snapshot)
        }
    }

    private func removeContinuation(_ id: UUID) {
        continuations[id] = nil
    }

    private func setNetworkAvailable(_ available: Bool) {
        let restored = !networkAvailable && available
        networkAvailable = available
        if restored {
            Task { await schedule() }
        }
    }
}

private func youtubeQuery(_ url: URL, _ name: String) -> String? {
    URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == name })?.value
}

private func applyProxy(_ settings: AppSettings, to config: URLSessionConfiguration) {
    switch settings.proxyMode {
    case .none:
        config.connectionProxyDictionary = [:]
    case .system:
        break
    case .http:
        guard let host = settings.proxyHost, let port = settings.proxyPort else { return }
        config.connectionProxyDictionary = [
            kCFNetworkProxiesHTTPEnable: true,
            kCFNetworkProxiesHTTPProxy: host,
            kCFNetworkProxiesHTTPPort: port,
            kCFNetworkProxiesHTTPSEnable: true,
            kCFNetworkProxiesHTTPSProxy: host,
            kCFNetworkProxiesHTTPSPort: port
        ]
    case .socks:
        guard let host = settings.proxyHost, let port = settings.proxyPort else { return }
        config.connectionProxyDictionary = [
            kCFNetworkProxiesSOCKSEnable: true,
            kCFNetworkProxiesSOCKSProxy: host,
            kCFNetworkProxiesSOCKSPort: port
        ]
    }
}
