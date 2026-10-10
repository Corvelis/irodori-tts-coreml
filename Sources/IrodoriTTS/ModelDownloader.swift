import Foundation
import CryptoKit

public struct ModelDownloadProgress: Sendable {
    public enum Phase: Sendable { case manifest, downloading, verifying, complete }
    public let phase: Phase
    /// Verified files plus bytes received for the current file. Not all bytes
    /// are verified until phase == .complete.
    public let receivedBytes: Int64
    public let totalBytes: Int64
    public let completedFiles: Int
    public let totalFiles: Int
    public let currentFile: String
    public var fractionCompleted: Double {
        totalBytes > 0 ? min(1, Double(receivedBytes) / Double(totalBytes)) : 0
    }
}

protocol ModelDownloadTransport: Sendable {
    func manifest(from url: URL) async throws -> Data
    func file(from url: URL, progress: @escaping @Sendable (Int64) -> Void) async throws -> URL
}

struct URLModelDownloadTransport: ModelDownloadTransport {
    let session: URLSession
    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 12 * 60 * 60
        session = URLSession(configuration: configuration)
    }
    func manifest(from url: URL) async throws -> Data {
        let (data, response) = try await session.data(from: url)
        try check(response)
        return data
    }
    func file(from url: URL, progress: @escaping @Sendable (Int64) -> Void) async throws -> URL {
        try await DownloadObserver(progress: progress).download(from: url)
    }
    private func check(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw IrodoriError.invalid("モデルを取得できませんでした（HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)）。再試行してください。")
        }
    }
}

private final class DownloadObserver: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let progress: @Sendable (Int64) -> Void
    private let lock = NSLock()
    private var continuation: CheckedContinuation<URL, Error>?
    private var session: URLSession?
    private var task: URLSessionDownloadTask?
    private var received: Result<URL, Error>?
    private var cancelled = false
    private var lastEmission: TimeInterval = -.infinity

    init(progress: @escaping @Sendable (Int64) -> Void) { self.progress = progress }

    func download(from url: URL) async throws -> URL {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                start(url, continuation: continuation)
            }
        } onCancel: { self.cancel() }
    }
    private func start(_ url: URL, continuation: CheckedContinuation<URL, Error>) {
        lock.lock()
        if cancelled { lock.unlock(); continuation.resume(throwing: CancellationError()); return }
        self.continuation = continuation
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 12 * 60 * 60
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        let task = session.downloadTask(with: url)
        self.session = session; self.task = task
        lock.unlock()
        task.resume()
    }
    private func cancel() {
        lock.lock(); cancelled = true; let task = self.task; lock.unlock()
        task?.cancel()
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        // URLSession serializes delegate callbacks. Bound UI update frequency
        // during multi-gigabyte transfers, always reporting the final bytes.
        let now = Date.timeIntervalSinceReferenceDate
        if now - lastEmission >= 0.15 || totalBytesWritten == totalBytesExpectedToWrite {
            lastEmission = now; progress(totalBytesWritten)
        }
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        let result: Result<URL, Error>
        do {
            guard let response = downloadTask.response as? HTTPURLResponse, response.statusCode == 200 else {
                throw IrodoriError.invalid("モデルを取得できませんでした（HTTP \((downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0)）。再試行してください。")
            }
            // URLSession removes its temporary location when this callback
            // returns. Move it to an owned location before resuming async code.
            let owned = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.moveItem(at: location, to: owned)
            result = .success(owned)
        } catch { result = .failure(error) }
        lock.lock(); received = result; lock.unlock()
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil; self.task = nil; self.session = nil
        let received = self.received
        let result: Result<URL, Error>
        if cancelled { result = .failure(CancellationError()) }
        else if let error { result = .failure(error) }
        else { result = received ?? .failure(IrodoriError.invalid("ファイルの受信を完了できませんでした。")) }
        self.received = nil
        lock.unlock()
        if case .failure = result, case .success(let url) = received { try? FileManager.default.removeItem(at: url) }
        session.finishTasksAndInvalidate()
        continuation?.resume(with: result)
    }
}

