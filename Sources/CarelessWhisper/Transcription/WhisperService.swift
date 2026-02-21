import Foundation
import SwiftWhisper
import os

final class WhisperService: Sendable {
    private let logger = Logger(subsystem: "com.carelesswhisper", category: "WhisperService")
    private nonisolated(unsafe) var whisper: Whisper?

    func loadModel(path: String) throws {
        logger.info("Loading whisper model from: \(path)")
        let whisper = Whisper(fromFileURL: URL(fileURLWithPath: path))
        self.whisper = whisper
        logger.info("Whisper model loaded")
    }

    func transcribe(samples: [Float]) async throws -> String {
        guard let whisper else {
            throw WhisperServiceError.modelNotLoaded
        }

        logger.info("Transcribing \(samples.count) samples (\(Double(samples.count) / 16000.0, format: .fixed(precision: 1))s)")

        // Use Task.detached to avoid inheriting @MainActor context.
        // SwiftWhisper resumes its continuation on DispatchQueue.main,
        // which deadlocks when called from a Swift actor/MainActor context.
        let segments = try await Task.detached {
            try await whisper.transcribe(audioFrames: samples)
        }.value

        let text = segments.map(\.text)
            .filter { !Self.isNonSpeechSegment($0) }
            .joined(separator: " ")
        logger.info("Transcription complete: \(text.prefix(100))")
        return text
    }

    /// Returns true if a segment's text is a non-speech hallucination
    /// (sound description, music annotation, etc.) rather than spoken words.
    private static func isNonSpeechSegment(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }

        // Text entirely wrapped in brackets or parentheses is a sound
        // description, never actual speech (e.g. "[wind]", "(eerie music)")
        if (trimmed.hasPrefix("[") && trimmed.hasSuffix("]")) ||
            (trimmed.hasPrefix("(") && trimmed.hasSuffix(")")) {
            return true
        }

        // Asterisk-wrapped annotations: *sighs*, *wind blowing*
        if trimmed.hasPrefix("*") && trimmed.hasSuffix("*") && trimmed.count > 2 {
            return true
        }

        // Music note symbols indicate non-speech audio
        if trimmed.contains("♪") || trimmed.contains("🎵") || trimmed.contains("🎶") {
            return true
        }

        // [BLANK_AUDIO] anywhere in the segment
        if trimmed.contains("[BLANK_AUDIO]") {
            return true
        }

        return false
    }

    func unloadModel() {
        whisper = nil
        logger.info("Model unloaded")
    }
}

enum WhisperServiceError: LocalizedError {
    case modelNotLoaded

    var errorDescription: String? {
        switch self {
        case .modelNotLoaded:
            return "Whisper model is not loaded"
        }
    }
}
