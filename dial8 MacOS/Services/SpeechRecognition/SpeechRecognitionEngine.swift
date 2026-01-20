//
//  SpeechRecognitionEngine.swift
//  dial8 MacOS
//
//  Protocol defining the interface for speech recognition engines.
//  Both WhisperEngine and ParakeetEngine conform to this protocol.
//

import Foundation
import Combine

/// Information about a speech recognition model
struct SpeechModelInfo: Identifiable {
    let id: String
    let name: String
    let description: String
    let icon: String
    let recommendation: String?
    var isAvailable: Bool
    var isSelected: Bool
    let fileSize: String
}

/// Represents a timestamped segment from transcription
struct TranscriptionSegment {
    let startTime: TimeInterval
    let endTime: TimeInterval
    let text: String

    var duration: TimeInterval {
        return endTime - startTime
    }
}

/// Errors that can occur during speech recognition
enum SpeechRecognitionError: LocalizedError {
    case modelNotReady
    case transcriptionFailed(String)
    case audioLoadingFailed(String)
    case downloadFailed(String)

    var errorDescription: String? {
        switch self {
        case .modelNotReady:
            return "Speech recognition model is not ready"
        case .transcriptionFailed(let message):
            return "Transcription failed: \(message)"
        case .audioLoadingFailed(let message):
            return "Failed to load audio: \(message)"
        case .downloadFailed(let message):
            return "Model download failed: \(message)"
        }
    }
}

/// Protocol defining the interface for speech recognition engines
@MainActor
protocol SpeechRecognitionEngine: ObservableObject {
    /// Whether the model is ready for transcription
    var isReady: Bool { get }

    /// Whether a model is currently downloading
    var isDownloading: Bool { get }

    /// Download progress (0.0 to 1.0)
    var downloadProgress: Double { get }

    /// Error message if something went wrong
    var errorMessage: String? { get }

    /// Currently selected model ID
    var selectedModelId: String { get }

    /// Languages supported by this engine
    var supportedLanguages: [String] { get }

    /// Display name for the engine
    var engineName: String { get }

    /// Download and prepare a model
    func downloadModel(modelId: String)

    /// Select a model for transcription
    func selectModel(modelId: String)

    /// Delete a downloaded model
    func deleteModel(modelId: String)

    /// Transcribe audio from a file URL
    func transcribe(audioURL: URL, language: String?, completion: @escaping (Result<String, Error>) -> Void)

    /// Wait until the model is ready
    func waitUntilReady() async
}

/// Engine type enumeration
enum SpeechEngineType: String, CaseIterable, Identifiable {
    case parakeet = "Parakeet"
    case whisper = "Whisper"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .parakeet:
            return "Parakeet (Fast)"
        case .whisper:
            return "Whisper (Multilingual)"
        }
    }

    var description: String {
        switch self {
        case .parakeet:
            return "Ultra-fast transcription optimized for Apple Silicon. Supports 25 European languages."
        case .whisper:
            return "Highly accurate multilingual transcription. Supports 99+ languages including Asian languages."
        }
    }

    var icon: String {
        switch self {
        case .parakeet:
            return "bolt.circle.fill"
        case .whisper:
            return "globe"
        }
    }
}
