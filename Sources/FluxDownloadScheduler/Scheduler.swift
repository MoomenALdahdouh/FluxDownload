import Foundation
import FluxDownloadCore
import FluxDownloadPersistence
import FluxDownloadEngine

public actor QueueManager {
    private let store: Store
    private let coordinator: DownloadCoordinator

    public init(store: Store, coordinator: DownloadCoordinator) {
        self.store = store
        self.coordinator = coordinator
    }

    public func create(_ queue: DownloadQueue) async throws {
        try await store.upsertQueue(queue)
    }

    public func update(_ queue: DownloadQueue) async throws {
        try await store.upsertQueue(queue)
        await coordinator.bandwidth.setQueueLimit(queue.id, queue.bandwidthLimitBytesPerSecond)
        if queue.isActive {
            await coordinator.schedule()
        }
    }

    public func start(_ id: UUID) async throws {
        guard var queue = try await store.allQueues().first(where: { $0.id == id }) else {
            throw FluxError.queueNotFound(id)
        }
        queue.isActive = true
        try await store.upsertQueue(queue)
        await coordinator.schedule()
    }

    public func stop(_ id: UUID) async throws {
        guard var queue = try await store.allQueues().first(where: { $0.id == id }) else {
            throw FluxError.queueNotFound(id)
        }
        queue.isActive = false
        try await store.upsertQueue(queue)
        let downloads = try await store.allDownloads()
        for download in downloads where download.queueID == id && download.status.canPause {
            try await coordinator.pause(download.id)
        }
    }

    public func assign(downloadID: UUID, queueID: UUID) async throws {
        guard var record = try await store.download(id: downloadID) else { throw FluxError.downloadNotFound(downloadID) }
        record.queueID = queueID
        try await store.upsertDownload(record)
    }
}

public actor SchedulerEngine {
    private let store: Store
    private let queues: QueueManager
    private var task: Task<Void, Never>?
    private var lastActive: [UUID: Bool] = [:]

    public init(store: Store, queues: QueueManager) {
        self.store = store
        self.queues = queues
    }

    public func start() {
        task?.cancel()
        task = Task { await loop() }
    }

    public func stop() {
        task?.cancel()
        task = nil
    }

    private func loop() async {
        while !Task.isCancelled {
            await tick()
            try? await Task.sleep(nanoseconds: 15_000_000_000)
        }
    }

    public func tick(now: Date = Date()) async {
        let schedules = (try? await store.allSchedules()) ?? []
        for schedule in schedules {
            let active = schedule.isActive(at: now)
            let was = lastActive[schedule.id] ?? false
            lastActive[schedule.id] = active
            guard let queueID = schedule.queueID else { continue }
            if active && !was {
                try? await queues.start(queueID)
            } else if !active && was {
                try? await queues.stop(queueID)
            } else if active {
                try? await queues.start(queueID)
            }
        }
    }
}
