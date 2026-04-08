//
//  WhisperManager.swift
//  dial8 MacOS
//
//  Created by Liam Alizadeh on 10/18/24.
//

/// WhisperManager handles all aspects of the Whisper speech recognition system.
///
/// This singleton service provides comprehensive speech recognition functionality:
///
/// Core Features:
/// - Model Management:
///   • Download and storage of Whisper models
///   • Model selection and persistence
///   • Automatic model verification
///   • Hardware-specific optimizations
///
/// Supported Models:
/// - Base: Fast, English-optimized model
/// - Small: High-accuracy English model
/// - Medium: Multilingual model
///
/// Hardware Support:
/// - ARM64 (Apple Silicon) optimization
/// - x86_64 with AVX2 support
/// - Fallback x86_64 compatibility
///
/// Functionality:
/// - Speech transcription
/// - Multiple recording modes
/// - Progress tracking
/// - Error handling
/// - Automatic language detection
///
/// File Management:
/// - Secure model storage
/// - Automatic cleanup
/// - Download progress tracking
/// - Model integrity verification
///
/// Usage:
/// ```swift
/// let manager = WhisperManager.shared
///
/// // Download a model
/// manager.downloadModel(modelSize: "Base")
///
/// // Transcribe audio
/// manager.transcribe(audioURL: url, mode: .transcriptionOnly) { result in
///     switch result {
///     case .success(let transcription):
///         // use transcription
///     case .failure(let error):
///         // handle error
///     }
/// }
/// ```
///
/// Note: This manager handles hardware-specific optimizations automatically,
/// selecting the appropriate Whisper executable based on the system architecture.

import Foundation
import Combine
import AppKit  // Add AppKit import for NSWorkspace and NSApplication
import os
import CryptoKit

/// Logger safe to use from background queues (avoids MainActor isolation on `WhisperManager`).
private let whisperProcessLogger = Logger(subsystem: "com.dial8", category: "WhisperManager")

/// File-level hashes so `nonisolated` verification does not touch `@MainActor` storage (Swift 6).
private enum WhisperModelIntegrityHashes {
    static let byFileName: [String: String] = [
        "ggml-small.bin": "PLACEHOLDER_HASH_small_REPLACE_WITH_ACTUAL_SHA256",
        "ggml-large-v3.bin": "PLACEHOLDER_HASH_largev3_REPLACE_WITH_ACTUAL_SHA256",
        "ggml-large-v3-turbo.bin": "PLACEHOLDER_HASH_largev3turbo_REPLACE_WITH_ACTUAL_SHA256"
    ]
}

/// SRT parsing without touching `@MainActor` (used from background transcription queue).
private enum WhisperSRTParser {
    static func parseContent(_ srtContent: String, recordingStartTime _: Date) -> [WhisperTranscriptionSegment] {
        var segments: [WhisperTranscriptionSegment] = []
        let lines = srtContent.components(separatedBy: .newlines)

        var currentIndex = 0
        while currentIndex < lines.count {
            let line = lines[currentIndex].trimmingCharacters(in: .whitespacesAndNewlines)

            if line.isEmpty {
                currentIndex += 1
                continue
            }

            if Int(line) != nil {
                if currentIndex + 1 < lines.count {
                    let timestampLine = lines[currentIndex + 1]

                    if let (startTime, endTime) = parseTimestamp(timestampLine) {
                        var textLines: [String] = []
                        var textIndex = currentIndex + 2

                        while textIndex < lines.count {
                            let textLine = lines[textIndex].trimmingCharacters(in: .whitespacesAndNewlines)
                            if textLine.isEmpty || Int(textLine) != nil {
                                break
                            }
                            textLines.append(textLine)
                            textIndex += 1
                        }

                        let fullText = textLines.joined(separator: " ")
                        let cleanedText = cleanTranscriptionText(fullText)

                        if !cleanedText.isEmpty {
                            let segment = WhisperTranscriptionSegment(
                                startTime: startTime,
                                endTime: endTime,
                                text: cleanedText
                            )
                            segments.append(segment)
                        }

                        currentIndex = textIndex
                    } else {
                        currentIndex += 1
                    }
                } else {
                    currentIndex += 1
                }
            } else {
                currentIndex += 1
            }
        }

        return segments
    }

