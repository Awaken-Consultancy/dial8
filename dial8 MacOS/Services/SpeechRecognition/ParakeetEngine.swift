//
//  ParakeetEngine.swift
//  dial8 MacOS
//
//  FluidAudio/Parakeet-based speech recognition engine.
//  Provides fast transcription optimized for Apple Silicon Neural Engine.
//

import Foundation
import Combine
@preconcurrency import AVFoundation
import FluidAudio
import os.log

@MainActor
class ParakeetEngine: ObservableObject, SpeechRecognitionEngine {
    private let logger = Logger(subsystem: "com.dial8", category: "ParakeetEngine")

    // MARK: - Published Properties

    @Published var isReady = false
    @Published var isDownloading = false
    @Published var downloadProgress: Double = 0.0
    @Published var errorMessage: String?
    @Published var availableModels: [SpeechModelInfo] = []
    @Published var selectedModelId: String = "parakeet-v3"

    // MARK: - Engine Info

    let engineName = "Parakeet"

    let supportedLanguages = [
        "auto", "english", "german", "french", "spanish", "italian", "portuguese",
        "dutch", "polish", "swedish", "danish", "norwegian", "finnish", "czech",
        "slovak", "hungarian", "romanian", "bulgarian", "croatian", "slovenian",
        "serbian", "ukrainian", "greek", "turkish", "catalan"
    ]

    // MARK: - Private Properties

    private var asrManager: AsrManager?
    private var models: AsrModels?
    private var initializationTask: Task<Void, Error>?
    private var isInitializing = false

    private static let vocabURL: URL = {
        guard let url = URL(string: "https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml/resolve/main/parakeet_vocab.json") else {
            fatalError("Invalid vocabulary URL - this is a programming error, please verify the URL string")
        }
        return url
    }()

    // MARK: - Initialization

    init() {
        loadAvailableModels()
        checkExistingModel()
    }

    private func loadAvailableModels() {
        let model = SpeechModelInfo(
            id: "parakeet-v3",
            name: "Parakeet v3",
            description: "Fast, accurate speech recognition for 25 European languages. Runs on Neural Engine for optimal performance.",
            icon: "bolt.circle.fill",
            recommendation: "Recommended for speed",
            isAvailable: false,
            isSelected: true,
            fileSize: "~600MB"
        )
        availableModels = [model]
    }

    private func checkExistingModel() {
        // Check if model is already cached by FluidAudio
        // FluidAudio handles its own caching, so we just try to initialize
        guard !isInitializing else { return }
        isInitializing = true

        initializationTask = Task {
            do {
                logger.info("Checking for cached Parakeet model...")

                // Ensure vocabulary file exists (workaround for FluidAudio bug)
                try await ensureVocabularyFile()

                // Try quick initialization to check if model exists
                let loadedModels = try await AsrModels.loadFromCache(version: .v3)
                let manager = AsrManager(config: .default)
                try await manager.initialize(models: loadedModels)

                self.models = loadedModels
                self.asrManager = manager

                if var model = availableModels.first {
                    model.isAvailable = true
                    availableModels = [model]
                }

                isReady = true
                isInitializing = false
                logger.info("Parakeet model loaded from cache and ready")
            } catch {
                // Model not cached, user needs to download
                isInitializing = false
                logger.info("Parakeet model not cached, download required: \(error.localizedDescription)")
                throw error
            }
        }
    }

    // MARK: - Model Management

    func downloadModel(modelId: String) {
        guard initializationTask == nil else {
            logger.warning("Download already in progress")
            return
        }

        isDownloading = true
        downloadProgress = 0.0
        errorMessage = nil

        initializationTask = Task {
            do {
                logger.info("Starting Parakeet model download (~600MB)")
                downloadProgress = 0.05

                // Ensure vocabulary file exists first (workaround for FluidAudio bug)
                try await ensureVocabularyFile()
                downloadProgress = 0.10

                // Start a background task to simulate progress while downloading
                let progressTask = Task {
                    var progress = 0.10
                    while progress < 0.85 && !Task.isCancelled {
                        try? await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds
                        progress += 0.05
                        await MainActor.run {
                            if self.isDownloading && self.downloadProgress < 0.85 {
                                self.downloadProgress = progress
                            }
                        }
                    }
                }

                let loadedModels = try await AsrModels.downloadAndLoad(version: .v3)
                progressTask.cancel()
                downloadProgress = 0.90

                let manager = AsrManager(config: .default)
                try await manager.initialize(models: loadedModels)
                downloadProgress = 0.95

                self.models = loadedModels
                self.asrManager = manager

                if var model = availableModels.first {
                    model.isAvailable = true
                    availableModels = [model]
                }

                downloadProgress = 1.0
                isReady = true
                isDownloading = false

                logger.info("Parakeet model ready")

            } catch {
                logger.error("Failed to initialize Parakeet: \(error.localizedDescription)")
                errorMessage = "Failed to download model: \(error.localizedDescription)"
                isDownloading = false
                isReady = false
            }

            initializationTask = nil
        }
    }

    func selectModel(modelId: String) {
        // Parakeet has only one model, so this is essentially a no-op
        selectedModelId = modelId
    }

    func deleteModel(modelId: String) {
        // Clear the in-memory model
        asrManager = nil
        models = nil
        isReady = false

        if var model = availableModels.first {
            model.isAvailable = false
            availableModels = [model]
        }

        logger.info("Parakeet model cleared from memory")
        // Note: FluidAudio manages its own cache, we can't easily delete it
    }

    // MARK: - Transcription

    // Minimum samples required by Parakeet (1 second at 16kHz)
    private static let minimumSamples = 16000

