import Foundation
import AVFoundation
import Combine
import SwiftUI
import os.log

class AudioTranscriptionService: ObservableObject {
    // Singleton instance
    static let shared = AudioTranscriptionService()

    private let logger = Logger(subsystem: "com.dial8", category: "AudioTranscriptionService")

    // Published properties
    @Published var useLocalSpeechModel = true
    @Published var speechModelIsReady: Bool = false
    @Published private(set) var accumulatedText: String = ""
    @Published private(set) var isProcessingSpeech = false

    // Current language selection
    private var selectedLanguage: String = UserDefaults.standard.string(forKey: "selectedLanguage") ?? "english"

    private var cancellables = Set<AnyCancellable>()

    private init() {
        // Force useLocalSpeechModel to always be true
        self.useLocalSpeechModel = true
        UserDefaults.standard.set(true, forKey: "useLocalWhisperModel")

        // Setup observers on main actor
        Task { @MainActor in
            self.setupObservers()

            // Start setup based on selected engine
            if SpeechRecognitionManager.shared.selectedEngineType == .whisper {
                WhisperManager.shared.startSetup()
            }
        }

        // Observe changes to the 'useLocalWhisperModel' key in UserDefaults
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleUserDefaultsChanged),
            name: UserDefaults.didChangeNotification,
            object: nil
        )

        // Add observer for language changes
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleLanguageChanged),
            name: NSNotification.Name("SelectedLanguageChanged"),
            object: nil
        )
    }

    @MainActor
    private func setupObservers() {
        let manager = SpeechRecognitionManager.shared

        // Observe both engines' isReady states
        WhisperManager.shared.$isReady
            .combineLatest(manager.parakeetEngine.$isReady)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] whisperReady, parakeetReady in
                guard let self = self else { return }
                // Model is ready if the currently selected engine is ready
                if SpeechRecognitionManager.shared.selectedEngineType == .whisper {
                    self.speechModelIsReady = whisperReady
                } else {
                    self.speechModelIsReady = parakeetReady
                }
            }
            .store(in: &cancellables)

        // Also observe engine type changes
        manager.$selectedEngineType
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self = self else { return }
                self.speechModelIsReady = SpeechRecognitionManager.shared.isReady
            }
            .store(in: &cancellables)
    }
    
    @objc private func handleUserDefaultsChanged(_ notification: Notification) {
        let newValue = UserDefaults.standard.bool(forKey: "useLocalWhisperModel")
        if newValue != self.useLocalSpeechModel {
            self.useLocalSpeechModel = newValue

            if newValue {
                // Start setup based on selected engine
                Task { @MainActor in
                    if SpeechRecognitionManager.shared.selectedEngineType == .whisper {
                        WhisperManager.shared.startSetup()
                    }
                }
            }
        }
    }
    
    @objc private func handleLanguageChanged(_ notification: Notification) {
        if let language = notification.userInfo?["language"] as? String {
            selectedLanguage = language
            logger.info("Language changed to: \(language, privacy: .public)")
        }
    }
    
    // This method will now be called by AudioProcessingQueueService
    func addToProcessingQueue(audioURL: URL, timestamp: Date) {
        // This is now implemented in AudioProcessingQueueService
        // When AudioManager calls this, it should be redirected to AudioProcessingQueueService
        NotificationCenter.default.post(
            name: NSNotification.Name("AudioSegmentReadyForProcessing"),
            object: nil,
            userInfo: ["audioURL": audioURL, "timestamp": timestamp]
        )
    }
    
    func handleTranscriptionResult(_ transcription: String, recordingStartTime: Date?, isTemporary: Bool = false) {
        logger.debug("AudioTranscriptionService.handleTranscriptionResult called with: \"\(transcription, privacy: .public)\"")
        
        DispatchQueue.main.async {
            // If this is temporary accumulated text, store it locally
            if isTemporary {
                self.accumulatedText = transcription
            } else {
                // Otherwise forward to the result handler
                self.logger.debug("AudioTranscriptionService: Forwarding transcription to TranscriptionResultHandler")
                
                // Forward to TranscriptionResultHandler with the start time
                TranscriptionResultHandler.shared.handleTranscriptionResult(
                    transcription,
                    recordingStartTime: recordingStartTime,
                    isTemporary: false
                )
                
                // Don't clear accumulated text here - let AudioManager manage it
                // self.accumulatedText = ""
                
                self.logger.debug("AudioTranscriptionService: Successfully forwarded transcription")
            }
        }
    }
    
    func processCurrentAudioFile(at fileURL: URL, mode: RecordingMode) {
        let audioFileURL = fileURL

        logger.debug("Processing audio file...")

        Task { @MainActor in
            let manager = SpeechRecognitionManager.shared

            if useLocalSpeechModel && manager.isReady {
                // Use local transcription with selected language
                let targetLanguage: String = selectedLanguage

                manager.transcribe(audioURL: audioFileURL, language: targetLanguage) { [weak self] result in
                    guard let self = self else { return }
                    DispatchQueue.main.async {
                        switch result {
                        case .success(let transcription):
                            self.handleTranscriptionResult(transcription, recordingStartTime: Date())
                        case .failure(let error):
                            self.logger.error("Transcription error: \(error.localizedDescription)")
                        }
                        // Clean up the processed file
                        try? FileManager.default.removeItem(at: audioFileURL)
                    }
                }
            } else {
                // Use server-based transcription - implementation details moved to AudioProcessingQueueService
                self.sendAudioToBackend(fileURL: audioFileURL) {
                    try? FileManager.default.removeItem(at: audioFileURL)
                }
            }
        }
    }
    
    private func sendAudioToBackend(fileURL: URL, completion: @escaping () -> Void) {
        let url = URL(string: "http://localhost:8180/stt")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue(AppConfig.API_KEY, forHTTPHeaderField: "X-API-Key")

        let boundary = "Boundary-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var data = Data()
        data.append("\r\n--\(boundary)\r\n".data(using: .utf8)!)
        data.append("Content-Disposition: form-data; name=\"file\"; filename=\"recording.wav\"\r\n".data(using: .utf8)!)
        data.append("Content-Type: audio/wav\r\n\r\n".data(using: .utf8)!)

        do {
            let audioData = try Data(contentsOf: fileURL)
            data.append(audioData)
        } catch {
            logger.error("Error reading audio file: \(error.localizedDescription, privacy: .public)")
            completion()
            return
        }

        data.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        URLSession.shared.uploadTask(with: request, from: data) { data, response, error in
            if let error = error {
                self.logger.error("Error sending audio: \(error.localizedDescription, privacy: .public)")
                completion()
                return
            }

            if let data = data, let jsonString = String(data: data, encoding: .utf8) {
                DispatchQueue.main.async {
                    let transcription = TranscriptionUtils.extractTranscription(from: jsonString)
                    self.logger.info("Transcription received: \(transcription, privacy: .public)")

                    self.handleTranscriptionResult(transcription, recordingStartTime: Date())
                }
            }

            DispatchQueue.main.async {
                completion()
            }
        }.resume()
    }
    
    func clearAccumulatedText() {
        DispatchQueue.main.async {
            // Simply set the text to empty without animation
            self.accumulatedText = ""
        }
    }
    
    func updateAccumulatedText(_ text: String) {
        DispatchQueue.main.async {
            self.accumulatedText = text
        }
    }
} 