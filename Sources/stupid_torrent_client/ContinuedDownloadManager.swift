#if os(iOS)
import BackgroundTasks
import Foundation
import OSLog
import TorrentCore

fileprivate final class ContinuedDownloadTaskBox: @unchecked Sendable {
    let task: BGContinuedProcessingTask

    init(_ task: BGContinuedProcessingTask) {
        self.task = task
    }
}

private func continuedDownloadLaunchHandler(
    manager: ContinuedDownloadManager,
    identifier: String
) -> @Sendable (BGTask) -> Void {
    { task in
        guard let continuedTask = task as? BGContinuedProcessingTask else {
            task.setTaskCompleted(success: false)
            return
        }
        continuedTask.progress.totalUnitCount = 1_000
        continuedTask.progress.completedUnitCount = 1
        continuedTask.expirationHandler = continuedDownloadExpirationHandler(
            manager: manager,
            identifier: identifier
        )
        let taskBox = ContinuedDownloadTaskBox(continuedTask)
        Task { await manager.begin(taskBox: taskBox, identifier: identifier) }
    }
}

private func continuedDownloadExpirationHandler(
    manager: ContinuedDownloadManager,
    identifier: String
) -> @Sendable () -> Void {
    {
        Task { await manager.expire(identifier: identifier) }
    }
}

actor ContinuedDownloadManager {
    static let shared = ContinuedDownloadManager()

    private struct Download: Sendable {
        let torrent: Torrent
        let metainfo: Metainfo
    }

    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.stupidtech.stupid-torrent-client",
        category: "BackgroundDownload"
    )
    private var downloads: [String: Download] = [:]
    private var registeredIdentifiers: Set<String> = []
    private var activeTasks: [String: ContinuedDownloadTaskBox] = [:]
    private var monitorTasks: [String: Task<Void, Never>] = [:]

    func track(torrent: Torrent, submit: Bool) {
        let metainfo = torrent.metainfo
        let identifier = taskIdentifier(for: metainfo)
        downloads[identifier] = Download(torrent: torrent, metainfo: metainfo)

        guard register(identifier: identifier) else { return }
        guard submit else { return }

        let request = BGContinuedProcessingTaskRequest(
            identifier: identifier,
            title: metainfo.displayName,
            subtitle: "Preparing download"
        )
        request.strategy = .queue

        do {
            try BGTaskScheduler.shared.submit(request)
            logger.info(
                "Submitted continued download task for \(metainfo.infoHash.hexString, privacy: .public)")
        } catch {
            logger.error(
                "Could not submit continued download task: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    func cancel(torrent: Torrent) {
        let identifier = taskIdentifier(for: torrent.metainfo)
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
        finish(identifier: identifier, success: false)
        downloads.removeValue(forKey: identifier)
    }

    private func register(identifier: String) -> Bool {
        if registeredIdentifiers.contains(identifier) { return true }

        let didRegister = BGTaskScheduler.shared.register(
            forTaskWithIdentifier: identifier,
            using: nil,
            launchHandler: continuedDownloadLaunchHandler(manager: self, identifier: identifier)
        )

        if didRegister {
            registeredIdentifiers.insert(identifier)
        } else {
            logger.error("Could not register continued download task \(identifier, privacy: .public)")
        }
        return didRegister
    }

    fileprivate func begin(taskBox: ContinuedDownloadTaskBox, identifier: String) {
        guard let download = downloads[identifier], activeTasks[identifier] == nil else {
            taskBox.task.setTaskCompleted(success: false)
            return
        }

        activeTasks[identifier] = taskBox
        let totalBytes = max(Int64(download.metainfo.totalLength), 1)
        taskBox.task.progress.totalUnitCount = totalBytes

        monitorTasks[identifier] = Task { [self] in
            for await status in await download.torrent.statusBroadcast.subscribe() {
                guard !Task.isCancelled else { return }
                await self.consume(status: status, identifier: identifier)
            }
        }
        logger.info(
            "Started continued download task for \(download.metainfo.infoHash.hexString, privacy: .public)"
        )
    }

    private func consume(status: TorrentStatus, identifier: String) {
        guard let taskBox = activeTasks[identifier], let download = downloads[identifier] else {
            return
        }

        let completedBytes = download.metainfo.verifiedByteCount(pieceCount: status.verifiedCount)
        taskBox.task.progress.completedUnitCount = completedBytes
        let percent = Int(
            (Double(completedBytes) / Double(taskBox.task.progress.totalUnitCount)) * 100)
        let subtitle =
            if status.downloadRate > 0 {
                "\(percent)% - \(formattedRate(status.downloadRate))"
            } else {
                "\(percent)% downloaded"
            }
        taskBox.task.updateTitle(download.metainfo.displayName, subtitle: subtitle)

        if status.isComplete {
            finish(identifier: identifier, success: true)
            downloads.removeValue(forKey: identifier)
        } else if status.state == .paused {
            finish(identifier: identifier, success: false)
            downloads.removeValue(forKey: identifier)
        } else if case .error = status.state {
            finish(identifier: identifier, success: false)
            downloads.removeValue(forKey: identifier)
        }
    }

    fileprivate func expire(identifier: String) async {
        guard let download = downloads[identifier] else {
            finish(identifier: identifier, success: false)
            return
        }
        await download.torrent.pause()
        finish(identifier: identifier, success: false)
        downloads.removeValue(forKey: identifier)
        logger.info(
            "Expired continued download task for \(download.metainfo.infoHash.hexString, privacy: .public)"
        )
    }

    private func finish(identifier: String, success: Bool) {
        monitorTasks.removeValue(forKey: identifier)?.cancel()
        guard let taskBox = activeTasks.removeValue(forKey: identifier) else { return }
        taskBox.task.expirationHandler = nil
        taskBox.task.setTaskCompleted(success: success)
    }

    private func taskIdentifier(for metainfo: Metainfo) -> String {
        let bundleIdentifier = Bundle.main.bundleIdentifier ?? "com.stupidtech.stupid-torrent-client"
        return "\(bundleIdentifier).download.\(metainfo.infoHash.hexString)"
    }

    private func formattedRate(_ bytesPerSecond: Double) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return "\(formatter.string(fromByteCount: Int64(bytesPerSecond)))/s"
    }
}
#endif
