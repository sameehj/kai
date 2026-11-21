// SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial
//
// Local models for the optional llama.cpp phraser (LlamaPhraser.swift).
//
// Nothing is bundled and nothing is fetched on its own: a model is downloaded
// only when download(_:progress:) is called, after the user agreed to the
// size in the consent sheet. Every file is pinned: a Hugging Face URL at a
// fixed commit (never "main"), its exact size and its SHA-256. A file that
// doesn't match is deleted, never loaded.
//
// Files live in ~/Library/Application Support/Kai/models/. A verified file
// gets a small sidecar (<file>.verified) holding its size, mtime and hash, so
// the app doesn't rehash half a gigabyte on every launch; any change to the
// file's size or mtime forces a full re-check.
//
// Foundation (+ CryptoKit for SHA-256) only: compiled into the app tests too.
import Foundation
import CryptoKit

struct LocalModel: Identifiable, Hashable, Codable {
    var id: String
    var name: String
    var license: String
    /// Hugging Face repo and the commit it's pinned to.
    var repo: String
    var revision: String
    var fileName: String
    var sizeBytes: Int64
    /// Lowercase hex SHA-256 of the whole file (the LFS oid on Hugging Face).
    var sha256: String

    var downloadURL: URL {
        URL(string: "https://huggingface.co/\(repo)/resolve/\(revision)/\(fileName)")!
    }
    /// "509 MB", for the consent sheet.
    var sizeText: String {
        ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
    }
}

enum ModelStoreError: Error, Equatable {
    case alreadyDownloading
    case badStatus(Int)
    case sizeMismatch(expected: Int64, got: Int64)
    case checksumMismatch
}

final class ModelStore: @unchecked Sendable {
    static let shared = ModelStore()

    /// Qwen3.5 0.8B instruct, Q4_K_M (Apache-2.0). Unsloth's GGUF: Qwen
    /// publishes no official GGUF for Qwen3.5.
    static let qwen35_0_8B = LocalModel(
        id: "qwen3.5-0.8b-q4_k_m",
        name: "Qwen3.5 0.8B (Q4_K_M)",
        license: "Apache-2.0",
        repo: "unsloth/Qwen3.5-0.8B-GGUF",
        revision: "6ab461498e2023f6e3c1baea90a8f0fe38ab64d0",
        fileName: "Qwen3.5-0.8B-Q4_K_M.gguf",
        sizeBytes: 532_517_120,
        sha256: "bd258782e35f7f458f8aced1adc053e6e92e89bc735ba3be89d38a06121dc517")

    /// Larger, better wording, slower: Qwen3.5 2B instruct, Q4_K_M (Apache-2.0).
    static let qwen35_2B = LocalModel(
        id: "qwen3.5-2b-q4_k_m",
        name: "Qwen3.5 2B (Q4_K_M)",
        license: "Apache-2.0",
        repo: "unsloth/Qwen3.5-2B-GGUF",
        revision: "f6d5376be1edb4d416d56da11e5397a961aca8ae",
        fileName: "Qwen3.5-2B-Q4_K_M.gguf",
        sizeBytes: 1_280_835_840,
        sha256: "aaf42c8b7c3cab2bf3d69c355048d4a0ee9973d48f16c731c0520ee914699223")

    static let catalog: [LocalModel] = [qwen35_0_8B, qwen35_2B]
    static var defaultModel: LocalModel { qwen35_0_8B }

