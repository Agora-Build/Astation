import Foundation
import CryptoKit

struct TranscriptionModelManifest: Codable, Equatable, Sendable {
    struct File: Codable, Equatable, Sendable {
        let path: String
        let url: URL
        let bytes: Int64
        let sha256: String
    }
    let schemaVersion: Int
    let id: String
    let name: String
    let revision: String
    let licenseURL: URL
    let totalBytes: Int64
    let files: [File]
    static let modelID = "parakeet-eou-120m-320ms-v1"
    static func bundled(for model: LocalTranscriptionModel = .parakeet) throws -> Self {
        guard let url = Bundle.module.url(forResource: model.manifestResource, withExtension: "json") else {
            throw TranscriptionError.message("The bundled transcription model manifest is missing.")
        }
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
    }
    func validate() throws {
        guard let model = LocalTranscriptionModel.allCases.first(where: { $0.id == id }),
              schemaVersion == 1, !files.isEmpty, files.count <= 150,
              totalBytes > 0, totalBytes <= 6_000_000_000, files.allSatisfy({ $0.bytes > 0 && $0.bytes <= 3_000_000_000 }),
              Set(files.map(\.path)).count == files.count,
              files.reduce(0, { $0 + $1.bytes }) == totalBytes else {
            throw TranscriptionError.message("Invalid or incompatible transcription model manifest.")
        }
        for file in files {
            let parts = file.path.split(separator: "/", omittingEmptySubsequences: false)
            guard !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }),
                  file.path.range(of: "^[A-Za-z0-9_./-]+$", options: .regularExpression) != nil,
                  file.bytes > 0, file.bytes <= 3_000_000_000,
                  file.sha256.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
                  Self.safeURL(file.url),
                  Self.allowedPath(file.path, model: model) else {
                throw TranscriptionError.message("Unsafe path, URL, or checksum in the model manifest.")
            }
        }
        let requiredFiles = model == .parakeet
            ? ["vocab.json", "decoder.mlmodelc/weights/weight.bin", "joint_decision.mlmodelc/weights/weight.bin", "streaming_encoder.mlmodelc/weights/weight.bin"]
            : ["AudioEncoder.mlmodelc/weights/weight.bin", "TextDecoder.mlmodelc/weights/weight.bin", "MelSpectrogram.mlmodelc/weights/weight.bin",
               "tokenizer/tokenizer.json", "tokenizer/tokenizer_config.json", "tokenizer/config.json"]
        for required in requiredFiles {
            guard files.contains(where: { $0.path == required }) else {
                throw TranscriptionError.message("The model manifest is missing \(required).")
            }
        }
    }
    private static func allowedPath(_ path: String, model: LocalTranscriptionModel) -> Bool {
        if ["LICENSE.html", "LICENSE.txt", "ATTRIBUTION.txt"].contains(path) { return true }
        if model == .parakeet {
            return path == "vocab.json" || ["decoder.mlmodelc/", "joint_decision.mlmodelc/", "streaming_encoder.mlmodelc/"].contains { path.hasPrefix($0) }
        }
        return ["config.json", "generation_config.json", "tokenizer/tokenizer.json", "tokenizer/tokenizer_config.json", "tokenizer/config.json"].contains(path)
            || ["AudioEncoder.mlmodelc/", "TextDecoder.mlmodelc/", "MelSpectrogram.mlmodelc/", "TextDecoderContextPrefill.mlmodelc/"].contains { path.hasPrefix($0) }
    }
    static func safeURL(_ url: URL) -> Bool {
        url.scheme == "https" && url.host?.isEmpty == false && url.user == nil && url.password == nil
            && url.fragment == nil && url.query == nil
    }
}

private final class ModelDownloadProgress: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let update: @Sendable (Int64) -> Void
    init(update: @escaping @Sendable (Int64) -> Void) { self.update = update }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) { update(totalBytesWritten) }
}

