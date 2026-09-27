import CoreServices
import Foundation
import OSLog

public final class DownloadMonitor {
    public enum State {
        case watching
        case cleared(String)
        case problem(String)
    }

    private final class EventContext {
        weak var monitor: DownloadMonitor?
        init(_ monitor: DownloadMonitor) { self.monitor = monitor }
    }

    private let inspector: DownloadInspector
    private let queue = DispatchQueue(label: "me.tonsky.Unquarantine.downloads", qos: .utility)
    private let logger = Logger(subsystem: "me.tonsky.Unquarantine", category: "Downloads")
    private let onStateChange: (State) -> Void
    private var stream: FSEventStreamRef?
    private var retryTimer: DispatchSourceTimer?
    private var pending: Set<URL> = []
    private var processingScheduled = false
    private var running = false
    private var previousError: String?
    private var startedAt: TimeInterval = 0
    private let notificationLock = NSLock()
    private var notificationGeneration = 0

    public init(folder: URL, onStateChange: @escaping (State) -> Void) {
        inspector = DownloadInspector(folder: folder)
        self.onStateChange = onStateChange
    }

    deinit {
        retryTimer?.cancel()
        releaseEventStream()
    }

    public func start() {
        queue.async { [self] in
            guard !running else { return }
            do {
                try inspector.checkFolderAccess()
                startedAt = Date().timeIntervalSince1970
                try startEventStream()
                running = true
                previousError = nil
                publish(.watching)
            } catch { report(error.localizedDescription) }
        }
    }

    public func stop() {
        queue.sync {
            running = false
            notificationLock.withLock { notificationGeneration &+= 1 }
            retryTimer?.cancel()
            retryTimer = nil
            pending.removeAll()
            processingScheduled = false
            releaseEventStream()
        }
    }

    private func releaseEventStream() {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
    }

    private func startEventStream() throws {
        let owner = EventContext(self)
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(owner).toOpaque(),
            retain: { info in
                guard let info else { return nil }
                _ = Unmanaged<EventContext>.fromOpaque(info).retain()
                return info
            },
            release: { info in
                if let info { Unmanaged<EventContext>.fromOpaque(info).release() }
            }, copyDescription: nil
        )
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot |
            kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer
        )
        guard let stream = FSEventStreamCreate(
            nil,
            { _, info, count, paths, flags, _ in
                guard let info,
                      let monitor = Unmanaged<EventContext>.fromOpaque(info).takeUnretainedValue().monitor else { return }
                let paths = unsafeBitCast(paths, to: NSArray.self) as! [String]
                for index in 0..<count {
                    monitor.receive(path: paths[index], flags: flags[index])
                }
                monitor.scheduleProcessing()
            },
            &context, [inspector.folder.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.25, flags
        ) else { throw watcherError() }
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            throw watcherError()
        }
        self.stream = stream
    }

    private func receive(path: String, flags: FSEventStreamEventFlags) {
        guard running else { return }
        if flags & FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged) != 0 {
            report("Downloads moved or became unavailable. Restart Unquarantine after restoring the folder.")
        }
        if flags & FSEventStreamEventFlags(kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped) != 0 {
            report("Filesystem events were dropped. Affected downloads will be checked when they change again.")
        }
        let partialRemoved = flags & FSEventStreamEventFlags(
            kFSEventStreamEventFlagItemRemoved | kFSEventStreamEventFlagItemRenamed
        ) != 0
        if let url = inspector.candidate(forEventAt: URL(fileURLWithPath: path), partialRemoved: partialRemoved) {
            do {
                if try inspector.changed(URL(fileURLWithPath: path), since: startedAt) {
                    pending.insert(url)
                }
            } catch { report(error.localizedDescription) }
        }
        // Directory-only/coalesced events never trigger recursive recovery scans.
    }

    private func scheduleProcessing() {
        guard running, !pending.isEmpty, !processingScheduled else { return }
        processingScheduled = true
        queue.async { [weak self] in
            self?.processingScheduled = false
            self?.processPending()
        }
    }

    private func processPending() {
        retryTimer?.cancel()
        retryTimer = nil
        guard running, !pending.isEmpty else { return }
        let candidates = pending
        pending.removeAll()
        var files: [DownloadTarget] = []
        for url in candidates {
            do {
                guard let target = try inspector.inspect(url) else { continue }
                if target.isApp {
                    // The directory's attribute can be cleared during extraction.
                    // Later events handle quarantine being reapplied to the root.
                    try clear(target)
                } else {
                    files.append(target)
                }
            } catch { report(error.localizedDescription) }
        }
        if !files.isEmpty {
            do {
                let busy = try QuarantineRemover.openFiles(files)
                for file in files {
                    do {
                        guard let current = try inspector.inspect(file.url) else { continue }
                        if busy.contains(file.identity) || current != file {
                            pending.insert(file.url)
                        } else {
                            try clear(current)
                        }
                    } catch { report(error.localizedDescription) }
                }
            } catch {
                // Command/permission errors wait for another filesystem event;
                // they must not create an endless background retry loop.
                report(error.localizedDescription)
            }
        }
        guard !pending.isEmpty else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .milliseconds(250), leeway: .milliseconds(25))
        timer.setEventHandler { [weak self] in self?.processPending() }
        retryTimer = timer
        timer.resume()
    }

    private func clear(_ target: DownloadTarget) throws {
        // Check the path again before touching it, including symlink ancestors.
        guard let current = try inspector.inspect(target.url) else { return }
        guard current.identity == target.identity,
              target.isApp || current == target else {
            pending.insert(target.url)
            return
        }
        try QuarantineRemover.remove(from: target.url)
        previousError = nil
        logger.info("Cleared quarantine: \(target.url.path, privacy: .private)")
        publish(.cleared(target.url.lastPathComponent))
    }

    private func watcherError() -> NSError {
        NSError(domain: "Unquarantine", code: 2, userInfo: [
            NSLocalizedDescriptionKey: "Could not start filesystem monitoring. Restart Unquarantine to try again.",
        ])
    }

    private func report(_ message: String) {
        guard message != previousError else { return }
        previousError = message
        logger.error("\(message, privacy: .public)")
        publish(.problem(message))
    }

    private func publish(_ state: State) {
        let generation = notificationLock.withLock { notificationGeneration }
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  self.notificationLock.withLock({ self.notificationGeneration == generation }) else { return }
            self.onStateChange(state)
        }
    }
}
