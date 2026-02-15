import Foundation
import os

enum WhisperModel: String, CaseIterable, Identifiable {
    case tinyEn = "ggml-tiny.en"
    case baseEn = "ggml-base.en"
    case smallEn = "ggml-small.en"

    var id: String { rawValue }

    var name: String {
        switch self {
        case .tinyEn: return "Tiny (English)"
        case .baseEn: return "Base (English)"
        case .smallEn: return "Small (English)"
        }
    }

    var fileName: String { "\(rawValue).bin" }

    var downloadURL: URL {
        URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/\(fileName)")!
    }

    /// CoreML encoder model archive (zip containing .mlmodelc directory)
    var coreMLFileName: String { "\(rawValue)-encoder.mlmodelc" }

    var coreMLDownloadURL: URL {
        URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/\(rawValue)-encoder.mlmodelc.zip")!
    }

    var sizeDescription: String {
        switch self {
        case .tinyEn: return "75 MB"
        case .baseEn: return "142 MB"
        case .smallEn: return "466 MB"
        }
    }
}

final class ModelManager {
    private let logger = Logger(subsystem: "com.carelesswhisper", category: "ModelManager")

    var modelsDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("CarelessWhisper/Models", isDirectory: true)
    }

    func modelPath(for model: WhisperModel) -> String {
        modelsDirectory.appendingPathComponent(model.fileName).path
    }

    func coreMLModelPath(for model: WhisperModel) -> String {
        modelsDirectory.appendingPathComponent(model.coreMLFileName).path
    }

    func isModelDownloaded(_ model: WhisperModel) -> Bool {
        FileManager.default.fileExists(atPath: modelPath(for: model))
    }

    func isCoreMLModelDownloaded(_ model: WhisperModel) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: coreMLModelPath(for: model), isDirectory: &isDir) && isDir.boolValue
    }

    func downloadModel(_ model: WhisperModel, progress: @escaping (Double) -> Void) async throws {
        try FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)

        let destination = modelsDirectory.appendingPathComponent(model.fileName)
        logger.info("Downloading \(model.name) from \(model.downloadURL)")

        let (tempURL, response) = try await downloadWithProgress(
            url: model.downloadURL,
            progress: progress
        )

        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            throw ModelManagerError.downloadFailed
        }

        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: tempURL, to: destination)

        logger.info("Model downloaded: \(destination.path)")
    }

    func downloadCoreMLModel(_ model: WhisperModel, progress: @escaping (Double) -> Void) async throws {
        try FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)

        logger.info("Downloading CoreML encoder for \(model.name)")

        let (tempURL, response) = try await downloadWithProgress(
            url: model.coreMLDownloadURL,
            progress: progress
        )

        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            throw ModelManagerError.downloadFailed
        }

        // Unzip the CoreML model
        let destination = modelsDirectory.appendingPathComponent(model.coreMLFileName)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }

        try unzip(tempURL, to: modelsDirectory)
        try FileManager.default.removeItem(at: tempURL)

        // Verify it was extracted
        guard isCoreMLModelDownloaded(model) else {
            throw ModelManagerError.coreMLExtractionFailed
        }

        logger.info("CoreML model downloaded: \(destination.path)")
    }

    func deleteModel(_ model: WhisperModel) throws {
        let path = modelPath(for: model)
        if FileManager.default.fileExists(atPath: path) {
            try FileManager.default.removeItem(atPath: path)
        }
        let coreMLPath = coreMLModelPath(for: model)
        if FileManager.default.fileExists(atPath: coreMLPath) {
            try FileManager.default.removeItem(atPath: coreMLPath)
        }
    }

    private func unzip(_ zipURL: URL, to destinationDir: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-o", zipURL.path, "-d", destinationDir.path]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            throw ModelManagerError.coreMLExtractionFailed
        }
    }

    private func downloadWithProgress(
        url: URL,
        progress: @escaping (Double) -> Void
    ) async throws -> (URL, URLResponse) {
        let delegate = DownloadDelegate(progress: progress)
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        return try await withCheckedThrowingContinuation { continuation in
            delegate.continuation = continuation
            let task = session.downloadTask(with: url)
            task.resume()
        }
    }
}

private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate {
    let progressHandler: (Double) -> Void
    var continuation: CheckedContinuation<(URL, URLResponse), Error>?

    init(progress: @escaping (Double) -> Void) {
        self.progressHandler = progress
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        do {
            try FileManager.default.moveItem(at: location, to: tempURL)
            continuation?.resume(returning: (tempURL, downloadTask.response!))
        } catch {
            continuation?.resume(throwing: error)
        }
        continuation = nil
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let fraction = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        progressHandler(fraction)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            continuation?.resume(throwing: error)
            continuation = nil
        }
    }
}

enum ModelManagerError: LocalizedError {
    case downloadFailed
    case coreMLExtractionFailed

    var errorDescription: String? {
        switch self {
        case .downloadFailed:
            return "Failed to download model from HuggingFace"
        case .coreMLExtractionFailed:
            return "Failed to extract CoreML model archive"
        }
    }
}
