import Foundation

/// Watches one path for changes, and keeps working when an editor replaces the file rather
/// than writing into it — which is what vim, and anything using an atomic save, actually does.
public final class FileWatcher: @unchecked Sendable {
    private let url: URL
    private let debounce: Double
    private let onChange: @Sendable () -> Void
    private let queue = DispatchQueue(label: "zip.tanner.bario.filewatcher")
    private let lock = NSLock()
    private var fileSource: DispatchSourceFileSystemObject?
    private var directorySource: DispatchSourceFileSystemObject?
    private var pending: DispatchWorkItem?
    private var lastStamp: (Date, UInt64)?
    private var stopped = false

    public init(url: URL, debounce: Double = 0.12, onChange: @escaping @Sendable () -> Void) {
        self.url = url
        self.debounce = debounce
        self.onChange = onChange
        lastStamp = FileWatcher.stamp(of: url)
        arm()
    }

    deinit {
        fileSource?.cancel()
        directorySource?.cancel()
    }

    public func stop() {
        lock.lock(); defer { lock.unlock() }
        stopped = true
        pending?.cancel()
        fileSource?.cancel()
        directorySource?.cancel()
        fileSource = nil
        directorySource = nil
    }

    private func arm() {
        lock.lock(); defer { lock.unlock() }
        armFile()
        armDirectory()
    }

    private func armFile() {
        fileSource?.cancel()
        fileSource = nil
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return }               // not there yet; the directory watch covers it
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .rename, .delete, .extend, .attrib], queue: queue)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let events = source.data
            self.schedule()
            // The file we were holding is gone; follow the new one at the same path.
            if events.contains(.rename) || events.contains(.delete) {
                self.queue.asyncAfter(deadline: .now() + 0.05) { self.rearmFile() }
            }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        fileSource = source
    }

    private func rearmFile() {
        lock.lock(); defer { lock.unlock() }
        guard !stopped else { return }
        armFile()
    }

    /// Re-arm after a directory event: the file may be new, and a directory closer to it may have
    /// just been created, in which case the watch moves down to it.
    private func rearm(watching directory: URL) {
        lock.lock(); defer { lock.unlock() }
        guard !stopped else { return }
        armFile()
        if FileWatcher.nearestExistingDirectory(of: url) != directory { armDirectory() }
    }

    /// The directory catches a file appearing for the first time, and an atomic replace. When the
    /// file's own directory is not there either, the nearest ancestor that *is* stands in for it,
    /// and its first event re-arms onto whatever now exists furthest down — so the watch follows
    /// `~/.config/bario` into being, which is what a first run actually does. Standing in higher
    /// up is noisier, but `schedule()` still only reports a file whose stamp moved.
    private func armDirectory() {
        directorySource?.cancel()
        directorySource = nil
        guard let directory = FileWatcher.nearestExistingDirectory(of: url) else { return }
        let fd = open(directory.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: queue)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            self.rearm(watching: directory)
            self.schedule()
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        directorySource = source
    }

    /// The nearest directory at or above the file's own that exists right now, or nil if even the
    /// root is gone — which cannot happen, but the walk needs a floor to stop at.
    private static func nearestExistingDirectory(of url: URL) -> URL? {
        var directory = url.deletingLastPathComponent()
        while true {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
               isDirectory.boolValue { return directory }
            let parent = directory.deletingLastPathComponent()
            guard parent.path != directory.path else { return nil }
            directory = parent
        }
    }

    /// Debounce, and then only report a change if the file really changed: a directory write
    /// fires for every sibling too.
    private func schedule() {
        lock.lock(); defer { lock.unlock() }
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let now = FileWatcher.stamp(of: self.url)
            self.lock.lock()
            let changed = now?.0 != self.lastStamp?.0 || now?.1 != self.lastStamp?.1
            self.lastStamp = now
            self.lock.unlock()
            if changed { self.onChange() }
        }
        pending = work
        queue.asyncAfter(deadline: .now() + debounce, execute: work)
    }

    private static func stamp(of url: URL) -> (Date, UInt64)? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        let date = attributes[.modificationDate] as? Date ?? .distantPast
        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        return (date, size)
    }
}
