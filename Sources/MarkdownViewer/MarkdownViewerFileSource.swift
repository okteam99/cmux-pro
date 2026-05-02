import Combine
import Foundation

/// File content source for the Markdown viewer window. Owns a
/// DispatchSource-backed watcher, atomic-save reattach, encoding fallback,
/// and 10MB truncation. Implemented independently of MarkdownPanel to honour
/// the "tab version frozen" decision (PRD §1.3).
@MainActor
final class MarkdownViewerFileSource: ObservableObject {
    /// Hard cap on bytes read from disk; files beyond this are truncated and
    /// `isTruncated` is set so the UI can surface a banner (AC-21).
    static let maxBytes: Int = 10 * 1024 * 1024

    /// Absolute path to the file being displayed.
    let filePath: String

    /// Current decoded markdown content. Empty string until the first load
    /// completes or when the file is unavailable.
    @Published private(set) var content: String = ""

    /// True when the file cannot be read (deleted, permission denied, or
    /// every encoding fallback exhausted).
    @Published private(set) var isFileUnavailable: Bool = false

    /// True when the file exceeds `maxBytes` and has been truncated in
    /// memory. Exposed so the UI can show the AC-21 banner.
    @Published private(set) var isTruncated: Bool = false

    /// Monotonic counter incremented every time `content` is refreshed. Lets
    /// observers detect "the file changed on disk" without diffing strings.
    @Published private(set) var reloadToken: Int = 0

    // MARK: - Private

    private nonisolated(unsafe) var watchSource: DispatchSourceFileSystemObject?
    private var fileDescriptor: Int32 = -1
    private var isClosed: Bool = false
    private let watchQueue = DispatchQueue(
        label: "com.cmux.markdownViewer.fileWatch",
        qos: .utility
    )

    /// Maximum number of reattach attempts after a delete/rename event. Six
    /// attempts × 0.5s = 3 seconds, which covers vim's `:w` rename-then-create
    /// pattern and atomic editor saves.
    private static let maxReattachAttempts = 6
    private static let reattachDelay: TimeInterval = 0.5

    init(filePath: String) {
        self.filePath = filePath
        load()
        startWatcher()
        if isFileUnavailable && watchSource == nil {
            scheduleReattach(attempt: 1)
        }
    }

    func close() {
        isClosed = true
        stopWatcher()
    }

    deinit {
        watchSource?.cancel()
    }

    // MARK: - Loading

    /// Read the file into `content`, applying UTF-8 → ISO-Latin-1 fallback
    /// and 10MB truncation. Updates publishers atomically.
    private func load() {
        guard let fh = FileHandle(forReadingAtPath: filePath) else {
            content = ""
            isFileUnavailable = true
            isTruncated = false
            reloadToken &+= 1
            return
        }
        defer { try? fh.close() }

        let data: Data
        do {
            // Cap the read at maxBytes + 1 so we can tell "truncated" from
            // "fits exactly".
            let raw: Data
            if #available(macOS 10.15.4, *) {
                raw = try fh.read(upToCount: Self.maxBytes + 1) ?? Data()
            } else {
                raw = fh.readData(ofLength: Self.maxBytes + 1)
            }
            data = raw
        } catch {
            content = ""
            isFileUnavailable = true
            isTruncated = false
            reloadToken &+= 1
            return
        }

        let truncated = data.count > Self.maxBytes
        let usable = truncated ? data.prefix(Self.maxBytes) : data[...]

        let decoded: String? =
            Self.decodeUTF8Safely(Data(usable))
            ?? String(data: Data(usable), encoding: .isoLatin1)

        if let decoded {
            content = decoded
            isFileUnavailable = false
            isTruncated = truncated
        } else {
            content = ""
            isFileUnavailable = true
            isTruncated = false
        }
        reloadToken &+= 1
    }

    /// Decode `data` as UTF-8, trimming any trailing partial code point
    /// caused by our byte-count truncation. Returns nil when the data is
    /// non-UTF-8 even after trimming, so callers can fall back to another
    /// encoding.
    private static func decodeUTF8Safely(_ data: Data) -> String? {
        if let direct = String(data: data, encoding: .utf8) {
            return direct
        }
        // Truncation may have cut a UTF-8 sequence mid-byte; peel up to 3
        // trailing bytes and retry once.
        let maxPeel = min(3, data.count)
        for peel in 1...maxPeel {
            let trimmed = data.dropLast(peel)
            if let decoded = String(data: trimmed, encoding: .utf8) {
                return decoded
            }
        }
        return nil
    }

    // MARK: - Watcher

    private func startWatcher() {
        let fd = open(filePath, O_EVTONLY)
        guard fd >= 0 else { return }
        fileDescriptor = fd

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .rename, .extend],
            queue: watchQueue
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let flags = source.data
            if flags.contains(.delete) || flags.contains(.rename) {
                DispatchQueue.main.async {
                    self.stopWatcher()
                    self.load()
                    if self.isFileUnavailable {
                        self.scheduleReattach(attempt: 1)
                    } else {
                        self.startWatcher()
                    }
                }
            } else {
                DispatchQueue.main.async {
                    self.load()
                }
            }
        }
        source.setCancelHandler {
            Darwin.close(fd)
        }
        source.resume()
        watchSource = source
    }

    private func scheduleReattach(attempt: Int) {
        guard attempt <= Self.maxReattachAttempts, !isClosed else { return }
        watchQueue.asyncAfter(deadline: .now() + Self.reattachDelay) { [weak self] in
            guard let self else { return }
            DispatchQueue.main.async {
                guard !self.isClosed else { return }
                if FileManager.default.fileExists(atPath: self.filePath) {
                    self.load()
                    self.startWatcher()
                } else {
                    self.scheduleReattach(attempt: attempt + 1)
                }
            }
        }
    }

    private func stopWatcher() {
        if let source = watchSource {
            source.cancel()
            watchSource = nil
        }
        fileDescriptor = -1
    }
}