/// Downloads to disk. A retry reuses completed files only after verifying their
/// size and SHA-256; an interrupted individual file is downloaded again.
/// Prefer an immutable commit SHA or a versioned release tag.
public actor ModelDownloader {
    private let transport: any ModelDownloadTransport
    private let capacity: @Sendable (URL) throws -> Int64?
    private var downloading = false

    public init() {
        transport = URLModelDownloadTransport()
        capacity = { try Self.availableCapacity(at: $0) }
    }
    init(transport: any ModelDownloadTransport, capacity: @escaping @Sendable (URL) throws -> Int64?) {
        self.transport = transport; self.capacity = capacity
    }

    public func download(manifestURL: URL, to destination: URL,
                         byteProgress: (@Sendable (ModelDownloadProgress) -> Void)? = nil,
                         progress: @Sendable (Int, Int, String) -> Void = { _, _, _ in }) async throws {
        guard !downloading else { throw IrodoriError.invalid("ダウンロードは既に進行中です。") }
        downloading = true
        defer { downloading = false }
        let files = FileManager.default
        guard !files.fileExists(atPath: destination.path) else {
            throw IrodoriError.invalid("Destination already exists. Select a new folder or verify the existing model.")
        }
        let staging = try Self.stagingDirectory(manifestURL: manifestURL, destination: destination)
        try files.createDirectory(at: staging, withIntermediateDirectories: true)
        byteProgress?(.init(phase: .manifest, receivedBytes: 0, totalBytes: 0,
                            completedFiles: 0, totalFiles: 0, currentFile: ""))
        let data = try await transport.manifest(from: manifestURL)
        try Task.checkCancellation()
        let manifest = try ModelBundle.manifest(from: data)
        if manifest.format == "irodori-coreml-distribution-v2" {
            if #available(iOS 18, macOS 15, *) {} else {
                throw IrodoriError.invalid("This model requires iOS 18 or macOS 15")
            }
        }
        let totalBytes = try Self.totalBytes(manifest)
        var reusable = Set<String>()
        var received: Int64 = 0
        for entry in manifest.files {
            try Task.checkCancellation()
            let target = try ModelBundle.safeURL(entry.path, under: staging)
            byteProgress?(.init(phase: .verifying, receivedBytes: received, totalBytes: totalBytes,
                                completedFiles: reusable.count, totalFiles: manifest.files.count, currentFile: entry.path))
            if let size = try? files.attributesOfItem(atPath: target.path)[.size] as? NSNumber,
               size.int64Value == entry.bytes, (try? ModelBundle.checksum(target)) == entry.sha256 {
                reusable.insert(entry.path); received += entry.bytes
            }
        }
        // Reserve room for the remaining download and approximately one model
        // copy for Core ML compilation, plus a margin. Specialization may need
        // more; this is an early check, not a guarantee of total cache size.
        let required = try Self.requiredCapacity(remaining: totalBytes - received, total: totalBytes)
        if let available = try capacity(staging), available < required {
            let amount = ByteCountFormatter.string(fromByteCount: required, countStyle: .file)
            throw IrodoriError.invalid("空き容量が不足しています。ダウンロードと初回準備のため、少なくとも約\(amount)の空き容量を確保して再試行してください。")
        }
        let base = manifestURL.deletingLastPathComponent()
        var completed = reusable.count
        for (index, entry) in manifest.files.enumerated() {
            try Task.checkCancellation()
            let target = try ModelBundle.safeURL(entry.path, under: staging)
            progress(index, manifest.files.count, entry.path)
            byteProgress?(.init(phase: .downloading, receivedBytes: received, totalBytes: totalBytes,
                                completedFiles: completed, totalFiles: manifest.files.count, currentFile: entry.path))
            if reusable.contains(entry.path) { continue }
            try files.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            let offset = received, completedBefore = completed
            let temporary = try await transport.file(from: base.appendingPathComponent(entry.path)) { bytes in
                byteProgress?(.init(phase: .downloading,
                                    receivedBytes: offset + max(0, min(bytes, entry.bytes)), totalBytes: totalBytes,
                                    completedFiles: completedBefore, totalFiles: manifest.files.count, currentFile: entry.path))
            }
            defer { try? files.removeItem(at: temporary) }
            try Task.checkCancellation()
            byteProgress?(.init(phase: .verifying, receivedBytes: received + entry.bytes, totalBytes: totalBytes,
                                completedFiles: completed, totalFiles: manifest.files.count, currentFile: entry.path))
            guard (try files.attributesOfItem(atPath: temporary.path)[.size] as? NSNumber)?.int64Value == entry.bytes,
                  try ModelBundle.checksum(temporary) == entry.sha256 else {
                throw IrodoriError.invalid("取得したファイルの検証に失敗しました。再試行してください。")
            }
            try Task.checkCancellation()
            if files.fileExists(atPath: target.path) { try files.removeItem(at: target) }
            try files.moveItem(at: temporary, to: target)
            received += entry.bytes; completed += 1
        }
        try Task.checkCancellation()
        byteProgress?(.init(phase: .verifying, receivedBytes: totalBytes, totalBytes: totalBytes,
                            completedFiles: completed, totalFiles: manifest.files.count, currentFile: ""))
        try data.write(to: staging.appendingPathComponent("manifest.json"), options: .atomic)
        try ModelBundle.validate(at: staging)
        try Task.checkCancellation()
        try files.moveItem(at: staging, to: destination)
        progress(manifest.files.count, manifest.files.count, "Complete")
        byteProgress?(.init(phase: .complete, receivedBytes: totalBytes, totalBytes: totalBytes,
                            completedFiles: manifest.files.count, totalFiles: manifest.files.count, currentFile: ""))
    }

    static func stagingDirectory(manifestURL: URL, destination: URL) throws -> URL {
        guard manifestURL.scheme == "https", manifestURL.host != nil else {
            throw IrodoriError.invalid("Use an HTTPS manifest URL")
        }
        let key = SHA256.hash(data: Data(manifestURL.absoluteString.utf8)).prefix(8)
            .map { String(format: "%02x", $0) }.joined()
        return destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent)-\(key).partial", isDirectory: true)
    }
    static func totalBytes(_ manifest: ModelManifest) throws -> Int64 {
        try manifest.files.reduce(Int64(0)) { partial, entry in
            let (sum, overflow) = partial.addingReportingOverflow(entry.bytes)
            guard !overflow else { throw IrodoriError.invalid("Model size overflow") }
            return sum
        }
    }
    static func requiredCapacity(remaining: Int64, total: Int64) throws -> Int64 {
        let (sum, overflow) = remaining.addingReportingOverflow(total)
        let (required, marginOverflow) = sum.addingReportingOverflow(512 * 1024 * 1024)
        guard !overflow, !marginOverflow else { throw IrodoriError.invalid("Model size overflow") }
        return required
    }
    private static func availableCapacity(at url: URL) throws -> Int64? {
        let values = try url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values.volumeAvailableCapacityForImportantUsage
    }
}