    static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Kai/models", isDirectory: true)
    }

    let directory: URL
    private let lock = NSLock()
    /// model id -> (size, mtime) of the file last verified.
    private var verified: [String: Stamp] = [:]
    private var downloading: Set<String> = []

    private struct Stamp: Codable, Equatable {
        var size: Int64
        var mtime: Double
        var sha256: String
    }

    init(directory: URL = ModelStore.defaultDirectory) {
        self.directory = directory
    }

    func fileURL(for model: LocalModel) -> URL {
        directory.appendingPathComponent(model.fileName)
    }
    private func partURL(for model: LocalModel) -> URL {
        directory.appendingPathComponent(model.fileName + ".part")
    }
    private func sidecarURL(for model: LocalModel) -> URL {
        directory.appendingPathComponent(model.fileName + ".verified")
    }

    // MARK: - Installed

    /// The model's file if it's present and matches its pinned SHA-256.
    /// Cheap after the first check (size + mtime); the first check of a file
    /// with no valid sidecar hashes it, so call this off the main thread then.
    func installedURL(for model: LocalModel) -> URL? {
        let url = fileURL(for: model)
        guard let stamp = currentStamp(url, sha256: model.sha256), stamp.size == model.sizeBytes else {
            forget(model)
            return nil
        }
        lock.lock()
        let cached = verified[model.id]
        lock.unlock()
        if cached == stamp { return url }

        if let data = try? Data(contentsOf: sidecarURL(for: model)),
           let saved = try? JSONDecoder().decode(Stamp.self, from: data), saved == stamp {
            remember(model, stamp)
            return url
        }
        guard let hash = try? Self.sha256(of: url), hash == model.sha256 else {
            forget(model)
            return nil
        }
        remember(model, stamp)
        writeSidecar(model, stamp)
        return url
    }

    func isInstalled(_ model: LocalModel) -> Bool { installedURL(for: model) != nil }

    func isDownloading(_ model: LocalModel) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return downloading.contains(model.id)
    }

    func delete(_ model: LocalModel) throws {
        forget(model)
        let fm = FileManager.default
        for url in [fileURL(for: model), partURL(for: model), sidecarURL(for: model)]
        where fm.fileExists(atPath: url.path) {
            try fm.removeItem(at: url)
        }
    }

    // MARK: - Download (only when called)

    /// Downloads the pinned file to <file>.part, hashing as it streams, then
    /// moves it into place atomically. A wrong size or hash deletes the part
    /// file and throws. `progress` gets 0...1 (on a background queue).
    /// Cancelling the calling task cancels the download.
    @discardableResult
    func download(_ model: LocalModel, progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> URL {
        try beginDownload(model)
        defer { endDownload(model) }

        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        var dir = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? dir.setResourceValues(values)

        let part = partURL(for: model)
        try? fm.removeItem(at: part)
        guard fm.createFile(atPath: part.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }

        let fetch = StreamingFetch(destination: part, expected: model.sizeBytes, progress: progress)
        let hash: String
        do {
            hash = try await fetch.run(model.downloadURL)
        } catch {
            try? fm.removeItem(at: part)
            throw error
        }
        let got = (try? fm.attributesOfItem(atPath: part.path)[.size] as? NSNumber)?.int64Value ?? -1
        guard got == model.sizeBytes else {
            try? fm.removeItem(at: part)
            throw ModelStoreError.sizeMismatch(expected: model.sizeBytes, got: got)
        }
        guard hash == model.sha256 else {
            try? fm.removeItem(at: part)
            throw ModelStoreError.checksumMismatch
        }
        let dest = fileURL(for: model)
        // rename(2) replaces the destination atomically.
        guard rename(part.path, dest.path) == 0 else {
            try? fm.removeItem(at: part)
            throw CocoaError(.fileWriteUnknown)
        }
        if let stamp = currentStamp(dest, sha256: hash) {
            remember(model, stamp)
            writeSidecar(model, stamp)
        }
        return dest
    }

    // MARK: - Helpers

    private func beginDownload(_ model: LocalModel) throws {
        lock.lock(); defer { lock.unlock() }
        if downloading.contains(model.id) { throw ModelStoreError.alreadyDownloading }
        downloading.insert(model.id)
    }
    private func endDownload(_ model: LocalModel) {
        lock.lock(); downloading.remove(model.id); lock.unlock()
    }

    private func currentStamp(_ url: URL, sha256: String) -> Stamp? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              (attrs[.type] as? FileAttributeType) == .typeRegular,
              let size = (attrs[.size] as? NSNumber)?.int64Value,
              let mtime = attrs[.modificationDate] as? Date else { return nil }
        return Stamp(size: size, mtime: mtime.timeIntervalSince1970, sha256: sha256)
    }
    private func remember(_ model: LocalModel, _ stamp: Stamp) {
        lock.lock(); verified[model.id] = stamp; lock.unlock()
    }
    private func forget(_ model: LocalModel) {
        lock.lock(); verified[model.id] = nil; lock.unlock()
    }
    private func writeSidecar(_ model: LocalModel, _ stamp: Stamp) {
        if let data = try? JSONEncoder().encode(stamp) {
            try? data.write(to: sidecarURL(for: model), options: .atomic)
        }
    }

    /// Streaming SHA-256 of a file, lowercase hex.
    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = try autoreleasepool { try handle.read(upToCount: 4 << 20) } ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// One download: an ephemeral session (no cache, no cookies) whose delegate
/// writes each chunk to the part file and feeds the hasher.
private final class StreamingFetch: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let destination: URL
    private let expected: Int64
    private let progress: @Sendable (Double) -> Void
    private var handle: FileHandle?
    private var hasher = SHA256()
    private var received: Int64 = 0
    private var lastReported = -1
    private var failure: Error?
    private var continuation: CheckedContinuation<String, Error>?
    private var task: URLSessionDataTask?
    private var cancelled = false
    private let queue = OperationQueue()

    init(destination: URL, expected: Int64, progress: @escaping @Sendable (Double) -> Void) {
        self.destination = destination
        self.expected = expected
        self.progress = progress
        queue.maxConcurrentOperationCount = 1
    }

    func run(_ url: URL) async throws -> String {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.timeoutIntervalForRequest = 60
        let session = URLSession(configuration: config, delegate: self, delegateQueue: queue)
        defer { session.finishTasksAndInvalidate() }
        handle = try FileHandle(forWritingTo: destination)
        var req = URLRequest(url: url)
        req.setValue("Kai", forHTTPHeaderField: "User-Agent")
        let request = req
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
                queue.addOperation {
                    if self.cancelled { cont.resume(throwing: CancellationError()); return }
                    self.continuation = cont
                    let task = session.dataTask(with: request)
                    self.task = task
                    task.resume()
                }
            }
        } onCancel: {
            queue.addOperation { self.cancelled = true; self.task?.cancel() }
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status != 200 {
            failure = ModelStoreError.badStatus(status)
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard failure == nil else { return }
        received += Int64(data.count)
        if received > expected {
            failure = ModelStoreError.sizeMismatch(expected: expected, got: received)
            dataTask.cancel()
            return
        }
        do {
            try handle?.write(contentsOf: data)
        } catch {
            failure = error
            dataTask.cancel()
            return
        }
        hasher.update(data: data)
        let pct = expected > 0 ? Int(received * 1000 / expected) : 0
        if pct != lastReported {
            lastReported = pct
            progress(Double(pct) / 1000)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        try? handle?.synchronize()
        try? handle?.close()
        handle = nil
        guard let cont = continuation else { return }
        continuation = nil
        if let failure {
            cont.resume(throwing: failure)
        } else if let error {
            let cancelled = (error as? URLError)?.code == .cancelled
            cont.resume(throwing: cancelled ? CancellationError() : error)
        } else {
            cont.resume(returning: hasher.finalize().map { String(format: "%02x", $0) }.joined())
        }
    }
}
