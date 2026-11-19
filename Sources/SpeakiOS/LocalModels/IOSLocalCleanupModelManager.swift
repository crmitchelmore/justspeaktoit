#if os(iOS)
import Foundation
import SpeakCore

/// Settings' view of the downloaded cleanup models: the models this device is
/// offered, each with its download state, plus download, cancel and remove.
@MainActor
public final class IOSLocalCleanupModelManager: ObservableObject {
    public static let shared = IOSLocalCleanupModelManager()

    @Published public private(set) var states: [String: IOSLocalModelInstallState] = [:]

    private let root: URL
    private let physicalMemory: UInt64
    private let engineProvider: () -> IOSLocalCleanupEngine?
    private let downloader: IOSPinnedFileDownloading
    private let freeSpaceBytes: () -> Int64?
    private var downloads: [String: Task<Void, Never>] = [:]

    public init(
        root: URL = IOSLocalModelsDirectory.root(),
        physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory,
        engine: @escaping () -> IOSLocalCleanupEngine? = { IOSLocalCleanupEngines.current },
        downloader: IOSPinnedFileDownloading = IOSPinnedFileDownloader(),
        freeSpaceBytes: @escaping () -> Int64? = { nil }
    ) {
        self.root = root
        self.physicalMemory = physicalMemory
        engineProvider = engine
        self.downloader = downloader
        self.freeSpaceBytes = freeSpaceBytes
        refresh()
    }

    public var engineAvailable: Bool { engineProvider() != nil }

    /// The pinned models offered on this device, in catalogue order.
    public var models: [LlamaCppModel] { IOSLocalCleanupModels.offered(physicalMemory: physicalMemory) }

    public func state(for model: LlamaCppModel) -> IOSLocalModelInstallState {
        states[model.catalogueID] ?? .notInstalled
    }

    public func isInstalled(_ identifier: String) -> Bool {
        guard let model = IOSLocalCleanupModels.model(for: identifier) else { return false }
        return IOSLocalCleanupModels.isInstalled(model, root: root)
    }

    public func installedSizeBytes(_ model: LlamaCppModel) -> Int64? {
        IOSLocalCleanupModels.installedSizeBytes(model, root: root)
    }

    /// Re-reads install state from disk, keeping any download in progress.
    public func refresh() {
        for model in IOSLocalCleanupModels.all where downloads[model.catalogueID] == nil {
            let installed = IOSLocalCleanupModels.isInstalled(model, root: root)
            states[model.catalogueID] = installed ? .installed : .notInstalled
        }
    }

    public func download(_ model: LlamaCppModel) {
        let modelID = model.catalogueID
        guard downloads[modelID] == nil else { return }
        guard engineAvailable else {
            states[modelID] = .failed(IOSLocalCleanupError.engineUnavailable.localizedDescription)
            return
        }
        let neededBytes = model.artifact.byteCount + 64 * 1_048_576
        if let free = freeSpaceBytes(), free < neededBytes {
            states[modelID] = .failed(
                IOSLocalCleanupError.insufficientSpace(neededMB: Int(neededBytes / 1_048_576)).localizedDescription
            )
            return
        }
        states[modelID] = .downloading(0)
        let destination = IOSLocalCleanupModels.fileURL(for: model, root: root)
        let directory = IOSLocalCleanupModels.directory(root: root)
        let downloader = self.downloader
        downloads[modelID] = Task { [weak self] in
            do {
                try IOSLocalModelsDirectory.prepare(directory)
                try await downloader.download(model.artifact, to: destination) { fraction in
                    Task { @MainActor [weak self] in
                        guard let self, case .downloading = self.states[modelID] else { return }
                        self.states[modelID] = .downloading(min(max(fraction, 0), 1))
                    }
                }
                self?.finishDownload(modelID, state: .installed)
            } catch {
                if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
                    self?.finishDownload(modelID, state: .notInstalled)
                } else {
                    self?.finishDownload(modelID, state: .failed(error.localizedDescription))
                }
            }
        }
    }

    public func cancelDownload(_ model: LlamaCppModel) {
        downloads[model.catalogueID]?.cancel()
    }

    private func finishDownload(_ modelID: String, state: IOSLocalModelInstallState) {
        downloads[modelID] = nil
        states[modelID] = state
    }

    /// Deletes a model's file. A model cleaning up a transcript is kept.
    public func remove(_ model: LlamaCppModel) throws {
        guard downloads[model.catalogueID] == nil, !IOSLocalCleanupModels.isInUse(model.catalogueID) else {
            throw IOSLocalCleanupError.modelInUse(model.displayName)
        }
        let file = IOSLocalCleanupModels.fileURL(for: model, root: root)
        if FileManager.default.fileExists(atPath: file.path) {
            try FileManager.default.removeItem(at: file)
        }
        states[model.catalogueID] = .notInstalled
    }
}

