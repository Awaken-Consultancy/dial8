//
//  SpeechRecognitionManager.swift
//  dial8 MacOS
//
//  Coordinator that manages speech recognition engines and delegates
//  transcription requests to the user-selected engine.
//

import Foundation
import Combine
import os.log

@MainActor
class SpeechRecognitionManager: ObservableObject {
    static let shared = SpeechRecognitionManager()

    private let logger = Logger(subsystem: "com.dial8", category: "SpeechRecognitionManager")

    // MARK: - Published Properties

    @Published var selectedEngineType: SpeechEngineType {
        didSet {
            UserDefaults.standard.setValue(selectedEngineType.rawValue, forKey: "SelectedSpeechEngine")
            logger.info("Speech engine changed to: \(self.selectedEngineType.rawValue)")
        }
    }

    // MARK: - Engines

    let whisperEngine = WhisperManager.shared
    let parakeetEngine = ParakeetEngine()

    // MARK: - Computed Properties

    /// Returns the currently selected engine
    var currentEngine: any SpeechRecognitionEngine {
        switch selectedEngineType {
        case .whisper:
            return whisperEngine
        case .parakeet:
            return parakeetEngine
        }
    }

    /// Whether the current engine is ready
    var isReady: Bool {
        currentEngine.isReady
    }

    /// Whether the current engine is downloading
    var isDownloading: Bool {
        currentEngine.isDownloading
    }

    /// Download progress of the current engine
    var downloadProgress: Double {
        currentEngine.downloadProgress
    }

    /// Error message from the current engine
    var errorMessage: String? {
        currentEngine.errorMessage
    }

    /// Languages supported by the current engine
    var supportedLanguages: [String] {
        currentEngine.supportedLanguages
    }

    // MARK: - Initialization

    private init() {
        // Load saved engine preference
        if let savedEngine = UserDefaults.standard.string(forKey: "SelectedSpeechEngine"),
           let engineType = SpeechEngineType(rawValue: savedEngine) {
            self.selectedEngineType = engineType
        } else {
            // Default to Parakeet for new users
            self.selectedEngineType = .parakeet
        }

        setupObservers()
        logger.info("🎤 SpeechRecognitionManager initialized with engine: \(self.selectedEngineType.rawValue)")
        logger.info("🎤 Whisper isReady: \(self.whisperEngine.isReady), Parakeet isReady: \(self.parakeetEngine.isReady)")
    }

    // MARK: - Observers

    private var cancellables = Set<AnyCancellable>()

    private func setupObservers() {
        // Forward engine state changes to trigger UI updates
        whisperEngine.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)

        parakeetEngine.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
    }

    // MARK: - Public Methods

    /// Download the model for the current engine
    func downloadCurrentModel() {
        switch selectedEngineType {
        case .whisper:
            whisperEngine.downloadModel(modelId: whisperEngine.selectedModelId)
        case .parakeet:
            parakeetEngine.downloadModel(modelId: "parakeet-v3")
        }
    }

    /// Transcribe audio using the current engine
    func transcribe(audioURL: URL, language: String?, completion: @escaping (Result<String, Error>) -> Void) {
        logger.info("🎤 Transcribing with \(self.selectedEngineType.rawValue) engine (isReady: \(self.isReady))")
        currentEngine.transcribe(audioURL: audioURL, language: language, completion: completion)
    }

    /// Wait until the current engine is ready
    func waitUntilReady() async {
        await currentEngine.waitUntilReady()
    }

    /// Check if a language is supported by the current engine
    func isLanguageSupported(_ language: String) -> Bool {
        supportedLanguages.contains(language.lowercased()) || supportedLanguages.contains("auto")
    }

    /// Get the recommended engine for a given language (Parakeet is the default product engine).
    func recommendedEngine(for language: String) -> SpeechEngineType {
        .parakeet
    }

    // MARK: - Engine-Specific Access

    /// Access Whisper-specific features (model selection, etc.)
    func whisperDownloadModel(modelSize: String) {
        whisperEngine.downloadModel(modelSize: modelSize)
    }

    func whisperSelectModel(modelSize: String) {
        whisperEngine.selectModel(modelSize: modelSize)
    }

    func whisperDeleteModel(modelSize: String) {
        whisperEngine.deleteModel(modelSize: modelSize)
    }

    // MARK: - Migration

    /// Reserved for future migrations; Parakeet is the default engine (do not auto-switch to Whisper).
    func migrateFromLegacySettings() {
    }
}