actor TranscriptionModelStore {
    typealias FetchFile = @Sendable (URL, @escaping @Sendable (Int64) -> Void) async throws -> URL
    static var defaultRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Astation/Models", isDirectory: true)
    }
    nonisolated let root: URL
    private let fetchFile: FetchFile
    private var downloading = false
    init(root: URL = defaultRoot, fetchFile: FetchFile? = nil) {
        self.root = root
        self.fetchFile = fetchFile ?? { url, progress in
            let delegate = ModelDownloadProgress(update: progress)
            let (temporary, response) = try await URLSession.shared.download(from: url, delegate: delegate)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw TranscriptionError.message("Model download failed. Check the download URL and try again.")
            }
            return temporary
        }
    }
    nonisolated var directory: URL { root.appendingPathComponent(TranscriptionModelManifest.modelID, isDirectory: true) }
    nonisolated func directory(for model: LocalTranscriptionModel) -> URL { root.appendingPathComponent(model.id, isDirectory: true) }
    nonisolated var hasInstalledModel: Bool {
        FileManager.default.fileExists(atPath: directory.appendingPathComponent("installed.json").path)
    }
    nonisolated func hasInstalledModel(_ model: LocalTranscriptionModel) -> Bool {
        FileManager.default.fileExists(atPath: directory(for: model).appendingPathComponent("installed.json").path)
    }
    func verifiedDirectory(for model: LocalTranscriptionModel = .parakeet) throws -> URL {
        let directory = directory(for: model)
        let manifestURL = directory.appendingPathComponent("installed.json")
        guard let data = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(TranscriptionModelManifest.self, from: data) else {
            throw TranscriptionError.message("Download \(model.name) before starting transcription.")
        }
        guard manifest.id == model.id else { throw TranscriptionError.message("The installed model does not match the selected profile.") }
        try manifest.validate()
        for file in manifest.files { try Self.verify(directory.appendingPathComponent(file.path), file: file) }
        return directory
    }
    func download(manifest: TranscriptionModelManifest,
                  progress: @escaping @Sendable (Double) -> Void) async throws {
        try manifest.validate()
        guard !downloading else { throw TranscriptionError.message("A model download is already running.") }
        let directory = root.appendingPathComponent(manifest.id, isDirectory: true)
        downloading = true
        defer { downloading = false }
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let staging = root.appendingPathComponent(".download-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        var complete: Int64 = 0
        for file in manifest.files {
            try Task.checkCancellation()
            let previous = complete
            let temporary = try await fetchFile(file.url) { bytes in
                progress(min(1, Double(previous + min(bytes, file.bytes)) / Double(manifest.totalBytes)))
            }
            defer { try? fm.removeItem(at: temporary) }
            try Task.checkCancellation()
            try Self.verify(temporary, file: file)
            let target = staging.appendingPathComponent(file.path)
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.moveItem(at: temporary, to: target)
            complete += file.bytes
            progress(Double(complete) / Double(manifest.totalBytes))
        }
        try Task.checkCancellation()
        try JSONEncoder().encode(manifest).write(to: staging.appendingPathComponent("installed.json"), options: .atomic)
        let backup = root.appendingPathComponent(".backup-\(UUID().uuidString)", isDirectory: true)
        let replacing = fm.fileExists(atPath: directory.path)
        if replacing { try fm.moveItem(at: directory, to: backup) }
        do { try fm.moveItem(at: staging, to: directory) }
        catch {
            if replacing { try? fm.moveItem(at: backup, to: directory) }
            throw error
        }
        if replacing { try? fm.removeItem(at: backup) }
        progress(1)
    }
    static func verify(_ url: URL, file: TranscriptionModelManifest.File) throws {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey, .isRegularFileKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, Int64(values.fileSize ?? -1) == file.bytes else {
            throw TranscriptionError.message("The downloaded \(file.path) is incomplete. Download the model again.")
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty { hash.update(data: data) }
        let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
        guard digest == file.sha256 else {
            throw TranscriptionError.message("Checksum verification failed for \(file.path). The model was not installed.")
        }
    }
}