/// Downloads one pinned file to `destination`, replacing it only once the
/// file has its pinned size and SHA-256.
public protocol IOSPinnedFileDownloading: Sendable {
    func download(
        _ artifact: LocalModelFileArtifact, to destination: URL, progress: @escaping @Sendable (Double) -> Void
    ) async throws
}

/// URLSession download of a pinned artefact. Redirects may leave only for the
/// artefact's allowed hosts; integrity comes from the size and SHA-256.
public struct IOSPinnedFileDownloader: IOSPinnedFileDownloading {
    public init() {}

    public func download(
        _ artifact: LocalModelFileArtifact, to destination: URL, progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let partial = destination.appendingPathExtension("partial")
        try? FileManager.default.removeItem(at: partial)
        let delegate = DownloadDelegate(
            allowedHosts: artifact.allowedHosts, expectedBytes: artifact.byteCount, partial: partial,
            progress: progress
        )
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                delegate.start(session: session, url: artifact.url, continuation: continuation)
            }
        } onCancel: {
            delegate.cancel()
        }
        do {
            try Task.checkCancellation()
            let digest = try await Task.detached(priority: .utility) {
                try IOSPinnedWeightsVerifier.sha256(of: partial)
            }.value
            let size = (try FileManager.default.attributesOfItem(atPath: partial.path)[.size] as? NSNumber)?.int64Value
            guard size == artifact.byteCount, digest == artifact.sha256 else {
                throw IOSLocalCleanupError.downloadFailed("the file did not match its pinned size and SHA-256.")
            }
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: partial, to: destination)
        } catch {
            try? FileManager.default.removeItem(at: partial)
            throw error
        }
    }
}

private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let allowedHosts: Set<String>
    private let expectedBytes: Int64
    private let partial: URL
    private let progress: @Sendable (Double) -> Void
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var task: URLSessionDownloadTask?
    private var cancelled = false
    private var moveError: Error?

    init(
        allowedHosts: Set<String>, expectedBytes: Int64, partial: URL, progress: @escaping @Sendable (Double) -> Void
    ) {
        self.allowedHosts = allowedHosts
        self.expectedBytes = expectedBytes
        self.partial = partial
        self.progress = progress
    }

    func start(session: URLSession, url: URL, continuation: CheckedContinuation<Void, Error>) {
        let task = session.downloadTask(with: url)
        lock.lock()
        self.continuation = continuation
        self.task = task
        let cancelled = self.cancelled
        lock.unlock()
        if cancelled {
            finish(.failure(CancellationError()))
        } else {
            task.resume()
        }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let task = self.task
        lock.unlock()
        task?.cancel()
    }

    private func finish(_ result: Result<Void, Error>) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
    ) {
        let host = request.url?.host?.lowercased() ?? ""
        let allowed = request.url?.scheme == "https" && allowedHosts.contains(host)
        completionHandler(allowed ? request : nil)
    }

    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
    ) {
        guard expectedBytes > 0 else { return }
        progress(Double(totalBytesWritten) / Double(expectedBytes))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        if let response = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(response.statusCode) {
            moveError = IOSLocalCleanupError.downloadFailed(
                "the server answered \(response.statusCode), or redirected to a host it may not use."
            )
            return
        }
        do {
            try FileManager.default.moveItem(at: location, to: partial)
        } catch {
            moveError = error
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            lock.lock()
            let cancelled = self.cancelled
            lock.unlock()
            finish(.failure(cancelled ? CancellationError() : error))
        } else if let moveError {
            finish(.failure(moveError))
        } else if (task.response as? HTTPURLResponse).map({ !(200..<300).contains($0.statusCode) }) ?? true {
            finish(.failure(IOSLocalCleanupError.downloadFailed("the server did not return the file.")))
        } else {
            finish(.success(()))
        }
    }
}
#endif