    private static func parseTimestamp(_ timestampLine: String) -> (TimeInterval, TimeInterval)? {
        let components = timestampLine.components(separatedBy: " --> ")
        guard components.count == 2 else { return nil }

        guard let startTime = parseSRTTime(components[0]),
              let endTime = parseSRTTime(components[1]) else {
            return nil
        }

        return (startTime, endTime)
    }

    private static func parseSRTTime(_ timeString: String) -> TimeInterval? {
        let cleaned = timeString.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = cleaned.components(separatedBy: ",")
        guard parts.count == 2 else { return nil }

        let timePart = parts[0]
        guard let milliseconds = Int(parts[1]) else { return nil }

        let timeComponents = timePart.components(separatedBy: ":")
        guard timeComponents.count == 3,
              let hours = Int(timeComponents[0]),
              let minutes = Int(timeComponents[1]),
              let seconds = Int(timeComponents[2]) else {
            return nil
        }

        let totalSeconds = TimeInterval(hours * 3600 + minutes * 60 + seconds)
        return totalSeconds + TimeInterval(milliseconds) / 1000.0
    }

    private static func cleanTranscriptionText(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\[.*?\\]|\\(.*?\\)|♪.*?♪", with: "", options: .regularExpression)
            .replacingOccurrences(of: "♪", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Error thrown when model integrity verification fails
enum ModelIntegrityError: Error, LocalizedError {
    case hashMismatch(fileName: String, expected: String, actual: String)

    var errorDescription: String? {
        switch self {
        case .hashMismatch(let fileName, let expected, let actual):
            return "SHA-256 hash mismatch for \(fileName). Expected: \(expected), got: \(actual)"
        }
    }
}

// Move ModelDisplayInfo to WhisperManager since it's model-related metadata
struct ModelDisplayInfo {
    let id: String
    let displayName: String
    let icon: String
    let description: String
    let recommendation: String?  // Optional recommendation text
}

struct WhisperModelInfo: Identifiable {
    let id: String
    let name: String
    let fileName: String
    let size: String
    let fileSize: UInt64
    var isAvailable: Bool
    var isSelected: Bool
    let description: String
    // Add display info
    var displayInfo: ModelDisplayInfo
}

/// Represents a timestamped segment from Whisper transcription
struct WhisperTranscriptionSegment {
    let startTime: TimeInterval
    let endTime: TimeInterval
    let text: String
    
    var duration: TimeInterval {
        return endTime - startTime
    }
}

@MainActor
class WhisperManager: NSObject, ObservableObject, URLSessionDownloadDelegate, SpeechRecognitionEngine {
    static let shared = WhisperManager()
    
    private let logger = Logger(subsystem: "com.dial8", category: "WhisperManager")

    // MARK: - SpeechRecognitionEngine Protocol Properties

    let engineName = "Whisper"

    let supportedLanguages = [
        "auto", "english", "chinese", "german", "spanish", "russian", "korean",
        "french", "japanese", "portuguese", "turkish", "polish", "catalan",
        "dutch", "arabic", "swedish", "italian", "indonesian", "hindi"
    ]

    var selectedModelId: String {
        get { selectedModelSize }
        set { selectedModelSize = newValue }
    }

    // MARK: - Published Properties

    @Published var isDownloading = false
    @Published var downloadProgress: Double = 0.0
    @Published var isReady = false
    @Published var errorMessage: String?
    @Published var availableModels: [WhisperModelInfo] = []
    @Published var selectedModelSize: String = "Small"

    // Process management
    private var processQueue = DispatchQueue(label: "com.dial8.whisper.process", qos: .userInitiated)
    private let processLock = NSLock()
    private var preloadedModel: URL?
    private var preloadedModelSize: String?
    private var isPreloading = false
    private var lastModelUseTime: Date?
    private let modelReloadThreshold: TimeInterval = 300 // 5 minutes

    var whisperModelURL: URL?
    private var modelFileName: String = ""
    private var cancellables = Set<AnyCancellable>()

    // Computed property to get the local URL for the selected model
    private var modelLocalURL: URL {
        getModelDirectory().appendingPathComponent(modelFileName)
    }

    private var downloadSession: URLSession?
    private var downloadTask: URLSessionDownloadTask?

    weak var globalHotkeyManager: GlobalHotkeyManager?

    // Add model display mapping as a static property
    private static let modelDisplayInfo: [String: ModelDisplayInfo] = [
        "Small": ModelDisplayInfo(
            id: "Small",
            displayName: "Small",
            icon: "scope",
            description: "Higher accuracy with slightly longer processing time. Ideal when precision matters most.",
            recommendation: "Best accuracy for English"
        ),
        "largev3": ModelDisplayInfo(
            id: "largev3",
            displayName: "Large V3",
            icon: "star.circle",
            description: "Highest accuracy model for professional transcription and complex audio.",
            recommendation: "Best for professional use"
        ),
        "largev3turbo": ModelDisplayInfo(
            id: "largev3turbo",
            displayName: "Large V3 Turbo",
            icon: "bolt.circle.fill",
            description: "Optimized large model with faster processing while maintaining high accuracy.",
            recommendation: "Best balance of speed and accuracy"
        )
    ]

    override init() {
        super.init()
        loadSelectedModel()
        loadAvailableModels()
        preloadSelectedModel()
        setupNotifications()
    }

    deinit {
        // No special cleanup needed anymore
    }

    // Get or create the directory for storing Whisper models
    private nonisolated func getModelDirectory() -> URL {
        let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let modelDirectory = applicationSupport.appendingPathComponent("Whisper")
        if !FileManager.default.fileExists(atPath: modelDirectory.path) {
            try? FileManager.default.createDirectory(at: modelDirectory, withIntermediateDirectories: true)
        }
        return modelDirectory
    }

    // Load the previously selected model from UserDefaults
    private func loadSelectedModel() {
        // Always use Small model instead of Base
        selectedModelSize = "Small"
        // Save this to UserDefaults
        UserDefaults.standard.setValue(selectedModelSize, forKey: "SelectedWhisperModel")
    }

    // Load information about available Whisper models
    private func loadAvailableModels() {
        // Include Small, largev3, and largev3turbo models
        let models = [
            ("Small", "ggml-small.bin"),
            ("largev3", "ggml-large-v3.bin"),
            ("largev3turbo", "ggml-large-v3-turbo.bin")
        ]

        var modelsInfo: [WhisperModelInfo] = []
        var selectedModelAvailable = false

        for (size, fileName) in models {
            let fileURL = getModelDirectory().appendingPathComponent(fileName)
            let isAvailable = FileManager.default.fileExists(atPath: fileURL.path)
            let fileSize = isAvailable ? (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? UInt64) ?? 0 : 0
            let sizeString = isAvailable ? ByteCountFormatter.string(fromByteCount: Int64(fileSize), countStyle: .file) : ""
            let isSelected = size == selectedModelSize

            if isSelected {
                selectedModelAvailable = true
            }

            // Get display info from static mapping
            let displayInfo = Self.modelDisplayInfo[size] ?? ModelDisplayInfo(
                id: size,
                displayName: "Unknown Model",
                icon: "questionmark.circle",
                description: "Unknown model type.",
                recommendation: nil
            )

            let modelInfo = WhisperModelInfo(
                id: size,
                name: displayInfo.displayName, // Use display name instead of default name
                fileName: fileName,
                size: sizeString,
                fileSize: fileSize,
                isAvailable: isAvailable,
                isSelected: isSelected,
                description: displayInfo.description,
                displayInfo: displayInfo
            )

            modelsInfo.append(modelInfo)
        }

        DispatchQueue.main.async {
            self.availableModels = modelsInfo
            self.isReady = selectedModelAvailable
        }
    }

    // Start the setup process for a given model size
    func startSetup(modelSize: String? = nil) {
        // Use provided model size or default to Small
        selectedModelSize = modelSize ?? "Small"
        UserDefaults.standard.setValue(selectedModelSize, forKey: "SelectedWhisperModel")
        
        // Update the UI state
        isReady = availableModels.first(where: { $0.id == selectedModelSize })?.isAvailable ?? false
        
        // Reload models to update UI
        loadAvailableModels()
    }

    // Download the specified Whisper model
    func downloadModel(modelSize: String) {
        // Map model size to file name
        let fileName: String
        switch modelSize {
        case "Small":
            fileName = "ggml-small.bin"
        case "largev3":
            fileName = "ggml-large-v3.bin"
        case "largev3turbo":
            fileName = "ggml-large-v3-turbo.bin"
        default:
            fileName = "ggml-small.bin" // Default fallback
        }
        
        let urlString = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/\(fileName)"
        guard let url = URL(string: urlString) else { return }

        isDownloading = true
        downloadProgress = 0.0
        whisperModelURL = url
        modelFileName = fileName

        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        let task = session.downloadTask(with: url)
        task.resume()
    }

    // Select a different Whisper model
    func selectModel(modelSize: String) {
        // Use the provided model size
        selectedModelSize = modelSize
        UserDefaults.standard.setValue(selectedModelSize, forKey: "SelectedWhisperModel")
        loadAvailableModels()
        preloadSelectedModel() // Preload the newly selected model
    }

    // Delete a downloaded Whisper model
    func deleteModel(modelSize: String) {
        guard let modelInfo = availableModels.first(where: { $0.id == modelSize }) else { return }

        let fileURL = getModelDirectory().appendingPathComponent(modelInfo.fileName)
        do {
            try FileManager.default.removeItem(at: fileURL)
            if selectedModelSize == modelSize {
                selectedModelSize = ""
                isReady = false
                UserDefaults.standard.setValue(selectedModelSize, forKey: "SelectedWhisperModel")

                // Clear preloaded model state
                preloadedModel = nil
                preloadedModelSize = nil
            }
            loadAvailableModels()
        } catch {
            DispatchQueue.main.async {
                self.errorMessage = "Failed to delete model: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - SpeechRecognitionEngine Protocol Methods

    /// Protocol-conforming wrapper for downloadModel
    func downloadModel(modelId: String) {
        downloadModel(modelSize: modelId)
    }

    /// Protocol-conforming wrapper for selectModel
    func selectModel(modelId: String) {
        selectModel(modelSize: modelId)
    }

    /// Protocol-conforming wrapper for deleteModel
    func deleteModel(modelId: String) {
        deleteModel(modelSize: modelId)
    }

    /// Protocol-conforming transcription method
    func transcribe(audioURL: URL, language: String?, completion: @escaping (Result<String, Error>) -> Void) {
        transcribe(audioURL: audioURL, mode: .transcriptionOnly, targetLanguage: language, completion: completion)
    }

    private func preloadSelectedModel() {
        Task { @MainActor in
            guard !isPreloading else { return }
            guard let selectedModel = availableModels.first(where: { $0.id == selectedModelSize }) else { return }

            isPreloading = true

            let modelPath = getModelDirectory().appendingPathComponent(selectedModel.fileName)
            guard FileManager.default.fileExists(atPath: modelPath.path) else {
                logger.error("Model file does not exist at path: \(modelPath.path, privacy: .public)")
                isPreloading = false
                return
            }

            guard let whisperURL = getWhisperExecutable() else {
                logger.error("Whisper executable not found")
                isPreloading = false
                return
            }

            let modelFileName = selectedModel.fileName
            let modelId = selectedModel.id

            processQueue.async { [weak self] in
                guard let self = self else { return }
                self.processLock.lock()
                defer { self.processLock.unlock() }

                let process = Process()
                process.executableURL = whisperURL

                let tempDir = FileManager.default.temporaryDirectory
                let testFile = tempDir.appendingPathComponent("preload_test.txt")
                try? "test".write(to: testFile, atomically: true, encoding: .utf8)

                process.arguments = [
                    "-m", modelPath.path,
                    "-f", testFile.path,
                    "--no-timestamps",
                    "--language", "auto"
                ]

                let outputPipe = Pipe()
                process.standardOutput = outputPipe
                process.standardError = outputPipe

                do {
                    try process.run()
                    process.waitUntilExit()
                    try? FileManager.default.removeItem(at: testFile)

                    if process.terminationStatus == 0 {
                        whisperProcessLogger.info("Model preloaded successfully: \(modelFileName, privacy: .public)")
                        Task { @MainActor in
                            self.preloadedModel = modelPath
                            self.preloadedModelSize = modelId
                            self.isReady = true
                            self.isPreloading = false
                        }
                    } else {
                        whisperProcessLogger.error("Failed to preload model")
                        Task { @MainActor in
                            self.preloadedModel = nil
                            self.preloadedModelSize = nil
                            self.isPreloading = false
                        }
                    }
                } catch {
                    whisperProcessLogger.error("Error preloading model: \(error.localizedDescription, privacy: .public)")
                    Task { @MainActor in
                        self.preloadedModel = nil
                        self.preloadedModelSize = nil
                        self.isPreloading = false
                    }
                }
            }
        }
    }

    private func setupNotifications() {
        #if os(macOS)
        // Register for sleep/wake notifications
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleSleepNotification(_:)),
            name: NSWorkspace.willSleepNotification,
            object: nil as Any?
        )
        
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleWakeNotification(_:)),
            name: NSWorkspace.didWakeNotification,
            object: nil as Any?
        )
        
        // Register for app state changes
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAppStateChange(_:)),
            name: NSApplication.willResignActiveNotification,
            object: nil as Any?
        )
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAppStateChange(_:)),
            name: NSApplication.didBecomeActiveNotification,
            object: nil as Any?
        )
        #endif
    }

    @objc private func handleSleepNotification(_ notification: Notification) {
        self.logger.info("System going to sleep - clearing model state")
        processLock.lock()
        defer { processLock.unlock() }
        
        preloadedModel = nil
        preloadedModelSize = nil
        lastModelUseTime = nil
    }

    @objc private func handleWakeNotification(_ notification: Notification) {
        self.logger.info("System waking up - preloading model")
        preloadSelectedModel()
    }

    @objc private func handleAppStateChange(_ notification: Notification) {
        if notification.name == NSApplication.willResignActiveNotification {
            self.logger.debug("App entering background")
            // No immediate action needed, we'll check state when used
        } else if notification.name == NSApplication.didBecomeActiveNotification {
            self.logger.debug("App becoming active - verifying model state")
            verifyModelState()
        }
    }

    private func verifyModelState() {
        processLock.lock()
        defer { processLock.unlock() }
        
        // Check if we need to reload based on time threshold
        if let lastUse = lastModelUseTime,
           Date().timeIntervalSince(lastUse) > modelReloadThreshold {
            self.logger.warning("Model state expired - reloading")
            preloadedModel = nil
            preloadedModelSize = nil
            preloadSelectedModel()
        }
    }

    func transcribe(audioURL: URL, mode: RecordingMode, targetLanguage: String? = nil, completion: @escaping (Result<String, Error>) -> Void) {
        // Update last use time
        lastModelUseTime = Date()
        
        // Verify model state before proceeding
        verifyModelState()
        
        guard isReady else {
            completion(.failure(NSError(domain: "WhisperManager", code: 0, userInfo: [NSLocalizedDescriptionKey: "Model is not ready"])))
            return
        }

        // Ensure we have the correct model loaded
        if preloadedModelSize != selectedModelSize {
            preloadSelectedModel()
        }

        guard let modelURL = preloadedModel else {
            completion(.failure(NSError(domain: "WhisperManager", code: 1, userInfo: [NSLocalizedDescriptionKey: "Model not preloaded"])))
            return
        }
        guard let whisperExecURL = getWhisperExecutable() else {
            completion(.failure(NSError(domain: "WhisperManager", code: 2, userInfo: [NSLocalizedDescriptionKey: "Whisper executable not found"])))
            return
        }

        processQueue.async { [weak self] in
            guard let self = self else { return }
            self.processLock.lock()
            defer { self.processLock.unlock() }

            // Create a temporary directory for this transcription
            let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("whisper_\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            let outputFile = tempDir.appendingPathComponent("transcription")

            let process = Process()
            process.executableURL = whisperExecURL

            // Set up pipes for output
            let outputPipe = Pipe()
            process.standardOutput = outputPipe
            process.standardError = outputPipe

            // Configure arguments based on mode - NOTE: Whisper automatically adds .txt extension to output file
            var arguments = [
                "-m", modelURL.path,
                "-otxt",
                "--no-timestamps",
                "-t", "8",  // Use 8 threads for faster processing on Apple Silicon
                "-p", "1",  // Single processor for better latency
                "-bs", "5", // Reduce beam size for faster processing (default is 5)
                "--best-of", "1", // Reduce best-of candidates for speed
                "-of", outputFile.path,
                audioURL.path
            ]

            switch mode {
            case .transcriptionOnly:
                arguments += ["--language", targetLanguage ?? "auto"]
            // case .meetingTranscription has been removed - all transcriptions use the same settings
            }

            process.arguments = arguments
            process.currentDirectoryURL = tempDir

            do {
                try process.run()
                process.waitUntilExit()

                let exitCode = process.terminationStatus
                if exitCode != 0 {
                    let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
                    let output = String(data: outputData, encoding: .utf8) ?? ""
                    throw NSError(domain: "WhisperManager", code: Int(exitCode), 
                                userInfo: [NSLocalizedDescriptionKey: "Process failed: \(output)"])
                }

                // Read the transcription - Whisper adds .txt extension automatically
                let transcriptionFile = outputFile.appendingPathExtension("txt")
                
                // Check if file exists before trying to read it
                if !FileManager.default.fileExists(atPath: transcriptionFile.path) {
                    whisperProcessLogger.warning("Transcription file not found at expected path: \(transcriptionFile.path, privacy: .public)")
                    whisperProcessLogger.debug("Directory contents:")
                    if let contents = try? FileManager.default.contentsOfDirectory(atPath: tempDir.path) {
                        whisperProcessLogger.debug("\(contents.joined(separator: ", "), privacy: .public)")
                    }
                    
                    // Try to read from process output instead
                    let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
                    if let output = String(data: outputData, encoding: .utf8), !output.isEmpty {
                        whisperProcessLogger.debug("Using process output for transcription instead")
                        throw NSError(domain: "WhisperManager", code: 404, 
                                    userInfo: [NSLocalizedDescriptionKey: "Transcription file not found, but process output available: \(output)"])
                    }
                    
                    throw NSError(domain: "WhisperManager", code: 404, 
                                userInfo: [NSLocalizedDescriptionKey: "Transcription file not found at: \(transcriptionFile.path)"])
                }
                
                // Read the transcription file
                let transcription = try String(contentsOf: transcriptionFile, encoding: .utf8)

                // Clean up
                try? FileManager.default.removeItem(at: tempDir)

                // Filter and process the transcription
                let filteredTranscription = transcription
                    .components(separatedBy: .newlines)
                    .map { line -> String in
                        line.replacingOccurrences(of: "\\[.*?\\]|\\(.*?\\)|♪.*?♪", with: "", options: .regularExpression)
                            .replacingOccurrences(of: "♪", with: "")
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                    .filter { !$0.isEmpty }
                    .joined(separator: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                DispatchQueue.main.async {
                    completion(.success(filteredTranscription))
                }
            } catch {
                // Clean up on error
                try? FileManager.default.removeItem(at: tempDir)
                DispatchQueue.main.async {
                    completion(.failure(error))
                }
            }
        }
    }
    
    /// Transcribe audio with timestamps for meeting mode
    func transcribeWithTimestamps(audioURL: URL, recordingStartTime: Date, targetLanguage: String? = nil, completion: @escaping (Result<[WhisperTranscriptionSegment], Error>) -> Void) {
        // Update last use time
        lastModelUseTime = Date()
        
        // Verify model state before proceeding
        verifyModelState()
        
        guard isReady else {
            completion(.failure(NSError(domain: "WhisperManager", code: 0, userInfo: [NSLocalizedDescriptionKey: "Model is not ready"])))
            return
        }

        // Ensure we have the correct model loaded
        if preloadedModelSize != selectedModelSize {
            preloadSelectedModel()
        }

        guard let modelURL = preloadedModel else {
            completion(.failure(NSError(domain: "WhisperManager", code: 1, userInfo: [NSLocalizedDescriptionKey: "Model not preloaded"])))
            return
        }
        guard let whisperExecURL = getWhisperExecutable() else {
            completion(.failure(NSError(domain: "WhisperManager", code: 2, userInfo: [NSLocalizedDescriptionKey: "Whisper executable not found"])))
            return
        }

        processQueue.async { [weak self] in
            guard let self = self else { return }
            self.processLock.lock()
            defer { self.processLock.unlock() }

            // Create a temporary directory for this transcription
            let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("whisper_\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            let outputFile = tempDir.appendingPathComponent("transcription")

            let process = Process()
            process.executableURL = whisperExecURL

            // Set up pipes for output
            let outputPipe = Pipe()
            process.standardOutput = outputPipe
            process.standardError = outputPipe

            // Configure arguments for timestamped output (SRT format for easy parsing)
            let arguments = [
                "-m", modelURL.path,
                "-osrt",  // Output SRT format for timestamps
                "-of", outputFile.path,
                "--language", targetLanguage ?? "auto",
                audioURL.path
            ]

            process.arguments = arguments
            process.currentDirectoryURL = tempDir

            do {
                try process.run()
                process.waitUntilExit()

                let exitCode = process.terminationStatus
                if exitCode != 0 {
                    let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
                    let output = String(data: outputData, encoding: .utf8) ?? ""
                    throw NSError(domain: "WhisperManager", code: Int(exitCode), 
                                userInfo: [NSLocalizedDescriptionKey: "Process failed: \(output)"])
                }

                // Read the SRT file - Whisper adds .srt extension automatically
                let srtFile = outputFile.appendingPathExtension("srt")
                
                // Check if file exists before trying to read it
                if !FileManager.default.fileExists(atPath: srtFile.path) {
                    whisperProcessLogger.warning("SRT file not found at expected path: \(srtFile.path, privacy: .public)")
                    whisperProcessLogger.debug("Directory contents:")
                    if let contents = try? FileManager.default.contentsOfDirectory(atPath: tempDir.path) {
                        whisperProcessLogger.debug("\(contents.joined(separator: ", "), privacy: .public)")
                    }
                    
                    throw NSError(domain: "WhisperManager", code: 404, 
                                userInfo: [NSLocalizedDescriptionKey: "SRT file not found at: \(srtFile.path)"])
                }
                
                // Read and parse the SRT file
                let srtContent = try String(contentsOf: srtFile, encoding: .utf8)
                let segments = WhisperSRTParser.parseContent(srtContent, recordingStartTime: recordingStartTime)

                // Clean up
                try? FileManager.default.removeItem(at: tempDir)

                DispatchQueue.main.async {
                    completion(.success(segments))
                }
            } catch {
                // Clean up on error
                try? FileManager.default.removeItem(at: tempDir)
                DispatchQueue.main.async {
                    completion(.failure(error))
                }
            }
        }
    }

    // MARK: - Model Integrity Verification

    /// Computes the SHA-256 hash of a file at the given URL
    private nonisolated func computeSHA256Hash(for fileURL: URL) throws -> String {
        let fileData = try Data(contentsOf: fileURL)
        let hash = SHA256.hash(data: fileData)
        return hash.compactMap { String(format: "%02x", $0) }.joined()
    }

    /// Verifies the integrity of a downloaded model file by comparing its SHA-256 hash
    /// - Parameters:
    ///   - fileURL: The URL of the downloaded model file
    ///   - fileName: The name of the model file
    /// - Throws: `ModelIntegrityError.hashMismatch` if the hash doesn't match the expected value
    private nonisolated func verifyModelIntegrity(fileURL: URL, fileName: String) throws {
        guard let expectedHash = WhisperModelIntegrityHashes.byFileName[fileName] else {
            whisperProcessLogger.warning("No SHA-256 hash registered for model: \(fileName, privacy: .public). Skipping integrity verification.")
            return
        }

        if expectedHash.hasPrefix("PLACEHOLDER_HASH_") {
            whisperProcessLogger.warning("Placeholder hash detected for \(fileName, privacy: .public). Skipping integrity verification. TODO: Add real SHA-256 hash.")
            return
        }

        let actualHash = try computeSHA256Hash(for: fileURL)

        guard actualHash == expectedHash else {
            throw ModelIntegrityError.hashMismatch(
                fileName: fileName,
                expected: expectedHash,
                actual: actualHash
            )
        }

        whisperProcessLogger.info("Model integrity verified for \(fileName, privacy: .public)")
    }

    // MARK: - URLSessionDownloadDelegate Methods

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        do {
            let fileManager = FileManager.default

            // Use getFileName(for:) to get the destination file name
            let destinationFileName = getFileName(for: downloadTask.originalRequest?.url)
            let destinationURL = getModelDirectory().appendingPathComponent(destinationFileName)

            // Remove existing file if necessary
            if fileManager.fileExists(atPath: destinationURL.path) {
                try fileManager.removeItem(at: destinationURL)
            }

            // Move the file from the temporary location to the destination URL
            try fileManager.moveItem(at: location, to: destinationURL)

            // Verify the integrity of the downloaded model
            try verifyModelIntegrity(fileURL: destinationURL, fileName: destinationFileName)

            DispatchQueue.main.async {
                self.isDownloading = false
                self.downloadProgress = 1.0
                self.isReady = true
                
                // Automatically select the newly downloaded model
                if let modelSize = self.availableModels.first(where: { $0.fileName == destinationFileName })?.id {
                    self.selectModel(modelSize: modelSize)
                }
                
                self.loadAvailableModels()  // Update available models
            }
        } catch ModelIntegrityError.hashMismatch(let fileName, let expected, let actual) {
            // Delete the corrupted file
            let fileManager = FileManager.default
            let destinationURL = self.getModelDirectory().appendingPathComponent(fileName)
            try? fileManager.removeItem(at: destinationURL)

            DispatchQueue.main.async {
                self.errorMessage = "Model integrity check failed for \(fileName). The downloaded file may be corrupted. Please try again."
                self.isDownloading = false
                self.downloadProgress = 0.0
                self.logger.error("SHA-256 hash mismatch for \(fileName, privacy: .public): expected \(expected, privacy: .public) actual \(actual, privacy: .public)")
            }
        } catch {
            // Delete the file if it exists (in case verification failed mid-move)
            let fileManager = FileManager.default
            let destinationFileName = self.getFileName(for: downloadTask.originalRequest?.url)
            let destinationURL = self.getModelDirectory().appendingPathComponent(destinationFileName)
            try? fileManager.removeItem(at: destinationURL)

            DispatchQueue.main.async {
                self.errorMessage = "Failed to download model: \(error.localizedDescription)"
                self.isDownloading = false
            }
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error {
            DispatchQueue.main.async {
                self.errorMessage = error.localizedDescription
                self.isDownloading = false
            }
        }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        let progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        DispatchQueue.main.async {
            self.downloadProgress = progress
        }
    }

    // Helper functions to get URLs and file names...

    private nonisolated func getFileName(for url: URL?) -> String {
        return url?.lastPathComponent ?? "downloaded_file"
    }

    private func detectCPUCapabilities() -> (architecture: String, features: Set<String>) {
        #if arch(arm64)
        return ("arm64", ["neon", "arm64"])
        #else
        // Only support Apple Silicon
        fatalError("This application only supports Apple Silicon Macs")
        #endif
    }

    nonisolated private func getWhisperExecutable() -> URL? {
        Bundle.main.url(forResource: "whisper", withExtension: nil)
    }

    func waitUntilReady() async {
        // Wait for up to 5 seconds for the model to be ready
        for _ in 0..<50 {
            if isReady {
                return
            }
            try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 second
        }
    }
}