    func transcribe(audioURL: URL, language: String?, completion: @escaping (Result<String, Error>) -> Void) {
        Task {
            do {
                // Wait for initialization to complete if it's in progress
                if let task = initializationTask {
                    logger.debug("Waiting for Parakeet initialization to complete...")
                    try? await task.value
                }

                guard let asrManager = asrManager else {
                    throw SpeechRecognitionError.modelNotReady
                }

                logger.debug("Starting Parakeet transcription for: \(audioURL.lastPathComponent)")

                // Load audio samples from file
                let samples = try await loadAudioSamples(from: audioURL)

                // Parakeet requires at least 1 second of audio (16000 samples)
                if samples.count < Self.minimumSamples {
                    logger.debug("Audio too short for Parakeet (\(samples.count) samples < \(Self.minimumSamples)), returning empty")
                    completion(.success(""))
                    return
                }

                // Transcribe using FluidAudio
                let result = try await asrManager.transcribe(samples)

                // Clean up transcription
                let cleanedText = cleanTranscriptionText(result.text)

                logger.debug("Parakeet transcription complete: \(cleanedText.prefix(50))...")
                completion(.success(cleanedText))

            } catch {
                logger.error("Parakeet transcription error: \(error.localizedDescription)")
                completion(.failure(error))
            }
        }
    }

    func waitUntilReady() async {
        // First wait for initialization task to complete if running
        if let task = initializationTask {
            logger.debug("waitUntilReady: Waiting for initialization task...")
            try? await task.value
        }

        // Then poll for ready state (in case download is needed)
        for _ in 0..<50 {
            if isReady {
                logger.debug("waitUntilReady: Parakeet is ready")
                return
            }
            try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 second
        }
        logger.warning("waitUntilReady: Timeout waiting for Parakeet to be ready")
    }

    // MARK: - Audio Loading

    private func loadAudioSamples(from url: URL) async throws -> [Float] {
        let audioFile = try AVAudioFile(forReading: url)

        let frameCount = AVAudioFrameCount(audioFile.length)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: audioFile.processingFormat,
                                            frameCapacity: frameCount) else {
            throw SpeechRecognitionError.audioLoadingFailed("Failed to create audio buffer")
        }

        try audioFile.read(into: buffer)

        // Check if we need to convert format
        let sourceFormat = audioFile.processingFormat
        let needsConversion = sourceFormat.sampleRate != 16000 || sourceFormat.channelCount != 1

        if needsConversion {
            return try await convertToTargetFormat(buffer: buffer)
        }

        // Extract float samples directly
        guard let channelData = buffer.floatChannelData?[0] else {
            throw SpeechRecognitionError.audioLoadingFailed("Failed to extract audio data")
        }

        return Array(UnsafeBufferPointer(start: channelData, count: Int(buffer.frameLength)))
    }

    private func convertToTargetFormat(buffer: AVAudioPCMBuffer) async throws -> [Float] {
        guard let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                               sampleRate: 16000,
                                               channels: 1,
                                               interleaved: false) else {
            throw SpeechRecognitionError.audioLoadingFailed("Failed to create target format")
        }

        guard let converter = AVAudioConverter(from: buffer.format, to: targetFormat) else {
            throw SpeechRecognitionError.audioLoadingFailed("Failed to create audio converter")
        }

        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let outputFrameCount = AVAudioFrameCount(Double(buffer.frameLength) * ratio)

        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat,
                                                  frameCapacity: outputFrameCount) else {
            throw SpeechRecognitionError.audioLoadingFailed("Failed to create output buffer")
        }

        var error: NSError?
        var inputConsumed = false
        // Use nonisolated(unsafe) to suppress Sendable warning - the closure runs synchronously
        let inputBuffer = buffer
        converter.convert(to: outputBuffer, error: &error) { inNumPackets, outStatus in
            if inputConsumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            outStatus.pointee = .haveData
            inputConsumed = true
            return inputBuffer
        }

        if let error = error {
            throw SpeechRecognitionError.audioLoadingFailed(error.localizedDescription)
        }

        guard let channelData = outputBuffer.floatChannelData?[0] else {
            throw SpeechRecognitionError.audioLoadingFailed("Failed to extract converted audio data")
        }

        return Array(UnsafeBufferPointer(start: channelData, count: Int(outputBuffer.frameLength)))
    }

    // MARK: - Text Processing

    private func cleanTranscriptionText(_ text: String) -> String {
        return text
            .replacingOccurrences(of: "\\[.*?\\]|\\(.*?\\)", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Vocabulary File Workaround

    /// Ensures the vocabulary file is present. FluidAudio has a bug where it doesn't download
    /// JSON files at the root level of the HuggingFace repo.
    private func ensureVocabularyFile() async throws {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw SpeechRecognitionError.downloadFailed("Unable to locate Application Support directory")
        }
        let modelsDir = appSupport
            .appendingPathComponent("FluidAudio", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
            .appendingPathComponent("parakeet-tdt-0.6b-v3-coreml", isDirectory: true)

        // Create directory if needed
        try FileManager.default.createDirectory(at: modelsDir, withIntermediateDirectories: true)

        let vocabPath = modelsDir.appendingPathComponent("parakeet_vocab.json")

        // Check if vocabulary file already exists
        if FileManager.default.fileExists(atPath: vocabPath.path) {
            logger.debug("Vocabulary file already exists")
            return
        }

        logger.info("Downloading vocabulary file (workaround for FluidAudio bug)")

        // Download the vocabulary file
        let (data, response) = try await URLSession.shared.data(from: Self.vocabURL)

        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            throw SpeechRecognitionError.downloadFailed("Failed to download vocabulary file")
        }

        try data.write(to: vocabPath)
        logger.info("Vocabulary file downloaded successfully")
    }
}
