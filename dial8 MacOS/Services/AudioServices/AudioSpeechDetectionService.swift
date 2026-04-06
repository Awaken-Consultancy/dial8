import Foundation
import AVFoundation
import Combine

class AudioSpeechDetectionService: ObservableObject {
    @Published private(set) var isSpeechDetected = false
    @Published private(set) var lastSpeechDetectedTime: Date?
    @Published private(set) var isProcessingSpeech = false
    
    private let speechRecognizer = AppleSpeechRecognizer.shared
    private let audioTranscriptionService = AudioTranscriptionService.shared
    
    private var currentRecordingMode: RecordingMode?
    
    var onSpeechDetected: (() -> Void)?
    var onSilenceDetected: (() -> Void)?
    
    init() {
        setupSpeechRecognition()
    }
    
    func setRecordingMode(_ mode: RecordingMode?) {
        self.currentRecordingMode = mode
        speechRecognizer.setRecordingMode(mode)
    }
    
    private func setupSpeechRecognition() {
        speechRecognizer.onSpeechDetected = { [weak self] in
            guard let self = self else { return }
            
            let now = Date()
            let detectionId = String(Int.random(in: 1000...9999))
            
            print("🗣️ [ID:\(detectionId)] Speech detected at \(DateFormatter.localizedString(from: now, dateStyle: .none, timeStyle: .medium))")
            
            let bufferTime = -3.0
            self.lastSpeechDetectedTime = now.addingTimeInterval(bufferTime)
            print("📊 [ID:\(detectionId)] Updated speech detection timestamp with \(abs(bufferTime))s buffer")
            
            self.isProcessingSpeech = true
            DispatchQueue.main.async {
                self.isSpeechDetected = true
                self.onSpeechDetected?()
            }
        }
        
        speechRecognizer.onSilenceDetected = { [weak self] in
            guard let self = self else { return }
            print("🤫 Silence detected")
            DispatchQueue.main.async {
                self.isSpeechDetected = false
            }
            
            TranscriptionResultHandler.shared.handleSilenceDetected()
            self.onSilenceDetected?()
            self.isProcessingSpeech = false
        }
    }
    
    func startSpeechDetection(with engine: AVAudioEngine) {
        self.lastSpeechDetectedTime = nil
        self.isProcessingSpeech = false
        
        DispatchQueue.main.async {
            self.isSpeechDetected = false
        }
        
        print("🎤 Starting speech detection")
        speechRecognizer.startListening(with: engine)
    }
    
    func processAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        speechRecognizer.appendAudioBuffer(buffer)
    }
    
    func stopSpeechDetection() {
        print("🛑 Stopping speech detection")
        speechRecognizer.stopListening()
        
        self.lastSpeechDetectedTime = nil
        self.isProcessingSpeech = false
        
        DispatchQueue.main.async {
            self.isSpeechDetected = false
        }
    }
    
    func hasSpeechBeenDetectedRecently(threshold: TimeInterval = 3.0) -> Bool {
        guard let lastSpeechTime = lastSpeechDetectedTime else {
            return false
        }
        
        let timeSinceLastSpeech = Date().timeIntervalSince(lastSpeechTime)
        return timeSinceLastSpeech < threshold
    }
    
    func getLastSpeechTime() -> Date? {
        return lastSpeechDetectedTime
    }
    
    deinit {
        speechRecognizer.stopListening()
    }
}
