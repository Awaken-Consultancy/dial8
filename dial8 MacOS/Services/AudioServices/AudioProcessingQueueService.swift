import Foundation
import AVFoundation
import Combine
import os.log

class AudioProcessingQueueService: ObservableObject {
    private let logger = Logger(subsystem: "com.dial8", category: "AudioProcessingQueueService")

    // Maximum number of items allowed in the processing queue to prevent memory buildup
    static let maxQueueSize = 50

    // Processing queue for audio segments
    private var processingQueue: [(URL, Date)] = []

    // Thread-safe access to isCurrentlyProcessing
    private let processingFlagQueue = DispatchQueue(label: "com.dial8.processingFlag")
    private var _isCurrentlyProcessing = false

    // Throttling for audio processing
    private var lastProcessingTime: Date?
    private let processingThrottle: TimeInterval = 0.1

    // Dependencies
    private let audioTranscriptionService: AudioTranscriptionService

    // State
    @Published private(set) var queueLength: Int = 0

    init(audioTranscriptionService: AudioTranscriptionService) {
        self.audioTranscriptionService = audioTranscriptionService

        // Set up notification observer for audio segments ready for processing
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAudioSegmentReady),
            name: NSNotification.Name("AudioSegmentReadyForProcessing"),
            object: nil
        )
    }
    
    @objc private func handleAudioSegmentReady(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let audioURL = userInfo["audioURL"] as? URL,
              let timestamp = userInfo["timestamp"] as? Date else {
            self.logger.error("Invalid notification data for audio segment processing")
            return
        }
        
        addToProcessingQueue(audioURL: audioURL, timestamp: timestamp)
    }
    
    func addToProcessingQueue(audioURL: URL, timestamp: Date) {
        DispatchQueue.main.async {
            // Check if queue exceeds max size before adding
            if self.processingQueue.count >= Self.maxQueueSize {
                let droppedItem = self.processingQueue.removeFirst()
                self.logger.warning("Queue exceeded maximum size of \(Self.maxQueueSize). Dropping oldest item.")
                // Clean up the dropped audio file
                try? FileManager.default.removeItem(at: droppedItem.0)
            }
            self.processingQueue.append((audioURL, timestamp))
            self.queueLength = self.processingQueue.count
            self.processNextInQueue()
        }
    }
    
    func processNextInQueue() {
        // Thread-safe read of isCurrentlyProcessing
        var currentlyProcessing: Bool = false
        processingFlagQueue.sync { currentlyProcessing = _isCurrentlyProcessing }

        // If already processing or queue is empty, return
        guard !currentlyProcessing, !processingQueue.isEmpty else { return }

        // Mark as processing (thread-safe)
        processingFlagQueue.sync { _isCurrentlyProcessing = true }

        // Get next item to process
        let (audioURL, timestamp) = processingQueue.removeFirst()
        queueLength = processingQueue.count

        self.logger.debug("Processing queued audio segment...")

        // Use high-priority queue for transcription
        let useLocalSpeechModel = self.audioTranscriptionService.useLocalSpeechModel

        Task { @MainActor [weak self] in
            guard let self = self else { return }

            let manager = SpeechRecognitionManager.shared
            self.logger.info("🎤 Processing audio: useLocalSpeechModel=\(useLocalSpeechModel), manager.isReady=\(manager.isReady), selectedEngine=\(manager.selectedEngineType.rawValue)")

            if useLocalSpeechModel && manager.isReady {
                self.processWithSpeechRecognition(audioURL: audioURL, timestamp: timestamp, manager: manager)
            } else {
                self.logger.warning("🎤 Using backend fallback (model not ready or disabled)")
                self.sendAudioToBackend(fileURL: audioURL) {
                    // Clean up immediately
                    try? FileManager.default.removeItem(at: audioURL)

                    DispatchQueue.main.async {
                        self.processingFlagQueue.sync { self._isCurrentlyProcessing = false }
                        self.processNextInQueue()
                    }
                }
            }
        }
    }

    @MainActor
    private func processWithSpeechRecognition(audioURL: URL, timestamp: Date, manager: SpeechRecognitionManager) {
        let selectedLanguage = UserDefaults.standard.string(forKey: "selectedLanguage") ?? "english"

        manager.transcribe(
            audioURL: audioURL,
            language: selectedLanguage
        ) { [weak self] result in
            guard let self = self else { return }

            // Clean up immediately after getting result
            try? FileManager.default.removeItem(at: audioURL)

            DispatchQueue.main.async {
                switch result {
                case .success(let transcription):
                    self.audioTranscriptionService.handleTranscriptionResult(transcription, recordingStartTime: timestamp)
                case .failure(let error):
                    self.logger.error("Transcription error: \(error.localizedDescription)")
                }

                // Mark as done and process next
                self.processingFlagQueue.sync { self._isCurrentlyProcessing = false }
                self.processNextInQueue()
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
            self.logger.error("Error reading audio file: \(error.localizedDescription)")
            completion()
            return
        }

        data.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        URLSession.shared.uploadTask(with: request, from: data) { [weak self] data, response, error in
            guard let self = self else { 
                completion()
                return 
            }
            
            if let error = error {
                self.logger.error("Error sending audio: \(error.localizedDescription)")
                completion()
                return
            }

            if let data = data, let jsonString = String(data: data, encoding: .utf8) {
                DispatchQueue.main.async {
                    let transcription = TranscriptionUtils.extractTranscription(from: jsonString)
                    self.logger.debug("Transcription received: \(transcription, privacy: .private)")

                    self.audioTranscriptionService.handleTranscriptionResult(transcription, recordingStartTime: Date())
                }
            }

            DispatchQueue.main.async {
                completion()
            }
        }.resume()
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
} 
