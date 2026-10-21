import Foundation

/// Calls `onChange` when entries are added to, removed from, or renamed in a directory.
public final class DirectoryWatcher {
    private let source: DispatchSourceFileSystemObject

    public init?(url: URL, queue: DispatchQueue = .main, onChange: @escaping () -> Void) {
        let descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else { return nil }
        source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .delete, .rename, .link],
            queue: queue
        )
        source.setEventHandler(handler: onChange)
        source.setCancelHandler { close(descriptor) }
        source.resume()
    }

    deinit {
        source.cancel()
    }
}
